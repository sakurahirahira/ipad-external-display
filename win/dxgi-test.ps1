# dxgi-test.ps1 - Diagnostic test for DXGI Desktop Duplication
# Tests each step and reports errors

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;

// Correct DXGI_OUTDUPL_FRAME_INFO (48 bytes)
[StructLayout(LayoutKind.Sequential)]
public struct DXGI_OUTDUPL_FRAME_INFO
{
    public long LastPresentTime;       // 8
    public long LastMouseUpdateTime;   // 8
    public uint AccumulatedFrames;     // 4
    public int RectsCoalesced;         // 4
    public int ProtectedContentMaskedOut; // 4
    public int PointerPositionX;       // 4 (POINT.x)
    public int PointerPositionY;       // 4 (POINT.y)
    public int PointerPositionVisible; // 4 (BOOL)
    public uint TotalMetadataBufferSize; // 4
    public uint PointerShapeBufferSize;  // 4
}                                      // Total: 48 bytes

[StructLayout(LayoutKind.Sequential)]
public struct D3D11_TEXTURE2D_DESC
{
    public uint Width;
    public uint Height;
    public uint MipLevels;
    public uint ArraySize;
    public uint Format;
    public uint SampleDescCount;
    public uint SampleDescQuality;
    public uint Usage;
    public uint BindFlags;
    public uint CPUAccessFlags;
    public uint MiscFlags;
}

[StructLayout(LayoutKind.Sequential)]
public struct D3D11_MAPPED_SUBRESOURCE
{
    public IntPtr pData;
    public uint RowPitch;
    public uint DepthPitch;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DXGI_OUTPUT_DESC
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string DeviceName;
    public int Left, Top, Right, Bottom;
    public int AttachedToDesktop;
    public int Rotation;
    public IntPtr Monitor;
}

public static class DXGINative
{
    [DllImport("dxgi.dll")]
    public static extern int CreateDXGIFactory1(
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppFactory);

    [DllImport("d3d11.dll")]
    public static extern int D3D11CreateDevice(
        IntPtr pAdapter, int DriverType, IntPtr Software, uint Flags,
        int[] pFeatureLevels, uint FeatureLevels, uint SDKVersion,
        out IntPtr ppDevice, out int pFeatureLevel, out IntPtr ppImmediateContext);

    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")]
    public static extern void CopyMemory(IntPtr dest, IntPtr src, uint count);
}

public static class VT
{
    public static IntPtr GetSlot(IntPtr obj, int slot)
    {
        IntPtr vtable = Marshal.ReadIntPtr(obj);
        return Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
    }

