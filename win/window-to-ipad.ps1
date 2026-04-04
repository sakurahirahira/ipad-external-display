# window-to-ipad.ps1 - Send a specific window to iPad (virtual extended display)
# Captures a window via PrintWindow API (works even if minimized!)
#
# Usage: powershell -ExecutionPolicy Bypass -File window-to-ipad.ps1 -iPadIP "192.168.137.169"

param(
    [string]$iPadIP = "192.168.137.169",
    [int]$Port = 9000,
    [int]$VideoPort = 9001,
    [int]$Fps = 30,
    [int]$JpegQuality = 80,
    [string]$Resolution = "2732x2048",  # iPad Air 13" M3 native resolution
    [string]$FFmpegPath = ""
)

# Auto-enable Mobile Hotspot via WinRT API (no admin required)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime] | Out-Null
    $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]::GetInternetConnectionProfile()
    $manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($connectionProfile)
    if ($manager.TetheringOperationalState -ne "On") {
        Write-Host "  Mobile Hotspot is OFF. Turning on..." -ForegroundColor Yellow
        $async = $manager.StartTetheringAsync()
        $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod
        } | Select-Object -First 1
        $task = $asTaskMethod.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($async))
        $task.Wait() | Out-Null
        $result = $task.Result
        if ($result.Status -eq [Windows.Networking.NetworkOperators.TetheringOperationStatus]::Success) {
            Write-Host "  Mobile Hotspot: ON" -ForegroundColor Green
            Start-Sleep -Seconds 2
        } else {
            Write-Host "  Failed to start hotspot: $($result.Status)" -ForegroundColor Red
        }
    } else {
        Write-Host "  Mobile Hotspot: ON" -ForegroundColor Green
    }
} catch {
    Write-Host "  Hotspot auto-start failed: $_" -ForegroundColor Yellow
    Write-Host "  Please enable Mobile Hotspot manually." -ForegroundColor Yellow
}

