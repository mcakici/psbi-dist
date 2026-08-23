param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/mcakici/psbi-dist/main/latest.json",
    [string]$InstallRoot = "$env:ProgramData\PSBI",
    [ValidateSet("Manual", "Dedicated")][string]$ExtensionMode = "Manual"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ($InstallRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\') -or $InstallRoot.TrimEnd('\') -eq $env:ProgramData.TrimEnd('\')) {
    throw "InstallRoot must be a safe subdirectory."
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-EnvValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $prefix = $Name + "="
    $line = Get-Content -LiteralPath $Path | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return $line.Substring($prefix.Length)
}

function Step([string]$Name, [scriptblock]$Body) {
    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Body
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Open PowerShell as Administrator and run the PSBI installer again."
    }
}

function Stop-ExistingAgent {
    $existing = Get-Service -Name PSBIAgent -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-Service -Name PSBIAgent -Force -ErrorAction SilentlyContinue
        try { $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15)) } catch {}
    }

    $agentProcesses = @(Get-Process -Name "psbi-agent" -ErrorAction SilentlyContinue)
    if ($agentProcesses.Count -gt 0) {
        $agentProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        $agentProcesses | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }

    if ($existing) {
        & sc.exe delete PSBIAgent | Out-Null
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            if (-not (Get-Service -Name PSBIAgent -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        if (Get-Service -Name PSBIAgent -ErrorAction SilentlyContinue) {
            throw "The existing PSBI Agent service could not be removed."
        }
    }
}

function Save-RemoteFile([string]$Url, [string]$Destination, [string]$ExpectedSha256) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    if ($ExpectedSha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "SHA-256 mismatch: $Url" }
    }
}

function New-RandomSecret([int]$Bytes = 32) {
    $buffer = [byte[]]::new($Bytes)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($buffer)
}

function Test-LaravelAppKey([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        if ($Value.StartsWith("base64:", [StringComparison]::Ordinal)) {
            return ([Convert]::FromBase64String($Value.Substring(7)).Length -eq 32)
        }
        return ([Text.Encoding]::UTF8.GetByteCount($Value) -eq 32)
    } catch {
        return $false
    }
}

