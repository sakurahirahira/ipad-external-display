# usb-tunnel.ps1 - usbmux protocol implementation for iPad USB tunneling
# Creates a local TCP proxy: localhost:ListenPort -> USB -> iPad:DevicePort
# Requires: Apple Mobile Device Service (from "Apple Devices" Store app or iTunes)
#
# Usage: powershell -ExecutionPolicy Bypass -File usb-tunnel.ps1
# Then:  screen-sender-ffmjpeg.ps1 -iPadIP "127.0.0.1" -Port 9001

param(
    [int]$ListenPort = 9001,      # Local port to listen on
    [int]$DevicePort = 9000,      # iPad app port to connect to
    [int]$UsbmuxPort = 27015      # Apple Mobile Device Service port
)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Xml;
using System.Collections.Generic;

public class UsbMuxClient
{
    private const int HEADER_SIZE = 16;
    private const int VERSION_PLIST = 1;
    private const int MSG_TYPE_PLIST = 8;
    private int usbmuxPort;
    private int tag = 1;

    public UsbMuxClient(int port) { usbmuxPort = port; }

    // Build usbmux packet: [length(4)][version(4)][type(4)][tag(4)][plist XML]
    private byte[] BuildPacket(string plistXml)
    {
        byte[] payload = Encoding.UTF8.GetBytes(plistXml);
        int totalLen = HEADER_SIZE + payload.Length;
        byte[] packet = new byte[totalLen];
        BitConverter.GetBytes(totalLen).CopyTo(packet, 0);       // length (LE)
        BitConverter.GetBytes(VERSION_PLIST).CopyTo(packet, 4);   // version
        BitConverter.GetBytes(MSG_TYPE_PLIST).CopyTo(packet, 8);  // type = plist
        BitConverter.GetBytes(tag++).CopyTo(packet, 12);          // tag
        Array.Copy(payload, 0, packet, HEADER_SIZE, payload.Length);
        return packet;
    }

    // Read one usbmux response packet, return the plist XML
    private string ReadResponse(NetworkStream ns)
    {
        byte[] header = new byte[HEADER_SIZE];
        int read = 0;
        while (read < HEADER_SIZE)
        {
            int n = ns.Read(header, read, HEADER_SIZE - read);
            if (n <= 0) throw new Exception("Connection closed reading header");
            read += n;
        }
        int totalLen = BitConverter.ToInt32(header, 0);
        int payloadLen = totalLen - HEADER_SIZE;
        if (payloadLen <= 0) return "";
        byte[] payload = new byte[payloadLen];
        read = 0;
        while (read < payloadLen)
        {
            int n = ns.Read(payload, read, payloadLen - read);
            if (n <= 0) throw new Exception("Connection closed reading payload");
            read += n;
        }
        return Encoding.UTF8.GetString(payload);
    }

    // Parse plist XML and extract key-value pairs (simple flat parser)
    private Dictionary<string, string> ParsePlist(string xml)
    {
        var dict = new Dictionary<string, string>();
        try
        {
            var doc = new XmlDocument();
            doc.LoadXml(xml);
            var nodes = doc.SelectNodes("//dict/*");
            if (nodes != null)
            {
                for (int i = 0; i < nodes.Count - 1; i += 2)
                {
                    if (nodes[i].Name == "key")
                        dict[nodes[i].InnerText] = nodes[i + 1].InnerText;
                }
            }
        }
        catch { }
        return dict;
    }

    // List connected USB devices, return list of DeviceIDs
    public List<int> ListDevices()
    {
        var ids = new List<int>();
        var tcp = new TcpClient("127.0.0.1", usbmuxPort);
        tcp.NoDelay = true;
        var ns = tcp.GetStream();

        string plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>ListDevices</string>" +
            "<key>ClientVersionString</key><string>usbmux-ps1</string>" +
            "<key>ProgName</key><string>screen-sender</string>" +
            "</dict></plist>";

        byte[] packet = BuildPacket(plist);
        ns.Write(packet, 0, packet.Length);
        ns.Flush();

        string response = ReadResponse(ns);
        tcp.Close();

        // Parse device list from response
        // Response contains <key>DeviceList</key><array>...</array>
        try
        {
            var doc = new XmlDocument();
            doc.LoadXml(response);
            var deviceNodes = doc.SelectNodes("//dict/key[text()='DeviceID']/following-sibling::integer[1]");
            if (deviceNodes != null)
            {
                foreach (XmlNode node in deviceNodes)
                {
                    int id;
                    if (int.TryParse(node.InnerText, out id))
                        ids.Add(id);
                }
            }
        }
        catch (Exception ex) { Console.WriteLine("Parse error: " + ex.Message); }

        return ids;
    }

    // Connect to a port on a device via usbmux, returns the raw TCP socket
    // After successful Connect, the socket becomes a transparent tunnel
    public TcpClient ConnectToDevice(int deviceId, int port)
    {
        var tcp = new TcpClient("127.0.0.1", usbmuxPort);
        tcp.NoDelay = true;
        tcp.SendBufferSize = 4 * 1024 * 1024;
        tcp.ReceiveBufferSize = 4 * 1024 * 1024;
        var ns = tcp.GetStream();

        // Port must be in network byte order (big-endian)
        int portBE = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);

        string plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            "<key>DeviceID</key><integer>" + deviceId + "</integer>" +
            "<key>PortNumber</key><integer>" + portBE + "</integer>" +
            "<key>ClientVersionString</key><string>usbmux-ps1</string>" +
            "<key>ProgName</key><string>screen-sender</string>" +
            "</dict></plist>";

        byte[] packet = BuildPacket(plist);
        ns.Write(packet, 0, packet.Length);
        ns.Flush();

        string response = ReadResponse(ns);
        var result = ParsePlist(response);

