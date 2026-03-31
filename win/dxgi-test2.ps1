# dxgi-test2.ps1 - Debug vtable slots and try alternative copy methods

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;

[StructLayout(LayoutKind.Sequential)]
public struct DXGI_OUTDUPL_FRAME_INFO
{
    public long LastPresentTime;
    public long LastMouseUpdateTime;
    public uint AccumulatedFrames;
    public int RectsCoalesced;
    public int ProtectedContentMaskedOut;
    public int PointerPositionX;
    public int PointerPositionY;
    public int PointerPositionVisible;
    public uint TotalMetadataBufferSize;
    public uint PointerShapeBufferSize;
}

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

public static class Native
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

    public static T F<T>(IntPtr obj, int slot) where T : class
    {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(GetSlot(obj, slot), typeof(T));
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int QID(IntPtr self, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate uint RelD(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int EnumAdapters1D(IntPtr self, uint index, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int EnumOutputsD(IntPtr self, uint index, out IntPtr output);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int GetDescD(IntPtr self, out DXGI_OUTPUT_DESC desc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int DupOutD(IntPtr self, IntPtr device, out IntPtr duplication);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int AcqFrameD(IntPtr self, uint timeoutMs, out DXGI_OUTDUPL_FRAME_INFO info, out IntPtr resource);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int RelFrameD(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int CreateTex2DD(IntPtr self, ref D3D11_TEXTURE2D_DESC desc, IntPtr init, out IntPtr tex);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int MapD(IntPtr self, IntPtr resource, uint sub, uint mapType, uint flags, out D3D11_MAPPED_SUBRESOURCE mapped);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void UnmapD(IntPtr self, IntPtr resource, uint sub);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void CopyResD(IntPtr self, IntPtr dst, IntPtr src);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void CopySubResD(IntPtr self, IntPtr dst, uint dstSub, uint dstX, uint dstY, uint dstZ, IntPtr src, uint srcSub, IntPtr srcBox);

    // ID3D11Texture2D::GetDesc (slot 10: IUnknown(3) + ID3D11DeviceChild(4) + ID3D11Resource(3) + GetDesc)
    // ID3D11Resource: GetType(7), SetEvictionPriority(8), GetEvictionPriority(9)
    // ID3D11Texture2D: GetDesc(10)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void GetTexDescD(IntPtr self, out D3D11_TEXTURE2D_DESC desc);
}

public class DXGITest2
{
    public static string Run()
    {
        var log = new System.Text.StringBuilder();
        IntPtr factory = IntPtr.Zero, adapter = IntPtr.Zero, output = IntPtr.Zero;
        IntPtr output1 = IntPtr.Zero, device = IntPtr.Zero, context = IntPtr.Zero;
        IntPtr duplication = IntPtr.Zero, stagingTex = IntPtr.Zero;

        try
        {
            // Setup - same as before, condensed
            var factoryGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            Native.CreateDXGIFactory1(factoryGuid, out factory);
            VT.F<VT.EnumAdapters1D>(factory, 12)(factory, 0, out adapter);

            int fl;
            Native.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0,
                new int[] { 0xb000 }, 1, 7, out device, out fl, out context);

            IntPtr output0;
            VT.F<VT.EnumOutputsD>(adapter, 7)(adapter, 0, out output0);

            DXGI_OUTPUT_DESC desc;
            VT.F<VT.GetDescD>(output0, 7)(output0, out desc);
            int w = desc.Right - desc.Left;
            int h = desc.Bottom - desc.Top;
            log.AppendLine("Screen: " + w + "x" + h);

            var o1guid = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
            VT.F<VT.QID>(output0, 0)(output0, ref o1guid, out output1);
            VT.F<VT.DupOutD>(output1, 22)(output1, device, out duplication);

            log.AppendLine("DXGI setup OK");

            // Acquire frame
            System.Threading.Thread.Sleep(200);
            DXGI_OUTDUPL_FRAME_INFO fi;
            IntPtr resource;
            int hr = VT.F<VT.AcqFrameD>(duplication, 8)(duplication, 1000, out fi, out resource);
            log.AppendLine("AcquireFrame: 0x" + hr.ToString("X8") + " AccFrames=" + fi.AccumulatedFrames);

            if (hr == 0)
            {
                // Get source texture
                var texGuid = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
                IntPtr srcTex;
                hr = VT.F<VT.QID>(resource, 0)(resource, ref texGuid, out srcTex);
                log.AppendLine("QI Texture2D: 0x" + hr.ToString("X8") + " ptr=" + srcTex.ToString("X"));

                // Get source texture desc
                D3D11_TEXTURE2D_DESC srcDesc;
                VT.F<VT.GetTexDescD>(srcTex, 10)(srcTex, out srcDesc);
                log.AppendLine("SrcTex: " + srcDesc.Width + "x" + srcDesc.Height +
                    " Fmt=" + srcDesc.Format + " Usage=" + srcDesc.Usage +
                    " Bind=" + srcDesc.BindFlags + " CPU=" + srcDesc.CPUAccessFlags);

                // Create staging texture matching source format
                D3D11_TEXTURE2D_DESC stgDesc = new D3D11_TEXTURE2D_DESC();
                stgDesc.Width = srcDesc.Width;
                stgDesc.Height = srcDesc.Height;
                stgDesc.MipLevels = 1;
                stgDesc.ArraySize = 1;
                stgDesc.Format = srcDesc.Format; // Match source format!
                stgDesc.SampleDescCount = 1;
                stgDesc.SampleDescQuality = 0;
                stgDesc.Usage = 3; // STAGING
                stgDesc.BindFlags = 0;
                stgDesc.CPUAccessFlags = 0x20000; // CPU_ACCESS_READ
                stgDesc.MiscFlags = 0;

                hr = VT.F<VT.CreateTex2DD>(device, 5)(device, ref stgDesc, IntPtr.Zero, out stagingTex);
                log.AppendLine("CreateStaging: 0x" + hr.ToString("X8") + " Fmt=" + stgDesc.Format);

                // Try CopyResource at slot 47
                log.AppendLine("Calling CopyResource(context, staging, src)...");
                VT.F<VT.CopyResD>(context, 47)(context, stagingTex, srcTex);
                log.AppendLine("CopyResource done");

                // Map and check
                D3D11_MAPPED_SUBRESOURCE mapped;
                hr = VT.F<VT.MapD>(context, 14)(context, stagingTex, 0, 1, 0, out mapped);
                log.AppendLine("Map: 0x" + hr.ToString("X8") + " Pitch=" + mapped.RowPitch);

                if (hr == 0)
                {
                    // Check pixels
                    bool allZero = true;
                    int nonZeroCount = 0;
                    for (int i = 0; i < 1000; i++)
                    {
                        int offset = i * (int)mapped.RowPitch / 1000 * 4; // spread across rows
                        if (offset >= h * (int)mapped.RowPitch) break;
                        byte val = Marshal.ReadByte(mapped.pData, offset);
                        if (val != 0) { allZero = false; nonZeroCount++; }
                    }
                    log.AppendLine("Pixels after CopyResource(47): allZero=" + allZero + " nonZeroSamples=" + nonZeroCount);

                    // Read some actual values at different offsets
                    for (int row = 0; row < h; row += h / 4)
                    {
                        long off = row * mapped.RowPitch + (w / 2) * 4;
                        byte b = Marshal.ReadByte(mapped.pData, (int)off);
                        byte g = Marshal.ReadByte(mapped.pData, (int)off + 1);
                        byte r = Marshal.ReadByte(mapped.pData, (int)off + 2);
                        byte a = Marshal.ReadByte(mapped.pData, (int)off + 3);
                        log.AppendLine("  Row " + row + " mid pixel: " + r + "," + g + "," + b + "," + a);
                    }

                    VT.F<VT.UnmapD>(context, 15)(context, stagingTex, 0);
                }

                // If CopyResource(47) didn't work, try CopySubresourceRegion(46)
                if (isAllZero(mapped.pData, (int)mapped.RowPitch, w, h))
                {
                    log.AppendLine("");
                    log.AppendLine("CopyResource produced zeros. Trying CopySubresourceRegion at slot 46...");
                    VT.F<VT.CopySubResD>(context, 46)(context, stagingTex, 0, 0, 0, 0, srcTex, 0, IntPtr.Zero);

                    hr = VT.F<VT.MapD>(context, 14)(context, stagingTex, 0, 1, 0, out mapped);
                    log.AppendLine("Map after CopySubRes: 0x" + hr.ToString("X8"));
                    if (hr == 0)
                    {
                        bool az = true;
                        for (int i = 0; i < 100; i++)
                        {
                            if (Marshal.ReadByte(mapped.pData, i * 4) != 0) { az = false; break; }
                        }
                        log.AppendLine("Pixels after CopySubRes(46): allZero=" + az);

                        if (!az)
                        {
                            log.AppendLine("CopySubresourceRegion WORKS! Slot 46 is correct.");
                            // This means CopyResource is at wrong slot or doesn't work
                            // Save this frame
                            saveBmp(mapped.pData, (int)mapped.RowPitch, w, h, "C:\\Users\\makoto aizawa\\dxgi_test2.bmp");
                            log.AppendLine("Saved to dxgi_test2.bmp");
                        }
                        VT.F<VT.UnmapD>(context, 15)(context, stagingTex, 0);
                    }
                }
                else
                {
                    saveBmp(mapped.pData, (int)mapped.RowPitch, w, h, "C:\\Users\\makoto aizawa\\dxgi_test2.bmp");
                    log.AppendLine("Saved to dxgi_test2.bmp");
                }

                VT.F<VT.RelD>(srcTex, 2)(srcTex);
                VT.F<VT.RelD>(resource, 2)(resource);
                VT.F<VT.RelFrameD>(duplication, 14)(duplication);
            }
        }
        catch (Exception ex)
        {
            log.AppendLine("EXCEPTION: " + ex.GetType().Name + ": " + ex.Message);
            log.AppendLine(ex.StackTrace);
        }
        finally
        {
            if (stagingTex != IntPtr.Zero) VT.F<VT.RelD>(stagingTex, 2)(stagingTex);
            if (duplication != IntPtr.Zero) VT.F<VT.RelD>(duplication, 2)(duplication);
            if (context != IntPtr.Zero) VT.F<VT.RelD>(context, 2)(context);
            if (device != IntPtr.Zero) VT.F<VT.RelD>(device, 2)(device);
        }

        return log.ToString();
    }

    static bool isAllZero(IntPtr data, int pitch, int w, int h)
    {
        for (int y = 0; y < h; y += h / 10 + 1)
        {
            for (int x = 0; x < w * 4; x += w)
            {
                if (Marshal.ReadByte(data, y * pitch + x) != 0) return false;
            }
        }
        return true;
    }

    static void saveBmp(IntPtr data, int pitch, int w, int h, string path)
    {
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb))
        {
            var bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            for (int y = 0; y < h; y++)
            {
                IntPtr src = new IntPtr(data.ToInt64() + y * pitch);
                IntPtr dst = new IntPtr(bd.Scan0.ToInt64() + y * bd.Stride);
                Native.CopyMemory(dst, src, (uint)(w * 4));
            }
            bmp.UnlockBits(bd);
            bmp.Save(path, ImageFormat.Bmp);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

Write-Host ([DXGITest2]::Run())
