# setup-apple-usb.ps1 - Apple USB Driver auto-setup (no iTunes installation needed)
# Downloads iTunes, extracts ONLY the USB driver + service, sets up for USB tunneling
# Requires: One-time admin elevation for driver installation
#
# Usage: powershell -ExecutionPolicy Bypass -File setup-apple-usb.ps1

param(
    [string]$iTunesExe = "",          # Path to iTunes64Setup.exe if already downloaded
    [string]$InstallDir = "",          # Where to put extracted files (default: ~\.apple-usb)
    [switch]$DriverOnly,               # Only install driver, skip service setup
    [switch]$Uninstall                 # Remove everything
)

$ErrorActionPreference = "Stop"

# Default install directory
if (-not $InstallDir) {
    $InstallDir = "$env:USERPROFILE\.apple-usb"
}

$driverDir = "$InstallDir\driver"
$serviceDir = "$InstallDir\service"
$extractDir = "$InstallDir\_extract"
$iTunesUrl = "https://www.apple.com/itunes/download/win64"

function Write-Step($step, $msg) {
    Write-Host ""
    Write-Host "[$step] $msg" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkGray
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# === Uninstall mode ===
if ($Uninstall) {
    Write-Host "=== Removing Apple USB Setup ===" -ForegroundColor Yellow

    # Stop and remove service
    $svc = Get-Service -Name "AppleMobileDeviceService" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Stopping service..."
        Stop-Service "AppleMobileDeviceService" -Force -ErrorAction SilentlyContinue
        sc.exe delete "AppleMobileDeviceService" | Out-Null
        Write-Host "Service removed."
    }

    # Remove driver (needs admin)
    if (Test-Admin) {
        $oem = pnputil /enum-drivers | Select-String -Pattern "usbaapl" -Context 5
        if ($oem) {
            Write-Host "Removing USB driver..."
            # Find OEM inf name
            $lines = pnputil /enum-drivers
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "usbaapl") {
                    for ($j = $i; $j -ge 0; $j--) {
                        if ($lines[$j] -match "(oem\d+\.inf)") {
                            pnputil /delete-driver $matches[1] /force
                            break
                        }
                    }
                    break
                }
            }
        }
    } else {
        Write-Host "Run as admin to remove USB driver" -ForegroundColor Yellow
    }

    # Remove files
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Host "Files removed: $InstallDir"
    }

    Write-Host "Done!" -ForegroundColor Green
    exit 0
}

# === Main Setup ===
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Apple USB Driver Setup (iTunes not needed)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Install dir: $InstallDir"
Write-Host ""

# Check if already set up
$alreadySetup = $false
if (Test-Path "$driverDir\usbaapl64.inf") {
    Write-Host "Driver files already extracted." -ForegroundColor Green
    $alreadySetup = $true
}

# Check if service is already running
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect("127.0.0.1", 27015)
    $testConn.Close()
    Write-Host ""
    Write-Host "Apple Mobile Device Service is ALREADY RUNNING on port 27015!" -ForegroundColor Green
    Write-Host "You can use usb-tunnel.ps1 directly." -ForegroundColor Green
    Write-Host ""

    $continue = Read-Host "Continue with setup anyway? (y/N)"
    if ($continue -ne "y") { exit 0 }
} catch {
    # Not running, proceed with setup
}

# ============================================================
# Step 1: Get iTunes installer
# ============================================================
Write-Step "1/5" "Getting iTunes installer"

if (-not (Test-Path "$InstallDir")) {
    New-Item -ItemType Directory -Path "$InstallDir" -Force | Out-Null
}

$iTunesLocal = "$InstallDir\iTunes64Setup.exe"

if ($iTunesExe -and (Test-Path $iTunesExe)) {
    Write-Host "Using provided: $iTunesExe"
    $iTunesLocal = $iTunesExe
} elseif (Test-Path $iTunesLocal) {
    Write-Host "Using cached: $iTunesLocal"
} else {
    Write-Host "Downloading iTunes installer..."
    Write-Host "URL: $iTunesUrl"
    Write-Host "(Only the USB driver will be extracted, iTunes will NOT be installed)"
    Write-Host ""

    try {
        # Use BITS for reliable download with progress
        $job = Start-BitsTransfer -Source $iTunesUrl -Destination $iTunesLocal -Description "Downloading iTunes (for USB driver extraction)" -ErrorAction Stop
        Write-Host "Download complete: $iTunesLocal" -ForegroundColor Green
    } catch {
        # Fallback to WebClient
        Write-Host "BITS failed, trying WebClient..."
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($iTunesUrl, $iTunesLocal)
            Write-Host "Download complete." -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Auto-download failed." -ForegroundColor Red
            Write-Host ""
            Write-Host "Please download manually:" -ForegroundColor Yellow
            Write-Host "  1. Open browser: https://support.apple.com/en-us/106372" -ForegroundColor Yellow
            Write-Host "  2. Download 'iTunes for Windows (64-bit)'" -ForegroundColor Yellow
            Write-Host "  3. Save to: $iTunesLocal" -ForegroundColor Yellow
            Write-Host "  4. Re-run this script" -ForegroundColor Yellow
            exit 1
        }
    }
}

