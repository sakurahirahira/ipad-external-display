# mf-test.ps1 - Test Media Foundation H.264 encoder availability
# Enumerates MFTs and tests basic H.264 encoding

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class MFNative
{
    [DllImport("mfplat.dll")]
    public static extern int MFStartup(uint version, uint flags);

    [DllImport("mfplat.dll")]
    public static extern int MFShutdown();

    [DllImport("mfplat.dll")]
    public static extern int MFCreateMediaType(out IntPtr ppMFType);

    [DllImport("mfplat.dll")]
    public static extern int MFCreateSample(out IntPtr ppSample);

    [DllImport("mfplat.dll")]
    public static extern int MFCreateMemoryBuffer(uint cbMaxLength, out IntPtr ppBuffer);

    [DllImport("mfplat.dll")]
    public static extern int MFTEnumEx(
        Guid guidCategory,
        uint flags,
        IntPtr pInputType,
        IntPtr pOutputType,
        out IntPtr pppMFTActivate,
        out uint pcMFTActivate);

    // MFT_CATEGORY_VIDEO_ENCODER
    public static readonly Guid MFT_CATEGORY_VIDEO_ENCODER = new Guid("f79eac7d-e545-4387-bdee-d647d7bde42a");

    // MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE etc
    public static readonly Guid MF_MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MF_MT_SUBTYPE = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MF_MT_AVG_BITRATE = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MF_MT_INTERLACE_MODE = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MF_MT_FRAME_SIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MF_MT_FRAME_RATE = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");

    public static readonly Guid MFMediaType_Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFVideoFormat_H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFVideoFormat_NV12 = new Guid("3231564E-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFVideoFormat_RGB32 = new Guid("00000016-0000-0010-8000-00AA00389B71");

    // MF version
    public const uint MF_VERSION = 0x00020070; // MF_SDK_VERSION | MF_API_VERSION
}

public static class VT
{
    public static T F<T>(IntPtr obj, int slot) where T : class
    {
        IntPtr vtable = Marshal.ReadIntPtr(obj);
        IntPtr fn = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(fn, typeof(T));
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate uint RelD(IntPtr self);

    // IMFActivate::ActivateObject (slot 14)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ActivateObjectD(IntPtr self, ref Guid riid, out IntPtr ppv);

    // IMFActivate::GetAllocatedString (slot 13 for MFT_FRIENDLY_NAME_Attribute)
    // Actually GetAllocatedString is from IMFAttributes (slot 13)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int GetAllocatedStringD(IntPtr self, ref Guid key, out IntPtr ppwsz, out uint pcch);

    // IMFAttributes GUID for friendly name
    public static readonly Guid MFT_FRIENDLY_NAME_Attribute = new Guid("314ffbae-5b41-4c95-9c19-4e7d586face3");

    // IMFTransform (starts at IUnknown offset 3)
    // 3: GetStreamLimits, 4: GetStreamCount, 5: GetStreamIDs
    // 6: GetInputStreamInfo, 7: GetOutputStreamInfo
    // 8: GetAttributes, 9: GetInputStreamAttributes, 10: GetOutputStreamAttributes
    // 11: DeleteInputStream, 12: AddInputStreams
    // 13: GetInputAvailableType, 14: GetOutputAvailableType
    // 15: SetInputType, 16: SetOutputType
    // 17: GetInputCurrentType, 18: GetOutputCurrentType
    // 19: GetInputStatus, 20: GetOutputStatus
    // 21: SetOutputBounds
    // 22: ProcessEvent
    // 23: ProcessMessage
    // 24: ProcessInput, 25: ProcessOutput

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SetInputTypeD(IntPtr self, uint streamID, IntPtr pType, uint flags);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SetOutputTypeD(IntPtr self, uint streamID, IntPtr pType, uint flags);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ProcessMessageD(IntPtr self, uint eMessage, IntPtr ulParam);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ProcessInputD(IntPtr self, uint streamID, IntPtr pSample, uint flags);

    // MFT_OUTPUT_DATA_BUFFER
    [StructLayout(LayoutKind.Sequential)]
    public struct MFT_OUTPUT_DATA_BUFFER
    {
        public uint dwStreamID;
        public IntPtr pSample;
        public uint dwStatus;
        public IntPtr pEvents;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ProcessOutputD(IntPtr self, uint flags, uint count, ref MFT_OUTPUT_DATA_BUFFER outputBuffers, out uint status);

    // IMFMediaType::SetGUID (slot 24 from IMFAttributes)
    // IMFAttributes inherits from IUnknown(3)
    // IMFAttributes methods: GetItem(3), GetItemType(4), CompareItem(5), Compare(6),
    // GetUINT32(7), GetUINT64(8), GetDouble(9), GetGUID(10), GetStringLength(11), GetString(12),
    // GetAllocatedString(13), GetBlobSize(14), GetBlob(15), GetAllocatedBlob(16),
    // GetUnknown(17), SetItem(18), DeleteItem(19), DeleteAllItems(20),
    // SetUINT32(21), SetUINT64(22), SetDouble(23), SetGUID(24), SetString(25), SetBlob(26),
    // SetUnknown(27), LockStore(28), UnlockStore(29), GetCount(30), GetItemByIndex(31),
    // CopyAllItems(32)
    // IMFMediaType inherits from IMFAttributes: IsCompressedFormat(33), IsEqual(34), GetRepresentation(35), FreeRepresentation(36)

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SetGUIDD(IntPtr self, ref Guid key, ref Guid value);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SetUINT32D(IntPtr self, ref Guid key, uint value);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int SetUINT64D(IntPtr self, ref Guid key, ulong value);
}

public class MFTest
{
    public static string Run()
    {
        var log = new System.Text.StringBuilder();

        int hr = MFNative.MFStartup(MFNative.MF_VERSION, 0);
        log.AppendLine("MFStartup: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
        if (hr != 0) return log.ToString();

        try
        {
            // Enumerate H.264 encoders
            IntPtr pActivate;
            uint count;
            hr = MFNative.MFTEnumEx(
                MFNative.MFT_CATEGORY_VIDEO_ENCODER,
                0x70, // MFT_ENUM_FLAG_ALL
                IntPtr.Zero, IntPtr.Zero,
                out pActivate, out count);
            log.AppendLine("MFTEnumEx: found " + count + " video encoders");

            for (uint i = 0; i < count; i++)
            {
                IntPtr activate = Marshal.ReadIntPtr(pActivate, (int)(i * (uint)IntPtr.Size));
                IntPtr namePtr;
                uint nameLen;
                Guid nameKey = VT.MFT_FRIENDLY_NAME_Attribute;
                hr = VT.F<VT.GetAllocatedStringD>(activate, 13)(activate, ref nameKey, out namePtr, out nameLen);
                if (hr == 0 && namePtr != IntPtr.Zero)
                {
                    string name = Marshal.PtrToStringUni(namePtr);
                    log.AppendLine("  [" + i + "] " + name);
                    Marshal.FreeCoTaskMem(namePtr);
                }
            }

            // Try to create an H.264 encoder
            log.AppendLine("");
            log.AppendLine("Testing H.264 encoder creation...");

            // Create input media type (NV12 or RGB32)
            IntPtr inputType;
            MFNative.MFCreateMediaType(out inputType);
            Guid majorType = MFNative.MF_MT_MAJOR_TYPE;
            Guid videoType = MFNative.MFMediaType_Video;
            VT.F<VT.SetGUIDD>(inputType, 24)(inputType, ref majorType, ref videoType);

            Guid subtypeKey = MFNative.MF_MT_SUBTYPE;
            Guid nv12 = MFNative.MFVideoFormat_NV12;
            VT.F<VT.SetGUIDD>(inputType, 24)(inputType, ref subtypeKey, ref nv12);

            Guid frameSizeKey = MFNative.MF_MT_FRAME_SIZE;
            ulong frameSize = ((ulong)1920 << 32) | 1080;
            VT.F<VT.SetUINT64D>(inputType, 22)(inputType, ref frameSizeKey, frameSize);

            Guid frameRateKey = MFNative.MF_MT_FRAME_RATE;
            ulong frameRate = ((ulong)60 << 32) | 1;
            VT.F<VT.SetUINT64D>(inputType, 22)(inputType, ref frameRateKey, frameRate);

            Guid interlaceKey = MFNative.MF_MT_INTERLACE_MODE;
            VT.F<VT.SetUINT32D>(inputType, 21)(inputType, ref interlaceKey, 2); // Progressive

            // Create output media type (H.264)
            IntPtr outputType;
            MFNative.MFCreateMediaType(out outputType);
            VT.F<VT.SetGUIDD>(outputType, 24)(outputType, ref majorType, ref videoType);

            Guid h264 = MFNative.MFVideoFormat_H264;
            VT.F<VT.SetGUIDD>(outputType, 24)(outputType, ref subtypeKey, ref h264);

            VT.F<VT.SetUINT64D>(outputType, 22)(outputType, ref frameSizeKey, frameSize);
            VT.F<VT.SetUINT64D>(outputType, 22)(outputType, ref frameRateKey, frameRate);
            VT.F<VT.SetUINT32D>(outputType, 21)(outputType, ref interlaceKey, 2);

            Guid bitrateKey = MFNative.MF_MT_AVG_BITRATE;
            VT.F<VT.SetUINT32D>(outputType, 21)(outputType, ref bitrateKey, 15000000); // 15 Mbps

            // Try to create and configure encoder from first H.264-capable MFT
            for (uint i = 0; i < count; i++)
            {
                IntPtr activate = Marshal.ReadIntPtr(pActivate, (int)(i * (uint)IntPtr.Size));
                IntPtr namePtr;
                uint nameLen;
                Guid nameKey = VT.MFT_FRIENDLY_NAME_Attribute;
                VT.F<VT.GetAllocatedStringD>(activate, 13)(activate, ref nameKey, out namePtr, out nameLen);
                string name = namePtr != IntPtr.Zero ? Marshal.PtrToStringUni(namePtr) : "unknown";
                if (namePtr != IntPtr.Zero) Marshal.FreeCoTaskMem(namePtr);

                if (!name.ToLower().Contains("h264") && !name.ToLower().Contains("h.264")) continue;

                log.AppendLine("Trying: " + name);

                Guid transformIID = new Guid("bf94c121-5b05-4e6f-8000-ba598961414d"); // IID_IMFTransform
                IntPtr transform;
                hr = VT.F<VT.ActivateObjectD>(activate, 33)(activate, ref transformIID, out transform);
                log.AppendLine("  ActivateObject: 0x" + hr.ToString("X8"));
                if (hr != 0) continue;

                // Set output type first (H.264)
                hr = VT.F<VT.SetOutputTypeD>(transform, 16)(transform, 0, outputType, 0);
                log.AppendLine("  SetOutputType(H264): 0x" + hr.ToString("X8"));

                // Set input type (NV12)
                hr = VT.F<VT.SetInputTypeD>(transform, 15)(transform, 0, inputType, 0);
                log.AppendLine("  SetInputType(NV12): 0x" + hr.ToString("X8"));

                if (hr == 0)
                {
                    log.AppendLine("  SUCCESS! H.264 encoder configured with NV12 input");

                    // Send BEGIN_STREAMING message
                    hr = VT.F<VT.ProcessMessageD>(transform, 23)(transform, 0x10000000, IntPtr.Zero); // MFT_MESSAGE_NOTIFY_BEGIN_STREAMING
                    log.AppendLine("  ProcessMessage(BEGIN_STREAMING): 0x" + hr.ToString("X8"));

                    VT.F<VT.RelD>(transform, 2)(transform);
                    break;
                }

                VT.F<VT.RelD>(transform, 2)(transform);
            }

            VT.F<VT.RelD>(inputType, 2)(inputType);
            VT.F<VT.RelD>(outputType, 2)(outputType);
        }
        catch (Exception ex)
        {
            log.AppendLine("EXCEPTION: " + ex.Message);
        }
        finally
        {
            MFNative.MFShutdown();
        }

        return log.ToString();
    }
}
"@ -ReferencedAssemblies System.Drawing

Write-Host ([MFTest]::Run())