    // IUnknown
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int QueryInterfaceD(IntPtr self, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate uint ReleaseD(IntPtr self);

    // IDXGIFactory1::EnumAdapters1 (slot 12)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int EnumAdapters1D(IntPtr self, uint index, out IntPtr adapter);

    // IDXGIAdapter::EnumOutputs (slot 7)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int EnumOutputsD(IntPtr self, uint index, out IntPtr output);

    // IDXGIOutput::GetDesc (slot 7)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int GetDescD(IntPtr self, out DXGI_OUTPUT_DESC desc);

    // IDXGIOutput1::DuplicateOutput (slot 22)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int DuplicateOutputD(IntPtr self, IntPtr device, out IntPtr duplication);

    // IDXGIOutputDuplication::AcquireNextFrame (slot 8)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int AcquireNextFrameD(IntPtr self, uint timeoutMs, out DXGI_OUTDUPL_FRAME_INFO info, out IntPtr resource);

    // IDXGIOutputDuplication::ReleaseFrame (slot 14)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ReleaseFrameD(IntPtr self);

    // ID3D11Device::CreateTexture2D (slot 5)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int CreateTexture2DD(IntPtr self, ref D3D11_TEXTURE2D_DESC desc, IntPtr init, out IntPtr tex);

    // ID3D11DeviceContext::Map (slot 14)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int MapD(IntPtr self, IntPtr resource, uint sub, uint mapType, uint flags, out D3D11_MAPPED_SUBRESOURCE mapped);

    // ID3D11DeviceContext::Unmap (slot 15)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void UnmapD(IntPtr self, IntPtr resource, uint sub);

    // ID3D11DeviceContext::CopyResource (slot 47)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void CopyResourceD(IntPtr self, IntPtr dst, IntPtr src);

    // ID3D11DeviceContext::Flush (slot 113)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void FlushD(IntPtr self);

    public static T GetFunc<T>(IntPtr obj, int slot) where T : class
    {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(GetSlot(obj, slot), typeof(T));
    }
}

public class DXGIDiag
{
    public static string Run()
    {
        var log = new System.Text.StringBuilder();
        IntPtr factory = IntPtr.Zero, adapter = IntPtr.Zero, output = IntPtr.Zero;
        IntPtr output1 = IntPtr.Zero, device = IntPtr.Zero, context = IntPtr.Zero;
        IntPtr duplication = IntPtr.Zero, stagingTex = IntPtr.Zero;

        try
        {
            // Step 1: Create Factory
            var factoryGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            int hr = DXGINative.CreateDXGIFactory1(factoryGuid, out factory);
            log.AppendLine("1. CreateDXGIFactory1: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 2: Enum Adapter
            var enumAdapters1 = VT.GetFunc<VT.EnumAdapters1D>(factory, 12);
            hr = enumAdapters1(factory, 0, out adapter);
            log.AppendLine("2. EnumAdapters1: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 3: Create D3D11 Device
            int[] featureLevels = { 0xb000 }; // D3D_FEATURE_LEVEL_11_0
            int featureLevel;
            hr = DXGINative.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0,
                featureLevels, 1, 7, out device, out featureLevel, out context);
            log.AppendLine("3. D3D11CreateDevice: 0x" + hr.ToString("X8") + " FeatureLevel=0x" + featureLevel.ToString("X") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 4: Enum Output
            var enumOutputs = VT.GetFunc<VT.EnumOutputsD>(adapter, 7);
            hr = enumOutputs(adapter, 0, out output);
            log.AppendLine("4. EnumOutputs: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 5: GetDesc
            var getDesc = VT.GetFunc<VT.GetDescD>(output, 7);
            DXGI_OUTPUT_DESC desc;
            hr = getDesc(output, out desc);
            int w = desc.Right - desc.Left;
            int h = desc.Bottom - desc.Top;
            log.AppendLine("5. GetDesc: 0x" + hr.ToString("X8") + " " + desc.DeviceName + " " + w + "x" + h + (hr == 0 ? " OK" : " FAIL"));

            // Step 6: QI for IDXGIOutput1
            var qi = VT.GetFunc<VT.QueryInterfaceD>(output, 0);
            var output1Guid = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
            hr = qi(output, ref output1Guid, out output1);
            log.AppendLine("6. QI IDXGIOutput1: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 7: DuplicateOutput
            var dupOut = VT.GetFunc<VT.DuplicateOutputD>(output1, 22);
            hr = dupOut(output1, device, out duplication);
            log.AppendLine("7. DuplicateOutput: 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 8: Create staging texture
            D3D11_TEXTURE2D_DESC texDesc = new D3D11_TEXTURE2D_DESC();
            texDesc.Width = (uint)w;
            texDesc.Height = (uint)h;
            texDesc.MipLevels = 1;
            texDesc.ArraySize = 1;
            texDesc.Format = 87; // DXGI_FORMAT_B8G8R8A8_UNORM
            texDesc.SampleDescCount = 1;
            texDesc.SampleDescQuality = 0;
            texDesc.Usage = 3; // D3D11_USAGE_STAGING
            texDesc.BindFlags = 0;
            texDesc.CPUAccessFlags = 0x20000; // D3D11_CPU_ACCESS_READ
            texDesc.MiscFlags = 0;

            var createTex = VT.GetFunc<VT.CreateTexture2DD>(device, 5);
            hr = createTex(device, ref texDesc, IntPtr.Zero, out stagingTex);
            log.AppendLine("8. CreateTexture2D (staging): 0x" + hr.ToString("X8") + (hr == 0 ? " OK" : " FAIL"));
            if (hr != 0) return log.ToString();

            // Step 9: Acquire a frame (try a few times)
            var acquireFrame = VT.GetFunc<VT.AcquireNextFrameD>(duplication, 8);
            var releaseFrame = VT.GetFunc<VT.ReleaseFrameD>(duplication, 14);
            var copyResource = VT.GetFunc<VT.CopyResourceD>(context, 47);
            var map = VT.GetFunc<VT.MapD>(context, 14);
            var unmap = VT.GetFunc<VT.UnmapD>(context, 15);
            var tex2dGuid = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

            log.AppendLine("9. Attempting frame capture (5 tries)...");
            log.AppendLine("   DXGI_OUTDUPL_FRAME_INFO size: " + Marshal.SizeOf(typeof(DXGI_OUTDUPL_FRAME_INFO)));

            bool gotFrame = false;
            for (int attempt = 0; attempt < 5; attempt++)
            {
                System.Threading.Thread.Sleep(100); // Wait for desktop update
                DXGI_OUTDUPL_FRAME_INFO frameInfo;
                IntPtr resource = IntPtr.Zero;
                hr = acquireFrame(duplication, 500, out frameInfo, out resource);
                log.AppendLine("   Attempt " + attempt + ": AcquireNextFrame=0x" + hr.ToString("X8") +
                    " AccFrames=" + frameInfo.AccumulatedFrames + " Resource=" + resource.ToString("X"));

                if (hr != 0) continue;

                // QI for ID3D11Texture2D
                var qiRes = VT.GetFunc<VT.QueryInterfaceD>(resource, 0);
                IntPtr srcTex;
                hr = qiRes(resource, ref tex2dGuid, out srcTex);
                log.AppendLine("   QI Texture2D: 0x" + hr.ToString("X8"));

                if (hr == 0)
                {
                    // Copy to staging + flush to ensure GPU completes
                    copyResource(context, stagingTex, srcTex);
                    var flush = VT.GetFunc<VT.FlushD>(context, 113);
                    flush(context);
                    log.AppendLine("   CopyResource + Flush: done");

                    // Map
                    D3D11_MAPPED_SUBRESOURCE mapped;
                    hr = map(context, stagingTex, 0, 1, 0, out mapped);
                    log.AppendLine("   Map: 0x" + hr.ToString("X8") + " pData=" + mapped.pData.ToString("X") + " Pitch=" + mapped.RowPitch);

                    if (hr == 0)
                    {
                        // Read first pixel to verify
                        byte b = Marshal.ReadByte(mapped.pData, 0);
                        byte g = Marshal.ReadByte(mapped.pData, 1);
                        byte r = Marshal.ReadByte(mapped.pData, 2);
                        byte a = Marshal.ReadByte(mapped.pData, 3);
                        log.AppendLine("   First pixel BGRA: " + b + "," + g + "," + r + "," + a);

                        // Read middle pixel
                        long midOffset = (h / 2) * mapped.RowPitch + (w / 2) * 4;
                        b = Marshal.ReadByte(mapped.pData, (int)midOffset);
                        g = Marshal.ReadByte(mapped.pData, (int)midOffset + 1);
                        r = Marshal.ReadByte(mapped.pData, (int)midOffset + 2);
                        a = Marshal.ReadByte(mapped.pData, (int)midOffset + 3);
                        log.AppendLine("   Mid pixel BGRA: " + b + "," + g + "," + r + "," + a);

                        // Save test frame
                        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb))
                        {
                            var bmpData = bmp.LockBits(new Rectangle(0, 0, w, h),
                                ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);

                            for (int y = 0; y < h; y++)
                            {
                                IntPtr src = new IntPtr(mapped.pData.ToInt64() + y * mapped.RowPitch);
                                IntPtr dst = new IntPtr(bmpData.Scan0.ToInt64() + y * bmpData.Stride);
                                DXGINative.CopyMemory(dst, src, (uint)(w * 4));
                            }
                            bmp.UnlockBits(bmpData);
                            bmp.Save("C:\\Users\\makoto aizawa\\dxgi_test.bmp", ImageFormat.Bmp);
                            log.AppendLine("   Saved test frame to dxgi_test.bmp");
                        }

                        unmap(context, stagingTex, 0);
                        gotFrame = true;
                    }

                    VT.GetFunc<VT.ReleaseD>(srcTex, 2)(srcTex);
                }

                VT.GetFunc<VT.ReleaseD>(resource, 2)(resource);
                releaseFrame(duplication);

                if (gotFrame) break;
            }

            if (!gotFrame) log.AppendLine("   FAILED to capture any frame!");
            else log.AppendLine("   SUCCESS!");
        }
        catch (Exception ex)
        {
            log.AppendLine("EXCEPTION: " + ex.Message);
            log.AppendLine(ex.StackTrace);
        }
        finally
        {
            if (stagingTex != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(stagingTex, 2)(stagingTex);
            if (duplication != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(duplication, 2)(duplication);
            if (context != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(context, 2)(context);
            if (device != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(device, 2)(device);
            if (output1 != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(output1, 2)(output1);
            if (output != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(output, 2)(output);
            if (adapter != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(adapter, 2)(adapter);
            if (factory != IntPtr.Zero) VT.GetFunc<VT.ReleaseD>(factory, 2)(factory);
        }

        return log.ToString();
    }
}
"@ -ReferencedAssemblies System.Drawing

$result = [DXGIDiag]::Run()
Write-Host $result
