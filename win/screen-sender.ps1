# screen-sender.ps1 - Phase1: Screen capture & send over TCP
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender.ps1 -iPadIP "172.20.10.1" -Port 9000

param(
    [string]$iPadIP = "172.20.10.1",  # iPad tethering default IP
    [int]$Port = 9000,
    [int]$Quality = 30,               # JPEG quality (1-100, lower = faster)
    [int]$ScalePercent = 50            # Scale down percentage (50 = half resolution)
)

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;

public class ScreenSender : IDisposable
{
    private TcpClient client;
    private NetworkStream stream;
    private ImageCodecInfo jpegCodec;
    private EncoderParameters encoderParams;
    private int scalePercent;

    public int FramesSent { get; private set; }
    public double LastFrameMs { get; private set; }

    public ScreenSender(int quality, int scalePercent)
    {
        this.scalePercent = scalePercent;

        // Setup JPEG encoder
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
    }

    public bool Connect(string ip, int port)
    {
        try
        {
            client = new TcpClient();
            client.NoDelay = true;
            client.SendBufferSize = 1024 * 1024; // 1MB buffer
            client.Connect(ip, port);
            stream = client.GetStream();
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
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            // Capture screen
            var bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
            using (var fullBmp = new Bitmap(bounds.Width, bounds.Height))
            {
                using (var g = Graphics.FromImage(fullBmp))
                {
                    g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
                }

                // Scale down
                int w = bounds.Width * scalePercent / 100;
                int h = bounds.Height * scalePercent / 100;
                using (var scaledBmp = new Bitmap(w, h))
                {
                    using (var g = Graphics.FromImage(scaledBmp))
                    {
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Low;
                        g.CompositingQuality = System.Drawing.Drawing2D.CompositingQuality.HighSpeed;
                        g.DrawImage(fullBmp, 0, 0, w, h);
                    }

                    // Encode to JPEG
                    using (var ms = new MemoryStream())
                    {
                        scaledBmp.Save(ms, jpegCodec, encoderParams);
                        byte[] data = ms.ToArray();

                        // Send: [4 bytes length][jpeg data]
                        byte[] header = BitConverter.GetBytes(data.Length);
                        stream.Write(header, 0, 4);
                        stream.Write(data, 0, data.Length);
                        stream.Flush();
                    }
                }
            }

            FramesSent++;
            sw.Stop();
            LastFrameMs = sw.Elapsed.TotalMilliseconds;
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
        if (stream != null) stream.Close();
        if (client != null) client.Close();
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Screen Sender (Phase1) ==="
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Quality: $Quality, Scale: ${ScalePercent}%"
Write-Host ""

$sender = New-Object ScreenSender($Quality, $ScalePercent)

# Retry connection loop
Write-Host "Connecting to iPad..."
while (-not $sender.Connect($iPadIP, $Port)) {
    Write-Host "  Retrying in 2 seconds..."
    Start-Sleep -Seconds 2
}
Write-Host "Connected!"
Write-Host "Sending frames... (Ctrl+C to stop)"
Write-Host ""

# Main loop
$fpsTimer = [System.Diagnostics.Stopwatch]::StartNew()
$frameCount = 0

try {
    while ($true) {
        if (-not $sender.SendFrame()) {
            Write-Host "Connection lost. Reconnecting..."
            $sender.Dispose()
            $sender = New-Object ScreenSender($Quality, $ScalePercent)
            while (-not $sender.Connect($iPadIP, $Port)) {
                Start-Sleep -Seconds 2
            }
            Write-Host "Reconnected!"
            continue
        }

        $frameCount++

        # Show FPS every second
        if ($fpsTimer.ElapsedMilliseconds -ge 1000) {
            $fps = [math]::Round($frameCount * 1000 / $fpsTimer.ElapsedMilliseconds, 1)
            $ms = [math]::Round($sender.LastFrameMs, 1)
            Write-Host "`rFPS: $fps | Frame: ${ms}ms" -NoNewline
            $frameCount = 0
            $fpsTimer.Restart()
        }
    }
}
finally {
    $sender.Dispose()
    Write-Host ""
    Write-Host "Stopped. Total frames sent: $($sender.FramesSent)"
}
