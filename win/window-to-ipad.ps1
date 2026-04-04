# window-to-ipad.ps1 - Send a specific window to iPad (virtual extended display)
# Captures a window via PrintWindow API (works even if minimized!)
#
# Usage: powershell -ExecutionPolicy Bypass -File window-to-ipad.ps1 -iPadIP "192.168.137.169"

param(
    [string]$iPadIP = "192.168.137.169",
    [int]$Port = 9000,
    [int]$Fps = 24,
    [int]$JpegQuality = 75
)

Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class WinCapture
{
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int maxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    // SendInput structures
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    public const uint INPUT_MOUSE = 0;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    // Convert window-relative coords to absolute screen coords
    // PrintWindow captures the FULL window (including title bar/border),
    // so map touch coords to the full window rect
    private static void GetAbsCoords(IntPtr hWnd, float relX, float relY, out int absX, out int absY)
    {
        RECT winRect;
        GetWindowRect(hWnd, out winRect);
        int w = winRect.Right - winRect.Left;
        int h = winRect.Bottom - winRect.Top;
        absX = winRect.Left + (int)(relX * w);
        absY = winRect.Top + (int)(relY * h);
    }

    public static void SendMouseDown(IntPtr hWnd, float relX, float relY)
    {
        int ax, ay;
        GetAbsCoords(hWnd, relX, relY, out ax, out ay);

        SetForegroundWindow(hWnd);
        SetCursorPos(ax, ay);

        var input = new INPUT[1];
        input[0].type = INPUT_MOUSE;
        input[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void SendMouseMove(IntPtr hWnd, float relX, float relY)
    {
        int ax, ay;
        GetAbsCoords(hWnd, relX, relY, out ax, out ay);
        SetCursorPos(ax, ay);

        var input = new INPUT[1];
        input[0].type = INPUT_MOUSE;
        input[0].mi.dwFlags = MOUSEEVENTF_MOVE;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void SendMouseUp(IntPtr hWnd, float relX, float relY)
    {
        int ax, ay;
        GetAbsCoords(hWnd, relX, relY, out ax, out ay);
        SetCursorPos(ax, ay);

        var input = new INPUT[1];
        input[0].type = INPUT_MOUSE;
        input[0].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static string GetTitle(IntPtr hWnd)
    {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<KeyValuePair<IntPtr, string>> GetWindows()
    {
        var list = new List<KeyValuePair<IntPtr, string>>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            string title = GetTitle(hWnd);
            if (string.IsNullOrEmpty(title)) return true;
            if (title == "Program Manager") return true;
            RECT r;
            GetWindowRect(hWnd, out r);
            if (r.Right - r.Left <= 0) return true;
            list.Add(new KeyValuePair<IntPtr, string>(hWnd, title));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static Bitmap CaptureWindow(IntPtr hWnd)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return null;
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) return null;

        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            // PW_RENDERFULLCONTENT = 2
            PrintWindow(hWnd, hdc, 2);
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }

    public static byte[] ToJpeg(Bitmap bmp, long quality)
    {
        using (var ms = new MemoryStream())
        {
            var enc = GetJpegEncoder();
            var p = new EncoderParameters(1);
            p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
            bmp.Save(ms, enc, p);
            return ms.ToArray();
        }
    }

    private static ImageCodecInfo GetJpegEncoder()
    {
        foreach (var c in ImageCodecInfo.GetImageDecoders())
            if (c.FormatID == ImageFormat.Jpeg.Guid) return c;
        return null;
    }
}

public class WinStreamer : IDisposable
{
    private TcpClient tcp;
    private NetworkStream net;
    private byte[] hdr = new byte[4];
    public int FramesSent;
    public long TotalBytes;
    public int TouchEvents;
    public volatile bool Running = true;
    public volatile IntPtr TouchTarget = IntPtr.Zero;

    public bool Connect(string ip, int port)
    {
        try
        {
            tcp = new TcpClient(); tcp.NoDelay = true;
            tcp.SendBufferSize = 4 * 1024 * 1024;
            tcp.ReceiveBufferSize = 64 * 1024;
            tcp.Connect(ip, port); net = tcp.GetStream();
            return true;
        }
        catch (Exception ex) { Console.WriteLine("TCP: " + ex.Message); return false; }
    }

    public void SendFrame(byte[] jpeg)
    {
        int len = jpeg.Length;
        hdr[0] = (byte)len; hdr[1] = (byte)(len >> 8);
        hdr[2] = (byte)(len >> 16); hdr[3] = (byte)(len >> 24);
        net.Write(hdr, 0, 4);
        net.Write(jpeg, 0, len);
        FramesSent++;
        TotalBytes += len + 4;
    }

    // Start listening for touch events from iPad in background thread
    // Protocol: [1byte type][4byte x_float][4byte y_float] = 9 bytes
    // type: 1=down, 2=move, 3=up
    public void StartTouchReceiver()
    {
        ThreadPool.QueueUserWorkItem(delegate {
            byte[] buf = new byte[9];
            while (Running)
            {
                try
                {
                    // Read exactly 9 bytes
                    int read = 0;
                    while (read < 9 && Running)
                    {
                        int n = net.Read(buf, read, 9 - read);
                        if (n <= 0) { Running = false; return; }
                        read += n;
                    }

                    byte touchType = buf[0];
                    float x = BitConverter.ToSingle(buf, 1);
                    float y = BitConverter.ToSingle(buf, 5);

                    IntPtr hwnd = TouchTarget;
                    if (hwnd == IntPtr.Zero) continue;

                    TouchEvents++;

                    switch (touchType)
                    {
                        case 1: // touchDown
                            WinCapture.SendMouseDown(hwnd, x, y);
                            break;
                        case 2: // touchMoved
                            WinCapture.SendMouseMove(hwnd, x, y);
                            break;
                        case 3: // touchUp
                            WinCapture.SendMouseUp(hwnd, x, y);
                            break;
                    }
                }
                catch { if (Running) Thread.Sleep(10); }
            }
        });
    }

    public void Dispose()
    {
        Running = false;
        if (net != null) try { net.Close(); } catch {}
        if (tcp != null) try { tcp.Close(); } catch {}
    }
}
"@ -ReferencedAssemblies System.Drawing

function Show-WindowList {
    $windows = [WinCapture]::GetWindows()
    Write-Host ""
    Write-Host "  === Open Windows ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $windows.Count -and $i -lt 20; $i++) {
        $title = $windows[$i].Value
        if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + "..." }
        Write-Host "  [$($i+1)] $title" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  [R] Refresh list" -ForegroundColor Gray
    Write-Host "  [Q] Quit" -ForegroundColor Gray
    Write-Host ""
    return $windows
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Window to iPad - Extended Display Mode" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Send any window to iPad!" -ForegroundColor White
Write-Host "  The window can be MINIMIZED on PC" -ForegroundColor White
Write-Host "  and still shows on iPad." -ForegroundColor Green
Write-Host ""

# Window selection loop
$targetHwnd = [IntPtr]::Zero
$streamer = $null

while ($true) {
    # Show window list FIRST (before connecting)
    $windows = Show-WindowList
    Write-Host "  Select window number: " -NoNewline -ForegroundColor Green
    $input = Read-Host

    if ($input -eq "Q" -or $input -eq "q") { break }
    if ($input -eq "R" -or $input -eq "r") { continue }

    $idx = 0
    if (-not [int]::TryParse($input, [ref]$idx) -or $idx -lt 1 -or $idx -gt $windows.Count) {
        Write-Host "  Invalid selection." -ForegroundColor Red
        continue
    }

    $targetHwnd = $windows[$idx - 1].Key
    $targetTitle = $windows[$idx - 1].Value
    Write-Host ""
    Write-Host "  Window: '$targetTitle'" -ForegroundColor Cyan

    # Connect AFTER selection (so no idle time on connection)
    if ($streamer -ne $null) { $streamer.Dispose() }
    $streamer = New-Object WinStreamer
    Write-Host "  Connecting to iPad (${iPadIP}:${Port})..." -ForegroundColor Gray
    $retries = 0
    while (-not $streamer.Connect($iPadIP, $Port)) {
        $retries++
        if ($retries -gt 15) {
            Write-Host "  Connection failed." -ForegroundColor Red
            break
        }
        Start-Sleep -Seconds 2
    }
    if ($retries -gt 15) { continue }
    Write-Host "  Connected! Streaming to iPad..." -ForegroundColor Green

    # Start touch receiver and set touch target
    $streamer.TouchTarget = $targetHwnd
    $streamer.StartTouchReceiver()
    Write-Host "  Touch input: ENABLED (iPad touch -> PC window)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [S] Select different window" -ForegroundColor Gray
    Write-Host "  [M] Minimize window on PC" -ForegroundColor Gray
    Write-Host "  [Q] Quit" -ForegroundColor Gray
    Write-Host ""

    # Streaming loop
    $interval = [int](1000 / $Fps)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fpsCount = 0
    $stopCapture = $false

    while (-not $stopCapture -and $streamer.Running) {
        try {
            if (-not [WinCapture]::IsWindow($targetHwnd)) {
                Write-Host "`n  Window closed!" -ForegroundColor Yellow
                break
            }

            $bmp = [WinCapture]::CaptureWindow($targetHwnd)
            if ($bmp -ne $null) {
                $jpeg = [WinCapture]::ToJpeg($bmp, $JpegQuality)
                $streamer.SendFrame($jpeg)
                $bmp.Dispose()
                $fpsCount++
            }

            # FPS display
            if ($sw.ElapsedMilliseconds -ge 1000) {
                $actualFps = [math]::Round($fpsCount * 1000.0 / $sw.ElapsedMilliseconds, 1)
                $kb = [math]::Round($streamer.TotalBytes / 1024)
                $touch = $streamer.TouchEvents
                Write-Host "`r  FPS: $actualFps | ${kb}KB | Touch: $touch     " -NoNewline
                $fpsCount = 0
                $sw.Restart()
            }

            # Check for key press
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    "S" { $stopCapture = $true }
                    "M" {
                        [WinCapture]::ShowWindow($targetHwnd, 6) | Out-Null
                        Write-Host "`n  Window minimized (still streaming to iPad)" -ForegroundColor Cyan
                    }
                    "Q" { $stopCapture = $true; $streamer.Running = $false }
                }
            }

            Start-Sleep -Milliseconds $interval
        }
        catch {
            Write-Host "`n  Error: $_" -ForegroundColor Red
            break
        }
    }

    if ($streamer -ne $null -and -not $streamer.Running) { break }
    Write-Host ""
}

if ($streamer -ne $null) {
    $streamer.Dispose()
    Write-Host ""
    Write-Host "Done. Total frames: $($streamer.FramesSent)" -ForegroundColor Green
}
