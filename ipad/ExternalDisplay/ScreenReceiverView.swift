import SwiftUI
import Network

struct ScreenReceiverView: View {
    @StateObject private var receiver = ScreenReceiver()

    var body: some View {
        ZStack {
            Color.black

            if let image = receiver.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Waiting for connection...")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("Port: \(receiver.port)")
                        .font(.title3)
                        .foregroundColor(.gray)
                    Text("IP: \(receiver.localIP)")
                        .font(.body)
                        .foregroundColor(.gray)
                        .textSelection(.enabled)
                    Text("Connections: \(receiver.connectionCount)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            if receiver.currentImage != nil {
                VStack {
                    HStack {
                        Text("\(receiver.fps, specifier: "%.1f") fps")
                            .font(.caption)
                            .padding(6)
                            .background(.black.opacity(0.6))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
    }
}

class ScreenReceiver: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var fps: Double = 0
    @Published var localIP: String = "..."
    @Published var connectionCount: Int = 0
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
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("Listener error: \(error)")
            return
        }

        listener?.stateUpdateHandler = { state in
            print("Listener state: \(state)")
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // Cancel previous connection if any
            self.connection?.cancel()
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("Connection ready: \(conn.endpoint)")
                case .failed(let error):
                    print("Connection failed: \(error)")
                    self?.handleDisconnect()
                case .cancelled:
                    print("Connection cancelled")
                    self?.handleDisconnect()
                default:
                    break
                }
            }

            conn.start(queue: self.queue)
            DispatchQueue.main.async {
                self.connectionCount += 1
            }
            self.receiveFrameLoop(conn)
            print("Client connected: \(conn.endpoint)")
        }

        listener?.start(queue: queue)
        print("Listening on port \(port)")
    }

    private func handleDisconnect() {
        DispatchQueue.main.async {
            self.currentImage = nil
            self.fps = 0
            self.frameCount = 0
        }
        print("Disconnected. Listener still active, waiting for new connection...")
    }

    private func receiveFrameLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if isComplete || error != nil {
                print("Connection ended: \(error?.localizedDescription ?? "closed")")
                self.handleDisconnect()
                return
            }

            guard let data, data.count == 4 else {
                self.handleDisconnect()
                return
            }

            let frameSize = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            guard frameSize > 0, frameSize < 10_000_000 else {
                print("Invalid frame size: \(frameSize)")
                self.handleDisconnect()
                return
            }

            self.receiveAll(conn, remaining: frameSize, accumulated: Data()) { jpegData in
                if let jpegData, let image = UIImage(data: jpegData) {
                    DispatchQueue.main.async {
                        self.currentImage = image
                        self.updateFPS()
                    }
                }
                self.receiveFrameLoop(conn)
            }
        }
    }

    private func receiveAll(_ conn: NWConnection, remaining: Int, accumulated: Data, completion: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
            guard let data else {
                completion(nil)
                return
            }
            var acc = accumulated
            acc.append(data)
            let left = remaining - data.count
            if left <= 0 {
                completion(acc)
            } else {
                self.receiveAll(conn, remaining: left, accumulated: acc, completion: completion)
            }
        }
    }

    private func updateFPS() {
        frameCount += 1
        let elapsed = Date.now.timeIntervalSince(fpsTimer)
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            fpsTimer = .now
        }
    }

    private func getLocalIP() -> String {
        var address = "unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            let family = iface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

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