# Find ffmpeg for H.264 hardware encoding (Intel QSV)
if (-not $FFmpegPath) {
    $candidates = @(
        "$env:USERPROFILE\ffmpeg.exe",
        "$env:USERPROFILE\Desktop\ffmpeg.exe",
        "$env:USERPROFILE\Downloads\ffmpeg.exe",
        "C:\ffmpeg\bin\ffmpeg.exe",
        "C:\ffmpeg\ffmpeg.exe",
        "$PSScriptRoot\ffmpeg.exe"
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

$useH264 = $false
if ($FFmpegPath -and (Test-Path $FFmpegPath)) {
    Write-Host "  ffmpeg found: $FFmpegPath" -ForegroundColor Green
    Write-Host "  HW JPEG mode enabled (MJPEG QSV with fallback)" -ForegroundColor Green
    $useH264 = $true
} else {
    Write-Host "  ffmpeg not found - using software JPEG mode" -ForegroundColor Yellow
    Write-Host "  Place ffmpeg.exe next to this script for HW-accelerated encoding" -ForegroundColor Yellow
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

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

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CURSORINFO pci);

    [DllImport("user32.dll")]
    public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr hIcon,
        int cxWidth, int cyWidth, uint istepIfAniCur, IntPtr hbrFlickerFreeDraw, uint diFlags);

    private const uint DI_NORMAL = 0x0003;

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool repaint);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AdjustWindowRect(ref RECT lpRect, uint dwStyle, bool bMenu);

    [DllImport("user32.dll")]
    public static extern uint GetWindowLong(IntPtr hWnd, int nIndex);

    private const int GWL_STYLE = -16;

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    // Resize window to iPad aspect ratio, fitting within PC screen
    // ScaleToFill will upscale to full iPad resolution
    public static void ResizeToClientArea(IntPtr hWnd, int targetW, int targetH)
    {
        RECT winRect;
        GetWindowRect(hWnd, out winRect);

        int screenW = GetSystemMetrics(0);
        int screenH = GetSystemMetrics(1);

        // Use max screen height, match iPad aspect ratio
        float aspect = (float)targetW / targetH;
        int clientH = screenH - 80; // leave room for titlebar
        int clientW = (int)(clientH * aspect);
        if (clientW > screenW)
        {
            clientW = screenW;
            clientH = (int)(clientW / aspect);
        }

        uint style = GetWindowLong(hWnd, GWL_STYLE);
        RECT r;
        r.Left = 0; r.Top = 0; r.Right = clientW; r.Bottom = clientH;
        AdjustWindowRect(ref r, style, false);

        MoveWindow(hWnd, 0, 0, r.Right - r.Left, r.Bottom - r.Top, true);
    }

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

    // Convert touch coords to absolute screen coords
    // Image sent is client area only, so map to client area
    private static void GetAbsCoords(IntPtr hWnd, float relX, float relY, out int absX, out int absY)
    {
        RECT winRect;
        GetWindowRect(hWnd, out winRect);
        RECT client;
        GetClientRect(hWnd, out client);

        int winW = winRect.Right - winRect.Left;
        int borderX = (winW - client.Right) / 2;
        int titleY = (winRect.Bottom - winRect.Top) - client.Bottom - borderX;

        absX = winRect.Left + borderX + (int)(relX * client.Right);
        absY = winRect.Top + titleY + (int)(relY * client.Bottom);
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

    public static void SendMouseHover(IntPtr hWnd, float relX, float relY)
    {
        int ax, ay;
        GetAbsCoords(hWnd, relX, relY, out ax, out ay);
        SetCursorPos(ax, ay);
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

    // Reusable capture buffer
    private static Bitmap captureBuf;
    private static int capBufW, capBufH;

    public static Bitmap CaptureWindow(IntPtr hWnd)
    {
        RECT client;
        GetClientRect(hWnd, out client);
        int cw = client.Right;
        int ch = client.Bottom;
        if (cw <= 0 || ch <= 0) return null;

        if (captureBuf == null || capBufW != cw || capBufH != ch)
        {
            if (captureBuf != null) captureBuf.Dispose();
            captureBuf = new Bitmap(cw, ch, PixelFormat.Format32bppArgb);
            capBufW = cw;
            capBufH = ch;
        }

        using (var g = Graphics.FromImage(captureBuf))
        {
            IntPtr hdc = g.GetHdc();
            // PW_CLIENTONLY=1 | PW_RENDERFULLCONTENT=2 = 3 (fast, client area only)
            PrintWindow(hWnd, hdc, 3);
            g.ReleaseHdc(hdc);
        }
        return captureBuf;
    }

    // Fast dirty check: sample a few pixels to detect if frame changed
    private static byte[] prevHash;

    public static bool FrameChanged(Bitmap bmp)
    {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        int h = bmp.Height;
        int w = bmp.Width;

        // Sample 16 pixels spread across image
        byte[] hash = new byte[64];
        int idx = 0;
        for (int i = 0; i < 16; i++)
        {
            int sy = (h * (i + 1)) / 17;
            int sx = (w * ((i * 7 + 3) % 16 + 1)) / 17;
            IntPtr row = (IntPtr)(data.Scan0.ToInt64() + sy * stride + sx * 4);
            hash[idx++] = Marshal.ReadByte(row, 0);
            hash[idx++] = Marshal.ReadByte(row, 1);
            hash[idx++] = Marshal.ReadByte(row, 2);
            hash[idx++] = Marshal.ReadByte(row, 3);
        }
        bmp.UnlockBits(data);

        if (prevHash != null)
        {
            bool same = true;
            for (int i = 0; i < 64; i++)
                if (hash[i] != prevHash[i]) { same = false; break; }
            if (same) return false;
        }
        prevHash = hash;
        return true;
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

    // Capture a thumbnail (new bitmap, caller must dispose)
    public static Bitmap CaptureThumbnail(IntPtr hWnd, int thumbW, int thumbH)
    {
        // If minimized, temporarily restore for capture
        bool wasMinimized = IsIconic(hWnd);
        if (wasMinimized) ShowWindow(hWnd, 9); // SW_RESTORE

        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return null;
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) return null;

        var full = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(full))
        {
            IntPtr hdc = g.GetHdc();
            PrintWindow(hWnd, hdc, 2);
            g.ReleaseHdc(hdc);
        }

        // Re-minimize if it was minimized
        if (wasMinimized) ShowWindow(hWnd, 6); // SW_MINIMIZE

        var thumb = new Bitmap(thumbW, thumbH);
        using (var g = Graphics.FromImage(thumb))
        {
            g.Clear(Color.Black);
            g.InterpolationMode = InterpolationMode.Bilinear;
            float scale = Math.Min((float)thumbW / w, (float)thumbH / h);
            int nw = (int)(w * scale), nh = (int)(h * scale);
            g.DrawImage(full, (thumbW - nw) / 2, (thumbH - nh) / 2, nw, nh);
        }
        full.Dispose();
        return thumb;
    }
}