function Get-RequiredOllamaModels($Manifest) {
    $models = @()
    if ($null -ne $Manifest.models -and $null -ne $Manifest.models.required) {
        foreach ($model in @($Manifest.models.required)) {
            $value = ([string]$model).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { $models += $value }
        }
    }
    if ($models.Count -eq 0) { $models = @("qwen3-embedding:0.6b") }
    foreach ($model in $models) {
        if ($model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$') { throw "The release manifest contains an invalid Ollama model name." }
    }
    return $models
}

function Find-GatewayPort {
    foreach ($port in 37641..37650) {
        $listener = $null
        try {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        } catch {} finally { if ($listener) { $listener.Stop() } }
    }
    throw "No available gateway port was found in the 37641-37650 range."
}

function Find-Chrome {
    @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

Assert-Administrator
if (-not ($ManifestUrl -match '^https?://') -or $ManifestUrl.Contains('__PSBI_')) {
    throw "ManifestUrl is not configured. The release workflow must replace the placeholder with the latest.json URL."
}

Step "Windows / Docker preflight" {
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or later is required." }
    & docker version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The Docker daemon is not running. Start Docker Desktop and try again." }
    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose v2 is required." }
}

New-Item -ItemType Directory -Force -Path $InstallRoot, (Join-Path $InstallRoot "state"), (Join-Path $InstallRoot "backups") | Out-Null
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("psbi-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $Temp | Out-Null

try {
    Step "Release manifest" { $script:manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl }
    if (-not $manifest.version -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$' -or -not $manifest.runtime.url -or -not $manifest.runtime.sha256 -or -not $manifest.agent.url -or -not $manifest.agent.sha256 -or -not $manifest.extension.url -or -not $manifest.extension.sha256) { throw "The release manifest is missing required fields or is invalid." }
    if ([string]$manifest.images.app -notmatch '^[a-zA-Z0-9._/@:-]+$' -or [string]$manifest.images.console -notmatch '^[a-zA-Z0-9._/@:-]+$') { throw "The release manifest contains an invalid image reference." }
    $requiredOllamaModels = @(Get-RequiredOllamaModels $manifest)

    Step "Release files" {
        Save-RemoteFile ([string]$manifest.runtime.url) (Join-Path $Temp "runtime.zip") ([string]$manifest.runtime.sha256)
        Save-RemoteFile ([string]$manifest.extension.url) (Join-Path $Temp "extension.zip") ([string]$manifest.extension.sha256)
        Save-RemoteFile ([string]$manifest.agent.url) (Join-Path $Temp "psbi-agent.exe") ([string]$manifest.agent.sha256)
        Expand-Archive -Force -LiteralPath (Join-Path $Temp "runtime.zip") -DestinationPath (Join-Path $Temp "runtime")
        Expand-Archive -Force -LiteralPath (Join-Path $Temp "extension.zip") -DestinationPath (Join-Path $Temp "extension")
    }

    Step "Stop existing PSBI Agent" { Stop-ExistingAgent }

    Step "Runtime configuration" {
        foreach ($name in @("compose.yaml", "nginx.conf", "update.ps1")) {
            Copy-Item -Force -LiteralPath (Join-Path $Temp ("runtime\" + $name)) -Destination (Join-Path $InstallRoot $name)
        }
        Copy-Item -Force -LiteralPath (Join-Path $Temp "psbi-agent.exe") -Destination (Join-Path $InstallRoot "psbi-agent.exe")
        $extensionPath = Join-Path $InstallRoot "extension"
        if (Test-Path -LiteralPath $extensionPath) { Remove-Item -Recurse -Force -LiteralPath $extensionPath }
        Move-Item -LiteralPath (Join-Path $Temp "extension") -Destination $extensionPath

        $envPath = Join-Path $InstallRoot ".env"
        $existingGatewayPort = Get-EnvValue $envPath "PSBI_GATEWAY_PORT"
        if ($existingGatewayPort -match '^\d+$' -and [int]$existingGatewayPort -ge 37641 -and [int]$existingGatewayPort -le 37650) {
            $script:gatewayPort = [int]$existingGatewayPort
        } else {
            $script:gatewayPort = Find-GatewayPort
        }

        $dbSecret = Get-EnvValue $envPath "DB_PASSWORD"
        if ([string]::IsNullOrWhiteSpace($dbSecret)) { $dbSecret = (New-RandomSecret 24) -replace '[^a-zA-Z0-9]', '' }
        $appKey = Get-EnvValue $envPath "APP_KEY"
        if (-not (Test-LaravelAppKey $appKey)) {
            if (-not [string]::IsNullOrWhiteSpace($appKey)) { Write-Warning "The existing APP_KEY is invalid and will be replaced." }
            $appKey = "base64:" + (New-RandomSecret 32)
        }
        $embeddingModel = Get-EnvValue $envPath "PSBI_EMBEDDING_MODEL"
        if ([string]::IsNullOrWhiteSpace($embeddingModel)) { $embeddingModel = "qwen3-embedding:0.6b" }
        if ($embeddingModel -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$') { throw "The configured embedding model name is invalid." }
        $embeddingDimensions = Get-EnvValue $envPath "PSBI_EMBEDDING_DIMENSIONS"
        if ($embeddingDimensions -notmatch '^\d+$' -or [int]$embeddingDimensions -lt 1 -or [int]$embeddingDimensions -gt 65536) { $embeddingDimensions = "1024" }
        $llmModel = Get-EnvValue $envPath "PSBI_LLM_MODEL"
        if (-not [string]::IsNullOrWhiteSpace($llmModel) -and $llmModel -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$') { throw "The configured LLM model name is invalid." }
        $requiredOllamaModelsValue = $requiredOllamaModels -join ','
        $envContent = @"
APP_NAME=PSBI
APP_ENV=production
APP_DEBUG=false
APP_KEY=$appKey
APP_URL=http://127.0.0.1:$gatewayPort
ASSET_URL=http://127.0.0.1:$gatewayPort
PSBI_VERSION=$($manifest.version)
PSBI_MIN_EXTENSION_VERSION=$($manifest.extension.version)
PSBI_GATEWAY_PORT=$gatewayPort
PSBI_APP_IMAGE=$($manifest.images.app)
PSBI_CONSOLE_IMAGE=$($manifest.images.console)
PSBI_RELEASE_MANIFEST_URL=$ManifestUrl
PSBI_AGENT_HOST=host.docker.internal
PSBI_AGENT_PORT=7300
DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_DATABASE=psbi
DB_USERNAME=psbi
DB_PASSWORD=$dbSecret
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_CLIENT=predis
QUEUE_CONNECTION=redis
REDIS_QUEUE_RETRY_AFTER=660
REDIS_MODEL_QUEUE_RETRY_AFTER=604800
SESSION_DRIVER=database
CACHE_STORE=redis
PSBI_REQUIRE_REDIS=true
BROADCAST_CONNECTION=log
PSBI_CONTROL_AUTH=false
PSBI_OLLAMA_URL=http://ollama:11434
PSBI_REQUIRED_OLLAMA_MODELS=$requiredOllamaModelsValue
PSBI_EMBEDDING_PROVIDER=ollama
PSBI_EMBEDDING_MODEL=$embeddingModel
PSBI_EMBEDDING_DIMENSIONS=$embeddingDimensions
PSBI_LLM_MODEL=$llmModel
"@
        Write-Utf8NoBom (Join-Path $InstallRoot ".env") ($envContent.Trim() + [Environment]::NewLine)
        Write-Utf8NoBom (Join-Path $InstallRoot "config.json") (@{ manifestUrl = $ManifestUrl; installRoot = $InstallRoot } | ConvertTo-Json)
    }

    Step "PSBI Agent Windows Service" {
        New-Service -Name PSBIAgent -BinaryPathName ('"' + (Join-Path $InstallRoot "psbi-agent.exe") + '"') -DisplayName "PSBI Update Agent" -StartupType Automatic | Out-Null
        Start-Service -Name PSBIAgent
    }

    Step "Docker Compose pull" {
        Push-Location $InstallRoot
        try {
            & docker compose --env-file .env -f compose.yaml pull
            if ($LASTEXITCODE -ne 0) { throw "docker compose pull failed." }
        } finally { Pop-Location }
    }

    Step "PostgreSQL credentials" {
        Push-Location $InstallRoot
        try {
            & docker compose --env-file .env -f compose.yaml stop app worker scheduler reverb gateway | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Existing application containers could not be stopped." }
            & docker compose --env-file .env -f compose.yaml up -d --wait postgres redis
            if ($LASTEXITCODE -ne 0) { throw "PostgreSQL or Redis failed to start." }

            $dbUser = Get-EnvValue (Join-Path $InstallRoot ".env") "DB_USERNAME"
            $dbName = Get-EnvValue (Join-Path $InstallRoot ".env") "DB_DATABASE"
            $dbPassword = Get-EnvValue (Join-Path $InstallRoot ".env") "DB_PASSWORD"
            if ($dbUser -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$' -or $dbName -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$' -or [string]::IsNullOrWhiteSpace($dbPassword)) {
                throw "Database credentials in .env are invalid."
            }
            $escapedDbUser = $dbUser.Replace('"', '""')
            $escapedDbPassword = $dbPassword.Replace("'", "''")
            $sql = "ALTER ROLE `"$escapedDbUser`" WITH PASSWORD '$escapedDbPassword';"
            $sql | & docker compose --env-file .env -f compose.yaml exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -U $dbUser -d $dbName
            if ($LASTEXITCODE -ne 0) { throw "PostgreSQL credentials could not be synchronized." }
        } finally { Pop-Location }
    }

    Step "Docker Compose up" {
        Push-Location $InstallRoot
        try {
            & docker compose --env-file .env -f compose.yaml up -d --remove-orphans --wait app worker model-worker ollama scheduler reverb postgres redis gateway console
            if ($LASTEXITCODE -ne 0) { throw "docker compose up failed." }
        } finally { Pop-Location }
    }

    Step "Queue required Ollama models" {
        Push-Location $InstallRoot
        try {
            & docker compose --env-file .env -f compose.yaml exec -T app php artisan psbi:models:ensure
            if ($LASTEXITCODE -ne 0) { throw "Required Ollama models could not be queued." }
        } finally { Pop-Location }
    }

    Write-Utf8NoBom (Join-Path $InstallRoot "state\current-release.json") (@{ version = [string]$manifest.version; extensionVersion = [string]$manifest.extension.version; manifestUrl = $ManifestUrl; updatedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json)

    Step "Chrome extension" {
        $chrome = Find-Chrome
        $extensionPath = Join-Path $InstallRoot "extension"
        if (-not $chrome) {
            Write-Warning "Chrome or Edge was not found. Extension directory: $extensionPath"
        } elseif ($ExtensionMode -eq "Dedicated") {
            $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "PSBI Browser.lnk"
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $chrome
            $shortcut.Arguments = "--user-data-dir=`"$env:LOCALAPPDATA\PSBI\ChromeProfile`" --load-extension=`"$extensionPath`""
            $shortcut.WorkingDirectory = Split-Path -Parent $chrome
            $shortcut.Save()
            Start-Process -FilePath $shortcutPath
        } else {
            Start-Process explorer.exe -ArgumentList "/select,`"$extensionPath\manifest.json`""
            Start-Process -FilePath $chrome -ArgumentList "chrome://extensions"
            Write-Host "In Developer mode, choose Load unpacked and select this directory once: $extensionPath" -ForegroundColor Yellow
        }
    }

    Write-Host "PSBI $($manifest.version) is ready: http://127.0.0.1:$gatewayPort" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $Temp) { Remove-Item -Recurse -Force -LiteralPath $Temp }
}
