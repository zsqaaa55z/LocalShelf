import Foundation

#if DEBUG && targetEnvironment(simulator)
/// Synthetic transport failures only; never contacts a real device.
private final class RecoveryReadFixture: URLProtocol {
    enum Action { case network(URLError.Code), status(Int), held(URLError.Code) }
    static let lock = NSLock()
    private static var route = "", action = Action.network(.timedOut)
    private static var pending: RecoveryReadFixture?
    static func configure(route: String, action: Action) {
        lock.lock(); defer { lock.unlock() }; precondition(pending == nil)
        self.route = route; self.action = action
    }
    static var waiting: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    static func release() {
        lock.lock(); let request = pending; pending = nil; let action = action; lock.unlock()
        if case .held(let code) = action { request?.fail(code) }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host?.hasPrefix("192.168.9.") == true && request.url?.path == route
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let action = Self.action
        if case .held = action { Self.pending = self }; Self.lock.unlock()
        switch action {
        case .network(let code): fail(code)
        case .status(let status):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .held: break
        }
    }
    private func fail(_ code: URLError.Code) { client?.urlProtocol(self, didFailWithError: URLError(code)) }
    override func stopLoading() {
        Self.lock.lock(); if Self.pending === self { Self.pending = nil }; Self.lock.unlock()
    }
}

enum ConnectionRecoveryChecks {
    private enum Read: CaseIterable {
        case cover, body, pageList
        func path(_ target: ServerTarget) -> String {
            switch self {
            case .cover: return "/v1/books/1/cover"
            case .body: return "/v1/books/1/pages/1"
            case .pageList: return "/v1/books/1/" + (target == .nas ? "manifest" : "pages")
            }
        }
        @MainActor func perform(_ client: Library) async throws {
            switch self {
            case .cover: _ = try await client.coverResponse(path(client.serverTarget), etag: nil)
            case .body: _ = try await client.data(path(client.serverTarget))
            case .pageList: _ = try await client.pageList("1", force: true)
            }
        }
    }
    @MainActor static func run() async {
        let defaults = UserDefaults.standard
        let selected = defaults.object(forKey: "server.selected"), hidden = defaults.object(forKey: "shelf.hideCovers")
        defer { defaults.set(selected, forKey: "server.selected"); defaults.set(hidden, forKey: "shelf.hideCovers") }
        defaults.set(false, forKey: "shelf.hideCovers")
        var count = 0
        func make(_ target: ServerTarget, _ read: Read, paired: Bool = true) async -> Library {
            defaults.set(target.rawValue, forKey: "server.selected")
            NASFixture.ready = true; NASFixture.bodyMode = target == .nas && read == .pageList
            NASFixture.conditionalMode = NASFixture.bodyMode
            var saved: PairingCode?
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryReadFixture.self, NASFixture.self]
            let client = Library(transport: LimitedHTTP(configuration: config), loadPair: { saved }, savePair: { saved = $0 }, removePair: { saved = nil })
            client.setForeground(false)
            client.address = target == .nas ? "http://192.168.9.2:8089" : "http://192.168.9.1:8088"
            if paired {
                await client.connect(pin: "001234")
                precondition(client.base != nil && client.paired != nil, "synthetic pairing setup failed")
            } else { client.base = try! LibraryRules.address(client.address) }
            return client
        }
        func failure(_ client: Library, _ read: Read) async -> Error {
            do { try await read.perform(client); preconditionFailure("failure fixture unexpectedly succeeded") }
            catch { return error }
        }
        func waitForHeldRequest() async {
            for _ in 0..<500 {
                if RecoveryReadFixture.waiting { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("request never reached the transport")
        }
        for target in ServerTarget.allCases {
            for read in Read.allCases {
                for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost] {
                    RecoveryReadFixture.configure(route: read.path(target), action: .network(code))
                    let client = await make(target, read), error = await failure(client, read)
                    precondition((error as? URLError)?.code == code)
                    precondition(client.base == nil && client.pairingStatus == "连接中断，正在等待" + target.title + "恢复…")
                    precondition(client.paired != nil); count += 1
                }
                for code: URLError.Code in [.cancelled, .badURL, .cannotDecodeContentData] {
                    RecoveryReadFixture.configure(route: read.path(target), action: .network(code))
                    let client = await make(target, read), before = client.pairingStatus, address = client.base
                    let error = await failure(client, read)
                    precondition((error as? URLError)?.code == code && client.base == address && client.pairingStatus == before); count += 1
                }
                for status in [401, 403, 404, 500] {
                    RecoveryReadFixture.configure(route: read.path(target), action: .status(status))
                    let client = await make(target, read), before = client.pairingStatus, address = client.base
                    let error = await failure(client, read)
                    guard case ServerFailure.status(let actual) = error else { preconditionFailure("HTTP status was replaced") }
                    precondition(actual == status && client.base == address && client.pairingStatus == before); count += 1
                }
                RecoveryReadFixture.configure(route: read.path(target), action: .held(.networkConnectionLost))
                let stale = await make(target, read), task = Task { await failure(stale, read) }
                await waitForHeldRequest(); stale.setForeground(false)
                stale.base = URL(string: "http://192.168.9.8:8089")!
                let replacement = stale.base, before = stale.pairingStatus
                RecoveryReadFixture.release(); _ = await task.value
                precondition(stale.base == replacement && stale.pairingStatus == before); count += 1

                RecoveryReadFixture.configure(route: read.path(target), action: .held(.timedOut))
                let cancelled = await make(target, read), prior = cancelled.base, priorStatus = cancelled.pairingStatus
                let cancellable = Task { await failure(cancelled, read) }
                await waitForHeldRequest(); cancellable.cancel(); let error = await cancellable.value
                precondition(error is CancellationError || (error as? URLError)?.code == .cancelled)
                precondition(cancelled.base == prior && cancelled.pairingStatus == priorStatus)
                RecoveryReadFixture.release(); count += 1

                // Without pairing/capability negotiation, page lists use the legacy route.
                let path = read == .pageList ? "/v1/books/1/pages" : read.path(target)
                RecoveryReadFixture.configure(route: path, action: .network(.timedOut))
                let unpaired = await make(target, read, paired: false), original = unpaired.base, status = unpaired.pairingStatus
                _ = await failure(unpaired, read)
                precondition(unpaired.base == original && unpaired.pairingStatus == status && unpaired.paired == nil); count += 1
                print("PASS \(target.rawValue) \(read): transient, HTTP, decoding, cancellation, stale-session and unpaired isolation")
            }
        }
        print("\(count) connection recovery checks passed")
    }
}
#endif
