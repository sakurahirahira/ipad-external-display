import SwiftUI
import Network
import AVFoundation

struct ScreenReceiverView: View {
    @StateObject private var receiver = ScreenReceiver()
    @State private var serverIP = ""
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video display
            if receiver.isStreaming {
                VideoLayerView(layer: receiver.sampleLayer)
                    .ignoresSafeArea()
            } else if let image = receiver.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // Settings / waiting overlay
            if showSettings && !receiver.isStreaming && receiver.currentImage == nil {
                VStack(spacing: 24) {
                    Text("iPad External Display")
                        .font(.largeTitle)
                        .foregroundColor(.white)

                    // Server mode (JPEG/PowerShell)
                    VStack(spacing: 8) {
                        Text("Mode A: Listening (PowerShell sender)")
                            .font(.headline).foregroundColor(.white)
                        Text("IP: \(receiver.localIP) : \(receiver.port)")
                            .font(.title3).foregroundColor(.green)
                            .textSelection(.enabled)
                        Text(receiver.isListening ? "Listening..." : "Starting...")
                            .font(.caption).foregroundColor(.gray)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))

                    Text("OR").foregroundColor(.gray)

                    // Client mode (ffmpeg)
                    VStack(spacing: 8) {
                        Text("Mode B: Connect to PC (ffmpeg sender)")
                            .font(.headline).foregroundColor(.white)
                        HStack {
                            TextField("PC IP address", text: $serverIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.decimalPad)
                                .frame(width: 200)
                            Button("Connect") {
                                if !serverIP.isEmpty {
                                    receiver.connectToServer(serverIP, port: receiver.port)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
                }
            }

            // FPS overlay
            if receiver.isStreaming || receiver.currentImage != nil {
                VStack {
                    HStack {
                        Text("\(receiver.fps, specifier: "%.1f") fps | \(receiver.mode)")
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
        .onTapGesture {
            if receiver.isStreaming || receiver.currentImage != nil {
                showSettings.toggle()
            }
        }
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
    }
}

struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        layer.videoGravity = .resizeAspect
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}

class ScreenReceiver: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var isStreaming = false
    @Published var isListening = false
    @Published var fps: Double = 0
    @Published var localIP: String = "..."
    @Published var mode: String = "waiting"
    let port: UInt16 = 9000

    let sampleLayer = AVSampleBufferDisplayLayer()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var frameCount = 0
    private var fpsTimer: Date = .now
    private let queue = DispatchQueue(label: "screen-receiver", qos: .userInteractive)

    // H.264 state
    private var pesBuffer = Data()
    private var spsNAL: Data?
    private var ppsNAL: Data?
    private var videoFormatDesc: CMVideoFormatDescription?

    func start() {
        localIP = getLocalIP()
        sampleLayer.videoGravity = .resizeAspect
        startListener()
    }

    func stop() {
        listener?.cancel()
        connection?.cancel()
    }

    // Mode B: connect to ffmpeg TCP server on PC
    func connectToServer(_ ip: String, port: UInt16) {
        connection?.cancel()
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Connected to server \(ip):\(port)")
                self?.detectProtocol(conn)
            case .failed(let error):
                print("Connection to server failed: \(error)")
                DispatchQueue.main.async {
                    self?.mode = "connection failed"
                }
            case .cancelled:
                self?.handleDisconnect()
            default: break
            }
        }

        connection = conn
        conn.start(queue: queue)
        DispatchQueue.main.async {
            self.mode = "connecting to \(ip)..."
        }
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
            self.detectProtocol(conn)
            print("Client connected: \(conn.endpoint)")
        }

        listener?.start(queue: queue)
        DispatchQueue.main.async { self.isListening = true }
    }

    private func detectProtocol(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                self?.handleDisconnect()
                return
            }

