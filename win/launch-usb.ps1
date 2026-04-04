# launch-usb.ps1 - USB Cable Mode (初回のみ管理者権限が必要)
# USB-Cケーブルで直接接続して画面送信。WiFi不要。
#
# Usage: powershell -ExecutionPolicy Bypass -File launch-usb.ps1

param(
    [int]$Fps = 30,
    [string]$Resolution = "2732x2048",
    [int]$JpegQuality = 5,
    [int]$DevicePort = 9000,
    [int]$LocalPort = 9001,
    [string]$CaptureArea = "",
    [string]$FFmpegPath = "",
    [switch]$Setup              # Run initial driver setup
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = "$env:USERPROFILE\.apple-usb"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "  iPad External Display - USB Cable Mode" -ForegroundColor Magenta
Write-Host "  (WiFi不要・USBケーブル直結)" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host ""

# ============================================================
# Step 1: Check Apple USB Driver
# ============================================================
Write-Host "[1/4] Apple USBドライバの確認" -ForegroundColor Yellow
Write-Host "----------------------------------------------"

$serviceRunning = $false
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect("127.0.0.1", 27015)
    $testConn.Close()
    $serviceRunning = $true
    Write-Host "  Apple Mobile Device Service: 稼働中" -ForegroundColor Green
} catch {
    Write-Host "  Apple Mobile Device Service: 未起動" -ForegroundColor Red
}

