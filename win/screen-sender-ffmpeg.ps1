# screen-sender-ffmpeg.ps1 - ffmpeg H.264 screen streaming to iPad
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-ffmpeg.ps1 -iPadIP "192.168.8.240"
#
# ffmpeg captures screen via GDI, encodes H.264, sends MPEG-TS over TCP.
# iPad app auto-detects H.264 stream (0x47 sync byte).

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [string]$Encoder = "auto",       # auto, h264_mf, h264_qsv, h264_nvenc, libx264
    [int]$Fps = 30,
    [string]$Resolution = "1920x1080",
    [int]$Bitrate = 10,              # Mbps
    [string]$FFmpegPath = ""         # Auto-detect if empty
)

# Find ffmpeg
if (-not $FFmpegPath) {
    $candidates = @(
        "ffmpeg.exe",
        "$env:USERPROFILE\ffmpeg.exe",
        "$env:USERPROFILE\Desktop\ffmpeg.exe",
        "$env:USERPROFILE\Downloads\ffmpeg.exe",
        "C:\ffmpeg\bin\ffmpeg.exe",
        "C:\ffmpeg\ffmpeg.exe"
    )
    # Also search WinGet packages
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPath) {
        $found = Get-ChildItem -Path $wingetPath -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $candidates += $found.FullName }
    }

    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            $FFmpegPath = $c
            break
        }
        if (Test-Path $c) {
            $FFmpegPath = $c
            break
        }
    }
}

if (-not $FFmpegPath -or -not (Test-Path $FFmpegPath)) {
    Write-Host "ERROR: ffmpeg.exe not found!"
    Write-Host "Download from: https://www.gyan.dev/ffmpeg/builds/"
    Write-Host "Place ffmpeg.exe anywhere and specify with -FFmpegPath"
    exit 1
}

Write-Host "=== FFmpeg Screen Sender ==="
Write-Host "ffmpeg: $FFmpegPath"

# Auto-detect encoder
if ($Encoder -eq "auto") {
    $encoderList = & $FFmpegPath -hide_banner -encoders 2>&1 | Select-String "h264"
    if ($encoderList -match "h264_nvenc") {
        # Test if NVENC actually works
        $test = & $FFmpegPath -hide_banner -f lavfi -i nullsrc=s=64x64:d=0.1 -c:v h264_nvenc -f null - 2>&1
        if ($LASTEXITCODE -eq 0) { $Encoder = "h264_nvenc" }
    }
    if ($Encoder -eq "auto" -and $encoderList -match "h264_qsv") {
        $test = & $FFmpegPath -hide_banner -f lavfi -i nullsrc=s=64x64:d=0.1 -c:v h264_qsv -f null - 2>&1
        if ($LASTEXITCODE -eq 0) { $Encoder = "h264_qsv" }
    }
    if ($Encoder -eq "auto" -and $encoderList -match "h264_mf") {
        $Encoder = "h264_mf"
    }
    if ($Encoder -eq "auto") {
        $Encoder = "libx264"
    }
}

Write-Host "Encoder: $Encoder"
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Resolution: $Resolution @ ${Fps}fps, ${Bitrate}Mbps"
Write-Host ""

# Build ffmpeg arguments
$ffArgs = @("-hide_banner", "-loglevel", "warning", "-stats")

# Input: screen capture
$ffArgs += @("-f", "gdigrab", "-framerate", "$Fps", "-i", "desktop")

# Video filter: scale
$ffArgs += @("-vf", "scale=$Resolution")

# Encoder settings
switch ($Encoder) {
    "h264_nvenc" {
        $ffArgs += @("-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ll",
                     "-rc", "cbr", "-b:v", "${Bitrate}M",
                     "-gpu", "0", "-zerolatency", "1")
    }
    "h264_qsv" {
        $ffArgs += @("-c:v", "h264_qsv", "-preset", "veryfast",
                     "-b:v", "${Bitrate}M", "-low_power", "1")
    }
    "h264_mf" {
        $ffArgs += @("-c:v", "h264_mf", "-b:v", "${Bitrate}M",
                     "-hw_encoding", "1")
    }
    "libx264" {
        $ffArgs += @("-c:v", "libx264", "-preset", "ultrafast",
                     "-tune", "zerolatency", "-crf", "23",
                     "-b:v", "${Bitrate}M", "-maxrate", "${Bitrate}M",
                     "-bufsize", "$([math]::Floor($Bitrate/2))M")
    }
}

# Output: MPEG-TS over TCP (listen mode - iPad connects to us)
$ffArgs += @("-f", "mpegts", "-muxdelay", "0", "-flush_packets", "1",
             "tcp://0.0.0.0:${Port}?listen=1")

Write-Host "Starting stream..."
Write-Host "Press 'q' in this window to stop."
Write-Host ""

& $FFmpegPath @ffArgs