public class WinStreamer : IDisposable
{
    private TcpClient tcp;
    private NetworkStream net;
    private byte[] hdr = new byte[4];
    private object sendLock = new object();
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
        lock (sendLock)
        {
            int len = jpeg.Length;
            hdr[0] = (byte)len; hdr[1] = (byte)(len >> 8);
            hdr[2] = (byte)(len >> 16); hdr[3] = (byte)(len >> 24);
            net.Write(hdr, 0, 4);
            net.Write(jpeg, 0, len);
            FramesSent++;
            TotalBytes += len + 4;
        }
    }

    // Send cursor position as separate high-frequency packet
    // Protocol: len=0xFFFFFFFF marker + [4byte x_float][4byte y_float][1byte visible]
    private void SendCursorPacket(float x, float y, byte visible)
    {
        lock (sendLock)
        {
            byte[] pkt = new byte[13];
            pkt[0] = 0xFF; pkt[1] = 0xFF; pkt[2] = 0xFF; pkt[3] = 0xFF;
            BitConverter.GetBytes(x).CopyTo(pkt, 4);
            BitConverter.GetBytes(y).CopyTo(pkt, 8);
            pkt[12] = visible;
            net.Write(pkt, 0, 13);
        }
    }

    // Background thread: send cursor position at ~60fps
    public void StartCursorSender()
    {
        ThreadPool.QueueUserWorkItem(delegate {
            float lastX = -1, lastY = -1;
            while (Running)
            {
                try
                {
                    IntPtr hwnd = TouchTarget;
                    if (hwnd == IntPtr.Zero) { Thread.Sleep(50); continue; }

                    WinCapture.POINT pt;
                    WinCapture.GetCursorPos(out pt);
                    WinCapture.RECT winRect;
                    WinCapture.GetWindowRect(hwnd, out winRect);
                    WinCapture.RECT client;
                    WinCapture.GetClientRect(hwnd, out client);

                    int w = winRect.Right - winRect.Left;
                    int cw = client.Right;
                    int ch = client.Bottom;
                    if (cw <= 0 || ch <= 0) { Thread.Sleep(16); continue; }

                    int borderX = (w - cw) / 2;
                    int titleY = (winRect.Bottom - winRect.Top) - ch - borderX;
                    int cx = pt.X - winRect.Left - borderX;
                    int cy = pt.Y - winRect.Top - titleY;

                    float rx = (float)cx / cw;
                    float ry = (float)cy / ch;
                    byte vis = (byte)((cx >= 0 && cy >= 0 && cx < cw && cy < ch) ? 1 : 0);

                    // Only send if position changed
                    if (rx != lastX || ry != lastY)
                    {
                        SendCursorPacket(rx, ry, vis);
                        lastX = rx;
                        lastY = ry;
                    }

                    Thread.Sleep(16); // ~60fps
                }
                catch { if (Running) Thread.Sleep(50); }
            }
        });
    }

    // Start listening for touch events from iPad in background thread
    // Protocol: [1byte type][4byte x_float][4byte y_float] = 9 bytes
    // type: 1=down, 2=move, 3=up, 4=hover
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
                        case 4: // hover (mouse move without button)
                            WinCapture.SendMouseHover(hwnd, x, y);
                            break;
                    }
                }
                catch { if (Running) Thread.Sleep(10); }
            }
        });
    }

    // Get PC's IP as seen from iPad (from the TCP connection)
    public string LocalIP
    {
        get
        {
            if (tcp != null && tcp.Connected)
            {
                var ep = (IPEndPoint)tcp.Client.LocalEndPoint;
                return ep.Address.ToString();
            }
            return "192.168.137.1";
        }
    }

    // Send H264 mode header: "H264" magic + port(uint16) + IP(null-terminated)
    public void SendH264Header(int videoPort)
    {
        lock (sendLock)
        {
            net.Write(new byte[] { 0x48, 0x32, 0x36, 0x34 }, 0, 4); // "H264"
            byte[] portB = BitConverter.GetBytes((ushort)videoPort);
            net.Write(portB, 0, 2);
            byte[] ipB = Encoding.ASCII.GetBytes(LocalIP + "\0");
            net.Write(ipB, 0, ipB.Length);
        }
    }

    public void Dispose()
    {
        Running = false;
        if (net != null) try { net.Close(); } catch {}
        if (tcp != null) try { tcp.Close(); } catch {}
    }
}