if (-not $serviceRunning) {
    # Check if driver files exist
    $driverExists = Test-Path "$installDir\driver\usbaapl64.inf"
    $serviceExists = Test-Path "$installDir\service\AppleMobileDeviceService.exe"

    if (-not $driverExists) {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host "  初回セットアップが必要です" -ForegroundColor Yellow
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  やること:" -ForegroundColor White
        Write-Host "    - iTunes(約200MB)をダウンロード" -ForegroundColor White
        Write-Host "    - USBドライバだけ抽出(iTunesはインストールしない)" -ForegroundColor White
        Write-Host "    - ドライバ登録(1回だけUACポップアップあり)" -ForegroundColor White
        Write-Host ""
        Write-Host "  セットアップを開始しますか？ (Y/n): " -NoNewline -ForegroundColor Green
        $doSetup = Read-Host
        if ($doSetup -eq "n") {
            Write-Host "  中止しました。" -ForegroundColor Gray
            exit 0
        }

        # Run setup
        $setupScript = "$scriptDir\setup-apple-usb.ps1"
        if (-not (Test-Path $setupScript)) {
            Write-Host "  ERROR: setup-apple-usb.ps1 が見つかりません" -ForegroundColor Red
            exit 1
        }
        & $setupScript -InstallDir $installDir

        # Re-check after setup
        try {
            $testConn2 = New-Object System.Net.Sockets.TcpClient
            $testConn2.Connect("127.0.0.1", 27015)
            $testConn2.Close()
            $serviceRunning = $true
        } catch {}
    }

    # Try starting service if not running
    if (-not $serviceRunning) {
        Write-Host ""
        Write-Host "  サービスを起動しています..." -ForegroundColor Gray

        # Try starting existing Windows service
        $svc = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Start-Service "Apple Mobile Device Service" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        # If still not running, try registering from extracted files
        if ($serviceExists) {
            $svcExe = "$installDir\service\AppleMobileDeviceService.exe"
            $existingSvc = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
            if (-not $existingSvc) {
                Write-Host "  サービスを登録しています（管理者権限が必要）..." -ForegroundColor Yellow
                $elevScript = @"
sc.exe create "Apple Mobile Device Service" binPath= "\`"$svcExe\`"" start= demand
sc.exe start "Apple Mobile Device Service"
Start-Sleep -Seconds 2
"@
                $elevPath = "$installDir\_elev-start.ps1"
                $elevScript | Out-File -FilePath $elevPath -Encoding UTF8
                Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File `"$elevPath`"" -Verb RunAs -Wait
            } else {
                Start-Service "Apple Mobile Device Service" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }

        # Final check
        try {
            $testConn3 = New-Object System.Net.Sockets.TcpClient
            $testConn3.Connect("127.0.0.1", 27015)
            $testConn3.Close()
            $serviceRunning = $true
            Write-Host "  サービス起動: OK" -ForegroundColor Green
        } catch {
            Write-Host ""
            Write-Host "  ERROR: サービスが起動できません" -ForegroundColor Red
            Write-Host "  setup-apple-usb.ps1 を管理者権限で実行してください:" -ForegroundColor Yellow
            Write-Host "    powershell -ExecutionPolicy Bypass -File `"$scriptDir\setup-apple-usb.ps1`"" -ForegroundColor White
            exit 1
        }
    }
}

# ============================================================
# Step 2: Detect iPad via USB
# ============================================================
Write-Host ""
Write-Host "[2/4] iPadのUSB接続を確認" -ForegroundColor Yellow
Write-Host "----------------------------------------------"
Write-Host ""
Write-Host "  iPadをUSB-Cケーブルで接続してください" -ForegroundColor White
Write-Host "  iPadの画面で「このコンピュータを信頼」をタップ" -ForegroundColor White
Write-Host ""

# Use usbmux ListDevices to check
Add-Type -TypeDefinition @"
using System;
using System.Net.Sockets;
using System.Text;
using System.Xml;
using System.Collections.Generic;

public class QuickMuxCheck
{
    public static List<int> ListDevices()
    {
        var ids = new List<int>();
        try
        {
            var tcp = new TcpClient("127.0.0.1", 27015);
            tcp.NoDelay = true;
            var ns = tcp.GetStream();

            string plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
                "<plist version=\"1.0\"><dict>" +
                "<key>MessageType</key><string>ListDevices</string>" +
                "<key>ClientVersionString</key><string>usbmux-ps1</string>" +
                "<key>ProgName</key><string>screen-sender</string>" +
                "</dict></plist>";

            byte[] payload = Encoding.UTF8.GetBytes(plist);
            int totalLen = 16 + payload.Length;
            byte[] packet = new byte[totalLen];
            BitConverter.GetBytes(totalLen).CopyTo(packet, 0);
            BitConverter.GetBytes(1).CopyTo(packet, 4);  // version=1
            BitConverter.GetBytes(8).CopyTo(packet, 8);  // type=plist
            BitConverter.GetBytes(1).CopyTo(packet, 12); // tag=1
            Array.Copy(payload, 0, packet, 16, payload.Length);
            ns.Write(packet, 0, packet.Length);
            ns.Flush();

            // Read response
            byte[] header = new byte[16];
            int read = 0;
            while (read < 16) { int n = ns.Read(header, read, 16 - read); if (n <= 0) break; read += n; }
            int respLen = BitConverter.ToInt32(header, 0) - 16;
            if (respLen > 0)
            {
                byte[] respBuf = new byte[respLen];
                read = 0;
                while (read < respLen) { int n = ns.Read(respBuf, read, respLen - read); if (n <= 0) break; read += n; }
                string xml = Encoding.UTF8.GetString(respBuf);
                var doc = new XmlDocument();
                doc.LoadXml(xml);
                var nodes = doc.SelectNodes("//dict/key[text()='DeviceID']/following-sibling::integer[1]");
                if (nodes != null) foreach (XmlNode node in nodes) { int id; if (int.TryParse(node.InnerText, out id)) ids.Add(id); }
            }
            tcp.Close();
        }
        catch (Exception ex) { Console.WriteLine("  usbmux error: " + ex.Message); }
        return ids;
    }
}
"@

$maxWait = 30
$waited = 0
$deviceFound = $false

while ($waited -lt $maxWait) {
    $devices = [QuickMuxCheck]::ListDevices()
    if ($devices.Count -gt 0) {
        $deviceFound = $true
        Write-Host "  iPad検出: DeviceID = $($devices[0])" -ForegroundColor Green
        break
    }
    if ($waited -eq 0) {
        Write-Host "  iPadを探しています..." -ForegroundColor Gray
    }
    Write-Host "." -NoNewline -ForegroundColor Gray
    Start-Sleep -Seconds 2
    $waited += 2
}

if (-not $deviceFound) {
    Write-Host ""
    Write-Host "  iPadが検出できませんでした。" -ForegroundColor Red
    Write-Host "  確認事項:" -ForegroundColor Yellow
    Write-Host "    - USB-Cケーブルが接続されている" -ForegroundColor White
    Write-Host "    - iPadがロック解除されている" -ForegroundColor White
    Write-Host "    - 「このコンピュータを信頼」をタップした" -ForegroundColor White
    Write-Host ""
    Write-Host "  続行しますか？ (Y/n): " -NoNewline
    $cont = Read-Host
    if ($cont -eq "n") { exit 1 }
}

# ============================================================
# Step 3: Start USB tunnel
# ============================================================
Write-Host ""
Write-Host "[3/4] USBトンネル起動" -ForegroundColor Yellow
Write-Host "----------------------------------------------"

# Start usb-tunnel.ps1 in background
$tunnelScript = "$scriptDir\usb-tunnel.ps1"
if (-not (Test-Path $tunnelScript)) {
    Write-Host "  ERROR: usb-tunnel.ps1 が見つかりません" -ForegroundColor Red
    exit 1
}

Write-Host "  トンネル起動: localhost:$LocalPort -> iPad:$DevicePort (USB)" -ForegroundColor White
$tunnelJob = Start-Job -ScriptBlock {
    param($script, $lp, $dp)
    & $script -ListenPort $lp -DevicePort $dp
} -ArgumentList $tunnelScript, $LocalPort, $DevicePort

# Wait for tunnel to be ready
Start-Sleep -Seconds 3
$tunnelReady = $false
for ($i = 0; $i -lt 5; $i++) {
    try {
        $testConn4 = New-Object System.Net.Sockets.TcpClient
        $testConn4.Connect("127.0.0.1", $LocalPort)
        $testConn4.Close()
        $tunnelReady = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}

if ($tunnelReady) {
    Write-Host "  USBトンネル: 稼働中" -ForegroundColor Green
} else {
    # Tunnel might still be starting, proceed anyway
    Write-Host "  USBトンネル: 起動中（送信開始時に接続します）" -ForegroundColor Yellow
}

# ============================================================
# Step 4: Start streaming
# ============================================================
Write-Host ""
Write-Host "[4/4] 画面送信開始" -ForegroundColor Yellow
Write-Host "----------------------------------------------"
Write-Host ""
Write-Host "  経路: PC -> localhost:$LocalPort -> USB -> iPad:$DevicePort" -ForegroundColor White
Write-Host "  解像度: $Resolution @ ${Fps}fps" -ForegroundColor White
Write-Host "  品質: $JpegQuality" -ForegroundColor White
if ($CaptureArea) { Write-Host "  キャプチャ: $CaptureArea" -ForegroundColor White }
Write-Host ""
Write-Host "  Ctrl+C で停止" -ForegroundColor Gray
Write-Host ""

$senderScript = "$scriptDir\screen-sender-ffmjpeg.ps1"
if (-not (Test-Path $senderScript)) {
    Write-Host "ERROR: screen-sender-ffmjpeg.ps1 が見つかりません" -ForegroundColor Red
    exit 1
}

$senderArgs = @(
    "-iPadIP", "127.0.0.1",
    "-Port", $LocalPort,
    "-Fps", $Fps,
    "-Resolution", $Resolution,
    "-JpegQuality", $JpegQuality
)
if ($CaptureArea) { $senderArgs += @("-CaptureArea", $CaptureArea) }
if ($FFmpegPath) { $senderArgs += @("-FFmpegPath", $FFmpegPath) }

try {
    & $senderScript @senderArgs
}
finally {
    # Cleanup tunnel job
    Write-Host ""
    Write-Host "USBトンネルを停止中..." -ForegroundColor Gray
    Stop-Job $tunnelJob -ErrorAction SilentlyContinue
    Remove-Job $tunnelJob -Force -ErrorAction SilentlyContinue
    Write-Host "終了しました。" -ForegroundColor Green
}
