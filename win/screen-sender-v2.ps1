# screen-sender-v2.ps1 - Phase2: Optimized with buffer reuse & detailed metrics
# Uses PowerShell 5.1 (.NET Framework 4.x) for maximum compatibility
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-v2.ps1 -iPadIP "192.168.8.240"

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [int]$Quality = 30,
    [int]$ScalePercent = 50,
    [int]$TargetFps = 60
)

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class ScreenSenderV2 : IDisposable
{
    private TcpClient client;
    private NetworkStream netStream;
    private ImageCodecInfo jpegCodec;
    private EncoderParameters encoderParams;
    private int scalePercent;

    // Reusable buffers - key optimization
    private Bitmap fullBmp;
    private Bitmap scaledBmp;
    private Graphics scaleGraphics;
    private MemoryStream jpegBuffer;
    private byte[] headerBuf = new byte[4];
    private int screenW, screenH, scaledW, scaledH;

    public int FramesSent { get; private set; }
    public double LastFrameMs { get; private set; }
    public double CaptureMs { get; private set; }
    public double EncodeMs { get; private set; }
    public double SendMs { get; private set; }
    public int LastFrameBytes { get; private set; }

    public ScreenSenderV2(int quality, int scalePercent)
    {
        this.scalePercent = scalePercent;

        foreach (var codec in ImageCodecInfo.GetImageEncoders())
        {
            if (codec.MimeType == "image/jpeg")
            {
                jpegCodec = codec;
                break;
            }
        }
        encoderParams = new EncoderParameters(1);
        encoderParams.Param[0] = new EncoderParameter(
            System.Drawing.Imaging.Encoder.Quality, (long)quality);

        // Pre-allocate reusable buffers
        var bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        screenW = bounds.Width;
        screenH = bounds.Height;
        scaledW = screenW * scalePercent / 100;
        scaledH = screenH * scalePercent / 100;

        fullBmp = new Bitmap(screenW, screenH, PixelFormat.Format32bppRgb);
        scaledBmp = new Bitmap(scaledW, scaledH, PixelFormat.Format32bppRgb);
        scaleGraphics = Graphics.FromImage(scaledBmp);
        scaleGraphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        scaleGraphics.CompositingMode = CompositingMode.SourceCopy;
        scaleGraphics.CompositingQuality = CompositingQuality.HighSpeed;
        scaleGraphics.PixelOffsetMode = PixelOffsetMode.HighSpeed;
        scaleGraphics.SmoothingMode = SmoothingMode.None;
        jpegBuffer = new MemoryStream(256 * 1024);
    }

    public string GetResolution()
    {
        return screenW + "x" + screenH + " -> " + scaledW + "x" + scaledH;
    }

    public bool Connect(string ip, int port)
    {
        try
        {
            client = new TcpClient();
            client.NoDelay = true;
            client.SendBufferSize = 2 * 1024 * 1024;
            client.Connect(ip, port);
            netStream = client.GetStream();
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Connection failed: " + ex.Message);
            return false;
        }
    }

    public bool SendFrame()
    {
        var swTotal = Stopwatch.StartNew();
        try
        {
            // 1. Capture - reuse fullBmp
            var swStep = Stopwatch.StartNew();
            using (var g = Graphics.FromImage(fullBmp))
            {
                g.CopyFromScreen(0, 0, 0, 0, new Size(screenW, screenH), CopyPixelOperation.SourceCopy);
            }
            swStep.Stop();
            CaptureMs = swStep.Elapsed.TotalMilliseconds;

            // 2. Scale + Encode - reuse scaledBmp, scaleGraphics, jpegBuffer
            swStep.Restart();
            scaleGraphics.DrawImage(fullBmp, 0, 0, scaledW, scaledH);
            jpegBuffer.SetLength(0);
            jpegBuffer.Position = 0;
            scaledBmp.Save(jpegBuffer, jpegCodec, encoderParams);
            swStep.Stop();
            EncodeMs = swStep.Elapsed.TotalMilliseconds;

            // 3. Send - use GetBuffer to avoid ToArray allocation
            swStep.Restart();
            int len = (int)jpegBuffer.Length;
            LastFrameBytes = len;
            headerBuf[0] = (byte)(len);
            headerBuf[1] = (byte)(len >> 8);
            headerBuf[2] = (byte)(len >> 16);
            headerBuf[3] = (byte)(len >> 24);
            netStream.Write(headerBuf, 0, 4);
            netStream.Write(jpegBuffer.GetBuffer(), 0, len);
            swStep.Stop();
            SendMs = swStep.Elapsed.TotalMilliseconds;

            FramesSent++;
            swTotal.Stop();
            LastFrameMs = swTotal.Elapsed.TotalMilliseconds;
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Send error: " + ex.Message);
            return false;
        }
    }

    public void Dispose()
    {
        if (scaleGraphics != null) scaleGraphics.Dispose();
        if (scaledBmp != null) scaledBmp.Dispose();
        if (fullBmp != null) fullBmp.Dispose();
        if (jpegBuffer != null) jpegBuffer.Dispose();
        if (netStream != null) netStream.Close();
        if (client != null) client.Close();
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Screen Sender v2 (Optimized) ==="
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Quality: $Quality, Scale: ${ScalePercent}%, Target: ${TargetFps}fps"

$sender = New-Object ScreenSenderV2($Quality, $ScalePercent)
Write-Host "Resolution: $($sender.GetResolution())"
Write-Host ""

$targetFrameTime = [math]::Floor(1000 / $TargetFps)

Write-Host "Connecting to iPad..."
while (-not $sender.Connect($iPadIP, $Port)) {
    Write-Host "  Retrying in 2 seconds..."
    Start-Sleep -Seconds 2
}
Write-Host "Connected!"
Write-Host "Streaming... (Ctrl+C to stop)"
Write-Host ""

$fpsTimer = [System.Diagnostics.Stopwatch]::StartNew()
$frameTimer = [System.Diagnostics.Stopwatch]::StartNew()
$frameCount = 0

try {
    while ($true) {
        $frameTimer.Restart()

        if (-not $sender.SendFrame()) {
            Write-Host "`nConnection lost. Reconnecting..."
            $sender.Dispose()
            $sender = New-Object ScreenSenderV2($Quality, $ScalePercent)
            while (-not $sender.Connect($iPadIP, $Port)) {
                Start-Sleep -Seconds 2
            }
            Write-Host "Reconnected!"
            $fpsTimer.Restart()
            $frameCount = 0
            continue
        }

        $frameCount++

        if ($fpsTimer.ElapsedMilliseconds -ge 1000) {
            $fps = [math]::Round($frameCount * 1000 / $fpsTimer.ElapsedMilliseconds, 1)
            $cap = [math]::Round($sender.CaptureMs, 1)
            $enc = [math]::Round($sender.EncodeMs, 1)
            $snd = [math]::Round($sender.SendMs, 1)
            $total = [math]::Round($sender.LastFrameMs, 1)
            $kb = [math]::Round($sender.LastFrameBytes / 1024, 1)
            Write-Host "`rFPS: $fps | Cap:${cap}ms Enc:${enc}ms Snd:${snd}ms = ${total}ms (${kb}KB)   " -NoNewline
            $frameCount = 0
            $fpsTimer.Restart()
        }

        # Frame pacing - only sleep if ahead of target
        $elapsed = $frameTimer.ElapsedMilliseconds
        $sleepMs = $targetFrameTime - $elapsed
        if ($sleepMs -gt 1) {
            Start-Sleep -Milliseconds $sleepMs
        }
    }
}
finally {
    $sender.Dispose()
    Write-Host ""
    Write-Host "Stopped. Total frames sent: $($sender.FramesSent)"
}
