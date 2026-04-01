# screen-sender-v7.ps1 - DXGI + MF H.264 SinkWriter -> TCP via growing file
# Captures DISPLAY2, encodes H.264, streams to iPad in real-time
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-v7.ps1 -iPadIP "192.168.8.240"

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [int]$Fps = 30,
    [int]$Width = 0,       # 0 = auto from DXGI
    [int]$Height = 0,
    [int]$BitrateMbps = 10,
    [int]$DisplayIndex = 1  # 0=primary, 1=second display
)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;

public static class MF
{
    [DllImport("mfplat.dll")] public static extern int MFStartup(uint ver, uint flags);
    [DllImport("mfplat.dll")] public static extern int MFShutdown();
    [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(uint cb, out IntPtr pp);
    [DllImport("mfreadwrite.dll")] public static extern int MFCreateSinkWriterFromURL(
        [MarshalAs(UnmanagedType.LPWStr)] string url, IntPtr stream, IntPtr attrs, out IntPtr pp);
    [DllImport("dxgi.dll")] public static extern int CreateDXGIFactory1([MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr pp);
    [DllImport("d3d11.dll")] public static extern int D3D11CreateDevice(IntPtr a, int dt, IntPtr sw, uint f, int[] fl, uint fc, uint sdk, out IntPtr d, out int feat, out IntPtr ctx);
    [DllImport("kernel32.dll", EntryPoint="RtlMoveMemory")] public static extern void Memcpy(IntPtr d, IntPtr s, uint c);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int a);

    // Cursor
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHot, yHot; public IntPtr hbmMask, hbmColor; }
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr h, int cw, int ch, uint step, IntPtr br, uint fl);
    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);

    public const uint MF_VERSION = 0x00020070;
    public static readonly Guid MT_MAJOR = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MT_SUB = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MT_BITRATE = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MT_INTERLACE = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MT_FRAMESIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MT_FRAMERATE = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid NV12 = new Guid("3231564E-0000-0010-8000-00AA00389B71");
}

