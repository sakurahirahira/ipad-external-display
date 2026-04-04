# virtual-screen.ps1 - Software Virtual Screen for iPad External Display
# Creates a large window that acts as a "second screen" area
# ffmpeg captures this window and streams to iPad
#
# Usage: powershell -ExecutionPolicy Bypass -File virtual-screen.ps1 -iPadIP "192.168.137.169"

param(
    [string]$iPadIP = "192.168.137.169",
    [int]$Port = 9000,
    [int]$Fps = 30,
    [int]$ScreenWidth = 2732,
    [int]$ScreenHeight = 2048,
    [int]$JpegQuality = 5,
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
    Write-Host "ERROR: ffmpeg.exe not found" -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net.Sockets;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Threading;

public class VirtualScreenForm : Form
{
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    private string windowTitle;
    private Label infoLabel;
    private Label hintLabel;

    public VirtualScreenForm(int w, int h)
    {
        windowTitle = "iPadVirtualScreen";
        this.Text = windowTitle;
        this.Width = w / 2;   // Show at half size on PC (scaled down for usability)
        this.Height = h / 2;
        this.FormBorderStyle = FormBorderStyle.Sizable;
        this.BackColor = Color.FromArgb(30, 30, 30);
        this.StartPosition = FormStartPosition.Manual;
        this.Location = new Point(50, 50);
        this.TopMost = true;
        this.ShowInTaskbar = true;
        this.DoubleBuffered = true;

        // Dark title bar (Windows 11)
        try
        {
            int val = 1;
            DwmSetWindowAttribute(this.Handle, 20, ref val, 4);
        }
        catch {}

        // Info label
        infoLabel = new Label();
        infoLabel.Text = "iPad Virtual Screen (" + w + "x" + h + ")";
        infoLabel.ForeColor = Color.FromArgb(100, 200, 255);
        infoLabel.BackColor = Color.Transparent;
        infoLabel.Font = new Font("Segoe UI", 14, FontStyle.Bold);
        infoLabel.AutoSize = true;
        infoLabel.Location = new Point(20, 15);
        this.Controls.Add(infoLabel);

        // Hint
        hintLabel = new Label();
        hintLabel.Text = "Drag app windows into this area\n" +
                         "This area will be shown on iPad\n\n" +
                         "Tips:\n" +
                         "  - Window is resizable\n" +
                         "  - Always on top by default\n" +
                         "  - Right-click for menu";
        hintLabel.ForeColor = Color.FromArgb(180, 180, 180);
        hintLabel.BackColor = Color.Transparent;
        hintLabel.Font = new Font("Segoe UI", 11);
        hintLabel.AutoSize = true;
        hintLabel.Location = new Point(20, 55);
        this.Controls.Add(hintLabel);

        // Border glow effect
        this.Paint += (s, e) => {
            using (var pen = new Pen(Color.FromArgb(80, 100, 200, 255), 2))
            {
                e.Graphics.DrawRectangle(pen, 1, 1, this.ClientSize.Width - 3, this.ClientSize.Height - 3);
            }
        };

        // Context menu
        var menu = new ContextMenuStrip();
        menu.Items.Add("Always on Top: ON/OFF", null, (s, e) => { this.TopMost = !this.TopMost; });
        menu.Items.Add("Transparent: ON/OFF", null, (s, e) => {
            this.Opacity = this.Opacity < 1.0 ? 1.0 : 0.7;
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Black background", null, (s, e) => { this.BackColor = Color.Black; infoLabel.Visible = false; hintLabel.Visible = false; });
        menu.Items.Add("Dark gray background", null, (s, e) => { this.BackColor = Color.FromArgb(30, 30, 30); infoLabel.Visible = true; hintLabel.Visible = true; });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Close", null, (s, e) => { this.Close(); });
        this.ContextMenuStrip = menu;
    }

    public string GetTitle() { return windowTitle; }
}

public class VirtualScreenStreamer : IDisposable
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

    public bool StartCapture(string ffmpegPath, string windowTitle, int fps, int outWidth, int outHeight, int quality)
    {
        var psi = new ProcessStartInfo();
        psi.FileName = ffmpegPath;

        // Capture specific window by title
        string scaleRes = outWidth + ":" + outHeight;
        psi.Arguments = "-hide_banner -loglevel error " +
            "-f gdigrab -framerate " + fps + " -i title=\"" + windowTitle + "\" " +
            "-vf \"scale=" + scaleRes + ":force_original_aspect_ratio=decrease,pad=" + scaleRes + ":(ow-iw)/2:(oh-ih)/2:black\" " +
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

    public void StreamLoop()
    {
        var ffOut = ffProcess.StandardOutput.BaseStream;
        byte[] readBuf = new byte[1024 * 1024];
        byte[] frameBuf = new byte[4 * 1024 * 1024];
        int framePos = 0;
        var sw = Stopwatch.StartNew();
        int fpsCount = 0;

        while (!ffProcess.HasExited)
        {
            int read = ffOut.Read(readBuf, 0, readBuf.Length);
            if (read <= 0) break;

            for (int i = 0; i < read; i++)
            {
                frameBuf[framePos++] = readBuf[i];

                if (framePos >= 2 && frameBuf[framePos - 2] == 0xFF && frameBuf[framePos - 1] == 0xD9)
                {
                    if (framePos >= 4 && frameBuf[0] == 0xFF && frameBuf[1] == 0xD8)
                    {
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

                if (framePos >= frameBuf.Length - 1) framePos = 0;
            }

            if (sw.ElapsedMilliseconds >= 1000)
            {
                double fps = fpsCount * 1000.0 / sw.ElapsedMilliseconds;
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
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

Write-Host "=== iPad Virtual Screen ===" -ForegroundColor Cyan
Write-Host "ffmpeg: $FFmpegPath"
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Virtual screen: ${ScreenWidth}x${ScreenHeight}"
Write-Host ""

# Create and show virtual screen window in a separate thread
$form = New-Object VirtualScreenForm($ScreenWidth, $ScreenHeight)
$windowTitle = $form.GetTitle()

# Run form in background thread
$formThread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    [System.Windows.Forms.Application]::Run($form)
})
$formThread.SetApartmentState([System.Threading.ApartmentState]::STA)
$formThread.IsBackground = $true
$formThread.Start()

# Wait for window to appear
Write-Host "Starting virtual screen window..." -ForegroundColor Gray
Start-Sleep -Seconds 2

Write-Host "Window '$windowTitle' created" -ForegroundColor Green
Write-Host ""

# Connect and stream
$streamer = New-Object VirtualScreenStreamer

Write-Host "Connecting to iPad..."
$retries = 0
while (-not $streamer.Connect($iPadIP, $Port)) {
    $retries++
    if ($retries -gt 15) {
        Write-Host "Connection failed. Check iPad app is running." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Retry... ($retries)" -ForegroundColor Gray
    Start-Sleep -Seconds 2
}
Write-Host "Connected!" -ForegroundColor Green

Write-Host ""
Write-Host "Streaming started!" -ForegroundColor Green
Write-Host "  - Drag app windows into the virtual screen window" -ForegroundColor White
Write-Host "  - The window content will be shown on iPad" -ForegroundColor White
Write-Host "  - Right-click for settings menu" -ForegroundColor White
Write-Host "  - Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""

if (-not $streamer.StartCapture($FFmpegPath, $windowTitle, $Fps, $ScreenWidth, $ScreenHeight, $JpegQuality)) {
    Write-Host "ffmpeg start failed" -ForegroundColor Red
    exit 1
}

try {
    $streamer.StreamLoop()
}
finally {
    $streamer.Dispose()
    Write-Host ""
    Write-Host "Done. Frames: $($streamer.FramesSent)" -ForegroundColor Green
}