public class WindowPicker
{
    public static int Show(List<KeyValuePair<IntPtr, string>> windows)
    {
        int selected = -1;
        int thumbW = 220, thumbH = 140;
        int cellW = thumbW + 20, cellH = thumbH + 40;
        int cols = 4;
        int count = Math.Min(windows.Count, 16);
        int rows = (count + cols - 1) / cols;

        // Capture thumbnails
        var thumbnails = new List<Bitmap>();
        var titles = new List<string>();
        for (int i = 0; i < count; i++)
        {
            thumbnails.Add(WinCapture.CaptureThumbnail(windows[i].Key, thumbW, thumbH));
            string t = windows[i].Value;
            if (t.Length > 28) t = t.Substring(0, 28) + "...";
            titles.Add(t);
        }

        int formW = cols * cellW + 40;
        int formH = rows * cellH + 100;

        var form = new Form();
        form.Text = "Window to iPad - Click to stream";
        form.Width = formW;
        form.Height = formH;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        form.TopMost = true;
        form.BackColor = Color.FromArgb(30, 30, 30);

        var panel = new Panel();
        panel.Left = 10; panel.Top = 10;
        panel.Width = formW - 30;
        panel.Height = rows * cellH;
        panel.BackColor = Color.FromArgb(30, 30, 30);
        form.Controls.Add(panel);

        var selBorder = new Panel(); // highlight indicator
        selBorder.Visible = false;
        selBorder.BackColor = Color.FromArgb(0, 120, 215);
        panel.Controls.Add(selBorder);

        for (int i = 0; i < count; i++)
        {
            int col = i % cols;
            int row = i / cols;
            int x = col * cellW + 5;
            int y = row * cellH + 5;
            int idx = i;

            // Thumbnail PictureBox
            var pic = new PictureBox();
            pic.Left = x + 5;
            pic.Top = y + 5;
            pic.Width = thumbW;
            pic.Height = thumbH;
            pic.SizeMode = PictureBoxSizeMode.StretchImage;
            pic.BorderStyle = BorderStyle.FixedSingle;
            if (thumbnails[i] != null) pic.Image = thumbnails[i];
            pic.Cursor = Cursors.Hand;

            // Click = select + close
            pic.Click += delegate {
                selected = idx;
                form.Close();
            };
            // Hover highlight
            pic.MouseEnter += delegate {
                selBorder.Left = pic.Left - 3;
                selBorder.Top = pic.Top - 3;
                selBorder.Width = pic.Width + 6;
                selBorder.Height = pic.Height + 6;
                selBorder.Visible = true;
                selBorder.SendToBack();
            };
            pic.MouseLeave += delegate { selBorder.Visible = false; };
            panel.Controls.Add(pic);

            // Title label
            var lbl = new Label();
            lbl.Left = x;
            lbl.Top = y + thumbH + 8;
            lbl.Width = cellW - 10;
            lbl.Height = 25;
            lbl.Text = titles[i];
            lbl.Font = new Font("Segoe UI", 8);
            lbl.ForeColor = Color.White;
            lbl.TextAlign = ContentAlignment.TopCenter;
            lbl.Cursor = Cursors.Hand;
            lbl.Click += delegate { selected = idx; form.Close(); };
            panel.Controls.Add(lbl);
        }

        // Bottom buttons
        int btnY = formH - 75;

        var btnRefresh = new Button();
        btnRefresh.Text = "Refresh";
        btnRefresh.Left = formW - 260; btnRefresh.Top = btnY;
        btnRefresh.Width = 110; btnRefresh.Height = 32;
        btnRefresh.Font = new Font("Segoe UI", 9);
        btnRefresh.FlatStyle = FlatStyle.Flat;
        btnRefresh.BackColor = Color.FromArgb(60, 60, 60);
        btnRefresh.ForeColor = Color.White;
        btnRefresh.Click += delegate { selected = -2; form.Close(); };
        form.Controls.Add(btnRefresh);

        var btnQuit = new Button();
        btnQuit.Text = "Quit";
        btnQuit.Left = formW - 140; btnQuit.Top = btnY;
        btnQuit.Width = 110; btnQuit.Height = 32;
        btnQuit.Font = new Font("Segoe UI", 9);
        btnQuit.FlatStyle = FlatStyle.Flat;
        btnQuit.BackColor = Color.FromArgb(60, 60, 60);
        btnQuit.ForeColor = Color.White;
        btnQuit.Click += delegate { selected = -1; form.Close(); };
        form.Controls.Add(btnQuit);
        form.CancelButton = btnQuit;

        form.ShowDialog();

        foreach (var t in thumbnails) if (t != null) t.Dispose();
        form.Dispose();
        return selected;
    }
}