            if data[0] == 0x47 {
                DispatchQueue.main.async {
                    self.mode = "H.264"
                    self.isStreaming = true
                }
                self.handleTSData(data)
                self.receiveTSLoop(conn)
            } else {
                DispatchQueue.main.async { self.mode = "JPEG" }
                if data.count >= 4 {
                    let frameSize = Int(data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
                    if frameSize > 0 && frameSize < 10_000_000 {
                        let initialData = data.count > 4 ? Data(data[4...]) : Data()
                        let remaining = frameSize - initialData.count
                        if remaining <= 0 {
                            self.handleJPEGFrame(Data(initialData.prefix(frameSize)))
                            self.receiveJPEGLoop(conn)
                        } else {
                            self.receiveAll(conn, remaining: remaining, accumulated: initialData) { jpeg in
                                if let jpeg { self.handleJPEGFrame(jpeg) }
                                self.receiveJPEGLoop(conn)
                            }
                        }
                    }
                }
            }
        }
    }

    // === JPEG mode ===

    private func handleJPEGFrame(_ data: Data) {
        if let image = UIImage(data: data) {
            DispatchQueue.main.async {
                self.currentImage = image
                self.updateFPS()
            }
        }
    }

    private func receiveJPEGLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data, data.count == 4 else { self.handleDisconnect(); return }

            let frameSize = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            guard frameSize > 0, frameSize < 10_000_000 else { self.handleDisconnect(); return }

            self.receiveAll(conn, remaining: frameSize, accumulated: Data()) { jpeg in
                if let jpeg { self.handleJPEGFrame(jpeg) }
                self.receiveJPEGLoop(conn)
            }
        }
    }

    // === H.264 MPEG-TS mode ===

    private func receiveTSLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.handleDisconnect(); return }
            guard let data else { self.handleDisconnect(); return }
            self.handleTSData(data)
            self.receiveTSLoop(conn)
        }
    }

    private func handleTSData(_ data: Data) {
        var offset = 0
        while offset + 188 <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let pktStart = offset
            offset += 188

            let hasAdapt = (data[pktStart + 3] & 0x20) != 0
            let hasPayload = (data[pktStart + 3] & 0x10) != 0
            let pid = (Int(data[pktStart + 1] & 0x1F) << 8) | Int(data[pktStart + 2])
            let payloadUnitStart = (data[pktStart + 1] & 0x40) != 0

            guard hasPayload, pid > 0, pid != 0x1FFF else { continue }

            var payOffset = pktStart + 4
            if hasAdapt {
                let adaptLen = Int(data[payOffset])
                payOffset += 1 + adaptLen
            }
            guard payOffset < pktStart + 188 else { continue }

            let payload = data[payOffset..<(pktStart + 188)]

            if payloadUnitStart {
                if !pesBuffer.isEmpty { extractNALUnits(from: pesBuffer) }
                pesBuffer = Data()

                if payload.count >= 9 &&
                   payload[payload.startIndex] == 0x00 &&
                   payload[payload.startIndex + 1] == 0x00 &&
                   payload[payload.startIndex + 2] == 0x01 {
                    let headerLen = Int(payload[payload.startIndex + 8])
                    let dataStart = payload.startIndex + 9 + headerLen
                    if dataStart < payload.endIndex {
                        pesBuffer.append(contentsOf: payload[dataStart...])
                    }
                } else {
                    pesBuffer.append(contentsOf: payload)
                }
            } else {
                pesBuffer.append(contentsOf: payload)
            }
        }
    }

    private func extractNALUnits(from data: Data) {
        var i = 0
        var nalStart = -1

        while i < data.count - 2 {
            if data[i] == 0 && data[i+1] == 0 {
                var scLen = 0
                if i + 3 < data.count && data[i+2] == 0 && data[i+3] == 1 { scLen = 4 }
                else if data[i+2] == 1 { scLen = 3 }

                if scLen > 0 {
                    if nalStart >= 0 {
                        processNAL(Data(data[nalStart..<i]))
                    }
                    nalStart = i + scLen
                    i += scLen
                    continue
                }
            }
            i += 1
        }
        if nalStart >= 0 && nalStart < data.count {
            processNAL(Data(data[nalStart...]))
        }
    }

    private func processNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F

        switch nalType {
        case 7: spsNAL = nal; tryCreateFormatDesc()
        case 8: ppsNAL = nal; tryCreateFormatDesc()
        case 1, 5:
            if let fmt = videoFormatDesc { displayNAL(nal, formatDesc: fmt) }
        default: break
        }
    }

    private func tryCreateFormatDesc() {
        guard let sps = spsNAL, let pps = ppsNAL else { return }

        let spsArr = Array(sps)
        let ppsArr = Array(pps)

        var formatDesc: CMVideoFormatDescription?
        spsArr.withUnsafeBufferPointer { spsBuf in
            ppsArr.withUnsafeBufferPointer { ppsBuf in
                let ptrs = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes = [spsArr.count, ppsArr.count]
                ptrs.withUnsafeBufferPointer { ptrsBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        if let fmt = formatDesc {
            videoFormatDesc = fmt
            let dim = CMVideoFormatDescriptionGetDimensions(fmt)
            print("H.264 format: \(dim.width)x\(dim.height)")
        }
    }

    private func displayNAL(_ nal: Data, formatDesc: CMVideoFormatDescription) {
        var length = UInt32(nal.count).bigEndian
        var nalWithLength = Data(bytes: &length, count: 4)
        nalWithLength.append(nal)

        var blockBuffer: CMBlockBuffer?
        let dataCount = nalWithLength.count

        nalWithLength.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            // Need to copy data since CMBlockBuffer might outlive this scope
            let copy = UnsafeMutableRawPointer.allocate(byteCount: dataCount, alignment: 1)
            copy.copyMemory(from: baseAddress, byteCount: dataCount)

            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: copy,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let block = blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleSize = dataCount

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        if let sb = sampleBuffer {
            DispatchQueue.main.async {
                if self.sampleLayer.status == .failed {
                    self.sampleLayer.flush()
                }
                self.sampleLayer.enqueue(sb)
                self.updateFPS()
            }
        }
    }

    private func handleDisconnect() {
        DispatchQueue.main.async {
            self.currentImage = nil
            self.isStreaming = false
            self.fps = 0
            self.frameCount = 0
            self.mode = "waiting"
        }
        pesBuffer = Data()
        spsNAL = nil
        ppsNAL = nil
        videoFormatDesc = nil
        print("Disconnected. Waiting for new connection...")
    }

    private func receiveAll(_ conn: NWConnection, remaining: Int, accumulated: Data, completion: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
            guard let data else { completion(nil); return }
            var acc = accumulated
            acc.append(data)
            let left = remaining - data.count
            if left <= 0 { completion(acc) }
            else { self.receiveAll(conn, remaining: left, accumulated: acc, completion: completion) }
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