# ============================================================
# Step 2: Extract MSI files from iTunes installer
# ============================================================
Write-Step "2/5" "Extracting MSI files from iTunes"

if (Test-Path $extractDir) {
    Remove-Item -Path $extractDir -Recurse -Force
}
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

Write-Host "Running: iTunes64Setup.exe /extract ..."
$proc = Start-Process -FilePath $iTunesLocal -ArgumentList "/extract `"$extractDir`"" -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    Write-Host "Extract via /extract failed, trying alternative method..."
    # Some versions need different extraction
    # Try running with /passive to let it extract without installing
    Write-Host "Please extract manually using 7-Zip if available" -ForegroundColor Yellow
}

# Find the Apple Mobile Device Support MSI
$amds_msi = Get-ChildItem -Path $extractDir -Filter "AppleMobileDeviceSupport*.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $amds_msi) {
    # Also check for different naming
    $amds_msi = Get-ChildItem -Path $extractDir -Filter "*MobileDevice*.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}

if (-not $amds_msi) {
    Write-Host "ERROR: AppleMobileDeviceSupport MSI not found in extracted files" -ForegroundColor Red
    Write-Host "Contents of extract dir:"
    Get-ChildItem $extractDir | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host "Found: $($amds_msi.Name)" -ForegroundColor Green

# ============================================================
# Step 3: Extract driver and service files from MSI
# ============================================================
Write-Step "3/5" "Extracting driver and service files"

$msiExtract = "$InstallDir\_msi"
if (Test-Path $msiExtract) {
    Remove-Item -Path $msiExtract -Recurse -Force
}
New-Item -ItemType Directory -Path $msiExtract -Force | Out-Null

Write-Host "Extracting MSI contents (no installation)..."
$msiProc = Start-Process -FilePath "msiexec" -ArgumentList "/a `"$($amds_msi.FullName)`" TARGETDIR=`"$msiExtract`" /qn" -Wait -PassThru -NoNewWindow
Write-Host "MSI extraction done."

# Find and copy driver files
if (-not (Test-Path $driverDir)) {
    New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
}
if (-not (Test-Path $serviceDir)) {
    New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null
}

# Search for driver files
Write-Host "Searching for driver files..."
$driverFiles = @("usbaapl64.sys", "usbaapl64.inf", "usbaapl64.cat")
foreach ($df in $driverFiles) {
    $found = Get-ChildItem -Path $msiExtract -Filter $df -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        Copy-Item -Path $found.FullName -Destination "$driverDir\$df" -Force
        Write-Host "  Found: $df" -ForegroundColor Green
    } else {
        Write-Host "  NOT FOUND: $df" -ForegroundColor Red
    }
}

# Search for service files
Write-Host "Searching for service files..."
$serviceFiles = @(
    "AppleMobileDeviceService.exe",
    "MobileDevice.dll", "MobileDevice64.dll",
    "CoreFoundation.dll", "CFNetwork.dll",
    "objc.dll", "libdispatch.dll",
    "icuin*.dll", "icuuc*.dll", "icudt*.dll"
)
$allDlls = Get-ChildItem -Path $msiExtract -Filter "*.dll" -Recurse -ErrorAction SilentlyContinue
$allExes = Get-ChildItem -Path $msiExtract -Filter "AppleMobileDeviceService.exe" -Recurse -ErrorAction SilentlyContinue

# Copy service exe
foreach ($exe in $allExes) {
    Copy-Item -Path $exe.FullName -Destination "$serviceDir\" -Force
    Write-Host "  Found: $($exe.Name)" -ForegroundColor Green
}

# Copy all DLLs from Apple directories (service needs many of them)
$appleDirs = Get-ChildItem -Path $msiExtract -Directory -Recurse | Where-Object {
    $_.FullName -match "Apple|Mobile Device|Application Support"
}
foreach ($dir in $appleDirs) {
    $dlls = Get-ChildItem -Path $dir.FullName -Filter "*.dll" -ErrorAction SilentlyContinue
    foreach ($dll in $dlls) {
        Copy-Item -Path $dll.FullName -Destination "$serviceDir\" -Force -ErrorAction SilentlyContinue
    }
}
$dllCount = (Get-ChildItem -Path $serviceDir -Filter "*.dll").Count
Write-Host "  Copied $dllCount DLLs to service directory" -ForegroundColor Green

