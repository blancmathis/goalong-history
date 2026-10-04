#if os(macOS)
    import Darwin
    import Dispatch
    import Foundation

    private struct GoalongBrokerRequest: Codable {
        let schemaVersion: Int
        let command: String
        let day: String?
        let days: [String]?
        let macOnly: Bool?
        let selectedDeviceIDs: [String]?
        var focus: GoalongFocusRequest? = nil
    }

    private struct GoalongFocusRemoteError: Codable { let focusError: String }

    private struct GoalongBrokerError: Codable {
        let brokerError: String
    }

    private struct GoalongBrokerStatus: Codable {
        let schemaVersion: Int
        let status: String
    }

    public enum GoalongReadOnlyQueryBroker {
        static let maximumRequestBytes = 96 * 1_024
        static let maximumResponseBytes = 64 * 1_024 * 1_024
        static let maximumScreenTimeRangeResponseBytes = 2 * 1_024 * 1_024

        /// Checks that the owner-only local broker is actively answering without reading Apple
        /// data or changing Goalong's active-day record.
        public static func isRunning(rootDirectory: URL) -> Bool {
            do {
                let response = try request(
                    rootDirectory: rootDirectory,
                    request: GoalongBrokerRequest(
                        schemaVersion: 1,
                        command: "status",
                        day: nil,
                        days: nil,
                        macOnly: nil,
                        selectedDeviceIDs: nil
                    ),
                    maximumResponseBytes: 4 * 1_024
                )
                let status = try JSONDecoder().decode(GoalongBrokerStatus.self, from: response)
                return status.schemaVersion == 1 && status.status == "ready"
            } catch {
                return false
            }
        }

        public static func requestScreenTime(
            rootDirectory: URL,
            day: String,
            macOnly: Bool,
            selectedDeviceIDs: [String] = []
        ) throws -> Data {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            defer { Darwin.close(descriptor) }
            setNoSigPipe(descriptor)
            setTimeout(descriptor)

            var address = try unixAddress(for: socketURL(rootDirectory: rootDirectory).path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, address.length)
                }
            }
            guard result == 0 else { throw BrokerFailure.system("connect", errno) }

            var request = try JSONEncoder().encode(
                GoalongBrokerRequest(
                    schemaVersion: 1,
                    command: "screen-time",
                    day: day,
                    days: nil,
                    macOnly: macOnly,
                    selectedDeviceIDs: selectedDeviceIDs.isEmpty ? nil : selectedDeviceIDs
                )
            )
            request.append(0x0A)
            try writeAll(request, to: descriptor)
            Darwin.shutdown(descriptor, SHUT_WR)

            let response = try readAll(
                from: descriptor,
                maximumBytes: maximumResponseBytes
            )
            guard !response.isEmpty else { throw BrokerFailure.emptyResponse }
            if let failure = try? JSONDecoder().decode(GoalongBrokerError.self, from: response) {
                throw BrokerFailure.remote(failure.brokerError)
            }
            _ = try JSONSerialization.jsonObject(with: response)
            return response
        }

        public static func requestScreenTimeRange(
            rootDirectory: URL,
            days: [String]
        ) throws -> Data {
            guard (1...31).contains(days.count) else {
                throw BrokerFailure.invalidDayCount
            }
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            defer { Darwin.close(descriptor) }
            setNoSigPipe(descriptor)
            setTimeout(descriptor)

            var address = try unixAddress(for: socketURL(rootDirectory: rootDirectory).path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, address.length)
                }
            }
            guard result == 0 else { throw BrokerFailure.system("connect", errno) }

            var request = try JSONEncoder().encode(
                GoalongBrokerRequest(
                    schemaVersion: 1,
                    command: "screen-time-range",
                    day: nil,
                    days: days,
                    macOnly: nil,
                    selectedDeviceIDs: nil
                )
            )
            request.append(0x0A)
            try writeAll(request, to: descriptor)
            Darwin.shutdown(descriptor, SHUT_WR)

            let response = try readAll(
                from: descriptor,
                maximumBytes: maximumScreenTimeRangeResponseBytes
            )
            guard !response.isEmpty else { throw BrokerFailure.emptyResponse }
            if let failure = try? JSONDecoder().decode(GoalongBrokerError.self, from: response) {
                throw BrokerFailure.remote(failure.brokerError)
            }
            _ = try JSONSerialization.jsonObject(with: response)
            return response
        }

        public static func requestFocus(rootDirectory: URL, request focus: GoalongFocusRequest) throws -> Data {
            guard focus.body.map({ $0.count <= GoalongFocusCLI.maximumInputBytes }) ?? true else { throw GoalongFocusError.invalidArgument }
            let request = GoalongBrokerRequest(schemaVersion: 1, command: "focus-route", day: nil, days: nil, macOnly: nil, selectedDeviceIDs: nil, focus: focus)
            guard try JSONEncoder().encode(request).count < maximumRequestBytes else { throw GoalongFocusError.invalidArgument }
            do {
                let data = try self.request(rootDirectory: rootDirectory, request: request, maximumResponseBytes: 2 * 1024 * 1024)
                if let failure = try? JSONDecoder().decode(GoalongFocusRemoteError.self, from: data) {
                    throw GoalongFocusError(rawValue: failure.focusError) ?? .invalidArgument
                }
                return data
            } catch let error as GoalongFocusError { throw error }
            catch BrokerFailure.system(_, _) { throw GoalongFocusError.appNotRunning }
            catch BrokerFailure.emptyResponse { throw GoalongFocusError.appNotRunning }
        }

        public static func socketURL(rootDirectory: URL) -> URL {
            rootDirectory
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("goalong-readonly.sock", isDirectory: false)
        }

        fileprivate static func unixAddress(for path: String) throws -> (
            value: sockaddr_un, length: socklen_t
        ) {
            var address = sockaddr_un()
            let bytes = Array(path.utf8CString)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count <= capacity else { throw BrokerFailure.socketPathTooLong }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    for index in bytes.indices {
                        destination[index] = bytes[index]
                    }
                }
            }
            let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            address.sun_len = UInt8(min(Int(UInt8.max), Int(length)))
            return (address, length)
        }

        fileprivate static func setNoSigPipe(_ descriptor: Int32) {
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) {
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
        }

        fileprivate static func setTimeout(_ descriptor: Int32) {
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw BrokerFailure.system("write", errno) }
                    offset += count
                }
            }
        }

        fileprivate static func readAll(from descriptor: Int32, maximumBytes: Int) throws -> Data {
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw BrokerFailure.system("read", errno) }
                if count == 0 { return result }
                guard result.count + count <= maximumBytes else {
                    throw BrokerFailure.responseTooLarge
                }
                result.append(contentsOf: buffer.prefix(count))
            }
        }

        private static func request(
            rootDirectory: URL,
            request: GoalongBrokerRequest,
            maximumResponseBytes: Int
        ) throws -> Data {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            defer { Darwin.close(descriptor) }
            setNoSigPipe(descriptor)
            setTimeout(descriptor)

            var address = try unixAddress(for: socketURL(rootDirectory: rootDirectory).path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, address.length)
                }
            }
            guard result == 0 else { throw BrokerFailure.system("connect", errno) }

            var encoded = try JSONEncoder().encode(request)
            guard encoded.count < maximumRequestBytes else { throw BrokerFailure.requestTooLarge }
            encoded.append(0x0A)
            try writeAll(encoded, to: descriptor)
            Darwin.shutdown(descriptor, SHUT_WR)

            let response = try readAll(from: descriptor, maximumBytes: maximumResponseBytes)
            guard !response.isEmpty else { throw BrokerFailure.emptyResponse }
            if let failure = try? JSONDecoder().decode(GoalongBrokerError.self, from: response) {
                throw BrokerFailure.remote(failure.brokerError)
            }
            _ = try JSONSerialization.jsonObject(with: response)
            return response
        }
    }

    public final class GoalongReadOnlyQueryServer {
        public typealias ScreenTimeHandler = (String, Bool, [String]) throws -> Data
        public typealias ScreenTimeRangeHandler = ([String]) throws -> Data

        private let rootDirectory: URL
        private let screenTimeHandler: ScreenTimeHandler
        private let screenTimeRangeHandler: ScreenTimeRangeHandler
        private let focusHandler: ((GoalongFocusRequest) throws -> Data)?
        private let clientsLock = NSLock()
        private var clientCount = 0
        private let appleQueue = DispatchQueue(label: "ai.goalong.broker.apple")
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.readonly-query-broker",
            qos: .utility
        )
        private var source: DispatchSourceRead?
        private var listeningDescriptor: Int32 = -1
        private var socketIdentity: (ino_t, dev_t)?

        public convenience init(rootDirectory: URL) {
            self.init(
                rootDirectory: rootDirectory,
                screenTimeHandler: { day, macOnly, selectedDeviceIDs in
                    try GoalongQueryCLI.screenTimePayload(
                        day: day,
                        macOnly: macOnly,
                        selectedDeviceIDs: selectedDeviceIDs
                    )
                },
                screenTimeRangeHandler: { days in
                    try GoalongQueryCLI.screenTimeRangePayload(days: days)
                }
            )
        }

        public init(
            rootDirectory: URL,
            screenTimeHandler: @escaping ScreenTimeHandler,
            screenTimeRangeHandler: ScreenTimeRangeHandler? = nil,
            focusHandler: ((GoalongFocusRequest) throws -> Data)? = nil
        ) {
            self.rootDirectory = rootDirectory
            self.focusHandler = focusHandler
            self.screenTimeHandler = screenTimeHandler
            self.screenTimeRangeHandler = screenTimeRangeHandler ?? { days in
                try GoalongQueryCLI.screenTimeRangePayload(days: days)
            }
        }

        deinit {
            stop()
        }

        public func start() throws {
            guard source == nil else { return }
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: rootDirectory)
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.removeOwnedStaleSocket(at: socketURL.path)

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            GoalongReadOnlyQueryBroker.setNoSigPipe(descriptor)

            do {
                var address = try GoalongReadOnlyQueryBroker.unixAddress(for: socketURL.path)
                let bindResult = withUnsafePointer(to: &address.value) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, address.length)
                    }
                }
                guard bindResult == 0 else { throw BrokerFailure.system("bind", errno) }
                guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                    throw BrokerFailure.system("chmod", errno)
                }
                guard Darwin.listen(descriptor, 4) == 0 else {
                    throw BrokerFailure.system("listen", errno)
                }
            } catch {
                Darwin.close(descriptor)
                try? Self.removeOwnedStaleSocket(at: socketURL.path)
                throw error
            }

            var info = stat()
            if Darwin.lstat(socketURL.path, &info) == 0 { socketIdentity = (info.st_ino, info.st_dev) }
            listeningDescriptor = descriptor
            let readSource = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: queue
            )
            readSource.setEventHandler { [weak self] in self?.acceptOneConnection() }
            source = readSource
            readSource.resume()
        }

        public func stop() {
            let socketPath = GoalongReadOnlyQueryBroker.socketURL(
                rootDirectory: rootDirectory
            ).path
            source?.cancel()
            source = nil
            if listeningDescriptor >= 0 {
                Darwin.close(listeningDescriptor)
                listeningDescriptor = -1
            }
            if let identity = socketIdentity {
                socketIdentity = nil
                var info = stat()
                if Darwin.lstat(socketPath, &info) == 0, info.st_ino == identity.0, info.st_dev == identity.1 {
                    try? Self.removeOwnedStaleSocket(at: socketPath)
                }
            }
        }

        /// Removes only a socket owned by the current user. This lets the app fail closed
        /// when Screen Time consent is off without deleting an unexpected filesystem entry.
        public static func removeOwnedStaleSocket(rootDirectory: URL) throws {
            try removeOwnedStaleSocket(
                at: GoalongReadOnlyQueryBroker.socketURL(rootDirectory: rootDirectory).path
            )
        }

        private func acceptOneConnection() {
            guard listeningDescriptor >= 0 else { return }
            let client = Darwin.accept(listeningDescriptor, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); return }
            clientsLock.lock()
            guard clientCount < 32 else { clientsLock.unlock(); Darwin.close(client); return }
            clientCount += 1; clientsLock.unlock()
            GoalongReadOnlyQueryBroker.setNoSigPipe(client)
            GoalongReadOnlyQueryBroker.setTimeout(client)
            DispatchQueue.global(qos: .utility).async { [self] in
                self.serve(client)
                clientsLock.lock(); clientCount -= 1; clientsLock.unlock()
            }
        }
        private func serve(_ client: Int32) {
            defer { Darwin.close(client) }

            do {
                let requestData = try readRequest(from: client)
                let request = try JSONDecoder().decode(GoalongBrokerRequest.self, from: requestData)
                guard request.schemaVersion == 1 else { throw BrokerFailure.unsupportedRequest }
                guard request.command == "focus-route" || requestData.count < 4 * 1024 else { throw BrokerFailure.requestTooLarge }
                let payload: Data
                switch request.command {
                case "status":
                    payload = try JSONEncoder().encode(
                        GoalongBrokerStatus(schemaVersion: 1, status: "ready")
                    )
                case "screen-time":
                    guard let day = request.day, let macOnly = request.macOnly else {
                        throw BrokerFailure.unsupportedRequest
                    }
                    payload = try appleQueue.sync { try screenTimeHandler(day, macOnly, request.selectedDeviceIDs ?? []) }
                case "screen-time-range":
                    guard let days = request.days, (1...31).contains(days.count) else {
                        throw BrokerFailure.invalidDayCount
                    }
                    payload = try appleQueue.sync { try screenTimeRangeHandler(days) }
                case "focus-route":
                    guard let focus = request.focus, let focusHandler else { throw GoalongFocusError.moduleDisabled }
                    payload = try focusHandler(focus)
                default:
                    throw BrokerFailure.unsupportedRequest
                }
                try GoalongReadOnlyQueryBroker.writeAll(payload, to: client)
            } catch {
                if let focus = error as? GoalongFocusError {
                    if let data = try? JSONEncoder().encode(GoalongFocusRemoteError(focusError: focus.rawValue)) { try? GoalongReadOnlyQueryBroker.writeAll(data, to: client) }
                    return
                }
                let payload = (try? JSONEncoder().encode(
                    GoalongBrokerError(brokerError: String(describing: error))
                )) ?? Data("{\"brokerError\":\"query failed\"}".utf8)
                try? GoalongReadOnlyQueryBroker.writeAll(payload, to: client)
            }
        }

        private func readRequest(from descriptor: Int32) throws -> Data {
            var result = Data()
            var byte: UInt8 = 0
            while result.count < GoalongReadOnlyQueryBroker.maximumRequestBytes {
                let count = Darwin.read(descriptor, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw BrokerFailure.system("read", errno) }
                if count == 0 || byte == 0x0A { return result }
                result.append(byte)
            }
            throw BrokerFailure.requestTooLarge
        }

        private static func removeOwnedStaleSocket(at path: String) throws {
            var status = stat()
            guard Darwin.lstat(path, &status) == 0 else {
                if errno == ENOENT { return }
                throw BrokerFailure.system("lstat", errno)
            }
            let fileType = status.st_mode & S_IFMT
            guard fileType == S_IFSOCK, status.st_uid == Darwin.getuid() else {
                throw BrokerFailure.unsafeExistingSocket
            }
            guard Darwin.unlink(path) == 0 else {
                throw BrokerFailure.system("unlink", errno)
            }
        }
    }

    private enum BrokerFailure: Error, CustomStringConvertible {
        case emptyResponse
        case invalidDayCount
        case remote(String)
        case requestTooLarge
        case responseTooLarge
        case socketPathTooLong
        case system(String, Int32)
        case unsafeExistingSocket
        case unsupportedRequest

        var description: String {
            switch self {
            case .emptyResponse: return "The Goalong query broker returned no data."
            case .invalidDayCount: return "A Screen Time range requires between 1 and 31 days."
            case .remote(let message): return message
            case .requestTooLarge: return "The Goalong query broker request exceeded its limit."
            case .responseTooLarge: return "The Goalong query broker response exceeded its limit."
            case .socketPathTooLong: return "The Goalong query broker socket path is too long."
            case .system(let operation, let code):
                return "Goalong query broker \(operation) failed with errno \(code)."
            case .unsafeExistingSocket:
                return "The Goalong query broker refused an unexpected existing socket path."
            case .unsupportedRequest: return "The Goalong query broker request is unsupported."
            }
        }
    }
#endif
