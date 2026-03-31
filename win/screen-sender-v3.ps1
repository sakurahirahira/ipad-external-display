# screen-sender-v3.ps1 - Fast GDI capture with native StretchBlt
# Uses PowerShell 5.1 (.NET Framework 4.x)
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-v3.ps1 -iPadIP "192.168.8.240"

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
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class FastScreenSender : IDisposable
{
    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]
    static extern bool StretchBlt(IntPtr hdcDest, int dx, int dy, int dw, int dh,
                                   IntPtr hdcSrc, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")]
    static extern int SetStretchBltMode(IntPtr hdc, int mode);
    [DllImport("gdi32.dll")]
    static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]
    static extern int GetDIBits(IntPtr hdc, IntPtr hBitmap, uint start, uint lines,
                                 IntPtr bits, ref BITMAPINFO bmi, uint usage);
    [DllImport("gdi32.dll")]
    static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi, uint usage,
                                           out IntPtr bits, IntPtr hSection, uint offset);
    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO
    {
        public int biSize;
        public int biWidth;
        public int biHeight;
        public short biPlanes;
        public short biBitCount;
        public int biCompression;
        public int biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public int biClrUsed;
        public int biClrImportant;
    }

    const uint SRCCOPY = 0x00CC0020;
    const int COLORONCOLOR = 3;

    private TcpClient client;
    private NetworkStream netStream;
    private ImageCodecInfo jpegCodec;
    private EncoderParameters encoderParams;

    private Bitmap scaledBmp;
    private MemoryStream jpegBuffer;
    private byte[] headerBuf = new byte[4];
    private int screenW, screenH, scaledW, scaledH;

    // Persistent native GDI handles
    private IntPtr hdcScreen;
    private IntPtr hdcMem;
    private IntPtr hDibSection;
    private IntPtr dibBits; // pointer to DIB pixel data
    private IntPtr hOldBitmap;

    public int FramesSent { get; private set; }
    public double LastFrameMs { get; private set; }
    public double CaptureMs { get; private set; }
    public double EncodeMs { get; private set; }
    public double SendMs { get; private set; }
    public int LastFrameBytes { get; private set; }

    public FastScreenSender(int quality, int scalePercent)
    {
        foreach (var codec in ImageCodecInfo.GetImageEncoders())
        {
            if (codec.MimeType == "image/jpeg") { jpegCodec = codec; break; }
        }
        encoderParams = new EncoderParameters(1);
        encoderParams.Param[0] = new EncoderParameter(
            System.Drawing.Imaging.Encoder.Quality, (long)quality);

        var bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        screenW = bounds.Width;
        screenH = bounds.Height;
        scaledW = screenW * scalePercent / 100;
        scaledH = screenH * scalePercent / 100;

        // Create DIB section - a bitmap whose pixels we can access directly
        hdcScreen = GetDC(IntPtr.Zero);
        hdcMem = CreateCompatibleDC(hdcScreen);

        BITMAPINFO bmi = new BITMAPINFO();
        bmi.biSize = 40;
        bmi.biWidth = scaledW;
        bmi.biHeight = -scaledH; // negative = top-down
        bmi.biPlanes = 1;
        bmi.biBitCount = 32;
        bmi.biCompression = 0; // BI_RGB
        bmi.biSizeImage = scaledW * scaledH * 4;

        hDibSection = CreateDIBSection(hdcMem, ref bmi, 0, out dibBits, IntPtr.Zero, 0);
        hOldBitmap = SelectObject(hdcMem, hDibSection);
        SetStretchBltMode(hdcMem, COLORONCOLOR);

        // Managed bitmap that shares layout with DIB
        scaledBmp = new Bitmap(scaledW, scaledH, scaledW * 4,
            PixelFormat.Format32bppRgb, dibBits);

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
            // 1. Capture + Scale in one native call
            // StretchBlt from screen -> DIB section (already scaled)
            // The managed Bitmap points to the same memory, so no copy needed!
            var swStep = Stopwatch.StartNew();
            StretchBlt(hdcMem, 0, 0, scaledW, scaledH,
                       hdcScreen, 0, 0, screenW, screenH, SRCCOPY);
            swStep.Stop();
            CaptureMs = swStep.Elapsed.TotalMilliseconds;

            // 2. Encode to JPEG - bitmap already has the pixels from StretchBlt
            swStep.Restart();
            jpegBuffer.SetLength(0);
            jpegBuffer.Position = 0;
            scaledBmp.Save(jpegBuffer, jpegCodec, encoderParams);
            swStep.Stop();
            EncodeMs = swStep.Elapsed.TotalMilliseconds;

            // 3. Send
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
        if (scaledBmp != null) scaledBmp.Dispose();
        SelectObject(hdcMem, hOldBitmap);
        if (hDibSection != IntPtr.Zero) DeleteObject(hDibSection);
        if (hdcMem != IntPtr.Zero) DeleteDC(hdcMem);
        if (hdcScreen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, hdcScreen);
        if (jpegBuffer != null) jpegBuffer.Dispose();
        if (netStream != null) netStream.Close();
        if (client != null) client.Close();
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Screen Sender v3 (Fast GDI) ==="
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Quality: $Quality, Scale: ${ScalePercent}%, Target: ${TargetFps}fps"

$sender = New-Object FastScreenSender($Quality, $ScalePercent)
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
            $sender = New-Object FastScreenSender($Quality, $ScalePercent)
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
