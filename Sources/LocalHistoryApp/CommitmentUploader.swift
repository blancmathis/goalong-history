#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct BoundedHTTPResponseBody {
        static let maximumBytes = 64 * 1_024

        private(set) var data = Data()

        mutating func reserve(expectedBytes: Int64) throws {
            guard expectedBytes < 0 || expectedBytes <= Int64(Self.maximumBytes) else {
                throw UploadError.responseTooLarge(Self.maximumBytes)
            }
            if expectedBytes > 0 {
                data.reserveCapacity(Int(expectedBytes))
            }
        }

        mutating func append(_ byte: UInt8) throws {
            guard data.count < Self.maximumBytes else {
                throw UploadError.responseTooLarge(Self.maximumBytes)
            }
            data.append(byte)
        }
    }

    struct CommitmentRegistrationStore {
        private let originFingerprint: String
        private let defaults: UserDefaults

        init(baseURL: URL, defaults: UserDefaults) {
            originFingerprint = SHA256Digest.hashHex(Self.canonicalOrigin(for: baseURL))
            self.defaults = defaults
        }

        func preferenceKey(deviceID: String) -> String {
            "LocalHistory.DeviceRegistered.v2.\(originFingerprint).\(deviceID)"
        }

        func isRegistered(deviceID: String) -> Bool {
            defaults.bool(forKey: preferenceKey(deviceID: deviceID))
        }

        func markRegistered(deviceID: String) {
            defaults.set(true, forKey: preferenceKey(deviceID: deviceID))
        }

        func invalidate(deviceID: String) {
            defaults.removeObject(forKey: preferenceKey(deviceID: deviceID))
        }

        @discardableResult
        func invalidateIfUnknownDevice(_ error: Error, deviceID: String) -> Bool {
            guard let uploadError = error as? UploadError,
                uploadError.isUnknownDeviceResponse
            else { return false }
            invalidate(deviceID: deviceID)
            return true
        }

        private static func canonicalOrigin(for url: URL) -> String {
            guard
                let components = URLComponents(
                    url: url.absoluteURL,
                    resolvingAgainstBaseURL: true
                ), let rawScheme = components.scheme, let rawHost = components.host
            else { return url.absoluteString }

            let scheme = rawScheme.lowercased()
            let host = rawHost.lowercased()
            let renderedHost = host.contains(":") ? "[\(host)]" : host
            let isDefaultPort =
                (scheme == "https" && components.port == 443)
                || (scheme == "http" && components.port == 80)
            let port = components.port.flatMap { isDefaultPort ? nil : ":\($0)" } ?? ""
            return "\(scheme)://\(renderedHost)\(port)"
        }
    }

    enum SecureReceiptJournal {
        private static let scanChunkBytes = 4 * 1_024
        private static let maximumRecoverableTailBytes = BoundedHTTPResponseBody.maximumBytes

        static func append(row: Data, fileName: String, directory: URL) throws {
            guard row.last == 0x0A,
                row.count <= maximumRecoverableTailBytes + 1,
                !fileName.isEmpty,
                fileName != ".",
                fileName != "..",
                !fileName.contains("/"),
                !fileName.hasPrefix(".")
            else {
                throw CommitmentReplayError.unsafeSource(
                    directory.appendingPathComponent(fileName).path
                )
            }

            let directoryDescriptor = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard directoryDescriptor >= 0 else {
                throw CommitmentReplayError.posix(
                    operation: "open receipts directory",
                    path: directory.path,
                    code: errno
                )
            }
            defer { _ = Darwin.close(directoryDescriptor) }

            let descriptor = fileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            let fileURL = directory.appendingPathComponent(fileName)
            guard descriptor >= 0 else {
                throw CommitmentReplayError.posix(
                    operation: "open receipt journal",
                    path: fileURL.path,
                    code: errno
                )
            }
            defer { _ = Darwin.close(descriptor) }
            try acquireExclusiveLock(descriptor, path: fileURL.path)
            defer { _ = flock(descriptor, LOCK_UN) }

            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                information.st_mode & S_IFMT == S_IFREG,
                information.st_size >= 0,
                information.st_nlink == 1
            else {
                throw CommitmentReplayError.unsafeSource(fileURL.path)
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw CommitmentReplayError.posix(
                    operation: "secure receipt journal",
                    path: fileURL.path,
                    code: errno
                )
            }

            try repairPartialTail(
                descriptor: descriptor,
                fileSize: information.st_size,
                path: fileURL.path
            )
            try writeAll(row, descriptor: descriptor, path: fileURL.path)
            try synchronize(descriptor, operation: "synchronize receipt", path: fileURL.path)
            try synchronize(
                directoryDescriptor,
                operation: "synchronize receipts directory",
                path: directory.path
            )
        }

        private static func repairPartialTail(
            descriptor: Int32,
            fileSize: Int64,
            path: String
        ) throws {
            guard fileSize > 0 else { return }
            let finalByte = try readExactly(
                descriptor: descriptor,
                offset: fileSize - 1,
                count: 1,
                path: path
            )
            guard finalByte.first != 0x0A else { return }

            let fragmentStart = try finalLineStart(
                descriptor: descriptor,
                fileSize: fileSize,
                path: path
            )
            let fragmentByteCount = fileSize - fragmentStart
            let isCompleteReceipt: Bool
            if fragmentByteCount <= Int64(maximumRecoverableTailBytes) {
                let fragment = try readExactly(
                    descriptor: descriptor,
                    offset: fragmentStart,
                    count: Int(fragmentByteCount),
                    path: path
                )
                isCompleteReceipt =
                    (try? JSONDecoder().decode(ReceiptSequence.self, from: fragment))
                    != nil
            } else {
                isCompleteReceipt = false
            }

            if isCompleteReceipt {
                try writeAll(Data([0x0A]), descriptor: descriptor, path: path)
            } else {
                guard Darwin.ftruncate(descriptor, fragmentStart) == 0 else {
                    throw CommitmentReplayError.posix(
                        operation: "truncate incomplete receipt tail",
                        path: path,
                        code: errno
                    )
                }
            }
            try synchronize(
                descriptor,
                operation: "synchronize repaired receipt tail",
                path: path
            )
        }

        private static func finalLineStart(
            descriptor: Int32,
            fileSize: Int64,
            path: String
        ) throws -> Int64 {
            var searchEnd = fileSize
            while searchEnd > 0 {
                let start = max(0, searchEnd - Int64(scanChunkBytes))
                let chunk = try readExactly(
                    descriptor: descriptor,
                    offset: start,
                    count: Int(searchEnd - start),
                    path: path
                )
                if let index = chunk.lastIndex(of: 0x0A) {
                    return start + Int64(index) + 1
                }
                searchEnd = start
            }
            return 0
        }

        private static func readExactly(
            descriptor: Int32,
            offset: Int64,
            count: Int,
            path: String
        ) throws -> Data {
            var data = Data(count: count)
            var readBytes = 0
            try data.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while readBytes < count {
                    let result = Darwin.pread(
                        descriptor,
                        base.advanced(by: readBytes),
                        count - readBytes,
                        offset + Int64(readBytes)
                    )
                    if result > 0 {
                        readBytes += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw CommitmentReplayError.posix(
                            operation: "read receipt journal tail",
                            path: path,
                            code: result == 0 ? EIO : errno
                        )
                    }
                }
            }
            return data
        }

        private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let result = Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if result > 0 {
                        written += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw CommitmentReplayError.posix(
                            operation: "append receipt",
                            path: path,
                            code: result == 0 ? EIO : errno
                        )
                    }
                }
            }
        }

        private static func acquireExclusiveLock(_ descriptor: Int32, path: String) throws {
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw CommitmentReplayError.posix(
                        operation: "lock receipt journal",
                        path: path,
                        code: errno
                    )
                }
            }
        }

        private static func synchronize(
            _ descriptor: Int32,
            operation: String,
            path: String
        ) throws {
            while Darwin.fsync(descriptor) != 0 {
                guard errno == EINTR else {
                    throw CommitmentReplayError.posix(
                        operation: operation,
                        path: path,
                        code: errno
                    )
                }
            }
        }
    }

    final class CommitmentUploader: MinuteSealUploader {
        typealias UploadAttempt = (LocalMinuteSeal, @escaping (Bool) -> Void) -> Void

        private let queue = DispatchQueue(label: "ai.goalong.localhistory.commitment-uploader")
        private let baseURL: URL
        private let appAttest: AppAttestManager
        private let session: URLSession
        private let registrationStore: CommitmentRegistrationStore
        private let replayScanner: CommitmentReplayScanner
        private let limits: CommitmentReplayLimits
        private let retryDelay: TimeInterval
        private let maximumRetryDelay: TimeInterval
        private let retryJitter: (TimeInterval) -> TimeInterval
        private let uploadAttemptOverride: UploadAttempt?
        private var pending: [CommitmentPendingSeal] = []
        private var pendingBytes = 0
        private var inFlight = false
        private var refillScheduled = false
        private var retryWorkItem: DispatchWorkItem?
        private var retryNotBefore: DispatchTime?
        private var consecutiveNetworkFailures = 0
        private var latestSnapshot = CommitmentUploaderSnapshot()

        init?(config: RecorderConfig, identity _: DeviceIdentity) {
            guard config.verificationEnabled == true,
                let raw = config.verificationServerURL,
                let url = URL(string: raw)
            else { return nil }

            self.baseURL = url
            self.appAttest = AppAttestManager(enabled: config.enableAppAttest != false)
            self.registrationStore = CommitmentRegistrationStore(
                baseURL: url,
                defaults: .standard
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: configuration)
            self.limits = .production
            self.retryDelay = 30
            self.maximumRetryDelay = 15 * 60
            self.retryJitter = { delay in
                delay * Double.random(in: 0.9...1.1)
            }
            self.uploadAttemptOverride = nil
            self.replayScanner = CommitmentReplayScanner(
                sealsDirectory: AppPaths.sealsDirectory,
                receiptsDirectory: AppPaths.receiptsDirectory,
                limits: .production
            )
        }

        init(
            testingBaseURL: URL,
            sealsDirectory: URL,
            receiptsDirectory: URL,
            limits: CommitmentReplayLimits,
            retryDelay: TimeInterval = 0.001,
            maximumRetryDelay: TimeInterval = 15 * 60,
            retryJitter: @escaping (TimeInterval) -> TimeInterval = { $0 },
            testingSession: URLSession? = nil,
            testingDefaults: UserDefaults = .standard,
            uploadAttempt: UploadAttempt? = nil
        ) {
            precondition(retryDelay > 0 && maximumRetryDelay >= retryDelay)
            baseURL = testingBaseURL
            appAttest = AppAttestManager(enabled: false)
            registrationStore = CommitmentRegistrationStore(
                baseURL: testingBaseURL,
                defaults: testingDefaults
            )
            if let testingSession {
                session = testingSession
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = false
                configuration.timeoutIntervalForRequest = 1
                configuration.timeoutIntervalForResource = 1
                configuration.httpMaximumConnectionsPerHost = 1
                session = URLSession(configuration: configuration)
            }
            self.limits = limits
            self.retryDelay = retryDelay
            self.maximumRetryDelay = maximumRetryDelay
            self.retryJitter = retryJitter
            uploadAttemptOverride = uploadAttempt
            replayScanner = CommitmentReplayScanner(
                sealsDirectory: sealsDirectory,
                receiptsDirectory: receiptsDirectory,
                limits: limits
            )
        }

        func enqueue(_: LocalMinuteSeal) {
            queue.async { [weak self] in
                guard let self else { return }
                // MinuteSealer calls this only after the row is durable. Re-read that row from
                // the source journal so a saturated in-memory queue never drops it.
                if self.pending.isEmpty, self.replayScanner.isBlocked {
                    self.replayScanner.reset()
                }
                self.refillAndDrain()
            }
        }

        func replayPending() {
            queue.async { [weak self] in
                guard let self else { return }
                if self.replayScanner.isBlocked {
                    self.replayScanner.reset()
                }
                self.refillAndDrain()
            }
        }

        var runtimeSnapshot: CommitmentUploaderSnapshot {
            queue.sync { snapshot() }
        }

        func waitUntilSettledForTesting(timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if queue.sync(execute: {
                    !inFlight && !refillScheduled && pending.isEmpty
                        && replayScanner.isExhausted
                }) {
                    return true
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return false
        }

        private func refillAndDrain() {
            guard pending.count < limits.queueCapacity,
                pendingBytes < limits.queueByteCapacity
            else {
                updateSnapshot(status: .ready)
                drain()
                return
            }

            let availableCount = limits.queueCapacity - pending.count
            let availableBytes = limits.queueByteCapacity - pendingBytes
            let batch = replayScanner.nextBatch(
                maximumCount: availableCount,
                maximumBytes: availableBytes
            )
            if !batch.seals.isEmpty {
                let existingSequences = Set(pending.map(\.seal.anchorSequence))
                let additions = batch.seals.filter {
                    !existingSequences.contains($0.seal.anchorSequence)
                }
                pending.append(contentsOf: additions)
                pendingBytes += additions.reduce(0) { $0 + $1.sourceBytes }
                latestSnapshot.maximumObservedPendingCount = max(
                    latestSnapshot.maximumObservedPendingCount,
                    pending.count
                )
                latestSnapshot.maximumObservedPendingBytes = max(
                    latestSnapshot.maximumObservedPendingBytes,
                    pendingBytes
                )
            }
            updateSnapshot(status: batch.status)

            switch batch.status {
            case .budgetExhausted
            where pending.count < limits.queueCapacity
                && batch.madeProgress:
                scheduleRefill(after: 0.01)
            case .budgetExhausted:
                Diagnostics.write("Commitment replay paused: \(batch.status.description)")
            case .blocked, .invalidated:
                Diagnostics.write("Commitment replay paused: \(batch.status.description)")
            default:
                break
            }
            // Records already decoded from the pinned descriptor remain signed durable
            // commitments. Drain that validated prefix even if a later identity check
            // invalidates further discovery; never discard it from RAM.
            drain()
        }

        private func scheduleRefill(after delay: TimeInterval) {
            guard !refillScheduled else { return }
            refillScheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.refillScheduled = false
                self.refillAndDrain()
            }
        }

        private func drain() {
            guard !inFlight, let item = pending.first else { return }
            if let retryNotBefore, DispatchTime.now() < retryNotBefore { return }
            retryWorkItem?.cancel()
            retryWorkItem = nil
            retryNotBefore = nil
            inFlight = true
            latestSnapshot.lastAttemptedSequence = item.seal.anchorSequence
            updateSnapshot(status: latestSnapshot.status)

            let attempt: UploadAttempt =
                uploadAttemptOverride ?? { [weak self] seal, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    self.ensureRegistered(for: seal) { ok in
                        guard ok else {
                            completion(false)
                            return
                        }
                        self.upload(seal, completion: completion)
                    }
                }
            attempt(item.seal) { [weak self] success in
                self?.finishAttempt(sequence: item.seal.anchorSequence, success: success)
            }
        }

        private func finishAttempt(sequence: UInt64, success: Bool) {
            queue.async { [weak self] in
                guard let self else { return }
                if success, self.pending.first?.seal.anchorSequence == sequence {
                    let removed = self.pending.removeFirst()
                    self.pendingBytes -= removed.sourceBytes
                    self.latestSnapshot.lastUploadedSequence = sequence
                }
                self.inFlight = false
                if success {
                    self.consecutiveNetworkFailures = 0
                    self.refillAndDrain()
                } else {
                    self.consecutiveNetworkFailures = min(
                        self.consecutiveNetworkFailures + 1,
                        63
                    )
                    self.updateSnapshot(status: .networkRetry)
                    self.scheduleNetworkRetry()
                }
            }
        }

        private func scheduleNetworkRetry() {
            guard retryWorkItem == nil else { return }
            let baseDelay = Self.exponentialRetryDelay(
                base: retryDelay,
                maximum: maximumRetryDelay,
                failureCount: consecutiveNetworkFailures
            )
            let delay = min(maximumRetryDelay, max(0.001, retryJitter(baseDelay)))
            let deadline = DispatchTime.now() + delay
            retryNotBefore = deadline
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.retryWorkItem = nil
                self.retryNotBefore = nil
                self.drain()
            }
            retryWorkItem = item
            queue.asyncAfter(deadline: deadline, execute: item)
        }

        static func exponentialRetryDelay(
            base: TimeInterval,
            maximum: TimeInterval,
            failureCount: Int
        ) -> TimeInterval {
            precondition(base > 0 && maximum >= base)
            let exponent = min(max(0, failureCount - 1), 20)
            return min(maximum, base * pow(2, Double(exponent)))
        }

        private func snapshot() -> CommitmentUploaderSnapshot {
            var result = latestSnapshot
            result.pendingCount = pending.count
            result.pendingBytes = pendingBytes
            result.inFlight = inFlight
            result.queueCapacity = limits.queueCapacity
            result.queueByteCapacity = limits.queueByteCapacity
            return result
        }

        private func updateSnapshot(status: CommitmentReplayStatus) {
            latestSnapshot.status = status
            latestSnapshot.pendingCount = pending.count
            latestSnapshot.pendingBytes = pendingBytes
            latestSnapshot.inFlight = inFlight
            latestSnapshot.queueCapacity = limits.queueCapacity
            latestSnapshot.queueByteCapacity = limits.queueByteCapacity
            latestSnapshot.scannedBytes = replayScanner.scannedBytes
            latestSnapshot.scannedLines = replayScanner.scannedLines
            latestSnapshot.openedFiles = replayScanner.openedFiles
        }

        private func ensureRegistered(for seal: LocalMinuteSeal, completion: @escaping (Bool) -> Void) {
            if registrationStore.isRegistered(deviceID: seal.deviceID) {
                completion(true)
                return
            }

            fetchChallenge(deviceID: seal.deviceID) { [weak self] challenge in
                guard let self, let challenge else {
                    completion(false)
                    return
                }
                let hash = self.registrationClientDataHash(
                    challenge: challenge,
                    deviceID: seal.deviceID,
                    publicKeyBase64: seal.publicKeyBase64
                )
                self.appAttest.materialForRegistration(clientDataHash: hash) { material in
                    let request = DeviceRegistrationRequest(
                        challengeID: challenge.challengeID,
                        deviceID: seal.deviceID,
                        publicKeyBase64: seal.publicKeyBase64,
                        signatureAlgorithm: seal.signatureAlgorithm,
                        localTrustTier: seal.trustTier,
                        appVersion: self.appVersion,
                        appAttestKeyID: material.keyID,
                        appAttestationObjectBase64: material.attestationObjectBase64
                    )
                    self.post(path: "/v1/devices/register", body: request, response: SimpleOK.self) { result in
                        switch result {
                        case .success(let response) where response.ok:
                            self.queue.async {
                                self.registrationStore.markRegistered(deviceID: seal.deviceID)
                                completion(true)
                            }
                        default:
                            completion(false)
                        }
                    }
                }
            }
        }

        private func upload(_ seal: LocalMinuteSeal, completion: @escaping (Bool) -> Void) {
            fetchChallenge(deviceID: seal.deviceID) { [weak self] challenge in
                guard let self, let challenge else {
                    completion(false)
                    return
                }

                let clientHash = self.anchorClientDataHash(challenge: challenge, seal: seal)
                self.appAttest.assertion(clientDataHash: clientHash) { material in
                    let request = AnchorUploadRequest(
                        deviceID: seal.deviceID,
                        anchorSequence: seal.anchorSequence,
                        minuteRoot: seal.minuteRoot,
                        previousAnchorHash: seal.previousAnchorHash,
                        anchorHash: seal.anchorHash,
                        signatureBase64: seal.signatureBase64,
                        signatureAlgorithm: seal.signatureAlgorithm,
                        appVersion: self.appVersion,
                        challengeID: challenge.challengeID,
                        appAttestKeyID: material.keyID,
                        appAttestAssertionBase64: material.assertionBase64
                    )
                    self.post(path: "/v1/anchors", body: request, response: AnchorReceipt.self) { result in
                        switch result {
                        case .success(let receipt):
                            do {
                                try self.appendReceipt(receipt)
                                completion(true)
                            } catch {
                                Diagnostics.write("Anchor accepted but receipt could not be stored: \(error)")
                                // Keep the durable seal at the head of the queue. A later
                                // idempotent retry is safer than forgetting an accepted anchor
                                // whose receipt was never made durable locally.
                                completion(false)
                            }
                        case .failure(let error):
                            if self.registrationStore.invalidateIfUnknownDevice(
                                error,
                                deviceID: seal.deviceID
                            ) {
                                Diagnostics.write(
                                    "Commitment server forgot device registration; re-registering on retry."
                                )
                            }
                            Diagnostics.write("Anchor upload failed: \(error)")
                            completion(false)
                        }
                    }
                }
            }
        }

        private func fetchChallenge(deviceID: String, completion: @escaping (ChallengeResponse?) -> Void) {
            let request = ChallengeRequest(deviceID: deviceID)
            post(path: "/v1/challenge", body: request, response: ChallengeResponse.self) {
                [weak self] result in
                switch result {
                case .success(let challenge): completion(challenge)
                case .failure(let error):
                    if self?.registrationStore.invalidateIfUnknownDevice(
                        error,
                        deviceID: deviceID
                    ) == true {
                        Diagnostics.write(
                            "Commitment challenge reports an unknown device; re-registering on retry."
                        )
                    }
                    Diagnostics.write("Challenge request failed: \(error)")
                    completion(nil)
                }
            }
        }

        private func registrationClientDataHash(
            challenge: ChallengeResponse,
            deviceID: String,
            publicKeyBase64: String
        ) -> Data {
            SHA256Digest.hash(
                Data(
                    "LH-APP-ATTEST-REGISTER-V1\0\(challenge.challengeBase64)\0\(deviceID)\0\(publicKeyBase64)"
                        .utf8
                ))
        }

        private func anchorClientDataHash(challenge: ChallengeResponse, seal: LocalMinuteSeal) -> Data {
            SHA256Digest.hash(
                Data(
                    "LH-APP-ATTEST-ANCHOR-V1\0\(challenge.challengeBase64)\0\(seal.anchorHash)\0\(seal.anchorSequence)"
                        .utf8
                ))
        }

        private func post<Body: Encodable, Response: Decodable>(
            path: String,
            body: Body,
            response: Response.Type,
            completion: @escaping (Result<Response, Error>) -> Void
        ) {
            guard let url = URL(string: path, relativeTo: baseURL) else {
                completion(.failure(UploadError.invalidURL))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                completion(.failure(error))
                return
            }

            let session = session
            Task {
                do {
                    let (bytes, responseObject) = try await session.bytes(for: request)
                    guard let http = responseObject as? HTTPURLResponse else {
                        bytes.task.cancel()
                        throw UploadError.badResponse
                    }
                    var body = BoundedHTTPResponseBody()
                    do {
                        try body.reserve(expectedBytes: http.expectedContentLength)
                        for try await byte in bytes {
                            try body.append(byte)
                        }
                    } catch {
                        bytes.task.cancel()
                        throw error
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw UploadError.httpResponse(
                            statusCode: http.statusCode,
                            body: body.data
                        )
                    }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    completion(.success(try decoder.decode(Response.self, from: body.data)))
                } catch {
                    completion(.failure(error))
                }
            }
        }

        private var appVersion: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.6.0-dev"
        }

        private func appendReceipt(_ receipt: AnchorReceipt) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(receipt)
            data.append(0x0A)
            let url = AppPaths.receiptFileURL(for: receipt.receivedAt)
            try SecureReceiptJournal.append(
                row: data,
                fileName: url.lastPathComponent,
                directory: AppPaths.receiptsDirectory
            )
        }
    }

    struct CommitmentReplayLimits: Equatable {
        let queueCapacity: Int
        let queueByteCapacity: Int
        let maximumBytesPerPass: Int
        let maximumLinesPerPass: Int
        let maximumDirectoryEntriesPerPass: Int
        let maximumFilesOpenedPerPass: Int
        let maximumLineBytes: Int
        let wholeFileByteLimit: Int64?
        let maximumPassDuration: TimeInterval
        let fileNameChunkCapacity: Int

        static let production = CommitmentReplayLimits(
            queueCapacity: 256,
            queueByteCapacity: 8 * 1_024 * 1_024,
            maximumBytesPerPass: 8 * 1_024 * 1_024,
            maximumLinesPerPass: 16_384,
            maximumDirectoryEntriesPerPass: 65_536,
            maximumFilesOpenedPerPass: 256,
            maximumLineBytes: MinuteSealer.maximumEncodedSealRowBytes,
            wholeFileByteLimit: nil,
            maximumPassDuration: 0.75,
            fileNameChunkCapacity: 256
        )

        init(
            queueCapacity: Int = 256,
            queueByteCapacity: Int = 8 * 1_024 * 1_024,
            maximumBytesPerPass: Int = 8 * 1_024 * 1_024,
            maximumLinesPerPass: Int = 16_384,
            maximumDirectoryEntriesPerPass: Int = 65_536,
            maximumFilesOpenedPerPass: Int = 256,
            maximumLineBytes: Int = 1 * 1_024 * 1_024,
            wholeFileByteLimit: Int64? = nil,
            maximumPassDuration: TimeInterval = 0.75,
            fileNameChunkCapacity: Int = 256
        ) {
            precondition(queueCapacity > 0 && queueCapacity <= 256)
            precondition(queueByteCapacity > 0)
            precondition(maximumBytesPerPass > 0)
            precondition(maximumLinesPerPass > 0)
            precondition(maximumDirectoryEntriesPerPass > 0)
            precondition(maximumFilesOpenedPerPass > 0)
            precondition(maximumLineBytes > 0)
            if let wholeFileByteLimit {
                precondition(wholeFileByteLimit >= maximumLineBytes)
            }
            precondition(maximumPassDuration > 0)
            precondition(fileNameChunkCapacity > 0 && fileNameChunkCapacity <= 1_024)
            self.queueCapacity = queueCapacity
            self.queueByteCapacity = queueByteCapacity
            self.maximumBytesPerPass = maximumBytesPerPass
            self.maximumLinesPerPass = maximumLinesPerPass
            self.maximumDirectoryEntriesPerPass = maximumDirectoryEntriesPerPass
            self.maximumFilesOpenedPerPass = maximumFilesOpenedPerPass
            self.maximumLineBytes = maximumLineBytes
            self.wholeFileByteLimit = wholeFileByteLimit
            self.maximumPassDuration = maximumPassDuration
            self.fileNameChunkCapacity = fileNameChunkCapacity
        }
    }

    enum CommitmentReplayStatus: Equatable {
        case idle
        case ready
        case exhausted
        case budgetExhausted(String)
        case blocked(String)
        case invalidated(String)
        case networkRetry

        var description: String {
            switch self {
            case .idle: return "idle"
            case .ready: return "ready"
            case .exhausted: return "source exhausted"
            case .budgetExhausted(let reason): return "budget exhausted: \(reason)"
            case .blocked(let reason): return "blocked: \(reason)"
            case .invalidated(let reason): return "source invalidated: \(reason)"
            case .networkRetry: return "network retry pending"
            }
        }
    }

    struct CommitmentUploaderSnapshot: Equatable {
        var status: CommitmentReplayStatus = .idle
        var pendingCount = 0
        var pendingBytes = 0
        var queueCapacity = CommitmentReplayLimits.production.queueCapacity
        var queueByteCapacity = CommitmentReplayLimits.production.queueByteCapacity
        var maximumObservedPendingCount = 0
        var maximumObservedPendingBytes = 0
        var inFlight = false
        var lastAttemptedSequence: UInt64?
        var lastUploadedSequence: UInt64?
        var scannedBytes: UInt64 = 0
        var scannedLines: UInt64 = 0
        var openedFiles: UInt64 = 0
    }

    struct CommitmentPendingSeal {
        let seal: LocalMinuteSeal
        let sourceBytes: Int
    }

    struct CommitmentReplayBatch {
        let seals: [CommitmentPendingSeal]
        let status: CommitmentReplayStatus
        let madeProgress: Bool
    }

    final class CommitmentReplayScanner {
        private let sealsDirectory: URL
        private let receiptsDirectory: URL
        private let limits: CommitmentReplayLimits
        private var sealStream: SecureJSONLSequenceStream<LocalMinuteSeal>
        private var receiptStream: SecureJSONLSequenceStream<ReceiptSequence>
        private var nextSeal: SecureJSONLRecord<LocalMinuteSeal>?
        private var nextReceipt: SecureJSONLRecord<ReceiptSequence>?
        private var receiptKnownExhausted = false
        private(set) var status: CommitmentReplayStatus = .idle
        private var priorScannedBytes: UInt64 = 0
        private var priorScannedLines: UInt64 = 0
        private var priorOpenedFiles: UInt64 = 0
        private var activeBudget: CommitmentReplayBudget?

        var scannedBytes: UInt64 {
            priorScannedBytes + sealStream.scannedBytes + receiptStream.scannedBytes
        }

        var scannedLines: UInt64 {
            priorScannedLines + sealStream.scannedLines + receiptStream.scannedLines
        }

        var openedFiles: UInt64 {
            priorOpenedFiles + sealStream.openedFiles + receiptStream.openedFiles
        }

        var isExhausted: Bool { status == .exhausted }

        var isBlocked: Bool {
            switch status {
            case .blocked, .invalidated: return true
            default: return false
            }
        }

        init(
            sealsDirectory: URL,
            receiptsDirectory: URL,
            limits: CommitmentReplayLimits = .production
        ) {
            self.sealsDirectory = sealsDirectory.standardizedFileURL
            self.receiptsDirectory = receiptsDirectory.standardizedFileURL
            self.limits = limits
            sealStream = Self.makeSealStream(
                directory: sealsDirectory,
                limits: limits
            )
            receiptStream = Self.makeReceiptStream(
                directory: receiptsDirectory,
                limits: limits
            )
        }

        func reset() {
            priorScannedBytes += sealStream.scannedBytes + receiptStream.scannedBytes
            priorScannedLines += sealStream.scannedLines + receiptStream.scannedLines
            priorOpenedFiles += sealStream.openedFiles + receiptStream.openedFiles
            sealStream = Self.makeSealStream(directory: sealsDirectory, limits: limits)
            receiptStream = Self.makeReceiptStream(directory: receiptsDirectory, limits: limits)
            nextSeal = nil
            nextReceipt = nil
            receiptKnownExhausted = false
            status = .idle
        }

        func nextBatch(
            maximumCount: Int,
            maximumBytes: Int
        ) -> CommitmentReplayBatch {
            guard maximumCount > 0, maximumBytes > 0 else {
                return CommitmentReplayBatch(seals: [], status: .ready, madeProgress: false)
            }
            guard !isBlocked else {
                return CommitmentReplayBatch(seals: [], status: status, madeProgress: false)
            }

            let startingBytes = scannedBytes
            let startingLines = scannedLines
            let budget = CommitmentReplayBudget(limits: limits)
            activeBudget = budget
            defer { activeBudget = nil }
            var output: [CommitmentPendingSeal] = []
            var outputBytes = 0

            while output.count < maximumCount {
                if nextSeal == nil {
                    switch sealStream.next(budget: budget) {
                    case .record(let record): nextSeal = record
                    case .end:
                        status = .exhausted
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    case .budget(let reason):
                        status = .budgetExhausted(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    case .blocked(let reason):
                        status = .blocked(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    case .invalidated(let reason):
                        status = .invalidated(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    }
                }

                if nextReceipt == nil, !receiptKnownExhausted {
                    switch receiptStream.next(budget: budget) {
                    case .record(let record): nextReceipt = record
                    case .end: receiptKnownExhausted = true
                    case .budget(let reason):
                        status = .budgetExhausted(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    case .blocked(let reason):
                        status = .blocked(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    case .invalidated(let reason):
                        status = .invalidated(reason)
                        return batch(
                            seals: output,
                            status: status,
                            startingBytes: startingBytes,
                            startingLines: startingLines
                        )
                    }
                }

                guard let sealRecord = nextSeal else { continue }
                if let receiptRecord = nextReceipt {
                    if receiptRecord.sequence < sealRecord.sequence {
                        nextReceipt = nil
                        continue
                    }
                    if receiptRecord.sequence == sealRecord.sequence {
                        nextReceipt = nil
                        nextSeal = nil
                        continue
                    }
                }

                guard outputBytes + sealRecord.sourceBytes <= maximumBytes else {
                    status = .ready
                    return batch(
                        seals: output,
                        status: status,
                        startingBytes: startingBytes,
                        startingLines: startingLines
                    )
                }
                output.append(
                    CommitmentPendingSeal(
                        seal: sealRecord.value,
                        sourceBytes: sealRecord.sourceBytes
                    )
                )
                outputBytes += sealRecord.sourceBytes
                nextSeal = nil
            }

            status = .ready
            return batch(
                seals: output,
                status: status,
                startingBytes: startingBytes,
                startingLines: startingLines
            )
        }

        private func batch(
            seals: [CommitmentPendingSeal],
            status: CommitmentReplayStatus,
            startingBytes: UInt64,
            startingLines: UInt64
        ) -> CommitmentReplayBatch {
            CommitmentReplayBatch(
                seals: seals,
                status: status,
                madeProgress: scannedBytes > startingBytes || scannedLines > startingLines
                    || (activeBudget?.consumedBytes ?? 0) > 0
                    || (activeBudget?.consumedDirectoryEntries ?? 0) > 0
                    || (activeBudget?.openedFiles ?? 0) > 0
            )
        }

        private static func makeSealStream(
            directory: URL,
            limits: CommitmentReplayLimits
        ) -> SecureJSONLSequenceStream<LocalMinuteSeal> {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return SecureJSONLSequenceStream(
                directoryURL: directory,
                requiredSuffix: ".seals.jsonl",
                kind: "seal",
                limits: limits,
                duplicatePolicy: .requireIdentical,
                decode: { try decoder.decode(LocalMinuteSeal.self, from: $0) },
                sequence: { $0.anchorSequence }
            )
        }

        private static func makeReceiptStream(
            directory: URL,
            limits: CommitmentReplayLimits
        ) -> SecureJSONLSequenceStream<ReceiptSequence> {
            let decoder = JSONDecoder()
            return SecureJSONLSequenceStream(
                directoryURL: directory,
                requiredSuffix: ".receipts.jsonl",
                kind: "receipt",
                limits: limits,
                duplicatePolicy: .allow,
                decode: { try decoder.decode(ReceiptSequence.self, from: $0) },
                sequence: { $0.anchorSequence }
            )
        }
    }

    private struct ReceiptSequence: Decodable {
        let anchorSequence: UInt64
    }

    private final class CommitmentReplayBudget {
        private let limits: CommitmentReplayLimits
        private let startedAt = ProcessInfo.processInfo.systemUptime
        private(set) var consumedBytes = 0
        private(set) var consumedLines = 0
        private(set) var consumedDirectoryEntries = 0
        private(set) var openedFiles = 0

        init(limits: CommitmentReplayLimits) {
            self.limits = limits
        }

        var remainingBytes: Int {
            max(0, limits.maximumBytesPerPass - consumedBytes)
        }

        func timeBudgetReason() -> String? {
            guard
                ProcessInfo.processInfo.systemUptime - startedAt
                    < limits.maximumPassDuration
            else { return "time" }
            return nil
        }

        func consume(bytes: Int) -> String? {
            guard timeBudgetReason() == nil else { return "time" }
            guard bytes >= 0, consumedBytes <= limits.maximumBytesPerPass - bytes else {
                return "source bytes"
            }
            consumedBytes += bytes
            return nil
        }

        func consumeLine() -> String? {
            guard timeBudgetReason() == nil else { return "time" }
            guard consumedLines < limits.maximumLinesPerPass else { return "lines" }
            consumedLines += 1
            return nil
        }

        func consumeDirectoryEntry() -> String? {
            guard timeBudgetReason() == nil else { return "time" }
            guard consumedDirectoryEntries < limits.maximumDirectoryEntriesPerPass else {
                return "directory entries"
            }
            consumedDirectoryEntries += 1
            return nil
        }

        func consumeFileOpen() -> String? {
            guard timeBudgetReason() == nil else { return "time" }
            guard openedFiles < limits.maximumFilesOpenedPerPass else { return "files" }
            openedFiles += 1
            return nil
        }
    }

    private struct SecureJSONLRecord<Value> {
        let value: Value
        let sequence: UInt64
        let sourceBytes: Int
    }

    private enum SecureJSONLReadResult<Value> {
        case record(SecureJSONLRecord<Value>)
        case end
        case budget(String)
        case blocked(String)
        case invalidated(String)
    }

    private enum SecureJSONLDuplicatePolicy {
        case allow
        case requireIdentical
    }

    private enum SecureLineReadResult {
        case line(Data, sourceBytes: Int)
        case end
        case partial
        case budget(String)
        case blocked(String)
        case invalidated(String)
    }

    private enum SecureReadInterruption {
        case budget(String)
        case blocked(String)
        case invalidated(String)
    }

    private enum SecureDiscoveryResult<Value> {
        case success(Value)
        case failure(SecureReadInterruption)
    }

    private enum SecureIdentityResult {
        case success(Int64)
        case failure(String)
    }

    private final class SecureDirectoryDiscoveryState {
        let afterName: String?
        let stream: UnsafeMutablePointer<DIR>
        var names: [String]

        init(afterName: String?, stream: UnsafeMutablePointer<DIR>) {
            self.afterName = afterName
            self.stream = stream
            names = []
        }

        deinit {
            _ = Darwin.closedir(stream)
        }
    }

    private struct SecureDirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
        }
    }

    private struct SecureFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
        }
    }

    private enum CommitmentReplayError: LocalizedError {
        case posix(operation: String, path: String, code: Int32)
        case unsafeSource(String)
        case oversizedSource(String, Int64)

        var errorDescription: String? {
            switch self {
            case .posix(let operation, let path, let code):
                let detail = String(cString: strerror(code))
                return "\(operation) failed for \(path): \(detail)"
            case .unsafeSource(let path):
                return "source is not a no-follow regular file or directory: \(path)"
            case .oversizedSource(let path, let maximumBytes):
                return "source exceeds the \(maximumBytes)-byte file budget: \(path)"
            }
        }
    }

    private final class SecureJSONLSequenceStream<Value> {
        private let directoryURL: URL
        private let requiredSuffix: String
        private let kind: String
        private let limits: CommitmentReplayLimits
        private let duplicatePolicy: SecureJSONLDuplicatePolicy
        private let decode: (Data) throws -> Value
        private let sequence: (Value) -> UInt64
        private var directoryDescriptor: Int32 = -1
        private var directoryIdentity: SecureDirectoryIdentity?
        private var current: SecureJSONLFileReader?
        private var completedThroughName: String?
        private var queuedNames: [String] = []
        private var discoveryState: SecureDirectoryDiscoveryState?
        private var lastSequence: UInt64?
        private var lastRowDigest: Data?
        private(set) var scannedBytes: UInt64 = 0
        private(set) var scannedLines: UInt64 = 0
        private(set) var openedFiles: UInt64 = 0

        init(
            directoryURL: URL,
            requiredSuffix: String,
            kind: String,
            limits: CommitmentReplayLimits,
            duplicatePolicy: SecureJSONLDuplicatePolicy,
            decode: @escaping (Data) throws -> Value,
            sequence: @escaping (Value) -> UInt64
        ) {
            self.directoryURL = directoryURL.standardizedFileURL
            self.requiredSuffix = requiredSuffix
            self.kind = kind
            self.limits = limits
            self.duplicatePolicy = duplicatePolicy
            self.decode = decode
            self.sequence = sequence
        }

        deinit {
            current = nil
            if directoryDescriptor >= 0 { _ = Darwin.close(directoryDescriptor) }
        }

        func next(budget: CommitmentReplayBudget) -> SecureJSONLReadResult<Value> {
            while true {
                do {
                    try ensureDirectory()
                } catch {
                    discoveryState = nil
                    return .blocked(error.localizedDescription)
                }

                if current == nil {
                    switch nextFileName(budget: budget) {
                    case .success(let name):
                        guard let name else { return .end }
                        if let reason = budget.consumeFileOpen() {
                            queuedNames.insert(name, at: 0)
                            return .budget(reason)
                        }
                        do {
                            current = try SecureJSONLFileReader(
                                directoryDescriptor: directoryDescriptor,
                                directoryURL: directoryURL,
                                name: name,
                                maximumLineBytes: limits.maximumLineBytes,
                                wholeFileByteLimit: limits.wholeFileByteLimit
                            )
                            openedFiles += 1
                        } catch {
                            return .blocked(error.localizedDescription)
                        }
                    case .failure(let status):
                        return readResult(for: status)
                    }
                }

                guard let current else { continue }
                switch current.nextLine(budget: budget) {
                case .line(let row, let sourceBytes):
                    scannedBytes += UInt64(sourceBytes)
                    scannedLines += 1
                    guard !row.isEmpty else { continue }
                    let value: Value
                    do {
                        value = try decode(row)
                    } catch {
                        return .blocked("malformed \(kind) row in \(current.name)")
                    }
                    let anchorSequence = sequence(value)
                    let digest = SHA256Digest.hash(row)
                    if let lastSequence {
                        if anchorSequence < lastSequence {
                            return .blocked(
                                "\(kind) sequence \(anchorSequence) follows \(lastSequence)"
                            )
                        }
                        if anchorSequence == lastSequence {
                            if duplicatePolicy == .requireIdentical,
                                digest != lastRowDigest
                            {
                                return .blocked(
                                    "conflicting duplicate \(kind) sequence \(anchorSequence)"
                                )
                            }
                            continue
                        }
                    }
                    self.lastSequence = anchorSequence
                    lastRowDigest = digest
                    return .record(
                        SecureJSONLRecord(
                            value: value,
                            sequence: anchorSequence,
                            sourceBytes: sourceBytes
                        )
                    )
                case .end:
                    let finishedName = current.name
                    if !queuedNames.isEmpty {
                        completedThroughName = finishedName
                        self.current = nil
                        continue
                    }
                    switch discoverNames(after: finishedName, budget: budget) {
                    case .success(let names) where !names.isEmpty:
                        completedThroughName = finishedName
                        self.current = nil
                        queuedNames = names
                        continue
                    case .success:
                        return .end
                    case .failure(let status):
                        return readResult(for: status)
                    }
                case .partial:
                    return .budget("incomplete \(kind) row awaiting append in \(current.name)")
                case .budget(let reason):
                    return .budget(reason)
                case .blocked(let reason):
                    return .blocked(reason)
                case .invalidated(let reason):
                    return .invalidated(reason)
                }
            }
        }

        private func ensureDirectory() throws {
            if directoryDescriptor < 0 {
                let descriptor = directoryURL.path.withCString {
                    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw CommitmentReplayError.posix(
                        operation: "open \(kind) directory",
                        path: directoryURL.path,
                        code: errno
                    )
                }
                var information = stat()
                guard Darwin.fstat(descriptor, &information) == 0,
                    information.st_mode & S_IFMT == S_IFDIR
                else {
                    _ = Darwin.close(descriptor)
                    throw CommitmentReplayError.unsafeSource(directoryURL.path)
                }
                directoryDescriptor = descriptor
                directoryIdentity = SecureDirectoryIdentity(information)
            }

            var pathInformation = stat()
            guard directoryURL.path.withCString({ Darwin.lstat($0, &pathInformation) }) == 0,
                pathInformation.st_mode & S_IFMT == S_IFDIR,
                SecureDirectoryIdentity(pathInformation) == directoryIdentity
            else {
                throw CommitmentReplayError.unsafeSource(directoryURL.path)
            }
        }

        private func readResult(
            for interruption: SecureReadInterruption
        ) -> SecureJSONLReadResult<Value> {
            switch interruption {
            case .budget(let reason): return .budget(reason)
            case .blocked(let reason): return .blocked(reason)
            case .invalidated(let reason): return .invalidated(reason)
            }
        }

        private func nextFileName(
            budget: CommitmentReplayBudget
        ) -> SecureDiscoveryResult<String?> {
            if !queuedNames.isEmpty { return .success(queuedNames.removeFirst()) }
            switch discoverNames(after: completedThroughName, budget: budget) {
            case .success(let names):
                queuedNames = names
                return .success(queuedNames.isEmpty ? nil : queuedNames.removeFirst())
            case .failure(let status):
                return .failure(status)
            }
        }

        private func discoverNames(
            after name: String?,
            budget: CommitmentReplayBudget
        ) -> SecureDiscoveryResult<[String]> {
            let state: SecureDirectoryDiscoveryState
            if let existing = discoveryState, existing.afterName == name {
                state = existing
            } else {
                discoveryState = nil
                let enumerationDescriptor = ".".withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard enumerationDescriptor >= 0 else {
                    return .failure(.blocked("could not enumerate \(kind) directory"))
                }
                guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
                    _ = Darwin.close(enumerationDescriptor)
                    return .failure(.blocked("could not enumerate \(kind) directory"))
                }
                state = SecureDirectoryDiscoveryState(afterName: name, stream: stream)
                discoveryState = state
            }

            while true {
                if let reason = budget.consumeDirectoryEntry() {
                    return .failure(.budget(reason))
                }
                errno = 0
                guard let entry = Darwin.readdir(state.stream) else {
                    if errno != 0 {
                        discoveryState = nil
                        return .failure(.blocked("could not enumerate \(kind) directory"))
                    }
                    discoveryState = nil
                    break
                }
                let candidate = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) { String(cString: $0) }
                }
                guard candidate != ".", candidate != "..",
                    !candidate.hasPrefix("."),
                    !candidate.contains("/"),
                    candidate.hasSuffix(requiredSuffix),
                    name == nil || candidate > name!
                else { continue }

                var information = stat()
                let result = candidate.withCString {
                    Darwin.fstatat(
                        directoryDescriptor,
                        $0,
                        &information,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard result == 0, information.st_mode & S_IFMT == S_IFREG else {
                    discoveryState = nil
                    return .failure(
                        .blocked("unsafe \(kind) source entry: \(candidate)")
                    )
                }
                state.names.append(candidate)
                state.names.sort()
                if state.names.count > limits.fileNameChunkCapacity { state.names.removeLast() }
            }
            return .success(state.names)
        }
    }

    private final class SecureJSONLFileReader {
        let name: String
        private let directoryDescriptor: Int32
        private let directoryURL: URL
        private let descriptor: Int32
        private let identity: SecureFileIdentity
        private let maximumLineBytes: Int
        private let wholeFileByteLimit: Int64?
        private var buffer = Data()
        private var readOffset: Int64 = 0
        private var lastObservedSize: Int64
        private var lastObservedModificationSeconds: Int64
        private var lastObservedModificationNanoseconds: Int64
        private var lastObservedChangeSeconds: Int64
        private var lastObservedChangeNanoseconds: Int64

        init(
            directoryDescriptor: Int32,
            directoryURL: URL,
            name: String,
            maximumLineBytes: Int,
            wholeFileByteLimit: Int64?
        ) throws {
            self.directoryDescriptor = directoryDescriptor
            self.directoryURL = directoryURL
            self.name = name
            self.maximumLineBytes = maximumLineBytes
            self.wholeFileByteLimit = wholeFileByteLimit
            let opened = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard opened >= 0 else {
                throw CommitmentReplayError.posix(
                    operation: "open source",
                    path: directoryURL.appendingPathComponent(name).path,
                    code: errno
                )
            }
            var information = stat()
            guard Darwin.fstat(opened, &information) == 0,
                information.st_mode & S_IFMT == S_IFREG
            else {
                _ = Darwin.close(opened)
                throw CommitmentReplayError.unsafeSource(
                    directoryURL.appendingPathComponent(name).path
                )
            }
            if let wholeFileByteLimit, information.st_size > wholeFileByteLimit {
                _ = Darwin.close(opened)
                throw CommitmentReplayError.oversizedSource(
                    directoryURL.appendingPathComponent(name).path,
                    wholeFileByteLimit
                )
            }
            descriptor = opened
            identity = SecureFileIdentity(information)
            lastObservedSize = Int64(information.st_size)
            lastObservedModificationSeconds = Int64(information.st_mtimespec.tv_sec)
            lastObservedModificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
            lastObservedChangeSeconds = Int64(information.st_ctimespec.tv_sec)
            lastObservedChangeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
        }

        deinit { _ = Darwin.close(descriptor) }

        func nextLine(budget: CommitmentReplayBudget) -> SecureLineReadResult {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    if let reason = budget.consumeLine() { return .budget(reason) }
                    let row = Data(buffer[..<newline])
                    let consumed = buffer.distance(from: buffer.startIndex, to: newline) + 1
                    buffer.removeFirst(consumed)
                    guard row.count <= maximumLineBytes else {
                        return .blocked("source row exceeds \(maximumLineBytes) bytes in \(name)")
                    }
                    return .line(row, sourceBytes: consumed)
                }
                guard buffer.count <= maximumLineBytes else {
                    return .blocked("source row exceeds \(maximumLineBytes) bytes in \(name)")
                }
                if let reason = budget.timeBudgetReason() { return .budget(reason) }
                guard budget.remainingBytes > 0 else { return .budget("source bytes") }

                switch verifyIdentity() {
                case .success(let size):
                    if readOffset >= size {
                        return buffer.isEmpty ? .end : .partial
                    }
                    let count = min(
                        64 * 1_024,
                        budget.remainingBytes,
                        Int(size - readOffset)
                    )
                    var chunk = Data(count: count)
                    var readCount = 0
                    let result: Int = chunk.withUnsafeMutableBytes { rawBuffer in
                        guard let base = rawBuffer.baseAddress else { return 0 }
                        return Darwin.pread(descriptor, base, count, off_t(readOffset))
                    }
                    if result > 0 {
                        readCount = result
                        if readCount < chunk.count { chunk.removeSubrange(readCount..<chunk.count) }
                        readOffset += Int64(readCount)
                        buffer.append(chunk)
                        if let reason = budget.consume(bytes: readCount) { return .budget(reason) }
                    } else if result == 0 {
                        return buffer.isEmpty ? .end : .partial
                    } else if errno == EINTR {
                        continue
                    } else {
                        return .blocked("could not read source file \(name)")
                    }
                case .failure(let reason):
                    return .invalidated(reason)
                }
            }
        }

        private func verifyIdentity() -> SecureIdentityResult {
            var descriptorInformation = stat()
            guard Darwin.fstat(descriptor, &descriptorInformation) == 0,
                descriptorInformation.st_mode & S_IFMT == S_IFREG,
                SecureFileIdentity(descriptorInformation) == identity,
                descriptorInformation.st_size >= readOffset
            else { return .failure("opened source changed: \(name)") }
            if let wholeFileByteLimit,
                descriptorInformation.st_size > wholeFileByteLimit
            {
                return .failure("source exceeded file budget: \(name)")
            }
            let currentSize = Int64(descriptorInformation.st_size)
            let modificationChanged =
                Int64(descriptorInformation.st_mtimespec.tv_sec)
                != lastObservedModificationSeconds
                || Int64(descriptorInformation.st_mtimespec.tv_nsec)
                    != lastObservedModificationNanoseconds
            let changeChanged =
                Int64(descriptorInformation.st_ctimespec.tv_sec) != lastObservedChangeSeconds
                || Int64(descriptorInformation.st_ctimespec.tv_nsec)
                    != lastObservedChangeNanoseconds
            if modificationChanged || changeChanged, currentSize <= lastObservedSize {
                return .failure("source changed without append growth: \(name)")
            }

            var pathInformation = stat()
            let lookup = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &pathInformation,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard lookup == 0,
                pathInformation.st_mode & S_IFMT == S_IFREG,
                SecureFileIdentity(pathInformation) == identity
            else { return .failure("source was removed or replaced: \(name)") }
            if currentSize > lastObservedSize {
                lastObservedSize = currentSize
                lastObservedModificationSeconds = Int64(
                    descriptorInformation.st_mtimespec.tv_sec
                )
                lastObservedModificationNanoseconds = Int64(
                    descriptorInformation.st_mtimespec.tv_nsec
                )
                lastObservedChangeSeconds = Int64(descriptorInformation.st_ctimespec.tv_sec)
                lastObservedChangeNanoseconds = Int64(descriptorInformation.st_ctimespec.tv_nsec)
            }
            return .success(currentSize)
        }
    }

    private struct SimpleOK: Codable { let ok: Bool }

    enum UploadError: LocalizedError {
        case invalidURL
        case badResponse
        case httpResponse(statusCode: Int, body: Data)
        case responseTooLarge(Int)

        var isUnknownDeviceResponse: Bool {
            guard case .httpResponse(let statusCode, _) = self else { return false }
            return statusCode == 404
        }

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The commitment endpoint URL is invalid."
            case .badResponse:
                return "The commitment endpoint returned a non-success response."
            case .httpResponse(let statusCode, _):
                return "The commitment endpoint returned HTTP \(statusCode)."
            case .responseTooLarge(let maximumBytes):
                return "The commitment endpoint response exceeded the bounded \(maximumBytes)-byte limit."
            }
        }
    }
#endif
