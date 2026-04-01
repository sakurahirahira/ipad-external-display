# screen-sender-ffhttp.ps1 - ffmpeg -> raw HTTP server (no admin needed)
# Usage: powershell -ExecutionPolicy Bypass -File screen-sender-ffhttp.ps1

param(
    [int]$Port = 8080,
    [int]$Fps = 30,
    [string]$Resolution = "1920x1080",
    [int]$Crf = 25
)

$ffmpeg = "C:\Users\makoto aizawa\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.0.1-full_build\bin\ffmpeg.exe"

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;
using System.Threading;
using System.Text;

public class FFRawHttpServer : IDisposable
{
    private TcpListener tcpListener;
    private Process ffProcess;
    private string ffmpegPath, resolution;
    private int fps, crf;
    private volatile bool running;
    public long TotalBytesSent;

    public FFRawHttpServer(string ffpath, int fps, string res, int crf)
    {
        ffmpegPath = ffpath; this.fps = fps; resolution = res; this.crf = crf;
    }

    public void Start(int port)
    {
        running = true;
        tcpListener = new TcpListener(IPAddress.Any, port);
        tcpListener.Start();
        Console.WriteLine("HTTP server on port " + port);
        Console.WriteLine("iPad URL: http://192.168.8.208:" + port + "/");

        while (running)
        {
            try
            {
                var client = tcpListener.AcceptTcpClient();
                Console.WriteLine("Client connected: " + client.Client.RemoteEndPoint);
                ThreadPool.QueueUserWorkItem(delegate { HandleClient(client); });
            }
            catch { if (running) Thread.Sleep(100); }
        }
    }

    void HandleClient(TcpClient client)
    {
        try
        {
            var stream = client.GetStream();

            // Read HTTP request (just consume it)
            byte[] reqBuf = new byte[4096];
            stream.ReadTimeout = 2000;
            try { stream.Read(reqBuf, 0, reqBuf.Length); } catch {}
            string req = Encoding.ASCII.GetString(reqBuf);
            Console.WriteLine("Request: " + req.Split('\n')[0]);

            // Send HTTP response header - no content-length, raw stream
            string header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: video/mp2t\r\n" +
                "Cache-Control: no-cache, no-store\r\n" +
                "Connection: close\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "\r\n";
            byte[] headerBytes = Encoding.ASCII.GetBytes(header);
            stream.Write(headerBytes, 0, headerBytes.Length);
            stream.Flush();
            Console.WriteLine("HTTP header sent, starting ffmpeg...");

            // Start ffmpeg
            var psi = new ProcessStartInfo();
            psi.FileName = ffmpegPath;
            psi.Arguments = "-hide_banner -loglevel error " +
                "-f gdigrab -framerate " + fps + " -i desktop " +
                "-vf scale=" + resolution + " " +
                "-c:v libx264 -preset ultrafast -tune zerolatency -crf " + crf + " " +
                "-g " + fps + " " +
                "-f mpegts pipe:1";
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;

            ffProcess = Process.Start(psi);
            var ffOut = ffProcess.StandardOutput.BaseStream;

            // Forward stderr in background
            ThreadPool.QueueUserWorkItem(delegate {
                try { string err; while ((err = ffProcess.StandardError.ReadLine()) != null) Console.WriteLine("ffmpeg: " + err); } catch {}
            });

            byte[] buf = new byte[32768];
            long sent = 0;
            var sw = Stopwatch.StartNew();

            while (!ffProcess.HasExited && running && client.Connected)
            {
                int read = ffOut.Read(buf, 0, buf.Length);
                if (read <= 0) break;

                // Raw stream - no chunked encoding
                stream.Write(buf, 0, read);
                stream.Flush();

                sent += read;
                TotalBytesSent += read;

                if (sw.ElapsedMilliseconds >= 2000)
                {
                    double kbps = sent * 8.0 / sw.Elapsed.TotalSeconds / 1000;
                    Console.Write("\rStreaming: " + (TotalBytesSent / 1024) + "KB total, " + Math.Round(kbps) + " kbps   ");
                    sent = 0;
                    sw.Restart();
                }
            }

            Console.WriteLine("\nStream ended");
        }
        catch (Exception ex) { Console.WriteLine("Client error: " + ex.Message); }
        finally
        {
            try { if (ffProcess != null && !ffProcess.HasExited) ffProcess.Kill(); } catch {}
            try { client.Close(); } catch {}
        }
    }

    public void Dispose()
    {
        running = false;
        try { tcpListener.Stop(); } catch {}
        try { if (ffProcess != null && !ffProcess.HasExited) ffProcess.Kill(); } catch {}
    }
}
"@

Write-Host "=== FFmpeg HTTP Streaming Server ==="
Write-Host "Resolution: $Resolution @ ${Fps}fps, CRF: $Crf"
Write-Host ""

$server = New-Object FFRawHttpServer($ffmpeg, $Fps, $Resolution, $Crf)
try {
    $server.Start($Port)
}
finally {
    $server.Dispose()
}
