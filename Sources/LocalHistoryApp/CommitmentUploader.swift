#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class CommitmentUploader {
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.commitment-uploader")
        private let baseURL: URL
        private let identity: DeviceIdentity
        private let appAttest: AppAttestManager
        private let session: URLSession
        private var pending: [LocalMinuteSeal] = []
        private var inFlight = false
        private var registered = false

        init?(config: RecorderConfig, identity: DeviceIdentity) {
            guard config.verificationEnabled == true,
                let raw = config.verificationServerURL,
                let url = URL(string: raw)
            else { return nil }

            self.baseURL = url
            self.identity = identity
            self.appAttest = AppAttestManager(enabled: config.enableAppAttest != false)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
            self.registered = UserDefaults.standard.bool(
                forKey: "LocalHistory.DeviceRegistered.\(identity.info.deviceID)")
        }

        func enqueue(_ seal: LocalMinuteSeal) {
            queue.async { [weak self] in
                guard let self else { return }
                if self.hasReceipt(for: seal.anchorSequence) { return }
                if !self.pending.contains(where: { $0.anchorSequence == seal.anchorSequence }) {
                    self.pending.append(seal)
                    self.pending.sort { $0.anchorSequence < $1.anchorSequence }
                }
                self.drain()
            }
        }

        func replayPending() {
            queue.async { [weak self] in
                guard let self else { return }
                let receipts = self.receiptSequences()
                for seal in self.loadAllSeals().filter({ !receipts.contains($0.anchorSequence) }) {
                    if !self.pending.contains(where: { $0.anchorSequence == seal.anchorSequence }) {
                        self.pending.append(seal)
                    }
                }
                self.pending.sort { $0.anchorSequence < $1.anchorSequence }
                self.drain()
            }
        }

        private func drain() {
            guard !inFlight, let seal = pending.first else { return }
            inFlight = true
            ensureRegistered { [weak self] ok in
                guard let self else { return }
                if !ok {
                    self.finishAttempt(success: false)
                    return
                }
                self.upload(seal) { success in
                    self.finishAttempt(success: success)
                }
            }
        }

        private func finishAttempt(success: Bool) {
            queue.async { [weak self] in
                guard let self else { return }
                if success, !self.pending.isEmpty {
                    self.pending.removeFirst()
                }
                self.inFlight = false
                if success {
                    self.drain()
                } else {
                    self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.drain() }
                }
            }
        }

        private func ensureRegistered(completion: @escaping (Bool) -> Void) {
            if registered {
                completion(true)
                return
            }

            fetchChallenge { [weak self] challenge in
                guard let self, let challenge else {
                    completion(false)
                    return
                }
                let hash = self.registrationClientDataHash(challenge: challenge)
                self.appAttest.materialForRegistration(clientDataHash: hash) { material in
                    let request = DeviceRegistrationRequest(
                        challengeID: challenge.challengeID,
                        deviceID: self.identity.info.deviceID,
                        publicKeyBase64: self.identity.info.publicKeyBase64,
                        signatureAlgorithm: self.identity.info.algorithm,
                        localTrustTier: self.identity.info.trustTier,
                        appVersion: self.appVersion,
                        appAttestKeyID: material.keyID,
                        appAttestationObjectBase64: material.attestationObjectBase64
                    )
                    self.post(path: "/v1/devices/register", body: request, response: SimpleOK.self) { result in
                        switch result {
                        case .success(let response) where response.ok:
                            self.queue.async {
                                self.registered = true
                                UserDefaults.standard.set(
                                    true, forKey: "LocalHistory.DeviceRegistered.\(self.identity.info.deviceID)")
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
            fetchChallenge { [weak self] challenge in
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
                                completion(true)
                            }
                        case .failure(let error):
                            Diagnostics.write("Anchor upload failed: \(error)")
                            completion(false)
                        }
                    }
                }
            }
        }

        private func fetchChallenge(completion: @escaping (ChallengeResponse?) -> Void) {
            let request = ChallengeRequest(deviceID: identity.info.deviceID)
            post(path: "/v1/challenge", body: request, response: ChallengeResponse.self) { result in
                switch result {
                case .success(let challenge): completion(challenge)
                case .failure(let error):
                    Diagnostics.write("Challenge request failed: \(error)")
                    completion(nil)
                }
            }
        }

        private func registrationClientDataHash(challenge: ChallengeResponse) -> Data {
            SHA256Digest.hash(
                Data(
                    "LH-APP-ATTEST-REGISTER-V1\0\(challenge.challengeBase64)\0\(identity.info.deviceID)\0\(identity.info.publicKeyBase64)"
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

            session.dataTask(with: request) { data, responseObject, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = responseObject as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let data
                else {
                    completion(.failure(UploadError.badResponse))
                    return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    completion(.success(try decoder.decode(Response.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }

        private var appVersion: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.4.0-dev"
        }

        private func appendReceipt(_ receipt: AnchorReceipt) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(receipt)
            data.append(0x0A)
            let url = AppPaths.receiptFileURL(for: receipt.receivedAt)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        }

        private func hasReceipt(for sequence: UInt64) -> Bool {
            receiptSequences().contains(sequence)
        }

        private func receiptSequences() -> Set<UInt64> {
            var result = Set<UInt64>()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: AppPaths.receiptsDirectory, includingPropertiesForKeys: nil)
            else { return result }
            for file in files where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let data = String(line).data(using: .utf8),
                        let receipt = try? decoder.decode(AnchorReceipt.self, from: data)
                    else { continue }
                    result.insert(receipt.anchorSequence)
                }
            }
            return result
        }

        private func loadAllSeals() -> [LocalMinuteSeal] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: AppPaths.sealsDirectory, includingPropertiesForKeys: nil)
            else { return [] }
            var result: [LocalMinuteSeal] = []
            for file in files where file.lastPathComponent.hasSuffix(".seals.jsonl") {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let data = String(line).data(using: .utf8),
                        let seal = try? decoder.decode(LocalMinuteSeal.self, from: data)
                    else { continue }
                    result.append(seal)
                }
            }
            return result.sorted { $0.anchorSequence < $1.anchorSequence }
        }
    }

    private struct SimpleOK: Codable { let ok: Bool }

    private enum UploadError: Error {
        case invalidURL
        case badResponse
    }
#endif
