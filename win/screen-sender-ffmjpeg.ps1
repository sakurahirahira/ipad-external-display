# screen-sender-ffmjpeg.ps1 - ffmpeg MJPEG capture -> JPEG TCP protocol (compatible with iPad JPEG mode)
# ffmpeg does capture+scale+encode, PowerShell does TCP framing
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-ffmjpeg.ps1 -iPadIP "192.168.8.240"

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [int]$Fps = 30,
    [string]$Resolution = "2732x2048",
    [int]$JpegQuality = 8,  # ffmpeg quality 2-31 (lower=better)
    [string]$CaptureArea = "",  # empty=full primary, "1366x1024+477+1440" for DISPLAY2
    [string]$FFmpegPath = ""
)

# Find ffmpeg
if (-not $FFmpegPath) {
    $candidates = @(
        "$env:USERPROFILE\ffmpeg.exe",
        "$env:USERPROFILE\Desktop\ffmpeg.exe",
        "$env:USERPROFILE\Downloads\ffmpeg.exe",
        "C:\ffmpeg\bin\ffmpeg.exe",
        "C:\ffmpeg\ffmpeg.exe"
    )
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPath) {
        $found = Get-ChildItem -Path $wingetPath -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $candidates = @($found.FullName) + $candidates }
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { $FFmpegPath = $c; break }
    }
}

if (-not $FFmpegPath -or -not (Test-Path $FFmpegPath)) {
    Write-Host "ERROR: ffmpeg.exe not found"
    exit 1
}

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net.Sockets;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class FFMjpegSender : IDisposable
{
    private Process ffProcess;
    private TcpClient tcp;
    private NetworkStream net;
    private byte[] headerBuf = new byte[4];
    public int FramesSent;
    public long TotalBytes;

    public bool Connect(string ip, int port)
    {
        try
        {
            tcp = new TcpClient(); tcp.NoDelay = true;
            tcp.SendBufferSize = 4 * 1024 * 1024;
            tcp.Connect(ip, port); net = tcp.GetStream();
            return true;
        }
        catch (Exception ex) { Console.WriteLine("TCP: " + ex.Message); return false; }
    }

    public bool StartCapture(string ffmpegPath, int fps, string resolution, int quality, string captureArea)
    {
        var psi = new ProcessStartInfo();
        psi.FileName = ffmpegPath;

        string input;
        if (!string.IsNullOrEmpty(captureArea) && captureArea.StartsWith("title="))
        {
            // Window title capture mode: "title=WindowTitle"
            string title = captureArea.Substring(6);
            input = "-f gdigrab -framerate " + fps + " -i title=" + title;
        }
        else if (!string.IsNullOrEmpty(captureArea))
        {
            // captureArea format: WxH+X+Y (e.g. "1366x1024+477+1440")
            var parts = captureArea.Replace("+", "x").Split('x');
            input = "-f gdigrab -framerate " + fps +
                " -offset_x " + parts[2] + " -offset_y " + parts[3] +
                " -video_size " + parts[0] + "x" + parts[1] + " -i desktop";
        }
        else
        {
            input = "-f gdigrab -framerate " + fps + " -i desktop";
        }

        // Scale to fit target resolution while keeping aspect ratio, pad with black bars
        string res = resolution.Replace("x", ":");
        string scaleFilter = string.IsNullOrEmpty(res) ? "" :
            "-vf \"scale=" + res + ":force_original_aspect_ratio=decrease,pad=" + res + ":(ow-iw)/2:(oh-ih)/2:black\" ";

        psi.Arguments = "-hide_banner -loglevel error " +
            input + " " +
            scaleFilter +
            "-c:v mjpeg -q:v " + quality + " " +
            "-f image2pipe -";
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;

        Console.WriteLine("ffmpeg: " + psi.Arguments);
        ffProcess = Process.Start(psi);

        // Log stderr
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            try { string l; while ((l = ffProcess.StandardError.ReadLine()) != null) Console.WriteLine("ffmpeg: " + l); } catch {}
        });

        return ffProcess != null && !ffProcess.HasExited;
    }

    // Read JPEG frames from ffmpeg stdout and send via [4-byte length][jpeg data] protocol
    public void StreamLoop()
    {
        var ffOut = ffProcess.StandardOutput.BaseStream;
        byte[] readBuf = new byte[1024 * 1024]; // 1MB read buffer
        byte[] frameBuf = new byte[4 * 1024 * 1024]; // 4MB frame accumulator
        int framePos = 0;
        var sw = Stopwatch.StartNew();
        int fpsCount = 0;

        while (!ffProcess.HasExited)
        {
            int read = ffOut.Read(readBuf, 0, readBuf.Length);
            if (read <= 0) break;

            // Scan for JPEG boundaries (FFD8=start, FFD9=end)
            for (int i = 0; i < read; i++)
            {
                frameBuf[framePos++] = readBuf[i];

                // Check for JPEG end marker (FFD9)
                if (framePos >= 2 && frameBuf[framePos - 2] == 0xFF && frameBuf[framePos - 1] == 0xD9)
                {
                    // Found complete JPEG frame
                    // Verify it starts with FFD8
                    if (framePos >= 4 && frameBuf[0] == 0xFF && frameBuf[1] == 0xD8)
                    {
                        // Send: [4-byte length][jpeg data]
                        try
                        {
                            int len = framePos;
                            headerBuf[0] = (byte)len;
                            headerBuf[1] = (byte)(len >> 8);
                            headerBuf[2] = (byte)(len >> 16);
                            headerBuf[3] = (byte)(len >> 24);
                            net.Write(headerBuf, 0, 4);
                            net.Write(frameBuf, 0, len);
                            FramesSent++;
                            TotalBytes += len + 4;
                            fpsCount++;
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine("Send error: " + ex.Message);
                            return;
                        }
                    }
                    framePos = 0;
                }

                // Safety: prevent buffer overflow
                if (framePos >= frameBuf.Length - 1) framePos = 0;
            }

            if (sw.ElapsedMilliseconds >= 1000)
            {
                double fps = fpsCount * 1000.0 / sw.ElapsedMilliseconds;
                double kbps = TotalBytes * 8.0 / 1000;
                Console.Write("\rFPS: " + Math.Round(fps, 1) + " | Sent: " + (TotalBytes / 1024) + "KB   ");
                fpsCount = 0;
                sw.Restart();
            }
        }
    }

    public void Dispose()
    {
        try { if (ffProcess != null && !ffProcess.HasExited) ffProcess.Kill(); } catch {}
        if (net != null) net.Close();
        if (tcp != null) tcp.Close();
    }
}
"@

Write-Host "=== FFmpeg MJPEG -> JPEG TCP Sender ==="
Write-Host "ffmpeg: $FFmpegPath"
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Resolution: $Resolution @ ${Fps}fps, Quality: $JpegQuality"
if ($CaptureArea) { Write-Host "Capture: $CaptureArea" }
Write-Host ""

$sender = New-Object FFMjpegSender

Write-Host "Connecting to iPad..."
while (-not $sender.Connect($iPadIP, $Port)) {
    Write-Host "  Retrying..."
    Start-Sleep -Seconds 2
}
Write-Host "Connected!"

if (-not $sender.StartCapture($FFmpegPath, $Fps, $Resolution, $JpegQuality, $CaptureArea)) {
    Write-Host "ffmpeg start failed"
    exit 1
}

Write-Host "Streaming... (Ctrl+C to stop)"
try {
    $sender.StreamLoop()
}
finally {
    $sender.Dispose()
    Write-Host ""
    Write-Host "Done. Frames: $($sender.FramesSent)"
}