[StructLayout(LayoutKind.Sequential)]
public struct DXGI_OUTDUPL_FRAME_INFO { public long T1, T2; public uint Acc; public int R, P, PX, PY, PV; public uint TM, PS; }
[StructLayout(LayoutKind.Sequential)]
public struct D3D11_TEXTURE2D_DESC { public uint W, H, Mip, Arr, Fmt, SC, SQ, Use, Bind, CPU, Misc; }
[StructLayout(LayoutKind.Sequential)]
public struct D3D11_MAPPED_SUBRESOURCE { public IntPtr pData; public uint Pitch, Depth; }
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct DXGI_OUTPUT_DESC { [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name; public int L, T, R, B, Att, Rot; public IntPtr Mon; }

public static class V
{
    public static T F<T>(IntPtr o, int s) where T:class
    { return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), s*IntPtr.Size), typeof(T)); }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate uint RelD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int QID(IntPtr s, ref Guid r, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetGD(IntPtr s, ref Guid k, ref Guid v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU32D(IntPtr s, ref Guid k, uint v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU64D(IntPtr s, ref Guid k, ulong v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int EnumAdD(IntPtr s, uint i, out IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int EnumOutD(IntPtr s, uint i, out IntPtr o);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetDescD(IntPtr s, out DXGI_OUTPUT_DESC d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int DupOutD(IntPtr s, IntPtr dev, out IntPtr d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int AcqFrD(IntPtr s, uint ms, out DXGI_OUTDUPL_FRAME_INFO i, out IntPtr r);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int RelFrD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int CreateTexD(IntPtr s, ref D3D11_TEXTURE2D_DESC d, IntPtr i, out IntPtr t);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int MapD(IntPtr s, IntPtr r, uint sub, uint mt, uint fl, out D3D11_MAPPED_SUBRESOURCE m);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void UnmapD(IntPtr s, IntPtr r, uint sub);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void CopyResD(IntPtr s, IntPtr d, IntPtr src);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void GetTexDescD(IntPtr s, out D3D11_TEXTURE2D_DESC d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int LockD(IntPtr s, out IntPtr buf, out uint max, out uint cur);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int UnlockBufD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetLenD(IntPtr s, uint len);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int AddBufD(IntPtr s, IntPtr buf);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetTimeD(IntPtr s, long time);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetDurD(IntPtr s, long dur);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWAddD(IntPtr s, IntPtr mt, out uint idx);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWSetInD(IntPtr s, uint idx, IntPtr mt, IntPtr enc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWBeginD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWWriteD(IntPtr s, uint idx, IntPtr samp);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWFinalD(IntPtr s);
}

public class V7Sender : IDisposable
{
    IntPtr dxDev, dxCtx, dxDup, dxStage;
    V.AcqFrD acqFrame; V.RelFrD relFrame; V.CopyResD copyRes; V.MapD mapTx; V.UnmapD unmapTx;
    Guid tex2dG = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    int texW, texH, screenL, screenT;

    IntPtr sinkWriter;
    uint streamIdx;
    long frameDur, frameIdx;
    int encW, encH;
    string tempFile;
    byte[] nv12Cache;

    // TCP streaming from growing file
    Thread streamThread;
    volatile bool running;
    TcpClient tcp;
    NetworkStream net;

    public int FramesSent;
    public long BytesSent;
    public double CaptureMs, ConvertMs, EncodeMs, TotalMs;

    public bool InitDXGI(int displayIdx)
    {
        try { MF.SetProcessDpiAwareness(2); } catch { MF.SetProcessDPIAware(); }
        try {
        IntPtr factory, adapter, output0, output1;
        var fg = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        MF.CreateDXGIFactory1(fg, out factory);
        V.F<V.EnumAdD>(factory, 12)(factory, 0, out adapter);
        int fl; MF.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new int[]{0xb000}, 1, 7, out dxDev, out fl, out dxCtx);
        V.F<V.EnumOutD>(adapter, 7)(adapter, (uint)displayIdx, out output0);

        DXGI_OUTPUT_DESC od; V.F<V.GetDescD>(output0, 7)(output0, out od);
        screenL = od.L; screenT = od.T;
        Console.WriteLine("Display " + displayIdx + ": " + od.Name + " offset=" + screenL + "," + screenT);

        var o1g = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
        V.F<V.QID>(output0, 0)(output0, ref o1g, out output1);
        V.F<V.DupOutD>(output1, 22)(output1, dxDev, out dxDup);

        System.Threading.Thread.Sleep(100);
        DXGI_OUTDUPL_FRAME_INFO fi; IntPtr res;
        V.F<V.AcqFrD>(dxDup, 8)(dxDup, 1000, out fi, out res);
        IntPtr st; V.F<V.QID>(res, 0)(res, ref tex2dG, out st);
        D3D11_TEXTURE2D_DESC sd; V.F<V.GetTexDescD>(st, 10)(st, out sd);
        texW = (int)sd.W; texH = (int)sd.H;

        D3D11_TEXTURE2D_DESC sg = new D3D11_TEXTURE2D_DESC();
        sg.W = sd.W; sg.H = sd.H; sg.Mip = 1; sg.Arr = 1; sg.Fmt = sd.Fmt;
        sg.SC = 1; sg.Use = 3; sg.CPU = 0x20000;
        V.F<V.CreateTexD>(dxDev, 5)(dxDev, ref sg, IntPtr.Zero, out dxStage);

        V.F<V.RelD>(st, 2)(st); V.F<V.RelD>(res, 2)(res);
        V.F<V.RelFrD>(dxDup, 14)(dxDup);
        acqFrame = V.F<V.AcqFrD>(dxDup, 8); relFrame = V.F<V.RelFrD>(dxDup, 14);
        copyRes = V.F<V.CopyResD>(dxCtx, 47); mapTx = V.F<V.MapD>(dxCtx, 14); unmapTx = V.F<V.UnmapD>(dxCtx, 15);

        V.F<V.RelD>(output0, 2)(output0); V.F<V.RelD>(output1, 2)(output1);
        V.F<V.RelD>(adapter, 2)(adapter); V.F<V.RelD>(factory, 2)(factory);
        Console.WriteLine("DXGI: " + texW + "x" + texH);
        return true;
        } catch (Exception ex) { Console.WriteLine("DXGI ERROR: " + ex.Message + "\n" + ex.StackTrace); return false; }
    }

    public bool InitEncoder(int w, int h, int fps, int bitMbps)
    {
        encW = w > 0 ? w : texW; encH = h > 0 ? h : texH;
        // Ensure even dimensions
        encW = (encW / 2) * 2; encH = (encH / 2) * 2;
        frameDur = 10000000L / fps;
        nv12Cache = new byte[encW * encH * 3 / 2];

        MF.MFStartup(MF.MF_VERSION, 0);
        tempFile = Path.Combine(Path.GetTempPath(), "v7_stream_" + Process.GetCurrentProcess().Id + ".ts");

        IntPtr outType; MF.MFCreateMediaType(out outType);
        Guid mk = MF.MT_MAJOR, mv = MF.Video;
        V.F<V.SetGD>(outType, 24)(outType, ref mk, ref mv);
        Guid sk = MF.MT_SUB, h264 = MF.H264;
        V.F<V.SetGD>(outType, 24)(outType, ref sk, ref h264);
        Guid fsk = MF.MT_FRAMESIZE; V.F<V.SetU64D>(outType, 22)(outType, ref fsk, ((ulong)encW << 32) | (uint)encH);
        Guid frk = MF.MT_FRAMERATE; V.F<V.SetU64D>(outType, 22)(outType, ref frk, ((ulong)fps << 32) | 1);
        Guid ik = MF.MT_INTERLACE; V.F<V.SetU32D>(outType, 21)(outType, ref ik, 2);
        Guid bk = MF.MT_BITRATE; V.F<V.SetU32D>(outType, 21)(outType, ref bk, (uint)(bitMbps * 1000000));

        IntPtr inType; MF.MFCreateMediaType(out inType);
        V.F<V.SetGD>(inType, 24)(inType, ref mk, ref mv);
        Guid nv12 = MF.NV12; V.F<V.SetGD>(inType, 24)(inType, ref sk, ref nv12);
        V.F<V.SetU64D>(inType, 22)(inType, ref fsk, ((ulong)encW << 32) | (uint)encH);
        V.F<V.SetU64D>(inType, 22)(inType, ref frk, ((ulong)fps << 32) | 1);
        V.F<V.SetU32D>(inType, 21)(inType, ref ik, 2);

        MF.MFCreateSinkWriterFromURL(tempFile, IntPtr.Zero, IntPtr.Zero, out sinkWriter);
        V.F<V.SWAddD>(sinkWriter, 3)(sinkWriter, outType, out streamIdx);
        V.F<V.SWSetInD>(sinkWriter, 4)(sinkWriter, streamIdx, inType, IntPtr.Zero);
        int hr = V.F<V.SWBeginD>(sinkWriter, 5)(sinkWriter);

        V.F<V.RelD>(outType, 2)(outType); V.F<V.RelD>(inType, 2)(inType);
        if (hr != 0) { Console.WriteLine("BeginWriting failed: 0x" + hr.ToString("X")); return false; }
        Console.WriteLine("Encoder: " + encW + "x" + encH + " " + fps + "fps " + bitMbps + "Mbps");
        return true;
    }

    public bool Connect(string ip, int port)
    {
        try
        {
            tcp = new TcpClient(); tcp.NoDelay = true; tcp.SendBufferSize = 4*1024*1024;
            tcp.Connect(ip, port); net = tcp.GetStream();
            Console.WriteLine("Connected to " + ip + ":" + port);
            return true;
        }
        catch (Exception ex) { Console.WriteLine("TCP: " + ex.Message); return false; }
    }

    static void BGRAtoNV12(IntPtr bgra, uint pitch, byte[] nv12, int w, int h, int srcW)
    {
        byte[] row = new byte[Math.Min(w, srcW) * 4];
        int readW = Math.Min(w, srcW);
        int ySize = w * h;
        for (int y = 0; y < h; y++)
        {
            if (y < h) Marshal.Copy(new IntPtr(bgra.ToInt64() + y * pitch), row, 0, readW * 4);
            for (int x = 0; x < w; x++)
            {
                int sx = x < readW ? x : readW - 1;
                int b = row[sx*4], g = row[sx*4+1], r = row[sx*4+2];
                int yv = ((66*r + 129*g + 25*b + 128) >> 8) + 16;
                nv12[y*w+x] = (byte)(yv < 16 ? 16 : yv > 235 ? 235 : yv);
                if ((y&1)==0 && (x&1)==0) {
                    int u = ((-38*r-74*g+112*b+128)>>8)+128;
                    int v = ((112*r-94*g-18*b+128)>>8)+128;
                    nv12[ySize+(y/2)*w+x] = (byte)(u<16?16:u>240?240:u);
                    nv12[ySize+(y/2)*w+x+1] = (byte)(v<16?16:v>240?240:v);
                }
            }
        }
    }

    void DrawCursor(Bitmap bmp)
    {
        MF.CURSORINFO ci = new MF.CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(MF.CURSORINFO));
        if (!MF.GetCursorInfo(ref ci) || ci.flags != 1 || ci.hCursor == IntPtr.Zero) return;

        int cx = ci.x - screenL, cy = ci.y - screenT;
        if (cx < 0 || cy < 0 || cx >= texW || cy >= texH) return;

        MF.ICONINFO ii; MF.GetIconInfo(ci.hCursor, out ii);
        using (var g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            MF.DrawIconEx(hdc, cx - ii.xHot, cy - ii.yHot, ci.hCursor, 0, 0, 0, IntPtr.Zero, 3);
            g.ReleaseHdc(hdc);
        }
    }

    // Capture DXGI -> Bitmap (with cursor)
    Bitmap captureBmp;
    bool CaptureFrame()
    {
        DXGI_OUTDUPL_FRAME_INFO fi; IntPtr res;
        int hr = acqFrame(dxDup, 100, out fi, out res);
        if (hr != 0) return false;

        IntPtr st; V.F<V.QID>(res, 0)(res, ref tex2dG, out st);
        copyRes(dxCtx, dxStage, st);
        D3D11_MAPPED_SUBRESOURCE m;
        bool ok = mapTx(dxCtx, dxStage, 0, 1, 0, out m) == 0;
        if (ok)
        {
            if (captureBmp == null) captureBmp = new Bitmap(texW, texH, PixelFormat.Format32bppRgb);
            var bd = captureBmp.LockBits(new Rectangle(0, 0, texW, texH), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            if (m.Pitch == (uint)bd.Stride)
                MF.Memcpy(bd.Scan0, m.pData, (uint)(texH * bd.Stride));
            else
                for (int y = 0; y < texH; y++)
                    MF.Memcpy(new IntPtr(bd.Scan0.ToInt64() + y * bd.Stride), new IntPtr(m.pData.ToInt64() + y * m.Pitch), (uint)(texW * 4));
            captureBmp.UnlockBits(bd);
            unmapTx(dxCtx, dxStage, 0);
            DrawCursor(captureBmp);
        }
        V.F<V.RelD>(st, 2)(st); V.F<V.RelD>(res, 2)(res); relFrame(dxDup);
        return ok;
    }

    // Encode one frame via SinkWriter
    bool EncodeFrame()
    {
        // BGRA -> NV12 from captureBmp
        var bd = captureBmp.LockBits(new Rectangle(0, 0, texW, texH), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        BGRAtoNV12(bd.Scan0, (uint)bd.Stride, nv12Cache, encW, encH, texW);
        captureBmp.UnlockBits(bd);

        int nv12Size = encW * encH * 3 / 2;
        IntPtr buf; MF.MFCreateMemoryBuffer((uint)nv12Size, out buf);
        IntPtr data; uint mx, cl;
        V.F<V.LockD>(buf, 3)(buf, out data, out mx, out cl);
        Marshal.Copy(nv12Cache, 0, data, nv12Size);
        V.F<V.UnlockBufD>(buf, 4)(buf);
        V.F<V.SetLenD>(buf, 6)(buf, (uint)nv12Size);

        IntPtr samp; MF.MFCreateSample(out samp);
        V.F<V.AddBufD>(samp, 42)(samp, buf);
        V.F<V.SetTimeD>(samp, 36)(samp, frameIdx * frameDur);
        V.F<V.SetDurD>(samp, 38)(samp, frameDur);
        frameIdx++;

        int hr = V.F<V.SWWriteD>(sinkWriter, 6)(sinkWriter, streamIdx, samp);
        V.F<V.RelD>(buf, 2)(buf); V.F<V.RelD>(samp, 2)(samp);
        if (hr == 0) FramesSent++;
        return hr == 0;
    }

    // Background thread: read growing file and send to TCP
    void StreamFileToTCP()
    {
        long pos = 0;
        byte[] buf = new byte[64 * 1024];
        while (running)
        {
            try
            {
                if (!File.Exists(tempFile)) { Thread.Sleep(50); continue; }
                using (var fs = new FileStream(tempFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    fs.Seek(pos, SeekOrigin.Begin);
                    int read = fs.Read(buf, 0, buf.Length);
                    if (read > 0)
                    {
                        net.Write(buf, 0, read);
                        pos += read;
                        BytesSent += read;
                    }
                    else
                    {
                        Thread.Sleep(10);
                    }
                }
            }
            catch { Thread.Sleep(50); }
        }
    }

    public void StartStreaming()
    {
        running = true;
        streamThread = new Thread(StreamFileToTCP);
        streamThread.IsBackground = true;
        streamThread.Start();
    }

    public bool ProcessFrame()
    {
        var swT = Stopwatch.StartNew();

        var sw = Stopwatch.StartNew();
        bool captured = CaptureFrame();
        sw.Stop(); CaptureMs = sw.Elapsed.TotalMilliseconds;
        if (!captured) { TotalMs = CaptureMs; return true; }

        sw.Restart();
        // NV12 conversion is inside EncodeFrame
        bool encoded = EncodeFrame();
        sw.Stop(); EncodeMs = sw.Elapsed.TotalMilliseconds;

        swT.Stop(); TotalMs = swT.Elapsed.TotalMilliseconds;
        return encoded;
    }

    public void FinalizeStream()
    {
        running = false;
        if (sinkWriter != IntPtr.Zero)
        {
            V.F<V.SWFinalD>(sinkWriter, 11)(sinkWriter);
            // Give stream thread time to send remaining data
            Thread.Sleep(500);
            if (streamThread != null) streamThread.Join(2000);
        }
    }

    public void Dispose()
    {
        running = false;
        if (captureBmp != null) captureBmp.Dispose();
        if (net != null) net.Close();
        if (tcp != null) tcp.Close();
        if (dxStage != IntPtr.Zero) V.F<V.RelD>(dxStage, 2)(dxStage);
        if (dxDup != IntPtr.Zero) V.F<V.RelD>(dxDup, 2)(dxDup);
        if (dxCtx != IntPtr.Zero) V.F<V.RelD>(dxCtx, 2)(dxCtx);
        if (dxDev != IntPtr.Zero) V.F<V.RelD>(dxDev, 2)(dxDev);
        MF.MFShutdown();
        try { if (tempFile != null) File.Delete(tempFile); } catch {}
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Screen Sender v7 (DXGI + MF H.264 -> TCP) ==="
Write-Host "Target: ${iPadIP}:${Port}, Display: $DisplayIndex"

$sender = New-Object V7Sender
if (-not $sender.InitDXGI($DisplayIndex)) { Write-Host "DXGI failed"; exit 1 }
if (-not $sender.InitEncoder($Width, $Height, $Fps, $BitrateMbps)) { Write-Host "Encoder failed"; exit 1 }

Write-Host "Connecting to iPad..."
while (-not $sender.Connect($iPadIP, $Port)) {
    Write-Host "  Retrying..."
    Start-Sleep -Seconds 2
}

$sender.StartStreaming()
Write-Host "Streaming H.264... (Ctrl+C to stop)"
Write-Host ""

$fpsTimer = [System.Diagnostics.Stopwatch]::StartNew()
$frameCount = 0
$targetMs = [math]::Floor(1000 / $Fps)

try {
    while ($true) {
        $ft = [System.Diagnostics.Stopwatch]::StartNew()
        if (-not $sender.ProcessFrame()) { Write-Host "Encode failed"; break }
        $frameCount++

        if ($fpsTimer.ElapsedMilliseconds -ge 1000) {
            $fps = [math]::Round($frameCount * 1000 / $fpsTimer.ElapsedMilliseconds, 1)
            $cap = [math]::Round($sender.CaptureMs, 1)
            $enc = [math]::Round($sender.EncodeMs, 1)
            $tot = [math]::Round($sender.TotalMs, 1)
            $sent = [math]::Round($sender.BytesSent / 1024, 0)
            Write-Host "`rFPS: $fps | Cap:${cap}ms Enc:${enc}ms = ${tot}ms | Sent:${sent}KB   " -NoNewline
            $frameCount = 0
            $fpsTimer.Restart()
        }

        $sleepMs = $targetMs - $ft.ElapsedMilliseconds
        if ($sleepMs -gt 1) { Start-Sleep -Milliseconds $sleepMs }
    }
}
finally {
    $sender.FinalizeStream()
    $sender.Dispose()
    Write-Host ""
    Write-Host "Done. Frames: $($sender.FramesSent), Sent: $([math]::Round($sender.BytesSent / 1024))KB"
}
