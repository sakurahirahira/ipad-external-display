# screen-sender-v6.ps1 - DXGI capture + Media Foundation H.264 via SinkWriter + TCP
# Pure PowerShell, no external dependencies
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-v6.ps1 -iPadIP "192.168.8.240"

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [int]$Fps = 30,
    [int]$Width = 1920,
    [int]$Height = 1080,
    [int]$BitrateMbps = 10
)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;
using System.Drawing;
using System.Drawing.Imaging;

public static class MF
{
    [DllImport("mfplat.dll")] public static extern int MFStartup(uint ver, uint flags);
    [DllImport("mfplat.dll")] public static extern int MFShutdown();
    [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(uint cb, out IntPtr pp);
    [DllImport("mfreadwrite.dll")] public static extern int MFCreateSinkWriterFromURL(
        [MarshalAs(UnmanagedType.LPWStr)] string url, IntPtr pByteStream, IntPtr pAttributes, out IntPtr ppSinkWriter);
    [DllImport("dxgi.dll")] public static extern int CreateDXGIFactory1([MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr pp);
    [DllImport("d3d11.dll")] public static extern int D3D11CreateDevice(IntPtr a, int dt, IntPtr sw, uint f, int[] fl, uint fc, uint sdk, out IntPtr d, out int feat, out IntPtr ctx);
    [DllImport("kernel32.dll", EntryPoint="RtlMoveMemory")] public static extern void Memcpy(IntPtr d, IntPtr s, uint c);

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
public struct DXGI_OUTDUPL_FRAME_INFO {
    public long T1, T2; public uint Acc; public int R, P, PX, PY, PV; public uint TM, PS;
}
[StructLayout(LayoutKind.Sequential)]
public struct D3D11_TEXTURE2D_DESC {
    public uint W, H, Mip, Arr, Fmt, SC, SQ, Use, Bind, CPU, Misc;
}
[StructLayout(LayoutKind.Sequential)]
public struct D3D11_MAPPED_SUBRESOURCE { public IntPtr pData; public uint Pitch, Depth; }

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
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWAddStreamD(IntPtr s, IntPtr mt, out uint idx);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWSetInTypeD(IntPtr s, uint idx, IntPtr mt, IntPtr enc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWBeginD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWWriteD(IntPtr s, uint idx, IntPtr samp);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SWFinalD(IntPtr s);
}

public class V6Sender : IDisposable
{
    IntPtr dxDev, dxCtx, dxDup, dxStage;
    V.AcqFrD acqFrame; V.RelFrD relFrame; V.CopyResD copyRes; V.MapD mapTx; V.UnmapD unmapTx;
    Guid tex2dG = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    int texW, texH, encW, encH;

    IntPtr sinkWriter;
    uint streamIdx;
    long frameDur;
    long frameIdx;

    string tempFile;
    TcpClient tcp;
    NetworkStream net;
    byte[] readBuf = new byte[256 * 1024];

    public int FramesSent;
    public double CaptureMs, ConvertMs, EncodeMs, SendMs, TotalMs;
    public int LastBytes;

    public bool InitDXGI()
    {
        IntPtr factory, adapter, output0, output1;
        var fg = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        MF.CreateDXGIFactory1(fg, out factory);
        V.F<V.EnumAdD>(factory, 12)(factory, 0, out adapter);
        int fl; MF.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new int[]{0xb000}, 1, 7, out dxDev, out fl, out dxCtx);
        V.F<V.EnumOutD>(adapter, 7)(adapter, 0, out output0);
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

        acqFrame = V.F<V.AcqFrD>(dxDup, 8);
        relFrame = V.F<V.RelFrD>(dxDup, 14);
        copyRes = V.F<V.CopyResD>(dxCtx, 47);
        mapTx = V.F<V.MapD>(dxCtx, 14);
        unmapTx = V.F<V.UnmapD>(dxCtx, 15);

        V.F<V.RelD>(output0, 2)(output0); V.F<V.RelD>(output1, 2)(output1);
        V.F<V.RelD>(adapter, 2)(adapter); V.F<V.RelD>(factory, 2)(factory);
        Console.WriteLine("DXGI: " + texW + "x" + texH);
        return true;
    }

    public bool InitEncoder(int w, int h, int fps, int bitMbps)
    {
        encW = w; encH = h;
        frameDur = 10000000L / fps;

        MF.MFStartup(MF.MF_VERSION, 0);

        // Use temp file as output (will stream it to TCP)
        tempFile = Path.Combine(Path.GetTempPath(), "mf_stream_" + Process.GetCurrentProcess().Id + ".mp4");

        IntPtr outType; MF.MFCreateMediaType(out outType);
        Guid mk = MF.MT_MAJOR, mv = MF.Video;
        V.F<V.SetGD>(outType, 24)(outType, ref mk, ref mv);
        Guid sk = MF.MT_SUB, h264 = MF.H264;
        V.F<V.SetGD>(outType, 24)(outType, ref sk, ref h264);
        Guid fsk = MF.MT_FRAMESIZE;
        V.F<V.SetU64D>(outType, 22)(outType, ref fsk, ((ulong)w << 32) | (uint)h);
        Guid frk = MF.MT_FRAMERATE;
        V.F<V.SetU64D>(outType, 22)(outType, ref frk, ((ulong)fps << 32) | 1);
        Guid ik = MF.MT_INTERLACE;
        V.F<V.SetU32D>(outType, 21)(outType, ref ik, 2);
        Guid bk = MF.MT_BITRATE;
        V.F<V.SetU32D>(outType, 21)(outType, ref bk, (uint)(bitMbps * 1000000));

        IntPtr inType; MF.MFCreateMediaType(out inType);
        V.F<V.SetGD>(inType, 24)(inType, ref mk, ref mv);
        Guid nv12 = MF.NV12;
        V.F<V.SetGD>(inType, 24)(inType, ref sk, ref nv12);
        V.F<V.SetU64D>(inType, 22)(inType, ref fsk, ((ulong)w << 32) | (uint)h);
        V.F<V.SetU64D>(inType, 22)(inType, ref frk, ((ulong)fps << 32) | 1);
        V.F<V.SetU32D>(inType, 21)(inType, ref ik, 2);

        int hr = MF.MFCreateSinkWriterFromURL(tempFile, IntPtr.Zero, IntPtr.Zero, out sinkWriter);
        if (hr != 0) { Console.WriteLine("SinkWriter failed: 0x" + hr.ToString("X")); return false; }

        V.F<V.SWAddStreamD>(sinkWriter, 3)(sinkWriter, outType, out streamIdx);
        V.F<V.SWSetInTypeD>(sinkWriter, 4)(sinkWriter, streamIdx, inType, IntPtr.Zero);
        hr = V.F<V.SWBeginD>(sinkWriter, 5)(sinkWriter);

        V.F<V.RelD>(outType, 2)(outType);
        V.F<V.RelD>(inType, 2)(inType);

        if (hr != 0) { Console.WriteLine("BeginWriting failed: 0x" + hr.ToString("X")); return false; }
        Console.WriteLine("Encoder: " + w + "x" + h + " " + fps + "fps " + bitMbps + "Mbps -> " + tempFile);
        return true;
    }

    public bool Connect(string ip, int port)
    {
        try
        {
            tcp = new TcpClient(); tcp.NoDelay = true;
            tcp.SendBufferSize = 4 * 1024 * 1024;
            tcp.Connect(ip, port);
            net = tcp.GetStream();
            return true;
        }
        catch (Exception ex) { Console.WriteLine("TCP: " + ex.Message); return false; }
    }

    static void BGRAtoNV12(IntPtr bgra, uint pitch, byte[] nv12, int w, int h)
    {
        byte[] row = new byte[w * 4];
        int ySize = w * h;
        for (int y = 0; y < h; y++)
        {
            Marshal.Copy(new IntPtr(bgra.ToInt64() + y * pitch), row, 0, w * 4);
            for (int x = 0; x < w; x++)
            {
                int b = row[x*4], g = row[x*4+1], r = row[x*4+2];
                int yv = ((66*r + 129*g + 25*b + 128) >> 8) + 16;
                nv12[y*w+x] = (byte)(yv < 16 ? 16 : yv > 235 ? 235 : yv);
                if ((y&1)==0 && (x&1)==0)
                {
                    int u = ((-38*r - 74*g + 112*b + 128) >> 8) + 128;
                    int v = ((112*r - 94*g - 18*b + 128) >> 8) + 128;
                    nv12[ySize + (y/2)*w + x] = (byte)(u < 16 ? 16 : u > 240 ? 240 : u);
                    nv12[ySize + (y/2)*w + x+1] = (byte)(v < 16 ? 16 : v > 240 ? 240 : v);
                }
            }
        }
    }

    byte[] nv12Cache;

    public bool ProcessFrame()
    {
        var swT = Stopwatch.StartNew();

        // 1. DXGI capture
        var sw = Stopwatch.StartNew();
        DXGI_OUTDUPL_FRAME_INFO fi; IntPtr res;
        int hr = acqFrame(dxDup, 100, out fi, out res);
        IntPtr mapped = IntPtr.Zero; uint pitch = 0;
        bool got = false;

        if (hr == 0)
        {
            IntPtr st; V.F<V.QID>(res, 0)(res, ref tex2dG, out st);
            copyRes(dxCtx, dxStage, st);
            D3D11_MAPPED_SUBRESOURCE m;
            if (mapTx(dxCtx, dxStage, 0, 1, 0, out m) == 0)
            { mapped = m.pData; pitch = m.Pitch; got = true; }
            V.F<V.RelD>(st, 2)(st);
        }
        sw.Stop(); CaptureMs = sw.Elapsed.TotalMilliseconds;
        if (!got) { if (hr==0) { V.F<V.RelD>(res, 2)(res); relFrame(dxDup); } return true; }

        // 2. BGRA -> NV12
        sw.Restart();
        int nv12Size = encW * encH * 3 / 2;
        if (nv12Cache == null) nv12Cache = new byte[nv12Size];
        BGRAtoNV12(mapped, pitch, nv12Cache, encW, encH);
        unmapTx(dxCtx, dxStage, 0);
        V.F<V.RelD>(res, 2)(res);
        relFrame(dxDup);
        sw.Stop(); ConvertMs = sw.Elapsed.TotalMilliseconds;

        // 3. Feed to SinkWriter
        sw.Restart();
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

        hr = V.F<V.SWWriteD>(sinkWriter, 6)(sinkWriter, streamIdx, samp);
        V.F<V.RelD>(buf, 2)(buf);
        V.F<V.RelD>(samp, 2)(samp);
        sw.Stop(); EncodeMs = sw.Elapsed.TotalMilliseconds;

        if (hr == 0) FramesSent++;
        swT.Stop(); TotalMs = swT.Elapsed.TotalMilliseconds;
        return hr == 0;
    }

    public void FinalizeAndStream()
    {
        // Finalize SinkWriter to flush all encoded data
        V.F<V.SWFinalD>(sinkWriter, 11)(sinkWriter);
        Console.WriteLine("Finalized. Streaming file to iPad...");

        // Stream the MP4 file to iPad
        if (net != null && File.Exists(tempFile))
        {
            byte[] fileData = File.ReadAllBytes(tempFile);
            net.Write(fileData, 0, fileData.Length);
            Console.WriteLine("Sent " + fileData.Length + " bytes");
        }
    }

    public void Dispose()
    {
        if (sinkWriter != IntPtr.Zero) V.F<V.RelD>(sinkWriter, 2)(sinkWriter);
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

Write-Host "=== Screen Sender v6 (DXGI + MF H.264 SinkWriter) ==="

$sender = New-Object V6Sender
if (-not $sender.InitDXGI()) { Write-Host "DXGI failed"; exit 1 }
if (-not $sender.InitEncoder($Width, $Height, $Fps, $BitrateMbps)) { Write-Host "Encoder failed"; exit 1 }

Write-Host "Encoding $Fps frames (1 second test)..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $Fps; $i++) {
    if (-not $sender.ProcessFrame()) { Write-Host "Frame $i failed"; break }
    if ($i % 10 -eq 9) {
        $cap = [math]::Round($sender.CaptureMs, 1)
        $conv = [math]::Round($sender.ConvertMs, 1)
        $enc = [math]::Round($sender.EncodeMs, 1)
        $tot = [math]::Round($sender.TotalMs, 1)
        Write-Host "  Frame $i | Cap:${cap}ms Conv:${conv}ms Enc:${enc}ms = ${tot}ms"
    }
}

$sw.Stop()
$fps = [math]::Round($sender.FramesSent / $sw.Elapsed.TotalSeconds, 1)
Write-Host ""
Write-Host "Captured $($sender.FramesSent) frames in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s = ${fps} fps"
Write-Host ""

$sender.FinalizeAndStream()
$sender.Dispose()
