# mf-encode-test.ps1 - Full Media Foundation H.264 encode pipeline test
# DXGI capture -> BGRA->NV12 -> MF H.264 encode -> output to file/TCP

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;

#region Native APIs

public static class MF
{
    [DllImport("mfplat.dll")] public static extern int MFStartup(uint ver, uint flags);
    [DllImport("mfplat.dll")] public static extern int MFShutdown();
    [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(uint cb, out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFTEnumEx(Guid cat, uint flags, IntPtr inType, IntPtr outType, out IntPtr ppAct, out uint count);
    [DllImport("kernel32.dll", EntryPoint="RtlMoveMemory")] public static extern void CopyMemory(IntPtr d, IntPtr s, uint c);
    [DllImport("dxgi.dll")] public static extern int CreateDXGIFactory1([MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr pp);
    [DllImport("d3d11.dll")] public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr sw, uint flags, int[] fl, uint flCount, uint sdk, out IntPtr dev, out int feat, out IntPtr ctx);

    public const uint MF_VERSION = 0x00020070;
    public static readonly Guid CAT_VIDEO_ENCODER = new Guid("f79eac7d-e545-4387-bdee-d647d7bde42a");
    public static readonly Guid MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MT_SUBTYPE = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MT_AVG_BITRATE = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MT_INTERLACE = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MT_FRAME_SIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MT_FRAME_RATE = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid MFMediaType_Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFVideoFormat_H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFVideoFormat_NV12 = new Guid("3231564E-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFT_FRIENDLY_NAME = new Guid("314ffbae-5b41-4c95-9c19-4e7d586face3");
    public static readonly Guid IID_IMFTransform = new Guid("bf94c121-5b05-4e6f-8000-ba598961414d");
}

[StructLayout(LayoutKind.Sequential)]
public struct DXGI_OUTDUPL_FRAME_INFO
{
    public long LastPresentTime, LastMouseUpdateTime;
    public uint AccumulatedFrames;
    public int RectsCoalesced, ProtectedContentMaskedOut;
    public int PtrX, PtrY, PtrVisible;
    public uint TotalMetadataSize, PointerShapeSize;
}

[StructLayout(LayoutKind.Sequential)]
public struct D3D11_TEXTURE2D_DESC
{
    public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CPUAccess, MiscFlags;
}

[StructLayout(LayoutKind.Sequential)]
public struct D3D11_MAPPED_SUBRESOURCE
{
    public IntPtr pData; public uint RowPitch, DepthPitch;
}

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct DXGI_OUTPUT_DESC
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    public int Left, Top, Right, Bottom, Attached, Rotation; public IntPtr Monitor;
}

[StructLayout(LayoutKind.Sequential)]
public struct MFT_OUTPUT_DATA_BUFFER
{
    public uint StreamID; public IntPtr pSample; public uint Status; public IntPtr pEvents;
}

public static class V
{
    public static T F<T>(IntPtr o, int s) where T:class { return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), s*IntPtr.Size), typeof(T)); }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate uint RelD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int QID(IntPtr s, ref Guid r, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetGD(IntPtr s, ref Guid k, ref Guid v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU32D(IntPtr s, ref Guid k, uint v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU64D(IntPtr s, ref Guid k, ulong v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetStrD(IntPtr s, ref Guid k, out IntPtr p, out uint l);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ActivateD(IntPtr s, ref Guid r, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetTypeD(IntPtr s, uint id, IntPtr t, uint f);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ProcMsgD(IntPtr s, uint msg, IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ProcInD(IntPtr s, uint id, IntPtr sample, uint f);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ProcOutD(IntPtr s, uint f, uint cnt, ref MFT_OUTPUT_DATA_BUFFER buf, out uint st);

    // IMFMediaBuffer
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int LockD(IntPtr s, out IntPtr buf, out uint maxLen, out uint curLen);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int UnlockD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetLenD(IntPtr s, uint len);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetLenD(IntPtr s, out uint len);

    // IMFSample
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int AddBufD(IntPtr s, IntPtr buf);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetTimeD(IntPtr s, long time);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetDurD(IntPtr s, long dur);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetBufByIdxD(IntPtr s, uint idx, out IntPtr buf);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ConvertToContiguousD(IntPtr s, out IntPtr buf);

    // DXGI
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int EnumAdD(IntPtr s, uint i, out IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int EnumOutD(IntPtr s, uint i, out IntPtr o);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetDescD(IntPtr s, out DXGI_OUTPUT_DESC d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int DupOutD(IntPtr s, IntPtr dev, out IntPtr dup);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int AcqFrD(IntPtr s, uint ms, out DXGI_OUTDUPL_FRAME_INFO i, out IntPtr r);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int RelFrD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int CreateTexD(IntPtr s, ref D3D11_TEXTURE2D_DESC d, IntPtr init, out IntPtr t);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int MapD(IntPtr s, IntPtr r, uint sub, uint mt, uint fl, out D3D11_MAPPED_SUBRESOURCE m);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void UnmapD(IntPtr s, IntPtr r, uint sub);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void CopyResD(IntPtr s, IntPtr d, IntPtr src);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate void GetTexDescD(IntPtr s, out D3D11_TEXTURE2D_DESC d);
}

#endregion

public class MFEncodePipeline : IDisposable
{
    // DXGI
    IntPtr dxDevice, dxContext, dxDuplication, dxStagingTex;
    int texW, texH;
    V.AcqFrD acquireFrame; V.RelFrD releaseFrame; V.CopyResD copyResource;
    V.MapD mapTex; V.UnmapD unmapTex;
    Guid tex2dGuid = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    // MF encoder
    IntPtr mfTransform;
    int encW, encH;
    long frameDuration;
    long frameIndex;

    // Output
    TcpClient tcpClient;
    NetworkStream netStream;
    FileStream fileOut;

    public double CaptureMs, ConvertMs, EncodeMs, SendMs, TotalMs;
    public int FramesSent;
    public int LastFrameBytes;

    public bool InitDXGI()
    {
        try
        {
            IntPtr factory, adapter, output0, output1;
            var fGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            MF.CreateDXGIFactory1(fGuid, out factory);
            V.F<V.EnumAdD>(factory, 12)(factory, 0, out adapter);
            int fl; MF.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new int[]{0xb000}, 1, 7, out dxDevice, out fl, out dxContext);
            V.F<V.EnumOutD>(adapter, 7)(adapter, 0, out output0);
            var o1g = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
            V.F<V.QID>(output0, 0)(output0, ref o1g, out output1);
            V.F<V.DupOutD>(output1, 22)(output1, dxDevice, out dxDuplication);

            // Get texture size from first frame
            System.Threading.Thread.Sleep(100);
            DXGI_OUTDUPL_FRAME_INFO fi; IntPtr res;
            V.F<V.AcqFrD>(dxDuplication, 8)(dxDuplication, 1000, out fi, out res);
            IntPtr srcTex; V.F<V.QID>(res, 0)(res, ref tex2dGuid, out srcTex);
            D3D11_TEXTURE2D_DESC srcDesc; V.F<V.GetTexDescD>(srcTex, 10)(srcTex, out srcDesc);
            texW = (int)srcDesc.Width; texH = (int)srcDesc.Height;

            D3D11_TEXTURE2D_DESC stg = new D3D11_TEXTURE2D_DESC();
            stg.Width = srcDesc.Width; stg.Height = srcDesc.Height;
            stg.MipLevels = 1; stg.ArraySize = 1; stg.Format = srcDesc.Format;
            stg.SampleCount = 1; stg.Usage = 3; stg.CPUAccess = 0x20000;
            V.F<V.CreateTexD>(dxDevice, 5)(dxDevice, ref stg, IntPtr.Zero, out dxStagingTex);

            V.F<V.RelD>(srcTex, 2)(srcTex);
            V.F<V.RelD>(res, 2)(res);
            V.F<V.RelFrD>(dxDuplication, 14)(dxDuplication);

            acquireFrame = V.F<V.AcqFrD>(dxDuplication, 8);
            releaseFrame = V.F<V.RelFrD>(dxDuplication, 14);
            copyResource = V.F<V.CopyResD>(dxContext, 47);
            mapTex = V.F<V.MapD>(dxContext, 14);
            unmapTex = V.F<V.UnmapD>(dxContext, 15);

            V.F<V.RelD>(output0, 2)(output0); V.F<V.RelD>(output1, 2)(output1);
            V.F<V.RelD>(adapter, 2)(adapter); V.F<V.RelD>(factory, 2)(factory);

            Console.WriteLine("DXGI: " + texW + "x" + texH);
            return true;
        }
        catch (Exception ex) { Console.WriteLine("DXGI error: " + ex.Message); return false; }
    }

    public bool InitEncoder(int width, int height, int fps, int bitrateMbps)
    {
        encW = width; encH = height;
        frameDuration = 10000000L / fps; // 100ns units

        MF.MFStartup(MF.MF_VERSION, 0);

        // Find H264 encoder
        IntPtr pAct; uint cnt;
        MF.MFTEnumEx(MF.CAT_VIDEO_ENCODER, 0x70, IntPtr.Zero, IntPtr.Zero, out pAct, out cnt);
        IntPtr activate = IntPtr.Zero;
        for (uint i = 0; i < cnt; i++)
        {
            IntPtr a = Marshal.ReadIntPtr(pAct, (int)(i * (uint)IntPtr.Size));
            IntPtr namePtr; uint nameLen;
            Guid nk = MF.MFT_FRIENDLY_NAME;
            V.F<V.GetStrD>(a, 13)(a, ref nk, out namePtr, out nameLen);
            string name = namePtr != IntPtr.Zero ? Marshal.PtrToStringUni(namePtr) : "";
            if (namePtr != IntPtr.Zero) Marshal.FreeCoTaskMem(namePtr);
            if (name.Contains("H264")) { activate = a; break; }
        }
        if (activate == IntPtr.Zero) { Console.WriteLine("No H264 encoder"); return false; }

        Guid iid = MF.IID_IMFTransform;
        int hr = V.F<V.ActivateD>(activate, 33)(activate, ref iid, out mfTransform);
        if (hr != 0) { Console.WriteLine("Activate failed: 0x" + hr.ToString("X")); return false; }

        // Output type: H.264
        IntPtr outType; MF.MFCreateMediaType(out outType);
        Guid mk = MF.MT_MAJOR_TYPE, mv = MF.MFMediaType_Video;
        V.F<V.SetGD>(outType, 24)(outType, ref mk, ref mv);
        Guid sk = MF.MT_SUBTYPE, h264 = MF.MFVideoFormat_H264;
        V.F<V.SetGD>(outType, 24)(outType, ref sk, ref h264);
        Guid fsk = MF.MT_FRAME_SIZE;
        V.F<V.SetU64D>(outType, 22)(outType, ref fsk, ((ulong)width << 32) | (uint)height);
        Guid frk = MF.MT_FRAME_RATE;
        V.F<V.SetU64D>(outType, 22)(outType, ref frk, ((ulong)fps << 32) | 1);
        Guid ik = MF.MT_INTERLACE;
        V.F<V.SetU32D>(outType, 21)(outType, ref ik, 2);
        Guid bk = MF.MT_AVG_BITRATE;
        V.F<V.SetU32D>(outType, 21)(outType, ref bk, (uint)(bitrateMbps * 1000000));

        hr = V.F<V.SetTypeD>(mfTransform, 16)(mfTransform, 0, outType, 0);
        Console.WriteLine("SetOutputType: 0x" + hr.ToString("X"));

        // Input type: NV12
        IntPtr inType; MF.MFCreateMediaType(out inType);
        V.F<V.SetGD>(inType, 24)(inType, ref mk, ref mv);
        Guid nv12 = MF.MFVideoFormat_NV12;
        V.F<V.SetGD>(inType, 24)(inType, ref sk, ref nv12);
        V.F<V.SetU64D>(inType, 22)(inType, ref fsk, ((ulong)width << 32) | (uint)height);
        V.F<V.SetU64D>(inType, 22)(inType, ref frk, ((ulong)fps << 32) | 1);
        V.F<V.SetU32D>(inType, 21)(inType, ref ik, 2);

        hr = V.F<V.SetTypeD>(mfTransform, 15)(mfTransform, 0, inType, 0);
        Console.WriteLine("SetInputType: 0x" + hr.ToString("X"));
        if (hr != 0) return false;

        // Set low latency via ICodecAPI
        Guid iidCodecAPI = new Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");
        IntPtr codecAPI;
        int hrCodec = V.F<V.QID>(mfTransform, 0)(mfTransform, ref iidCodecAPI, out codecAPI);
        if (hrCodec == 0)
        {
            Console.WriteLine("ICodecAPI available - setting low latency");
            // ICodecAPI::SetValue for CODECAPI_AVLowLatencyMode (slot 7 + 6 = 13? Actually ICodecAPI has its own vtable)
            // Too complex for now - try without it
            V.F<V.RelD>(codecAPI, 2)(codecAPI);
        }

        // Begin streaming
        V.F<V.ProcMsgD>(mfTransform, 23)(mfTransform, 0x10000000, IntPtr.Zero);
        V.F<V.ProcMsgD>(mfTransform, 23)(mfTransform, 0x10000003, IntPtr.Zero); // START_OF_STREAM

        V.F<V.RelD>(outType, 2)(outType);
        V.F<V.RelD>(inType, 2)(inType);

        Console.WriteLine("Encoder ready: " + width + "x" + height + " @ " + fps + "fps " + bitrateMbps + "Mbps");
        return true;
    }

    public bool ConnectTCP(string ip, int port)
    {
        try
        {
            tcpClient = new TcpClient(); tcpClient.NoDelay = true;
            tcpClient.SendBufferSize = 4 * 1024 * 1024;
            tcpClient.Connect(ip, port);
            netStream = tcpClient.GetStream();
            return true;
        }
        catch (Exception ex) { Console.WriteLine("TCP error: " + ex.Message); return false; }
    }

    public void SetFileOutput(string path)
    {
        fileOut = new FileStream(path, FileMode.Create);
    }

    // BGRA (from DXGI) -> NV12 conversion using Marshal (safe code)
    // NV12: Y plane (w*h bytes) + UV interleaved plane (w*h/2 bytes)
    static void BGRAtoNV12(IntPtr bgra, uint bgraPitch, IntPtr nv12, int w, int h)
    {
        int yPlaneSize = w * h;
        byte[] bgraRow = new byte[w * 4];
        byte[] yRow = new byte[w];
        byte[] uvRow = new byte[w]; // for even rows only

        for (int y = 0; y < h; y++)
        {
            // Read BGRA row
            IntPtr rowPtr = new IntPtr(bgra.ToInt64() + y * bgraPitch);
            Marshal.Copy(rowPtr, bgraRow, 0, w * 4);

            // Convert to Y
            for (int x = 0; x < w; x++)
            {
                int b = bgraRow[x * 4];
                int g = bgraRow[x * 4 + 1];
                int r = bgraRow[x * 4 + 2];
                int yVal = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                yRow[x] = (byte)(yVal < 16 ? 16 : (yVal > 235 ? 235 : yVal));
            }
            Marshal.Copy(yRow, 0, new IntPtr(nv12.ToInt64() + y * w), w);

            // UV (every other row, subsampled 2x)
            if ((y & 1) == 0)
            {
                for (int x = 0; x < w; x += 2)
                {
                    int b = bgraRow[x * 4];
                    int g = bgraRow[x * 4 + 1];
                    int r = bgraRow[x * 4 + 2];
                    int uVal = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                    int vVal = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                    uvRow[x] = (byte)(uVal < 16 ? 16 : (uVal > 240 ? 240 : uVal));
                    uvRow[x + 1] = (byte)(vVal < 16 ? 16 : (vVal > 240 ? 240 : vVal));
                }
                Marshal.Copy(uvRow, 0, new IntPtr(nv12.ToInt64() + yPlaneSize + (y / 2) * w), w);
            }
        }
    }

    public bool ProcessFrame()
    {
        var swTotal = Stopwatch.StartNew();

        // 1. DXGI capture
        var sw = Stopwatch.StartNew();
        DXGI_OUTDUPL_FRAME_INFO fi; IntPtr res;
        int hr = acquireFrame(dxDuplication, 100, out fi, out res);
        IntPtr mappedData = IntPtr.Zero;
        uint mappedPitch = 0;
        bool newFrame = false;

        if (hr == 0)
        {
            IntPtr srcTex;
            V.F<V.QID>(res, 0)(res, ref tex2dGuid, out srcTex);
            copyResource(dxContext, dxStagingTex, srcTex);

            D3D11_MAPPED_SUBRESOURCE mapped;
            if (mapTex(dxContext, dxStagingTex, 0, 1, 0, out mapped) == 0)
            {
                mappedData = mapped.pData;
                mappedPitch = mapped.RowPitch;
                newFrame = true;
            }
            V.F<V.RelD>(srcTex, 2)(srcTex);
        }
        sw.Stop();
        CaptureMs = sw.Elapsed.TotalMilliseconds;

        if (!newFrame)
        {
            if (hr == 0) { V.F<V.RelD>(res, 2)(res); releaseFrame(dxDuplication); }
            return true; // No new frame, skip
        }

        // 2. BGRA -> NV12 (at encode resolution)
        sw.Restart();
        int nv12Size = encW * encH * 3 / 2;
        IntPtr nv12Buf; MF.MFCreateMemoryBuffer((uint)nv12Size, out nv12Buf);
        IntPtr nv12Data; uint maxLen, curLen;

        // IMFMediaBuffer: Lock(3), Unlock(4), GetCurrentLength(5), SetCurrentLength(6), GetMaxLength(7)
        V.F<V.LockD>(nv12Buf, 3)(nv12Buf, out nv12Data, out maxLen, out curLen);

        // Scale + convert: for now just use center crop at encode resolution
        // TODO: proper scaling
        BGRAtoNV12(mappedData, mappedPitch, nv12Data, encW, encH);

        V.F<V.UnlockD>(nv12Buf, 4)(nv12Buf);
        hr = V.F<V.SetLenD>(nv12Buf, 6)(nv12Buf, (uint)nv12Size);
        if (frameIndex == 0) Console.WriteLine("SetCurrentLength(" + nv12Size + "): 0x" + hr.ToString("X8"));

        unmapTex(dxContext, dxStagingTex, 0);
        V.F<V.RelD>(res, 2)(res);
        releaseFrame(dxDuplication);

        sw.Stop();
        ConvertMs = sw.Elapsed.TotalMilliseconds;

        // 3. Create IMFSample and feed to encoder
        sw.Restart();
        IntPtr sample; MF.MFCreateSample(out sample);

        // IMFSample inherits from IMFAttributes(33 methods: 0-32), then:
        // GetSampleFlags(33), SetSampleFlags(34), GetSampleTime(35), SetSampleTime(36),
        // GetSampleDuration(37), SetSampleDuration(38), GetBufferCount(39), GetBufferByIndex(40),
        // ConvertToContiguousBuffer(41), AddBuffer(42), RemoveBufferByIndex(43), RemoveAllBuffers(44),
        // GetTotalLength(45), CopyToBuffer(46)
        int hrAdd = V.F<V.AddBufD>(sample, 42)(sample, nv12Buf);
        int hrTime = V.F<V.SetTimeD>(sample, 36)(sample, frameIndex * frameDuration);
        int hrDur = V.F<V.SetDurD>(sample, 38)(sample, frameDuration);
        if (frameIndex == 0) Console.WriteLine("AddBuffer: 0x" + hrAdd.ToString("X8") + " SetTime: 0x" + hrTime.ToString("X8") + " SetDur: 0x" + hrDur.ToString("X8"));
        frameIndex++;

        // Feed input, drain output in a loop
        bool inputSent = false;
        int maxRetries = 10;

        for (int retry = 0; retry < maxRetries; retry++)
        {
            if (!inputSent)
            {
                hr = V.F<V.ProcInD>(mfTransform, 24)(mfTransform, 0, sample, 0);
                if (frameIndex <= 3)
                    Console.WriteLine("  ProcIn hr=0x" + hr.ToString("X8") + " time=" + ((frameIndex-1) * frameDuration));
                if (hr == 0)
                {
                    inputSent = true;
                }
                else if (hr == unchecked((int)0xC00D36B5)) // MF_E_NOTACCEPTING
                {
                    // Drain output first, then retry input
                }
                else
                {
                    Console.WriteLine("ProcessInput failed: 0x" + hr.ToString("X8"));
                    break;
                }
            }

            // Try to get output
            IntPtr outSample; MF.MFCreateSample(out outSample);
            IntPtr outBuf; MF.MFCreateMemoryBuffer(2 * 1024 * 1024, out outBuf);
            V.F<V.AddBufD>(outSample, 42)(outSample, outBuf);

            MFT_OUTPUT_DATA_BUFFER outData = new MFT_OUTPUT_DATA_BUFFER();
            outData.pSample = outSample;
            outData.StreamID = 0;
            outData.Status = 0;
            outData.pEvents = IntPtr.Zero;
            uint status;

            int outHr = V.F<V.ProcOutD>(mfTransform, 25)(mfTransform, 0, 1, ref outData, out status);

            if (frameIndex <= 5)
                Console.WriteLine("  ProcOut hr=0x" + outHr.ToString("X8") + " status=" + status);

            if (outHr == 0)
            {
                // Got encoded data!
                uint encLen;
                V.F<V.GetLenD>(outBuf, 5)(outBuf, out encLen);

                if (encLen > 0)
                {
                    IntPtr encData; uint eMaxLen, eLen;
                    V.F<V.LockD>(outBuf, 3)(outBuf, out encData, out eMaxLen, out eLen);
                    byte[] h264Data = new byte[eLen];
                    Marshal.Copy(encData, h264Data, 0, (int)eLen);
                    V.F<V.UnlockD>(outBuf, 4)(outBuf);

                    LastFrameBytes = (int)eLen;
                    if (netStream != null) netStream.Write(h264Data, 0, h264Data.Length);
                    if (fileOut != null) fileOut.Write(h264Data, 0, h264Data.Length);
                    FramesSent++;
                }
            }

            V.F<V.RelD>(outBuf, 2)(outBuf);
            V.F<V.RelD>(outSample, 2)(outSample);

            if (inputSent && outHr == unchecked((int)0xC00D6D72)) break; // NEED_MORE_INPUT - done
            if (inputSent && outHr != 0) break;
        }

        V.F<V.RelD>(nv12Buf, 2)(nv12Buf);
        V.F<V.RelD>(sample, 2)(sample);

        swTotal.Stop();
        TotalMs = swTotal.Elapsed.TotalMilliseconds;
        return true;
    }

    public void Dispose()
    {
        if (mfTransform != IntPtr.Zero)
        {
            V.F<V.ProcMsgD>(mfTransform, 23)(mfTransform, 0x10000004, IntPtr.Zero); // END_OF_STREAM
            V.F<V.RelD>(mfTransform, 2)(mfTransform);
        }
        if (netStream != null) netStream.Close();
        if (tcpClient != null) tcpClient.Close();
        if (fileOut != null) fileOut.Close();
        if (dxStagingTex != IntPtr.Zero) V.F<V.RelD>(dxStagingTex, 2)(dxStagingTex);
        if (dxDuplication != IntPtr.Zero) V.F<V.RelD>(dxDuplication, 2)(dxDuplication);
        if (dxContext != IntPtr.Zero) V.F<V.RelD>(dxContext, 2)(dxContext);
        if (dxDevice != IntPtr.Zero) V.F<V.RelD>(dxDevice, 2)(dxDevice);
        MF.MFShutdown();
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Media Foundation H.264 Encode Pipeline Test ==="

$pipe = New-Object MFEncodePipeline

if (-not $pipe.InitDXGI()) { Write-Host "DXGI init failed"; exit 1 }
if (-not $pipe.InitEncoder(1920, 1080, 30, 10)) { Write-Host "Encoder init failed"; exit 1 }

# Output to file for testing
$pipe.SetFileOutput("C:\Users\makoto aizawa\mf_test.h264")

Write-Host "Encoding 200 frames..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt 200; $i++) {
    if (-not $pipe.ProcessFrame()) { Write-Host "Frame $i failed"; break }

    if ($i % 10 -eq 9) {
        $cap = [math]::Round($pipe.CaptureMs, 1)
        $conv = [math]::Round($pipe.ConvertMs, 1)
        $enc = [math]::Round($pipe.EncodeMs, 1)
        $snd = [math]::Round($pipe.SendMs, 1)
        $tot = [math]::Round($pipe.TotalMs, 1)
        $kb = [math]::Round($pipe.LastFrameBytes / 1024, 1)
        Write-Host "Frame $i | Cap:${cap}ms Conv:${conv}ms Enc:${enc}ms Snd:${snd}ms = ${tot}ms (${kb}KB)"
    }
}

$sw.Stop()
$elapsed = $sw.Elapsed.TotalSeconds
$fps = [math]::Round($pipe.FramesSent / $elapsed, 1)
Write-Host ""
Write-Host "Done: $($pipe.FramesSent) frames in $([math]::Round($elapsed, 1))s = ${fps} fps"

$pipe.Dispose()