        string numStr;
        if (result.TryGetValue("Number", out numStr))
        {
            int num = int.Parse(numStr);
            if (num != 0)
            {
                tcp.Close();
                throw new Exception("Connect failed with error code: " + num +
                    (num == 3 ? " (device not found)" :
                     num == 5 ? " (port refused - is the iPad app running?)" : ""));
            }
        }
        else
        {
            tcp.Close();
            throw new Exception("Invalid response: " + response);
        }

        // Success! Socket is now a raw tunnel to iPad port
        return tcp;
    }
}

public class UsbTunnel : IDisposable
{
    private TcpListener listener;
    private UsbMuxClient mux;
    private volatile bool running;
    private int devicePort;
    public long TotalForwarded;

    public UsbTunnel(int usbmuxPort, int devicePort)
    {
        mux = new UsbMuxClient(usbmuxPort);
        this.devicePort = devicePort;
    }

    public void Start(int listenPort)
    {
        // First, check for connected devices
        Console.WriteLine("Checking for USB-connected iOS devices...");
        var devices = mux.ListDevices();
        if (devices.Count == 0)
        {
            Console.WriteLine("ERROR: No iOS device found via USB!");
            Console.WriteLine("Make sure:");
            Console.WriteLine("  1. iPad is connected via USB-C cable");
            Console.WriteLine("  2. iPad is unlocked and trusted this PC");
            Console.WriteLine("  3. Apple Mobile Device Service is running");
            Console.WriteLine("     (Install 'Apple Devices' from Microsoft Store if needed)");
            return;
        }
        Console.WriteLine("Found " + devices.Count + " device(s): " + string.Join(", ", devices));

        running = true;
        listener = new TcpListener(IPAddress.Loopback, listenPort);
        listener.Start();
        Console.WriteLine("USB Tunnel ready: localhost:" + listenPort + " -> iPad(USB):" + devicePort);
        Console.WriteLine("Now run: screen-sender-ffmjpeg.ps1 -iPadIP \"127.0.0.1\" -Port " + listenPort);
        Console.WriteLine("Waiting for connections...");

        while (running)
        {
            try
            {
                var localClient = listener.AcceptTcpClient();
                Console.WriteLine("Local client connected, establishing USB tunnel...");

                // Connect to iPad via USB
                int devId = devices[0]; // Use first device
                TcpClient usbClient;
                try
                {
                    usbClient = mux.ConnectToDevice(devId, devicePort);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("USB connect failed: " + ex.Message);
                    // Refresh device list
                    try { devices = mux.ListDevices(); } catch {}
                    localClient.Close();
                    continue;
                }

                Console.WriteLine("USB tunnel established! Forwarding data...");

                // Bidirectional forwarding
                var localStream = localClient.GetStream();
                var usbStream = usbClient.GetStream();

                // Local -> USB (main direction: screen data)
                ThreadPool.QueueUserWorkItem(delegate {
                    try
                    {
                        byte[] buf = new byte[65536];
                        while (running && localClient.Connected && usbClient.Connected)
                        {
                            int n = localStream.Read(buf, 0, buf.Length);
                            if (n <= 0) break;
                            usbStream.Write(buf, 0, n);
                            usbStream.Flush();
                            TotalForwarded += n;
                        }
                    }
                    catch { }
                    finally
                    {
                        try { usbClient.Close(); } catch {}
                        try { localClient.Close(); } catch {}
                        Console.WriteLine("Tunnel closed (local->usb)");
                    }
                });

                // USB -> Local (for any responses from iPad)
                ThreadPool.QueueUserWorkItem(delegate {
                    try
                    {
                        byte[] buf = new byte[65536];
                        while (running && localClient.Connected && usbClient.Connected)
                        {
                            int n = usbStream.Read(buf, 0, buf.Length);
                            if (n <= 0) break;
                            localStream.Write(buf, 0, n);
                            localStream.Flush();
                        }
                    }
                    catch { }
                    finally
                    {
                        try { usbClient.Close(); } catch {}
                        try { localClient.Close(); } catch {}
                        Console.WriteLine("Tunnel closed (usb->local)");
                    }
                });
            }
            catch (Exception ex)
            {
                if (running) Console.WriteLine("Accept error: " + ex.Message);
            }
        }
    }

    public void Dispose()
    {
        running = false;
        try { listener.Stop(); } catch {}
    }
}
"@

Write-Host "=== USB Tunnel (usbmux protocol) ==="
Write-Host "Local port: $ListenPort -> iPad USB port: $DevicePort"
Write-Host ""

# Check if Apple Mobile Device Service is reachable
try {
    $testConn = New-Object System.Net.Sockets.TcpClient
    $testConn.Connect("127.0.0.1", $UsbmuxPort)
    $testConn.Close()
    Write-Host "Apple Mobile Device Service: OK (port $UsbmuxPort)"
} catch {
    Write-Host "ERROR: Apple Mobile Device Service not found on port $UsbmuxPort" -ForegroundColor Red
    Write-Host ""
    Write-Host "This service is required for USB communication with iPad." -ForegroundColor Yellow
    Write-Host "Install one of the following:" -ForegroundColor Yellow
    Write-Host "  1. Microsoft Store: 'Apple Devices' app (recommended, lightweight)" -ForegroundColor Cyan
    Write-Host "  2. apple.com: iTunes for Windows (full version)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After installing, reconnect iPad via USB and re-run this script."
    exit 1
}

Write-Host ""
$tunnel = New-Object UsbTunnel($UsbmuxPort, $DevicePort)
try {
    $tunnel.Start($ListenPort)
}
finally {
    $tunnel.Dispose()
    Write-Host "Tunnel closed. Total forwarded: $($tunnel.TotalForwarded / 1024) KB"
}
