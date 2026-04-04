# start-usb-service.ps1 - Start Apple Mobile Device Service and verify
# Run this before usb-tunnel.ps1 if the service isn't already running
#
# Usage: powershell -ExecutionPolicy Bypass -File start-usb-service.ps1

param(
    [string]$InstallDir = "$env:USERPROFILE\.apple-usb"
)

Write-Host "=== Apple Mobile Device Service Starter ===" -ForegroundColor Cyan
Write-Host ""

# Check if already running
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect("127.0.0.1", 27015)
    $testConn.Close()
    Write-Host "Service is already running on port 27015" -ForegroundColor Green
    Write-Host "Ready for usb-tunnel.ps1!" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "Service not running. Starting..."
}

# Try starting existing service
$svc = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Running") {
        Write-Host "Starting registered service..."
        Start-Service "Apple Mobile Device Service" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
} else {
    # Try to find and register
    $serviceExe = "$InstallDir\service\AppleMobileDeviceService.exe"
    if (Test-Path $serviceExe) {
        Write-Host "Service not registered. Registering..."
        Write-Host "This requires admin elevation." -ForegroundColor Yellow

        $script = @"
sc.exe create "Apple Mobile Device Service" binPath= "`"$serviceExe`"" start= demand DisplayName= "Apple Mobile Device Service (Portable)"
sc.exe start "Apple Mobile Device Service"
Write-Host 'Done. Press Enter.'
Read-Host
"@
        $scriptPath = "$InstallDir\_start-svc.ps1"
        $script | Out-File -FilePath $scriptPath -Encoding UTF8
        Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs -Wait
    } else {
        Write-Host "ERROR: Service exe not found at $serviceExe" -ForegroundColor Red
        Write-Host "Run setup-apple-usb.ps1 first!" -ForegroundColor Yellow
        exit 1
    }
}

# Verify
Start-Sleep -Seconds 2
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect("127.0.0.1", 27015)
    $testConn.Close()
    Write-Host ""
    Write-Host "Service is running!" -ForegroundColor Green
    Write-Host "Now run: .\usb-tunnel.ps1" -ForegroundColor Cyan
} catch {
    Write-Host ""
    Write-Host "Service failed to start." -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check Device Manager - iPad should show under 'Apple Mobile Device USB Driver'" -ForegroundColor White
    Write-Host "  2. Try: sc.exe query 'Apple Mobile Device Service'" -ForegroundColor White
    Write-Host "  3. Try: net start 'Apple Mobile Device Service'" -ForegroundColor White
    Write-Host "  4. Reconnect iPad and unlock it" -ForegroundColor White
}