public class StreamingPanel
{
    public volatile int Action = 0; // 0=streaming, 1=change window, 2=quit
    private Form form;
    private Label lblStatus;
    private Label lblTitle;

    public void Show(string windowTitle)
    {
        form = new Form();
        form.Text = "Window to iPad - Streaming";
        form.Width = 350;
        form.Height = 180;
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(
            Screen.PrimaryScreen.WorkingArea.Right - 360,
            Screen.PrimaryScreen.WorkingArea.Bottom - 190);
        form.FormBorderStyle = FormBorderStyle.FixedSingle;
        form.TopMost = false;
        form.BackColor = Color.FromArgb(30, 30, 30);
        form.ShowInTaskbar = true;

        lblTitle = new Label();
        lblTitle.Text = windowTitle;
        if (lblTitle.Text.Length > 35) lblTitle.Text = lblTitle.Text.Substring(0, 35) + "...";
        lblTitle.Left = 15; lblTitle.Top = 10;
        lblTitle.Width = 310; lblTitle.Height = 22;
        lblTitle.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        lblTitle.ForeColor = Color.FromArgb(0, 180, 255);
        form.Controls.Add(lblTitle);

        lblStatus = new Label();
        lblStatus.Text = "Connecting...";
        lblStatus.Left = 15; lblStatus.Top = 38;
        lblStatus.Width = 310; lblStatus.Height = 45;
        lblStatus.Font = new Font("Consolas", 10);
        lblStatus.ForeColor = Color.FromArgb(200, 200, 200);
        form.Controls.Add(lblStatus);

        int btnY = 95;
        var btnChange = new Button();
        btnChange.Text = "Change Window";
        btnChange.Left = 15; btnChange.Top = btnY;
        btnChange.Width = 150; btnChange.Height = 35;
        btnChange.Font = new Font("Segoe UI", 9);
        btnChange.FlatStyle = FlatStyle.Flat;
        btnChange.BackColor = Color.FromArgb(0, 100, 180);
        btnChange.ForeColor = Color.White;
        btnChange.Click += delegate { Action = 1; };
        form.Controls.Add(btnChange);

        var btnQuit = new Button();
        btnQuit.Text = "Quit";
        btnQuit.Left = 175; btnQuit.Top = btnY;
        btnQuit.Width = 150; btnQuit.Height = 35;
        btnQuit.Font = new Font("Segoe UI", 9);
        btnQuit.FlatStyle = FlatStyle.Flat;
        btnQuit.BackColor = Color.FromArgb(60, 60, 60);
        btnQuit.ForeColor = Color.White;
        btnQuit.Click += delegate { Action = 2; };
        form.Controls.Add(btnQuit);
        form.CancelButton = btnQuit;

        form.FormClosing += delegate(object s, FormClosingEventArgs e) {
            if (Action == 0) { Action = 2; }
        };

        form.Show();
    }

