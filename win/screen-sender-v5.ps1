# screen-sender-v5.ps1 - DXGI Desktop Duplication (working version)
# Uses PowerShell 5.1 (.NET Framework 4.x)
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-v5.ps1 -iPadIP "192.168.8.240"

param(
    [string]$iPadIP = "192.168.8.240",
    [int]$Port = 9000,
    [int]$Quality = 40,
    [int]$ScalePercent = 50,
    [int]$TargetFps = 60
)

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net.Sockets;
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

public static class N
{
    [DllImport("dxgi.dll")]
    public static extern int CreateDXGIFactory1([MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppFactory);
    [DllImport("d3d11.dll")]
    public static extern int D3D11CreateDevice(IntPtr pAdapter, int DriverType, IntPtr Software, uint Flags,
        int[] pFeatureLevels, uint FeatureLevels, uint SDKVersion,
        out IntPtr ppDevice, out int pFeatureLevel, out IntPtr ppImmediateContext);
    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")]
    public static extern void CopyMemory(IntPtr dest, IntPtr src, uint count);
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
    public delegate int AcqD(IntPtr self, uint timeoutMs, out DXGI_OUTDUPL_FRAME_INFO info, out IntPtr resource);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int RelFD(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int CreateTex2DD(IntPtr self, ref D3D11_TEXTURE2D_DESC desc, IntPtr init, out IntPtr tex);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int MapD(IntPtr self, IntPtr resource, uint sub, uint mapType, uint flags, out D3D11_MAPPED_SUBRESOURCE mapped);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void UnmapD(IntPtr self, IntPtr resource, uint sub);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void CopyResD(IntPtr self, IntPtr dst, IntPtr src);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void GetTexDescD(IntPtr self, out D3D11_TEXTURE2D_DESC desc);
}

public class DXGISender : IDisposable
{
    private IntPtr device, context, duplication, stagingTex;
    private int texW, texH;

    // Cached delegates
    private VT.AcqD acquireFrame;
    private VT.RelFD releaseFrame;
    private VT.CopyResD copyResource;
    private VT.MapD mapTex;
    private VT.UnmapD unmapTex;
    private Guid tex2dGuid = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    private Bitmap fullBmp;
    private Bitmap scaledBmp;
    private MemoryStream jpegBuffer;
    private ImageCodecInfo jpegCodec;
    private EncoderParameters encoderParams;
    private byte[] headerBuf = new byte[4];
    private int scaledW, scaledH;

    private TcpClient client;
    private NetworkStream netStream;

    public int FramesSent { get; private set; }
    public double LastFrameMs { get; private set; }
    public double CaptureMs { get; private set; }
    public double EncodeMs { get; private set; }
    public double SendMs { get; private set; }
    public int LastFrameBytes { get; private set; }


    public bool Initialize(int quality, int scalePercent)
    {
        try
        {
            // JPEG encoder
            foreach (var c in ImageCodecInfo.GetImageEncoders())
                if (c.MimeType == "image/jpeg") { jpegCodec = c; break; }
            encoderParams = new EncoderParameters(1);
            encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
            jpegBuffer = new MemoryStream(512 * 1024);

            // DXGI setup
            IntPtr factory, adapter, output0, output1;
            var fGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            N.CreateDXGIFactory1(fGuid, out factory);
            VT.F<VT.EnumAdapters1D>(factory, 12)(factory, 0, out adapter);
            int fl;
            N.D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new int[] { 0xb000 }, 1, 7, out device, out fl, out context);
            VT.F<VT.EnumOutputsD>(adapter, 7)(adapter, 0, out output0);
            var o1g = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
            VT.F<VT.QID>(output0, 0)(output0, ref o1g, out output1);
            int hr = VT.F<VT.DupOutD>(output1, 22)(output1, device, out duplication);
            if (hr != 0) { Console.WriteLine("DuplicateOutput failed: 0x" + hr.ToString("X")); return false; }

            // Get actual texture size from first frame
            System.Threading.Thread.Sleep(100);
            DXGI_OUTDUPL_FRAME_INFO fi;
            IntPtr res;
            hr = VT.F<VT.AcqD>(duplication, 8)(duplication, 1000, out fi, out res);
            if (hr != 0) { Console.WriteLine("Initial AcquireFrame failed: 0x" + hr.ToString("X")); return false; }

            IntPtr srcTex;
            VT.F<VT.QID>(res, 0)(res, ref tex2dGuid, out srcTex);
            D3D11_TEXTURE2D_DESC srcDesc;
            VT.F<VT.GetTexDescD>(srcTex, 10)(srcTex, out srcDesc);
            texW = (int)srcDesc.Width;
            texH = (int)srcDesc.Height;
            Console.WriteLine("DXGI texture: " + texW + "x" + texH + " fmt=" + srcDesc.Format);

            // Create staging texture matching source
            D3D11_TEXTURE2D_DESC stg = new D3D11_TEXTURE2D_DESC();
            stg.Width = srcDesc.Width; stg.Height = srcDesc.Height;
            stg.MipLevels = 1; stg.ArraySize = 1;
            stg.Format = srcDesc.Format;
            stg.SampleDescCount = 1; stg.SampleDescQuality = 0;
            stg.Usage = 3; stg.BindFlags = 0;
            stg.CPUAccessFlags = 0x20000; stg.MiscFlags = 0;
            VT.F<VT.CreateTex2DD>(device, 5)(device, ref stg, IntPtr.Zero, out stagingTex);

            VT.F<VT.RelD>(srcTex, 2)(srcTex);
            VT.F<VT.RelD>(res, 2)(res);
            VT.F<VT.RelFD>(duplication, 14)(duplication);

            // Cache delegates for hot path
            acquireFrame = VT.F<VT.AcqD>(duplication, 8);
            releaseFrame = VT.F<VT.RelFD>(duplication, 14);
            copyResource = VT.F<VT.CopyResD>(context, 47);
            mapTex = VT.F<VT.MapD>(context, 14);
            unmapTex = VT.F<VT.UnmapD>(context, 15);

            // Bitmaps
            fullBmp = new Bitmap(texW, texH, PixelFormat.Format32bppRgb);
            scaledW = texW * scalePercent / 100;
            scaledH = texH * scalePercent / 100;
            scaledBmp = new Bitmap(scaledW, scaledH, PixelFormat.Format32bppRgb);

            // Cleanup init refs
            VT.F<VT.RelD>(output0, 2)(output0);
            VT.F<VT.RelD>(output1, 2)(output1);
            VT.F<VT.RelD>(adapter, 2)(adapter);
            VT.F<VT.RelD>(factory, 2)(factory);

            Console.WriteLine("DXGI ready: " + texW + "x" + texH + " -> " + scaledW + "x" + scaledH);
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Init error: " + ex.Message);
            return false;
        }
    }

    public string GetResolution() { return texW + "x" + texH + " -> " + scaledW + "x" + scaledH; }

    public bool Connect(string ip, int port)
    {
        try
        {
            client = new TcpClient();
            client.NoDelay = true;
            client.SendBufferSize = 2 * 1024 * 1024;
            client.Connect(ip, port);
            netStream = client.GetStream();
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Connect failed: " + ex.Message);
            return false;
        }
    }

    public bool SendFrame()
    {
        var swTotal = Stopwatch.StartNew();
        try
        {
            // 1. DXGI Capture
            var sw = Stopwatch.StartNew();
            DXGI_OUTDUPL_FRAME_INFO fi;
            IntPtr res;
            int hr = acquireFrame(duplication, 100, out fi, out res);

            if (hr == 0)
            {
                IntPtr srcTex;
                VT.F<VT.QID>(res, 0)(res, ref tex2dGuid, out srcTex);
                copyResource(context, stagingTex, srcTex);

                D3D11_MAPPED_SUBRESOURCE mapped;
                hr = mapTex(context, stagingTex, 0, 1, 0, out mapped);
                if (hr == 0)
                {
                    // Copy to fullBmp
                    var bd = fullBmp.LockBits(new Rectangle(0, 0, texW, texH),
                        ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
                    for (int y = 0; y < texH; y++)
                    {
                        IntPtr src = new IntPtr(mapped.pData.ToInt64() + y * mapped.RowPitch);
                        IntPtr dst = new IntPtr(bd.Scan0.ToInt64() + y * bd.Stride);
                        N.CopyMemory(dst, src, (uint)(texW * 4));
                    }
                    fullBmp.UnlockBits(bd);
                    unmapTex(context, stagingTex, 0);
                }

                VT.F<VT.RelD>(srcTex, 2)(srcTex);
                VT.F<VT.RelD>(res, 2)(res);
                releaseFrame(duplication);
            }
            // If acquire failed (timeout), we re-send previous frame

            sw.Stop();
            CaptureMs = sw.Elapsed.TotalMilliseconds;

            // 2. Scale using Graphics.DrawImage (safe, no HDC leak)
            sw.Restart();
            using (var g = Graphics.FromImage(scaledBmp))
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.CompositingMode = CompositingMode.SourceCopy;
                g.PixelOffsetMode = PixelOffsetMode.HighSpeed;
                g.DrawImage(fullBmp, 0, 0, scaledW, scaledH);
            }

            // JPEG encode
            jpegBuffer.SetLength(0);
            jpegBuffer.Position = 0;
            scaledBmp.Save(jpegBuffer, jpegCodec, encoderParams);
            sw.Stop();
            EncodeMs = sw.Elapsed.TotalMilliseconds;

            // 3. Send
            sw.Restart();
            int len = (int)jpegBuffer.Length;
            LastFrameBytes = len;
            headerBuf[0] = (byte)len; headerBuf[1] = (byte)(len >> 8);
            headerBuf[2] = (byte)(len >> 16); headerBuf[3] = (byte)(len >> 24);
            netStream.Write(headerBuf, 0, 4);
            netStream.Write(jpegBuffer.GetBuffer(), 0, len);
            sw.Stop();
            SendMs = sw.Elapsed.TotalMilliseconds;

            FramesSent++;
            swTotal.Stop();
            LastFrameMs = swTotal.Elapsed.TotalMilliseconds;
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("SendFrame error: " + ex.Message);
            return false;
        }
    }

    public void Dispose()
    {
        if (scaledBmp != null) scaledBmp.Dispose();
        if (fullBmp != null) fullBmp.Dispose();
        if (jpegBuffer != null) jpegBuffer.Dispose();
        if (netStream != null) netStream.Close();
        if (client != null) client.Close();
        if (stagingTex != IntPtr.Zero) VT.F<VT.RelD>(stagingTex, 2)(stagingTex);
        if (duplication != IntPtr.Zero) VT.F<VT.RelD>(duplication, 2)(duplication);
        if (context != IntPtr.Zero) VT.F<VT.RelD>(context, 2)(context);
        if (device != IntPtr.Zero) VT.F<VT.RelD>(device, 2)(device);
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

Write-Host "=== Screen Sender v5 (DXGI Desktop Duplication) ==="
Write-Host "Target: ${iPadIP}:${Port}"
Write-Host "Quality: $Quality, Scale: ${ScalePercent}%, Target: ${TargetFps}fps"

$sender = New-Object DXGISender
if (-not $sender.Initialize($Quality, $ScalePercent)) {
    Write-Host "DXGI init failed!"
    exit 1
}
Write-Host "Resolution: $($sender.GetResolution())"
Write-Host ""

$targetFrameTime = [math]::Floor(1000 / $TargetFps)

Write-Host "Connecting to iPad..."
while (-not $sender.Connect($iPadIP, $Port)) {
    Write-Host "  Retrying in 2 seconds..."
    Start-Sleep -Seconds 2
}
Write-Host "Connected!"
Write-Host "Streaming (DXGI)... (Ctrl+C to stop)"
Write-Host ""

$fpsTimer = [System.Diagnostics.Stopwatch]::StartNew()
$frameCount = 0

try {
    while ($true) {
        if (-not $sender.SendFrame()) {
            Write-Host "`nConnection lost. Exiting..."
            break
        }

        $frameCount++

        if ($fpsTimer.ElapsedMilliseconds -ge 1000) {
            $fps = [math]::Round($frameCount * 1000 / $fpsTimer.ElapsedMilliseconds, 1)
            $cap = [math]::Round($sender.CaptureMs, 1)
            $enc = [math]::Round($sender.EncodeMs, 1)
            $snd = [math]::Round($sender.SendMs, 1)
            $total = [math]::Round($sender.LastFrameMs, 1)
            $kb = [math]::Round($sender.LastFrameBytes / 1024, 1)
            Write-Host "`rFPS: $fps | Cap:${cap}ms Enc:${enc}ms Snd:${snd}ms = ${total}ms (${kb}KB)   " -NoNewline
            $frameCount = 0
            $fpsTimer.Restart()
        }

        $elapsed = [int]$sender.LastFrameMs
        $sleepMs = $targetFrameTime - $elapsed
        if ($sleepMs -gt 1) {
            Start-Sleep -Milliseconds $sleepMs
        }
    }
}
finally {
    $sender.Dispose()
    Write-Host ""
    Write-Host "Stopped. Total: $($sender.FramesSent) frames"
}