# ============================================================
# Step 4: Install USB driver
# ============================================================
Write-Step "4/5" "Installing USB driver"

if (-not (Test-Path "$driverDir\usbaapl64.inf")) {
    Write-Host "ERROR: Driver files not found!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Admin)) {
    Write-Host "Admin elevation required for USB driver installation." -ForegroundColor Yellow
    Write-Host "Launching elevated prompt..." -ForegroundColor Yellow

    # Create a small script for elevated execution
    $elevatedScript = @"
Write-Host 'Installing Apple USB driver...'
pnputil /add-driver "$driverDir\usbaapl64.inf" /install
Write-Host ''
Write-Host 'Driver installation complete. Press Enter to close.'
Read-Host
"@
    $elevatedScriptPath = "$InstallDir\_install-driver.ps1"
    $elevatedScript | Out-File -FilePath $elevatedScriptPath -Encoding UTF8

    Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File `"$elevatedScriptPath`"" -Verb RunAs -Wait
    Write-Host "Driver installation attempted." -ForegroundColor Green
} else {
    Write-Host "Running as admin, installing driver..."
    pnputil /add-driver "$driverDir\usbaapl64.inf" /install
    Write-Host "Driver installed." -ForegroundColor Green
}

# ============================================================
# Step 5: Register and start Apple Mobile Device Service
# ============================================================
Write-Step "5/5" "Setting up Apple Mobile Device Service"

$serviceExe = "$serviceDir\AppleMobileDeviceService.exe"

if (-not (Test-Path $serviceExe)) {
    Write-Host "WARNING: AppleMobileDeviceService.exe not found" -ForegroundColor Yellow
    Write-Host "USB driver is installed but service may not start." -ForegroundColor Yellow
    Write-Host "Try connecting iPad and checking Device Manager." -ForegroundColor Yellow
} else {
    # Check if service already exists
    $existingSvc = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
    if (-not $existingSvc) {
        Write-Host "Registering Apple Mobile Device Service..."

        if (-not (Test-Admin)) {
            $elevatedScript2 = @"
# Register service
sc.exe create "Apple Mobile Device Service" binPath= "`"$serviceExe`"" start= demand DisplayName= "Apple Mobile Device Service (Portable)"
sc.exe start "Apple Mobile Device Service"
Write-Host 'Service registered and started. Press Enter to close.'
Read-Host
"@
            $elevatedScript2Path = "$InstallDir\_start-service.ps1"
            $elevatedScript2 | Out-File -FilePath $elevatedScript2Path -Encoding UTF8
            Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File `"$elevatedScript2Path`"" -Verb RunAs -Wait
        } else {
            sc.exe create "Apple Mobile Device Service" binPath= "`"$serviceExe`"" start= demand DisplayName= "Apple Mobile Device Service (Portable)"
            sc.exe start "Apple Mobile Device Service"
        }
    } else {
        Write-Host "Service already registered, starting..."
        Start-Service "Apple Mobile Device Service" -ErrorAction SilentlyContinue
    }

    # Verify service is running
    Start-Sleep -Seconds 2
    try {
        $testConn = New-Object System.Net.Sockets.TcpClient
        $testConn.Connect("127.0.0.1", 27015)
        $testConn.Close()
        Write-Host ""
        Write-Host "SUCCESS! Apple Mobile Device Service is running on port 27015" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "WARNING: Service may not be listening yet." -ForegroundColor Yellow
        Write-Host "Try: sc.exe start `"Apple Mobile Device Service`"" -ForegroundColor Yellow
    }
}

# ============================================================
# Cleanup
# ============================================================
Write-Host ""
Write-Host "Cleaning up temporary files..."
if (Test-Path $extractDir) { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path "$InstallDir\_msi") { Remove-Item -Path "$InstallDir\_msi" -Recurse -Force -ErrorAction SilentlyContinue }
# Keep iTunes installer for potential re-use
# if (Test-Path $iTunesLocal) { Remove-Item $iTunesLocal -Force }

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Files installed to: $InstallDir" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Connect iPad via USB-C cable" -ForegroundColor White
Write-Host "  2. On iPad: tap 'Trust This Computer'" -ForegroundColor White
Write-Host "  3. Run: .\usb-tunnel.ps1" -ForegroundColor White
Write-Host "  4. Run: .\screen-sender-ffmjpeg.ps1 -iPadIP '127.0.0.1' -Port 9001" -ForegroundColor White
Write-Host ""
Write-Host "To uninstall: .\setup-apple-usb.ps1 -Uninstall" -ForegroundColor Gray
