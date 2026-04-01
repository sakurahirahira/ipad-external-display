import SwiftUI
import AVKit
import Network

struct ScreenReceiverView: View {
    @StateObject private var receiver = ScreenReceiver()
    @State private var serverIP = ""
    @State private var showUI = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // AVPlayer video
            if let player = receiver.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // Fallback JPEG mode
            if receiver.mode == "JPEG", let image = receiver.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // UI overlay
            if showUI {
                VStack(spacing: 20) {
                    if receiver.player == nil && receiver.currentImage == nil {
                        Text("iPad External Display")
                            .font(.largeTitle)
                            .foregroundColor(.white)

                        // Mode A: JPEG server
                        VStack(spacing: 8) {
                            Text("Mode A: JPEG (PowerShell)")
                                .font(.headline).foregroundColor(.white)
                            Text("IP: \(receiver.localIP):\(receiver.port)")
                                .font(.title3).foregroundColor(.green)
                                .textSelection(.enabled)
                            Text(receiver.isListening ? "Listening..." : "Starting...")
                                .font(.caption).foregroundColor(.gray)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))

                        Text("OR").foregroundColor(.gray)

                        // Mode B: H.264 HTTP stream
                        VStack(spacing: 8) {
                            Text("Mode B: H.264 Stream (ffmpeg)")
                                .font(.headline).foregroundColor(.white)
                            HStack {
                                TextField("PC IP address", text: $serverIP)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 200)
                                Button("Connect") {
                                    receiver.connectHTTP(serverIP)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
                    }

                    // FPS / status overlay
                    if receiver.player != nil || receiver.currentImage != nil {
                        HStack {
                            Text("\(receiver.mode)")
                                .font(.caption)
                                .padding(6)
                                .background(.black.opacity(0.6))
                                .foregroundColor(.green)
                                .cornerRadius(6)
                            Spacer()
                        }
                        .padding(8)
                    }
                }
            }
        }
        .onTapGesture {
            if receiver.player != nil || receiver.currentImage != nil {
                showUI.toggle()
            }
        }
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
    }
}

class ScreenReceiver: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var player: AVPlayer?
    @Published var isListening = false
    @Published var localIP: String = "..."
    @Published var mode: String = "waiting"
    let port: UInt16 = 9000

    private var listener: NWListener?
    private var connection: NWConnection?
    private var frameCount = 0
    private var fpsTimer: Date = .now
    private let queue = DispatchQueue(label: "screen-receiver", qos: .userInteractive)

    func start() {
        localIP = getLocalIP()
        startListener()
    }

    func stop() {
        listener?.cancel()
        connection?.cancel()
        player?.pause()
    }

    // Mode B: Connect to ffmpeg HTTP MPEG-TS stream
    func connectHTTP(_ ip: String) {
        let urlStr = "http://\(ip):9000"
        guard let url = URL(string: urlStr) else {
            mode = "Invalid URL"
            return
        }

        mode = "Connecting to \(ip)..."

        // Use AVPlayer for HTTP MPEG-TS playback
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [:],
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0.5 // Low buffer for low latency

        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.automaticallyWaitsToMinimizeStalling = false // Don't wait, play ASAP

        DispatchQueue.main.async {
            self.player = avPlayer
            self.mode = "H.264 Stream"
            avPlayer.play()
        }
    }

    // Mode A: JPEG TCP listener
    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("Listener error: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.main.async { self?.isListening = true }
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.handleDisconnect() }
                if case .cancelled = state { self?.handleDisconnect() }
            }

            conn.start(queue: self.queue)
            self.receiveJPEGHeader(conn)
            DispatchQueue.main.async { self.mode = "JPEG" }
        }

        listener?.start(queue: queue)
        DispatchQueue.main.async { self.isListening = true }
    }

    private func receiveJPEGHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count == 4 else { self.handleDisconnect(); return }

            let frameSize = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            guard frameSize > 0, frameSize < 10_000_000 else { self.handleDisconnect(); return }

            self.receiveAll(conn, remaining: frameSize, accumulated: Data()) { jpeg in
                if let jpeg, let image = UIImage(data: jpeg) {
                    DispatchQueue.main.async { self.currentImage = image }
                }
                self.receiveJPEGHeader(conn)
            }
        }
    }

    private func handleDisconnect() {
        DispatchQueue.main.async {
            self.currentImage = nil
            self.mode = "waiting"
        }
    }

    private func receiveAll(_ conn: NWConnection, remaining: Int, accumulated: Data, completion: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, _ in
            guard let data else { completion(nil); return }
            var acc = accumulated
            acc.append(data)
            let left = remaining - data.count
            if left <= 0 { completion(acc) }
            else { self.receiveAll(conn, remaining: left, accumulated: acc, completion: completion) }
        }
    }

    private func getLocalIP() -> String {
        var address = "unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard ["en0", "en1", "en2", "bridge100"].contains(name) else { continue }
            var addr = iface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }
}
