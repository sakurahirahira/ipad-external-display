# launch-wifi.ps1 - WiFi Hotspot Mode (管理者権限不要)
# PCのモバイルホットスポットでiPadと直接接続して画面送信
#
# Usage: powershell -ExecutionPolicy Bypass -File launch-wifi.ps1

param(
    [int]$Fps = 30,
    [string]$Resolution = "2732x2048",
    [int]$JpegQuality = 5,
    [int]$Port = 9000,
    [string]$CaptureArea = "",
    [string]$FFmpegPath = ""
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  iPad External Display - WiFi Hotspot Mode" -ForegroundColor Cyan
Write-Host "  (管理者権限不要)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Step 1: Check Mobile Hotspot
# ============================================================
Write-Host "[1/4] モバイルホットスポットの確認" -ForegroundColor Yellow
Write-Host "----------------------------------------------"
Write-Host ""

# Check if Mobile Hotspot is available via netsh
$hostedNetwork = netsh wlan show hostednetwork 2>$null
$mobileHotspot = netsh wlan show drivers 2>$null | Select-String "Hosted network supported"

if ($mobileHotspot -match "Yes") {
    Write-Host "  WiFi Hotspot: 対応しています" -ForegroundColor Green
} else {
    Write-Host "  WiFi Hotspot: 確認できません（非対応またはWiFiアダプタなし）" -ForegroundColor Yellow
    Write-Host "  続行しますが、設定画面で確認してください" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  以下の手順でホットスポットを有効にしてください:" -ForegroundColor White
Write-Host ""
Write-Host "  [PC側]" -ForegroundColor Cyan
Write-Host "    1. 設定 → ネットワークとインターネット → モバイルホットスポット" -ForegroundColor White
Write-Host "    2. 「モバイルホットスポット」をON" -ForegroundColor White
Write-Host "    3. ネットワーク名とパスワードをメモ" -ForegroundColor White
Write-Host ""
Write-Host "  [iPad側]" -ForegroundColor Cyan
Write-Host "    4. 設定 → WiFi → 上記のネットワークに接続" -ForegroundColor White
Write-Host "    5. ExternalDisplay アプリを起動" -ForegroundColor White
Write-Host ""

# Open Mobile Hotspot settings
Write-Host "  ホットスポット設定画面を開きますか？ (Y/n): " -NoNewline -ForegroundColor Green
$openSettings = Read-Host
if ($openSettings -ne "n") {
    Start-Process "ms-settings:network-mobilehotspot"
    Write-Host "  設定画面を開きました。" -ForegroundColor Green
}

Write-Host ""
Write-Host "  iPadが接続できたら Enter を押してください..." -ForegroundColor Yellow
Read-Host

# ============================================================
# Step 2: Find iPad IP
# ============================================================
Write-Host "[2/4] iPadのIPアドレスを検出" -ForegroundColor Yellow
Write-Host "----------------------------------------------"
Write-Host ""

# Get hotspot adapter IP range (usually 192.168.137.x)
$iPadIP = ""

# Check for hotspot adapter
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$hotspotAdapter = $adapters | Where-Object {
    $_.Name -match "Local Area Connection\*|Wi-Fi Direct|ホットスポット|vEthernet"
}

# Get connected clients from ARP table
Write-Host "  接続済みデバイスを検索中..." -ForegroundColor Gray

# Refresh ARP
ping -n 1 -w 500 192.168.137.255 >$null 2>&1

$arpEntries = arp -a | Select-String "192\.168\.(137|0)\.\d+" | ForEach-Object {
    if ($_ -match "(\d+\.\d+\.\d+\.\d+)") { $matches[1] }
} | Where-Object { $_ -notmatch "\.1$" -and $_ -notmatch "\.255$" }

if ($arpEntries) {
    Write-Host ""
    Write-Host "  検出されたデバイス:" -ForegroundColor Green
    $i = 1
    $candidates = @()
    foreach ($entry in $arpEntries) {
        Write-Host "    [$i] $entry" -ForegroundColor White
        $candidates += $entry
        $i++
    }
    Write-Host ""

    if ($candidates.Count -eq 1) {
        $iPadIP = $candidates[0]
        Write-Host "  自動選択: $iPadIP" -ForegroundColor Green
    } else {
        Write-Host "  iPadの番号を入力 (または IPアドレスを直接入力): " -NoNewline -ForegroundColor Green
        $sel = Read-Host
        if ($sel -match "^\d+$" -and [int]$sel -le $candidates.Count) {
            $iPadIP = $candidates[[int]$sel - 1]
        } else {
            $iPadIP = $sel
        }
    }
} else {
    Write-Host "  デバイスが自動検出できませんでした。" -ForegroundColor Yellow
}

if (-not $iPadIP) {
    Write-Host ""
    Write-Host "  iPadアプリに表示されているIPアドレスを入力してください: " -NoNewline -ForegroundColor Green
    $iPadIP = Read-Host
}

Write-Host ""
Write-Host "  iPad IP: $iPadIP" -ForegroundColor Green

# ============================================================
# Step 3: Test connection
# ============================================================
Write-Host ""
Write-Host "[3/4] 接続テスト" -ForegroundColor Yellow
Write-Host "----------------------------------------------"

$connected = $false
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect($iPadIP, $Port)
    $testConn.Close()
    Write-Host "  iPadアプリ (port $Port): 接続OK!" -ForegroundColor Green
    $connected = $true
} catch {
    Write-Host "  iPadアプリ (port $Port): 接続できません" -ForegroundColor Red
    Write-Host "  iPadでExternalDisplayアプリが起動しているか確認してください" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  再試行しますか？ (Y/n): " -NoNewline
    $retry = Read-Host
    if ($retry -ne "n") {
        Write-Host "  iPadアプリを起動して Enter を押してください..."
        Read-Host
        try {
            $testConn2 = New-Object System.Net.Sockets.TcpClient
            $testConn2.Connect($iPadIP, $Port)
            $testConn2.Close()
            Write-Host "  接続OK!" -ForegroundColor Green
            $connected = $true
        } catch {
            Write-Host "  接続失敗。IPアドレスを確認してください。" -ForegroundColor Red
            exit 1
        }
    }
}

# ============================================================
# Step 4: Start streaming
# ============================================================
Write-Host ""
Write-Host "[4/4] 画面送信開始" -ForegroundColor Yellow
Write-Host "----------------------------------------------"
Write-Host ""
Write-Host "  送信先: ${iPadIP}:${Port}" -ForegroundColor White
Write-Host "  解像度: $Resolution @ ${Fps}fps" -ForegroundColor White
Write-Host "  品質: $JpegQuality (低い=高画質)" -ForegroundColor White
if ($CaptureArea) { Write-Host "  キャプチャ領域: $CaptureArea" -ForegroundColor White }
Write-Host ""

$senderScript = "$scriptDir\screen-sender-ffmjpeg.ps1"
if (-not (Test-Path $senderScript)) {
    Write-Host "ERROR: screen-sender-ffmjpeg.ps1 が見つかりません" -ForegroundColor Red
    exit 1
}

# Build arguments
$args = @(
    "-iPadIP", $iPadIP,
    "-Port", $Port,
    "-Fps", $Fps,
    "-Resolution", $Resolution,
    "-JpegQuality", $JpegQuality
)
if ($CaptureArea) { $args += @("-CaptureArea", $CaptureArea) }
if ($FFmpegPath) { $args += @("-FFmpegPath", $FFmpegPath) }

Write-Host "  Ctrl+C で停止" -ForegroundColor Gray
Write-Host ""

& $senderScript @args