    public void UpdateStatus(string text)
    {
        if (form != null && !form.IsDisposed && lblStatus != null)
        {
            try { lblStatus.Text = text; } catch {}
        }
    }

    public void Close()
    {
        if (form != null && !form.IsDisposed)
        {
            try { form.Close(); } catch {}
        }
    }
}

// HW-accelerated JPEG encoder via ffmpeg QSV with optimized buffered pipe
public class HWEncoder : IDisposable
{
    private Process ffProc;
    private Stream ffIn;
    private Stream ffOut;
    private Thread writerThread;
    private Thread readerThread;
    private byte[] pendingBuf;
    private byte[] writeBuf;
    private object frameLock = new object();
    private volatile bool hasPending;
    private byte[] encodedBuf;
    private int encodedLen;
    private object outLock = new object();
    private volatile bool hasEncoded;
    private volatile bool running;
    private int fW, fH, rawSize;
    public string Encoder = "";
    public int FramesSent;
    public bool IsRunning { get { return running && ffProc != null && !ffProc.HasExited; } }

    public bool Start(string ffPath, int w, int h, int fps)
    {
        fW = w; fH = h;
        rawSize = w * h * 4;
        pendingBuf = new byte[rawSize];
        writeBuf = new byte[rawSize];
        running = true;
        if (TryStart(ffPath, w, h, fps, "mjpeg_qsv", "-global_quality 80")) return true;
        if (TryStart(ffPath, w, h, fps, "mjpeg", "-q:v 5")) return true;
        return false;
    }

    private bool TryStart(string p, int w, int h, int fps, string codec, string opts)
    {
        var psi = new ProcessStartInfo();
        psi.FileName = p;
        psi.Arguments = string.Format(
            "-y -f rawvideo -pix_fmt bgra -s {0}x{1} -r {2} -i pipe:0 " +
            "-vf format=nv12 -c:v {3} {4} -f image2pipe pipe:1",
            w, h, fps, codec, opts);
        psi.UseShellExecute = false;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        try
        {
            ffProc = Process.Start(psi);
            Thread.Sleep(500);
            if (ffProc.HasExited) { Console.WriteLine(codec + " not available"); return false; }
            Encoder = codec;
            ffIn = ffProc.StandardInput.BaseStream;
            ffOut = ffProc.StandardOutput.BaseStream;
            ThreadPool.QueueUserWorkItem(delegate {
                try { while (ffProc.StandardError.ReadLine() != null) { } } catch { }
            });
            writerThread = new Thread(WriterLoop) { IsBackground = true };
            writerThread.Start();
            readerThread = new Thread(ReaderLoop) { IsBackground = true };
            readerThread.Start();
            Console.WriteLine("HW Encoder: " + codec + " @ " + w + "x" + h);
            return true;
        }
        catch { return false; }
    }

    private void WriterLoop()
    {
        while (running)
        {
            if (hasPending)
            {
                lock (frameLock)
                {
                    Buffer.BlockCopy(pendingBuf, 0, writeBuf, 0, rawSize);
                    hasPending = false;
                }
                try { ffIn.Write(writeBuf, 0, rawSize); ffIn.Flush(); }
                catch { if (running) Thread.Sleep(50); }
            }
            else Thread.Sleep(1);
        }
    }

