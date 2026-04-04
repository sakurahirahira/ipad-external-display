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

            // AVPlayer video (H.264 mode)
            if let player = receiver.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // JPEG mode
            if receiver.mode == "JPEG", let image = receiver.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            }

            // Touch overlay (works for both JPEG and H.264 modes)
            if receiver.player != nil || receiver.currentImage != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let size = UIScreen.main.bounds.size
                                let x = Float(value.location.x / size.width)
                                let y = Float(value.location.y / size.height)
                                if value.translation == .zero {
                                    receiver.sendTouch(type: 1, x: x, y: y)
                                } else {
                                    receiver.sendTouch(type: 2, x: x, y: y)
                                }
                            }
                            .onEnded { value in
                                let size = UIScreen.main.bounds.size
                                let x = Float(value.location.x / size.width)
                                let y = Float(value.location.y / size.height)
                                receiver.sendTouch(type: 3, x: x, y: y)
                            }
                    )
            }

            // PC mouse cursor overlay (high-frequency, independent of frame rate)
            if receiver.cursorVisible {
                Canvas { context, size in
                    let x = CGFloat(receiver.cursorRelX) * size.width
                    let y = CGFloat(receiver.cursorRelY) * size.height
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: x, y: y))
                    arrow.addLine(to: CGPoint(x: x, y: y + 20))
                    arrow.addLine(to: CGPoint(x: x + 6, y: y + 16))
                    arrow.addLine(to: CGPoint(x: x + 10, y: y + 24))
                    arrow.addLine(to: CGPoint(x: x + 13, y: y + 22))
                    arrow.addLine(to: CGPoint(x: x + 9, y: y + 14))
                    arrow.addLine(to: CGPoint(x: x + 15, y: y + 14))
                    arrow.closeSubpath()
                    context.fill(arrow, with: .color(.white))
                    context.stroke(arrow, with: .color(.black), lineWidth: 1.5)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
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
                            Text("\(receiver.mode) | Touch: \(receiver.touchEnabled ? "ON" : "OFF")")
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
    @Published var touchEnabled = false
    @Published var cursorRelX: Float = 0
    @Published var cursorRelY: Float = 0
    @Published var cursorVisible = false
    private var h264Mode = false
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

    // Send touch event to PC: [1byte type][4byte x][4byte y] = 9 bytes
    func sendTouch(type: UInt8, x: Float, y: Float) {
        guard let conn = connection else { return }
        var data = Data(count: 9)
        data[0] = type
        var xVal = x
        var yVal = y
        withUnsafeBytes(of: &xVal) { data.replaceSubrange(1..<5, with: $0) }
        withUnsafeBytes(of: &yVal) { data.replaceSubrange(5..<9, with: $0) }
        conn.send(content: data, completion: .idempotent)
        if !touchEnabled {
            DispatchQueue.main.async { self.touchEnabled = true }
        }
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
            self.receiveJPEGHeader(conn) // Will detect H264 magic or JPEG frames
            DispatchQueue.main.async {
                self.mode = "connecting"
                self.touchEnabled = false
            }
        }

        listener?.start(queue: queue)
        DispatchQueue.main.async { self.isListening = true }
    }

    private func receiveJPEGHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count == 4 else { self.handleDisconnect(); return }

            // Detect H264 magic: "H264" = [0x48, 0x32, 0x36, 0x34]
            if data[0] == 0x48 && data[1] == 0x32 && data[2] == 0x36 && data[3] == 0x34 {
                self.receiveH264Config(conn)
                return
            }

            let frameSize = data.withUnsafeBytes { $0.load(as: UInt32.self) }

            // Cursor packet: marker 0xFFFFFFFF + 9 bytes cursor data
            if frameSize == 0xFFFFFFFF {
                self.receiveCursorPacket(conn)
                return
            }

            let size = Int(frameSize)
            guard size > 0, size < 10_000_000 else { self.handleDisconnect(); return }

            self.receiveAll(conn, remaining: size, accumulated: Data()) { jpeg in
                if let jpeg, let image = UIImage(data: jpeg) {
                    DispatchQueue.main.async {
                        self.currentImage = image
                        if self.mode != "JPEG" { self.mode = "JPEG" }
                    }
                }
                self.receiveJPEGHeader(conn)
            }
        }
    }

    // Receive H.264 config: port(uint16) + IP(null-terminated string)
    private func receiveH264Config(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 3, maximumLength: 30) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count >= 3 else { self.handleDisconnect(); return }

            let port = data.withUnsafeBytes { $0.load(as: UInt16.self) }
            let ipData = data.suffix(from: 2)
            let ip = String(data: ipData.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
            let urlStr = "http://\(ip):\(port)"
            print("H.264 video URL: \(urlStr)")

            self.h264Mode = true

            DispatchQueue.main.async {
                self.mode = "H.264"
                self.connectVideo(urlStr)
            }

            // Continue receiving cursor packets on control channel
            self.receiveControlHeader(conn)
        }
    }

    // Control channel header loop (H.264 mode: cursor packets only)
    private func receiveControlHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count == 4 else { self.handleDisconnect(); return }

            let marker = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            if marker == 0xFFFFFFFF {
                self.receiveCursorPacket(conn)
            } else {
                // Unknown, skip and continue
                self.receiveControlHeader(conn)
            }
        }
    }

    // Connect AVPlayer to H.264 video URL
    private func connectVideo(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0.5

        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.automaticallyWaitsToMinimizeStalling = false

        self.player = avPlayer
        avPlayer.play()
    }

    private func receiveCursorPacket(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count == 9 else { self.handleDisconnect(); return }

            let x = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float.self) }
            let y = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
            let vis = data[8]

            DispatchQueue.main.async {
                self.cursorRelX = x
                self.cursorRelY = y
                self.cursorVisible = vis == 1
            }

            // Route to correct header loop based on mode
            if self.h264Mode {
                self.receiveControlHeader(conn)
            } else {
                self.receiveJPEGHeader(conn)
            }
        }
    }

    private func handleDisconnect() {
        connection?.cancel()
        connection = nil
        h264Mode = false
        DispatchQueue.main.async {
            self.currentImage = nil
            self.player?.pause()
            self.player = nil
            self.mode = "waiting"
            self.touchEnabled = false
            self.cursorVisible = false
        }
        // Listener keeps running - ready for next connection automatically
        print("Disconnected. Waiting for new connection on port \(port)...")
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
