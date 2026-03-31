# mf-debug.ps1 - Debug why H264 Encoder MFT doesn't produce output
# Check async mode, low latency settings, and try IMFSinkWriter approach

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.IO;

public static class MF
{
    [DllImport("mfplat.dll")] public static extern int MFStartup(uint ver, uint flags);
    [DllImport("mfplat.dll")] public static extern int MFShutdown();
    [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(uint cb, out IntPtr pp);
    [DllImport("mfplat.dll")] public static extern int MFTEnumEx(Guid cat, uint flags, IntPtr i, IntPtr o, out IntPtr pp, out uint cnt);
    [DllImport("mfreadwrite.dll")] public static extern int MFCreateSinkWriterFromURL(
        [MarshalAs(UnmanagedType.LPWStr)] string url, IntPtr pByteStream, IntPtr pAttributes, out IntPtr ppSinkWriter);

    public const uint MF_VERSION = 0x00020070;
    public static readonly Guid CAT_VID_ENC = new Guid("f79eac7d-e545-4387-bdee-d647d7bde42a");
    public static readonly Guid MT_MAJOR = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MT_SUB = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MT_BITRATE = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MT_INTERLACE = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MT_FRAMESIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MT_FRAMERATE = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid NV12 = new Guid("3231564E-0000-0010-8000-00AA00389B71");
    public static readonly Guid RGB32 = new Guid("00000016-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFT_NAME = new Guid("314ffbae-5b41-4c95-9c19-4e7d586face3");
    public static readonly Guid IID_MFT = new Guid("bf94c121-5b05-4e6f-8000-ba598961414d");
    // Async attributes
    public static readonly Guid MF_TRANSFORM_ASYNC = new Guid("f81a699a-649a-497d-8c73-29f8fed6ad7a");
    public static readonly Guid MF_TRANSFORM_ASYNC_UNLOCK = new Guid("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    public static readonly Guid CODECAPI_AVLowLatencyMode = new Guid("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid MF_LOW_LATENCY = new Guid("9c27891a-ed7a-40e1-88e8-b22727a024ee");
}

public static class V
{
    public static T F<T>(IntPtr o, int s) where T:class
    { return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), s*IntPtr.Size), typeof(T)); }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate uint RelD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int QID(IntPtr s, ref Guid r, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetGD(IntPtr s, ref Guid k, ref Guid v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU32D(IntPtr s, ref Guid k, uint v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetU64D(IntPtr s, ref Guid k, ulong v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetU32D(IntPtr s, ref Guid k, out uint v);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetStrD(IntPtr s, ref Guid k, out IntPtr p, out uint l);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ActivateD(IntPtr s, ref Guid r, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetTypeD(IntPtr s, uint id, IntPtr t, uint f);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int GetAttrsD(IntPtr s, out IntPtr attrs);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ProcMsgD(IntPtr s, uint msg, IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int ProcInD(IntPtr s, uint id, IntPtr samp, uint f);

    [StructLayout(LayoutKind.Sequential)]
    public struct MFT_OUTPUT_DATA_BUFFER { public uint StreamID; public IntPtr pSample; public uint Status; public IntPtr pEvents; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ProcOutD(IntPtr s, uint f, uint cnt, ref MFT_OUTPUT_DATA_BUFFER buf, out uint st);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int LockD(IntPtr s, out IntPtr buf, out uint max, out uint cur);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int UnlockD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetLenD(IntPtr s, uint len);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int AddBufD(IntPtr s, IntPtr buf);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetTimeD(IntPtr s, long time);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] public delegate int SetDurD(IntPtr s, long dur);

    // IMFSinkWriter: AddStream(3), SetInputMediaType(4), BeginWriting(5), WriteSample(6), SendStreamTick(7), PlaceSample(8?), Flush(9?), Finalize(9 or 10?)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SWAddStreamD(IntPtr s, IntPtr mediaType, out uint streamIdx);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SWSetInputTypeD(IntPtr s, uint streamIdx, IntPtr mediaType, IntPtr encodingParams);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SWBeginWritingD(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SWWriteSampleD(IntPtr s, uint streamIdx, IntPtr sample);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SWFinalizeD(IntPtr s);
}

public class MFDebug
{
    public static string Run()
    {
        var log = new System.Text.StringBuilder();
        MF.MFStartup(MF.MF_VERSION, 0);

        try
        {
            // === Part 1: Check if MFT is async ===
            IntPtr pAct; uint cnt;
            MF.MFTEnumEx(MF.CAT_VID_ENC, 0x70, IntPtr.Zero, IntPtr.Zero, out pAct, out cnt);

            IntPtr activate = IntPtr.Zero;
            for (uint i = 0; i < cnt; i++)
            {
                IntPtr a = Marshal.ReadIntPtr(pAct, (int)(i * (uint)IntPtr.Size));
                IntPtr np; uint nl; Guid nk = MF.MFT_NAME;
                V.F<V.GetStrD>(a, 13)(a, ref nk, out np, out nl);
                string n = np != IntPtr.Zero ? Marshal.PtrToStringUni(np) : "";
                if (np != IntPtr.Zero) Marshal.FreeCoTaskMem(np);
                if (n.Contains("H264")) { activate = a; log.AppendLine("Found: " + n); break; }
            }

            Guid iid = MF.IID_MFT; IntPtr transform;
            V.F<V.ActivateD>(activate, 33)(activate, ref iid, out transform);
            log.AppendLine("Activated MFT: " + (transform != IntPtr.Zero));

            // Get attributes (IMFTransform::GetAttributes = slot 8)
            IntPtr attrs;
            int hr = V.F<V.GetAttrsD>(transform, 8)(transform, out attrs);
            log.AppendLine("GetAttributes: 0x" + hr.ToString("X8"));

            if (hr == 0 && attrs != IntPtr.Zero)
            {
                // Check MF_TRANSFORM_ASYNC
                uint isAsync;
                Guid asyncKey = MF.MF_TRANSFORM_ASYNC;
                hr = V.F<V.GetU32D>(attrs, 7)(attrs, ref asyncKey, out isAsync);
                log.AppendLine("MF_TRANSFORM_ASYNC: hr=0x" + hr.ToString("X8") + " val=" + isAsync);

                if (isAsync != 0 || hr == 0)
                {
                    // Unlock async
                    Guid unlockKey = MF.MF_TRANSFORM_ASYNC_UNLOCK;
                    hr = V.F<V.SetU32D>(attrs, 21)(attrs, ref unlockKey, 1);
                    log.AppendLine("Set ASYNC_UNLOCK=1: 0x" + hr.ToString("X8"));
                }

                // Set low latency
                Guid llKey = MF.MF_LOW_LATENCY;
                hr = V.F<V.SetU32D>(attrs, 21)(attrs, ref llKey, 1);
                log.AppendLine("Set LOW_LATENCY=1: 0x" + hr.ToString("X8"));
            }

            // Configure encoder
            int w = 1920, h = 1080, fps = 30;
            long frameDur = 10000000L / fps;

            IntPtr outType; MF.MFCreateMediaType(out outType);
            Guid mk = MF.MT_MAJOR, mv = MF.Video;
            V.F<V.SetGD>(outType, 24)(outType, ref mk, ref mv);
            Guid sk = MF.MT_SUB, h264g = MF.H264;
            V.F<V.SetGD>(outType, 24)(outType, ref sk, ref h264g);
            Guid fsk = MF.MT_FRAMESIZE;
            V.F<V.SetU64D>(outType, 22)(outType, ref fsk, ((ulong)w << 32) | (uint)h);
            Guid frk = MF.MT_FRAMERATE;
            V.F<V.SetU64D>(outType, 22)(outType, ref frk, ((ulong)fps << 32) | 1);
            Guid ik = MF.MT_INTERLACE;
            V.F<V.SetU32D>(outType, 21)(outType, ref ik, 2);
            Guid bk = MF.MT_BITRATE;
            V.F<V.SetU32D>(outType, 21)(outType, ref bk, 10000000);

            hr = V.F<V.SetTypeD>(transform, 16)(transform, 0, outType, 0);
            log.AppendLine("SetOutputType: 0x" + hr.ToString("X8"));

            IntPtr inType; MF.MFCreateMediaType(out inType);
            V.F<V.SetGD>(inType, 24)(inType, ref mk, ref mv);
            Guid nv12g = MF.NV12;
            V.F<V.SetGD>(inType, 24)(inType, ref sk, ref nv12g);
            V.F<V.SetU64D>(inType, 22)(inType, ref fsk, ((ulong)w << 32) | (uint)h);
            V.F<V.SetU64D>(inType, 22)(inType, ref frk, ((ulong)fps << 32) | 1);
            V.F<V.SetU32D>(inType, 21)(inType, ref ik, 2);

            hr = V.F<V.SetTypeD>(transform, 15)(transform, 0, inType, 0);
            log.AppendLine("SetInputType: 0x" + hr.ToString("X8"));

            // Begin
            V.F<V.ProcMsgD>(transform, 23)(transform, 0x10000000, IntPtr.Zero); // NOTIFY_BEGIN_STREAMING
            V.F<V.ProcMsgD>(transform, 23)(transform, 0x10000003, IntPtr.Zero); // NOTIFY_START_OF_STREAM

            // Create and feed 30 NV12 frames (1 second), check output after each
            int nv12Size = w * h * 3 / 2;
            int outputFrames = 0;

            for (int frame = 0; frame < 30; frame++)
            {
                // Create NV12 sample with test pattern
                IntPtr buf; MF.MFCreateMemoryBuffer((uint)nv12Size, out buf);
                IntPtr data; uint maxL, curL;
                V.F<V.LockD>(buf, 3)(buf, out data, out maxL, out curL);

                // Fill with a simple gradient pattern (not all black)
                byte[] nv12Data = new byte[nv12Size];
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                        nv12Data[y * w + x] = (byte)((x + y + frame * 10) & 0xFF); // Y
                for (int i = w * h; i < nv12Size; i++)
                    nv12Data[i] = 128; // UV = gray
                Marshal.Copy(nv12Data, 0, data, nv12Size);

                V.F<V.UnlockD>(buf, 4)(buf);
                V.F<V.SetLenD>(buf, 6)(buf, (uint)nv12Size);

                IntPtr sample; MF.MFCreateSample(out sample);
                V.F<V.AddBufD>(sample, 42)(sample, buf);
                V.F<V.SetTimeD>(sample, 36)(sample, frame * frameDur);
                V.F<V.SetDurD>(sample, 38)(sample, frameDur);

                hr = V.F<V.ProcInD>(transform, 24)(transform, 0, sample, 0);
                string inResult = "OK";
                if (hr == unchecked((int)0xC00D36B5)) inResult = "NOTACCEPTING";
                else if (hr != 0) inResult = "0x" + hr.ToString("X8");

                // Try output
                IntPtr oSamp; MF.MFCreateSample(out oSamp);
                IntPtr oBuf; MF.MFCreateMemoryBuffer(1024 * 1024, out oBuf);
                V.F<V.AddBufD>(oSamp, 42)(oSamp, oBuf);

                V.MFT_OUTPUT_DATA_BUFFER od = new V.MFT_OUTPUT_DATA_BUFFER();
                od.pSample = oSamp; od.StreamID = 0;
                uint st;
                int ohr = V.F<V.ProcOutD>(transform, 25)(transform, 0, 1, ref od, out st);
                string outResult;
                if (ohr == 0)
                {
                    IntPtr oData; uint oMax, oCur;
                    V.F<V.LockD>(oBuf, 3)(oBuf, out oData, out oMax, out oCur);
                    V.F<V.UnlockD>(oBuf, 4)(oBuf);
                    outResult = "GOT " + oCur + " bytes!";
                    if (oCur > 0) outputFrames++;
                }
                else if (ohr == unchecked((int)0xC00D6D72)) outResult = "NEED_MORE";
                else outResult = "0x" + ohr.ToString("X8");

                if (frame < 5 || frame == 29 || ohr == 0)
                    log.AppendLine("Frame " + frame + ": In=" + inResult + " Out=" + outResult);

                V.F<V.RelD>(oBuf, 2)(oBuf);
                V.F<V.RelD>(oSamp, 2)(oSamp);
                V.F<V.RelD>(buf, 2)(buf);
                V.F<V.RelD>(sample, 2)(sample);
            }

            // Send drain message and try to flush output
            log.AppendLine("");
            log.AppendLine("Sending DRAIN command...");
            hr = V.F<V.ProcMsgD>(transform, 23)(transform, 0x10000002, IntPtr.Zero); // MFT_MESSAGE_COMMAND_DRAIN
            log.AppendLine("DRAIN: 0x" + hr.ToString("X8"));

            // Try to get output after drain
            for (int i = 0; i < 50; i++)
            {
                IntPtr oSamp; MF.MFCreateSample(out oSamp);
                IntPtr oBuf; MF.MFCreateMemoryBuffer(1024 * 1024, out oBuf);
                V.F<V.AddBufD>(oSamp, 42)(oSamp, oBuf);

                V.MFT_OUTPUT_DATA_BUFFER od = new V.MFT_OUTPUT_DATA_BUFFER();
                od.pSample = oSamp;
                uint st;
                int ohr = V.F<V.ProcOutD>(transform, 25)(transform, 0, 1, ref od, out st);

                if (ohr == 0)
                {
                    IntPtr oData; uint oMax, oCur;
                    V.F<V.LockD>(oBuf, 3)(oBuf, out oData, out oMax, out oCur);
                    V.F<V.UnlockD>(oBuf, 4)(oBuf);
                    log.AppendLine("  Drain output " + i + ": " + oCur + " bytes");
                    if (oCur > 0) outputFrames++;
                }
                else
                {
                    if (ohr == unchecked((int)0xC00D6D72))
                        log.AppendLine("  Drain output " + i + ": NEED_MORE (done)");
                    else
                        log.AppendLine("  Drain output " + i + ": 0x" + ohr.ToString("X8"));
                    V.F<V.RelD>(oBuf, 2)(oBuf);
                    V.F<V.RelD>(oSamp, 2)(oSamp);
                    break;
                }

                V.F<V.RelD>(oBuf, 2)(oBuf);
                V.F<V.RelD>(oSamp, 2)(oSamp);
            }

            log.AppendLine("");
            log.AppendLine("Total output frames: " + outputFrames);

            // === Part 2: Try IMFSinkWriter approach ===
            log.AppendLine("");
            log.AppendLine("=== Testing IMFSinkWriter ===");
            string testFile = "C:\\Users\\makoto aizawa\\mf_sinkwriter_test.mp4";

            IntPtr sinkWriter;
            hr = MF.MFCreateSinkWriterFromURL(testFile, IntPtr.Zero, IntPtr.Zero, out sinkWriter);
            log.AppendLine("MFCreateSinkWriterFromURL: 0x" + hr.ToString("X8"));

            if (hr == 0 && sinkWriter != IntPtr.Zero)
            {
                // AddStream with H.264 output type (slot 3)
                uint streamIdx;
                hr = V.F<V.SWAddStreamD>(sinkWriter, 3)(sinkWriter, outType, out streamIdx);
                log.AppendLine("AddStream: 0x" + hr.ToString("X8") + " idx=" + streamIdx);

                // SetInputMediaType with NV12 (slot 4)
                hr = V.F<V.SWSetInputTypeD>(sinkWriter, 4)(sinkWriter, streamIdx, inType, IntPtr.Zero);
                log.AppendLine("SetInputMediaType: 0x" + hr.ToString("X8"));

                // BeginWriting (slot 5)
                hr = V.F<V.SWBeginWritingD>(sinkWriter, 5)(sinkWriter);
                log.AppendLine("BeginWriting: 0x" + hr.ToString("X8"));

                if (hr == 0)
                {
                    // Write 30 frames
                    for (int frame = 0; frame < 30; frame++)
                    {
                        IntPtr buf2; MF.MFCreateMemoryBuffer((uint)nv12Size, out buf2);
                        IntPtr data2; uint mx2, cl2;
                        V.F<V.LockD>(buf2, 3)(buf2, out data2, out mx2, out cl2);
                        byte[] pattern = new byte[nv12Size];
                        for (int y = 0; y < h; y++)
                            for (int x = 0; x < w; x++)
                                pattern[y * w + x] = (byte)((x + y + frame * 10) & 0xFF);
                        for (int i = w * h; i < nv12Size; i++) pattern[i] = 128;
                        Marshal.Copy(pattern, 0, data2, nv12Size);
                        V.F<V.UnlockD>(buf2, 4)(buf2);
                        V.F<V.SetLenD>(buf2, 6)(buf2, (uint)nv12Size);

                        IntPtr samp2; MF.MFCreateSample(out samp2);
                        V.F<V.AddBufD>(samp2, 42)(samp2, buf2);
                        V.F<V.SetTimeD>(samp2, 36)(samp2, frame * frameDur);
                        V.F<V.SetDurD>(samp2, 38)(samp2, frameDur);

                        hr = V.F<V.SWWriteSampleD>(sinkWriter, 6)(sinkWriter, streamIdx, samp2);
                        if (frame < 3 || frame == 29)
                            log.AppendLine("  WriteSample " + frame + ": 0x" + hr.ToString("X8"));

                        V.F<V.RelD>(buf2, 2)(buf2);
                        V.F<V.RelD>(samp2, 2)(samp2);
                    }

                    // Finalize (slot 11 for IMFSinkWriter)
                    // IMFSinkWriter: AddStream(3), SetInputMediaType(4), BeginWriting(5), WriteSample(6), SendStreamTick(7), PlaceMarker(8), GetStatistics(9), GetServiceForStream(10), Finalize(11)
                    hr = V.F<V.SWFinalizeD>(sinkWriter, 11)(sinkWriter);
                    log.AppendLine("Finalize: 0x" + hr.ToString("X8"));
                }

                V.F<V.RelD>(sinkWriter, 2)(sinkWriter);

                if (File.Exists(testFile))
                {
                    var fi = new FileInfo(testFile);
                    log.AppendLine("Output file: " + fi.Length + " bytes");
                }
            }

            V.F<V.RelD>(outType, 2)(outType);
            V.F<V.RelD>(inType, 2)(inType);
            V.F<V.RelD>(transform, 2)(transform);
        }
        catch (Exception ex) { log.AppendLine("ERROR: " + ex.Message); }
        finally { MF.MFShutdown(); }
        return log.ToString();
    }
}
"@ -ReferencedAssemblies System.Drawing

Write-Host ([MFDebug]::Run())