    private void ReaderLoop()
    {
        byte[] readBuf = new byte[512 * 1024];
        byte[] frameBuf = new byte[4 * 1024 * 1024];
        int pos = 0;
        while (running && !ffProc.HasExited)
        {
            try
            {
                int n = ffOut.Read(readBuf, 0, readBuf.Length);
                if (n <= 0) break;
                for (int i = 0; i < n; i++)
                {
                    frameBuf[pos++] = readBuf[i];
                    if (pos >= 2 && frameBuf[pos - 2] == 0xFF && frameBuf[pos - 1] == 0xD9)
                    {
                        if (pos >= 4 && frameBuf[0] == 0xFF && frameBuf[1] == 0xD8)
                        {
                            lock (outLock)
                            {
                                if (encodedBuf == null || encodedBuf.Length < pos)
                                    encodedBuf = new byte[pos * 2];
                                Buffer.BlockCopy(frameBuf, 0, encodedBuf, 0, pos);
                                encodedLen = pos;
                                hasEncoded = true;
                            }
                            FramesSent++;
                        }
                        pos = 0;
                    }
                    if (pos >= frameBuf.Length - 1) pos = 0;
                }
            }
            catch { break; }
        }
    }

    public void WriteFrame(Bitmap bmp)
    {
        if (!running || bmp.Width != fW || bmp.Height != fH) return;
        try
        {
            var d = bmp.LockBits(new Rectangle(0, 0, fW, fH),
                ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                lock (frameLock)
                {
                    int rawRow = fW * 4;
                    if (d.Stride == rawRow)
                        Marshal.Copy(d.Scan0, pendingBuf, 0, rawSize);
                    else
                        for (int y = 0; y < fH; y++)
                            Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + y * d.Stride),
                                pendingBuf, y * rawRow, rawRow);
                    hasPending = true;
                }
            }
            finally { bmp.UnlockBits(d); }
        }
        catch { }
    }

    public byte[] GetFrame()
    {
        if (!hasEncoded) return null;
        lock (outLock)
        {
            if (!hasEncoded) return null;
            byte[] result = new byte[encodedLen];
            Buffer.BlockCopy(encodedBuf, 0, result, 0, encodedLen);
            hasEncoded = false;
            return result;
        }
    }

    public void Dispose()
    {
        running = false;
        try { if (ffProc != null && !ffProc.HasExited) ffProc.Kill(); } catch { }
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

# Parse target resolution
$resParts = $Resolution.Split("x")
$targetW = [int]$resParts[0]
$targetH = [int]$resParts[1]

# All GUI, no terminal interaction needed
$targetHwnd = [IntPtr]::Zero
$streamer = $null

while ($true) {
    # GUI: Window picker (grid with thumbnails)
    $windows = [WinCapture]::GetWindows()
    $pick = [WindowPicker]::Show($windows)

    if ($pick -eq -1) { break }       # Quit
    if ($pick -eq -2) { continue }    # Refresh

    $targetHwnd = $windows[$pick].Key
    $targetTitle = $windows[$pick].Value

    # Resize window to iPad aspect ratio
    [WinCapture]::ResizeToClientArea($targetHwnd, $targetW, $targetH)

    # Connect to iPad (control channel)
    if ($streamer -ne $null) { $streamer.Dispose() }
    $streamer = New-Object WinStreamer

    # GUI: Show streaming status panel
    $panel = New-Object StreamingPanel
    $panel.Show($targetTitle)
    $panel.UpdateStatus("Connecting to iPad...")
    [System.Windows.Forms.Application]::DoEvents()

    $retries = 0
    while (-not $streamer.Connect($iPadIP, $Port)) {
        $retries++
        if ($retries -gt 15) {
            $panel.UpdateStatus("Connection failed!")
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 2
            $panel.Close()
            break
        }
        $panel.UpdateStatus("Connecting... ($retries/15)")
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 2
    }
    if ($retries -gt 15) { continue }

    # Start HW encoder (QSV with buffered pipe) if ffmpeg available
    $hwenc = $null
    $encoderLabel = "JPEG"
    if ($useH264) {
        $clientRect = New-Object WinCapture+RECT
        [WinCapture]::GetClientRect($targetHwnd, [ref]$clientRect)
        $captureW = $clientRect.Right
        $captureH = $clientRect.Bottom

        if ($captureW -gt 0 -and $captureH -gt 0) {
            $hwenc = New-Object HWEncoder
            $panel.UpdateStatus("Starting HW encoder (buffered pipe)...")
            [System.Windows.Forms.Application]::DoEvents()

            if ($hwenc.Start($FFmpegPath, $captureW, $captureH, $Fps)) {
                $encoderLabel = $hwenc.Encoder
                $panel.UpdateStatus("$encoderLabel ready!")
                [System.Windows.Forms.Application]::DoEvents()
            } else {
                Write-Host "  HW encoder failed, falling back to SW JPEG" -ForegroundColor Yellow
                $hwenc.Dispose()
                $hwenc = $null
            }
        }
    }

    # Start touch receiver + cursor sender
    $streamer.TouchTarget = $targetHwnd
    $streamer.StartTouchReceiver()
    $streamer.StartCursorSender()
    $panel.UpdateStatus("$encoderLabel | Touch ON")
    [System.Windows.Forms.Application]::DoEvents()

    # Streaming loop (GUI-driven)
    $interval = [int](1000 / $Fps)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $frameSw = [System.Diagnostics.Stopwatch]::New()
    $fpsCount = 0

    while ($panel.Action -eq 0 -and $streamer.Running) {
        try {
            $frameSw.Restart()

            if (-not [WinCapture]::IsWindow($targetHwnd)) {
                $panel.UpdateStatus("Window closed!")
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Seconds 1
                break
            }

            $bmp = [WinCapture]::CaptureWindow($targetHwnd)
            if ($bmp -ne $null) {
                if ($hwenc -ne $null) {
                    # HW encode: capture -> buffered pipe -> QSV encode -> JPEG
                    $hwenc.WriteFrame($bmp)
                    $jpeg = $hwenc.GetFrame()
                    if ($jpeg -ne $null) {
                        $streamer.SendFrame($jpeg)
                        $fpsCount++
                    }
                } elseif ([WinCapture]::FrameChanged($bmp)) {
                    # SW JPEG fallback
                    $jpeg = [WinCapture]::ToJpeg($bmp, $JpegQuality)
                    $streamer.SendFrame($jpeg)
                    $fpsCount++
                }
            }

            # Update status GUI every second
            if ($sw.ElapsedMilliseconds -ge 1000) {
                $actualFps = [math]::Round($fpsCount * 1000.0 / $sw.ElapsedMilliseconds, 1)
                $kb = [math]::Round($streamer.TotalBytes / 1024)
                $touch = $streamer.TouchEvents
                $panel.UpdateStatus("$encoderLabel | FPS: $actualFps | ${kb} KB | Touch: $touch")
                $fpsCount = 0
                $sw.Restart()
            }

            # Keep GUI responsive
            [System.Windows.Forms.Application]::DoEvents()

            # Adaptive sleep: only sleep remaining time to hit target interval
            $elapsed = [int]$frameSw.ElapsedMilliseconds
            $remaining = $interval - $elapsed
            if ($remaining -gt 1) { Start-Sleep -Milliseconds $remaining }

            # Check if encoder died
            if ($hwenc -ne $null -and -not $hwenc.IsRunning) {
                $panel.UpdateStatus("Encoder stopped!")
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Seconds 1
                break
            }
        }
        catch {
            $panel.UpdateStatus("Error: $_")
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 2
            break
        }
    }

    $panel.Close()
    if ($hwenc -ne $null) { $hwenc.Dispose(); $hwenc = $null }

    # Quit requested
    if ($panel.Action -eq 2 -or (-not $streamer.Running)) { break }
    # Action 1 = change window -> loop back to picker
}

if ($streamer -ne $null) {
    $streamer.Dispose()
}
