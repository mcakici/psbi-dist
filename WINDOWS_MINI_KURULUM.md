# PSBI Windows Mini Kurulum

Bu rehber, PSBI uygulamasını ve Chrome/Edge extension'ını Windows üzerinde public dağıtım kanalından kurmak için gereken kısa adımları içerir. Kaynak kod deposuna erişim gerekmez.

## Gereksinimler

- Windows 10/11 x64
- Çalışır durumda Docker Desktop ve Docker Compose v2
- Chrome veya Microsoft Edge
- Yönetici yetkisi
- `github.com`, `raw.githubusercontent.com` ve `ghcr.io` adreslerine internet erişimi

İlk kurulumda Docker imajları indirileceği için işlem bağlantı hızına göre birkaç dakika sürebilir.

## 1. Kurulumu başlatın

PowerShell'i **Yönetici olarak çalıştır** seçeneğiyle açın ve aşağıdaki komutları çalıştırın:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$installer = Join-Path $env:TEMP "psbi-install.ps1"
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/mcakici/psbi-dist/main/install.ps1" -OutFile $installer
Unblock-File -LiteralPath $installer
& $installer
```

Kurulum betiği otomatik olarak:

- güncel sürüm manifestini okur;
- paketleri indirip SHA-256 değerlerini doğrular;
- PSBI Docker servislerini kurup başlatır;
- `PSBIAgent` Windows servisini kurar;
- extension dosyalarını `C:\ProgramData\PSBI\extension` klasörüne çıkarır;
- uygun ilk boş yerel portu seçer (`37641-37650`).

Kurulum tamamlandığında uygulama adresi PowerShell ekranında gösterilir. İlk port boşsa adres genellikle:

```text
http://127.0.0.1:37641
```

## 2. Extension'ı bir kez yükleyin

Normal Chrome/Edge profilinde ilk kurulum bir kez manuel tamamlanır:

1. Chrome için `chrome://extensions`, Edge için `edge://extensions` adresini açın.
2. **Geliştirici modu** seçeneğini etkinleştirin.
3. **Paketlenmemiş öğe yükle** düğmesine basın.
4. `C:\ProgramData\PSBI\extension` klasörünü seçin.
5. PSBI extension'ını araç çubuğuna sabitleyin.

Sonraki uygulama güncellemeleri aynı extension klasörünü yerinde yeniler ve yüklü unpacked extension kendini yeniden yükler. Klasörü tekrar seçmeniz gerekmez; chrome://extensions üzerinde bir kez Load unpacked yeterlidir.

## Ayrı PSBI tarayıcı profili kullanma

Normal tarayıcı profilinden ayrı bir PSBI profili ve masaüstü kısayolu oluşturmak için installer'ı şu şekilde çalıştırabilirsiniz:

```powershell
& $installer -ExtensionMode Dedicated
```

## Güncelleme

Extension içinde **Ayarlar → Uygulama güncellemesi → Güncellemeleri denetle** yolunu kullanın. Yeni sürüm varsa `PSBIAgent` public `latest.json` manifestini okuyarak uygulamayı, Docker imajlarını ve extension klasörünü günceller.

Güncelleme kanalı:

- Manifest: <https://raw.githubusercontent.com/mcakici/psbi-dist/main/latest.json>
- Yayınlar: <https://github.com/mcakici/psbi-dist/releases/latest>

## Hızlı kontrol

Kurulumla ilgili sorun yaşarsanız Yönetici PowerShell'de şu kontrolleri çalıştırın:

```powershell
docker version
docker compose version
Get-Service PSBIAgent
```

`PSBIAgent` duruyorsa:

```powershell
Start-Service PSBIAgent
```

Docker Desktop'ın çalıştığından emin olduktan sonra uygulama adresini yeniden açın.

