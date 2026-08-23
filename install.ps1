param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/mcakici/psbi-dist/main/latest.json",
    [string]$InstallRoot = "$env:ProgramData\PSBI",
    [ValidateSet("Manual", "Dedicated")][string]$ExtensionMode = "Manual"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ($InstallRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\') -or $InstallRoot.TrimEnd('\') -eq $env:ProgramData.TrimEnd('\')) {
    throw "InstallRoot güvenli bir alt klasör olmalıdır."
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Step([string]$Name, [scriptblock]$Body) {
    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Body
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "PSBI kurulumu için PowerShell'i Yönetici olarak açın ve komutu yeniden çalıştırın."
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

function Find-GatewayPort {
    foreach ($port in 37641..37650) {
        $listener = $null
        try {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        } catch {} finally { if ($listener) { $listener.Stop() } }
    }
    throw "37641-37650 aralığında boş gateway portu bulunamadı."
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
    throw "ManifestUrl yapılandırılmamış. Release workflow placeholder'ı latest.json URL'siyle değiştirmelidir."
}

Step "Windows / Docker preflight" {
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 veya üzeri gerekli." }
    & docker version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker daemon çalışmıyor. Docker Desktop'ı başlatın." }
    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose v2 gerekli." }
}

New-Item -ItemType Directory -Force -Path $InstallRoot, (Join-Path $InstallRoot "state"), (Join-Path $InstallRoot "backups") | Out-Null
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("psbi-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $Temp | Out-Null

try {
    Step "Release manifest" { $script:manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl }
    if (-not $manifest.version -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$' -or -not $manifest.runtime.url -or -not $manifest.runtime.sha256 -or -not $manifest.agent.url -or -not $manifest.agent.sha256 -or -not $manifest.extension.url -or -not $manifest.extension.sha256) { throw "Release manifest eksik veya geçersiz." }
    if ([string]$manifest.images.app -notmatch '^[a-zA-Z0-9._/@:-]+$' -or [string]$manifest.images.console -notmatch '^[a-zA-Z0-9._/@:-]+$') { throw "Release manifest image referansı geçersiz." }

    Step "Release dosyaları" {
        Save-RemoteFile ([string]$manifest.runtime.url) (Join-Path $Temp "runtime.zip") ([string]$manifest.runtime.sha256)
        Save-RemoteFile ([string]$manifest.extension.url) (Join-Path $Temp "extension.zip") ([string]$manifest.extension.sha256)
        Save-RemoteFile ([string]$manifest.agent.url) (Join-Path $Temp "psbi-agent.exe") ([string]$manifest.agent.sha256)
        Expand-Archive -Force -LiteralPath (Join-Path $Temp "runtime.zip") -DestinationPath (Join-Path $Temp "runtime")
        Expand-Archive -Force -LiteralPath (Join-Path $Temp "extension.zip") -DestinationPath (Join-Path $Temp "extension")
    }

    Step "Runtime configuration" {
        foreach ($name in @("compose.yaml", "nginx.conf", "update.ps1")) {
            Copy-Item -Force -LiteralPath (Join-Path $Temp ("runtime\" + $name)) -Destination (Join-Path $InstallRoot $name)
        }
        Copy-Item -Force -LiteralPath (Join-Path $Temp "psbi-agent.exe") -Destination (Join-Path $InstallRoot "psbi-agent.exe")
        $extensionPath = Join-Path $InstallRoot "extension"
        if (Test-Path -LiteralPath $extensionPath) { Remove-Item -Recurse -Force -LiteralPath $extensionPath }
        Move-Item -LiteralPath (Join-Path $Temp "extension") -Destination $extensionPath

        $script:gatewayPort = Find-GatewayPort
        $dbSecret = (New-RandomSecret 24) -replace '[^a-zA-Z0-9]', ''
        $appKey = "base64:" + (New-RandomSecret 32)
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
SESSION_DRIVER=database
CACHE_STORE=redis
BROADCAST_CONNECTION=log
PSBI_CONTROL_AUTH=false
PSBI_OLLAMA_URL=http://ollama:11434
PSBI_EMBEDDING_PROVIDER=ollama
PSBI_EMBEDDING_MODEL=qwen3-embedding:0.6b
PSBI_EMBEDDING_DIMENSIONS=1024
"@
        Write-Utf8NoBom (Join-Path $InstallRoot ".env") ($envContent.Trim() + [Environment]::NewLine)
        Write-Utf8NoBom (Join-Path $InstallRoot "config.json") (@{ manifestUrl = $ManifestUrl; installRoot = $InstallRoot } | ConvertTo-Json)
    }

    Step "PSBI Agent Windows Service" {
        $existing = Get-Service -Name PSBIAgent -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-Service -Name PSBIAgent -Force -ErrorAction SilentlyContinue
            & sc.exe delete PSBIAgent | Out-Null
            Start-Sleep -Seconds 1
        }
        New-Service -Name PSBIAgent -BinaryPathName ('"' + (Join-Path $InstallRoot "psbi-agent.exe") + '"') -DisplayName "PSBI Update Agent" -StartupType Automatic | Out-Null
        Start-Service -Name PSBIAgent
    }

    Step "Docker Compose pull/up" {
        Push-Location $InstallRoot
        try {
            & docker compose --env-file .env -f compose.yaml pull
            if ($LASTEXITCODE -ne 0) { throw "docker compose pull başarısız." }
            & docker compose --env-file .env -f compose.yaml up -d --remove-orphans --wait
            if ($LASTEXITCODE -ne 0) { throw "docker compose up başarısız." }
        } finally { Pop-Location }
    }

    Write-Utf8NoBom (Join-Path $InstallRoot "state\current-release.json") (@{ version = [string]$manifest.version; extensionVersion = [string]$manifest.extension.version; manifestUrl = $ManifestUrl; updatedAt = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json)

    Step "Chrome extension" {
        $chrome = Find-Chrome
        $extensionPath = Join-Path $InstallRoot "extension"
        if (-not $chrome) {
            Write-Warning "Chrome/Edge bulunamadı. Extension klasörü: $extensionPath"
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
            Write-Host "Developer mode > Load unpacked ile şu klasörü bir kez seçin: $extensionPath" -ForegroundColor Yellow
        }
    }

    Write-Host "PSBI $($manifest.version) hazır: http://127.0.0.1:$gatewayPort" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $Temp) { Remove-Item -Recurse -Force -LiteralPath $Temp }
}
