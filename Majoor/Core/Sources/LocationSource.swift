// LocationSource.swift
// Majoor — The phone's location as events (Phase 2 step 4c)
//
// An iPhone Shortcut POSTs `{event, latitude, longitude, accuracy, place}`
// (the shape `Scripts/location-poc.py` fixed) to a tiny HTTP/1.1 responder on
// the Tailscale address, port 47822, with a per-device token in
// `X-Majoor-Token`. Only `POST /location` exists; the token's SHA-256 must
// match a `location_devices` row; bodies over 4 KB are refused. Fixes are kept
// seven days in `location_fixes` and emitted as `locationFix` events. Location
// is the most sensitive class there is: nothing here ever leaves the Mac.

import Foundation
import Network
import GRDB
import CryptoKit

// MARK: - Records and stores

nonisolated struct LocationDeviceRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "location_devices"
    var deviceId: String
    var name: String
    var tokenHash: String
    var createdAt: Date

    var id: String { deviceId }
}

nonisolated struct LocationFixRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "location_fixes"
    var id: Int64?
    var at: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double?
    var place: String?
    var event: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Devices allowed to post fixes. The token is shown once and only its hash
/// is kept, like paired control clients.
nonisolated final class LocationDeviceStore: @unchecked Sendable {

    static let shared = LocationDeviceStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A new device and its token. The token is returned exactly once.
    func mint(name: String) throws -> (device: LocationDeviceRecord, token: String) {
        let token = Self.mintToken()
        let device = LocationDeviceRecord(deviceId: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "iPhone" : name,
                                          tokenHash: Self.hash(token), createdAt: Date())
        try db.write { db in try device.insert(db) }
        return (device, token)
    }

    /// The device a presented token belongs to, or nil.
    func device(forToken token: String) -> LocationDeviceRecord? {
        guard !token.isEmpty else { return nil }
        let hash = Self.hash(token)
        return (try? db.read { db in try LocationDeviceRecord.filter(Column("tokenHash") == hash).fetchOne(db) }) ?? nil
    }

    func all() -> [LocationDeviceRecord] {
        (try? db.read { db in try LocationDeviceRecord.order(Column("createdAt")).fetchAll(db) }) ?? []
    }

    func revoke(deviceId: String) {
        _ = try? db.write { db in try LocationDeviceRecord.deleteOne(db, key: deviceId) }
    }
}

nonisolated final class LocationFixStore: @unchecked Sendable {

    static let shared = LocationFixStore(db: DatabaseManager.shared.dbQueue)
    static let retention: TimeInterval = 7 * 24 * 3600

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    @discardableResult
    func insert(_ fix: LocationFixRecord) throws -> LocationFixRecord {
        try db.write { db in
            var row = fix
            try row.insert(db)
            return row
        }
    }

    func latest() -> LocationFixRecord? {
        (try? db.read { db in try LocationFixRecord.order(Column("at").desc).fetchOne(db) }) ?? nil
    }

    func recent(limit: Int = 20) -> [LocationFixRecord] {
        (try? db.read { db in try LocationFixRecord.order(Column("at").desc).limit(limit).fetchAll(db) }) ?? []
    }

    @discardableResult
    func deleteOlder(than cutoff: Date) -> Int {
        (try? db.write { db in try LocationFixRecord.filter(Column("at") < cutoff).deleteAll(db) }) ?? 0
    }
}

// MARK: - The report body

nonisolated struct LocationReport: Sendable, Equatable {
    var event: String
    var latitude: Double
    var longitude: Double
    var accuracy: Double?
    var place: String?

    static let allowedEvents: Set<String> = ["arrive", "leave", "manual", "periodic", "requested"]

    /// Parses and validates the POST body. Nil for anything that is not a
    /// well-formed fix on Earth.
    static func parse(_ data: Data) -> LocationReport? {
        guard let json = try? JSONValue(data: data), let object = json.objectValue else { return nil }
        func number(_ key: String) -> Double? {
            if let value = object[key]?.doubleValue { return value }
            if let text = object[key]?.stringValue { return Double(text.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        guard let latitude = number("latitude"), let longitude = number("longitude"),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let rawEvent = (object["event"]?.stringValue ?? "manual").lowercased().trimmingCharacters(in: .whitespaces)
        let event = allowedEvents.contains(rawEvent) ? rawEvent : "manual"
        var accuracy = number("accuracy")
        if let value = accuracy, !(value >= 0 && value.isFinite) { accuracy = nil }
        let place = object["place"]?.stringValue.map { String(UntrustedContent.stripControlCharacters($0).prefix(200)) }
        return LocationReport(event: event, latitude: latitude, longitude: longitude, accuracy: accuracy, place: place?.isEmpty == true ? nil : place)
    }
}

// MARK: - HTTP parsing

/// Just enough HTTP/1.1 to read one small request.
nonisolated enum HTTPRequestReader {

    nonisolated struct Request: Sendable, Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    nonisolated enum Outcome: Sendable, Equatable {
        case needMore
        case complete(Request)
        case tooLarge
        case malformed
    }

    static let headerLimit = 8_192

    /// The `Content-Length` once the head is complete, nil before or when absent or invalid.
    static func declaredLength(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Body bytes received so far, nil before the head is complete.
    static func bodyByteCount(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return buffer.count - headerEnd.upperBound + buffer.startIndex
    }

    static func read(_ buffer: Data, maxBody: Int) -> Outcome {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > headerLimit ? .tooLarge : .needMore
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .malformed }
        if length > maxBody { return .tooLarge }
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return .needMore }
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(requestLine[1])
        return .complete(Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: Data(body.prefix(length))))
    }
}

// MARK: - Endpoint

/// The listener. Accepted reports come out of `reports`; `LocationSource`
/// stores and emits them. Like `ControlServer`, it binds only to the
/// Tailscale address and waits while there is none; tests bind to 127.0.0.1.
actor LocationEndpoint {

    static let defaultPort: UInt16 = 47822
    static let maxBodyBytes = 4_096
    /// An over-long body up to this size is read before the 413 goes out, so
    /// the phone sees the status instead of a reset mid-upload.
    static let drainLimit = 65_536
    static let tokenHeader = "x-majoor-token"
    static let path = "/location"

    nonisolated enum State: Sendable, Equatable {
        case stopped
        case waitingForTailscale
        case listening(address: String, port: UInt16)
        case failed(String)

        var text: String {
            switch self {
            case .stopped: return "Off"
            case .waitingForTailscale: return "Waiting for Tailscale"
            case .listening(let address, let port): return "Listening on \(address):\(port)"
            case .failed(let detail): return "Failed: \(detail)"
            }
        }
    }

    nonisolated struct AcceptedReport: Sendable, Equatable {
        var deviceId: String
        var report: LocationReport
    }

    typealias Resolver = @Sendable (String) -> String?

    nonisolated let reports: AsyncStream<AcceptedReport>
    private let reportContinuation: AsyncStream<AcceptedReport>.Continuation

    private let queue = DispatchQueue(label: "ai.majoor.location")
    private let resolveDevice: Resolver
    private var port: UInt16
    private var listener: NWListener?
    private var listenerAddress: String?
    private var watcher: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stateSubscribers: [UUID: AsyncStream<State>.Continuation] = [:]
    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            for continuation in stateSubscribers.values { continuation.yield(state) }
        }
    }

    /// `resolveDevice` maps a presented token to a device id, or nil.
    init(port: UInt16 = LocationEndpoint.defaultPort, resolveDevice: @escaping Resolver) {
        self.port = port
        self.resolveDevice = resolveDevice
        (reports, reportContinuation) = AsyncStream.makeStream(of: AcceptedReport.self, bufferingPolicy: .unbounded)
    }

    func stateStream() -> AsyncStream<State> {
        let id = UUID()
        let current = state
        return AsyncStream { continuation in
            continuation.yield(current)
            stateSubscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStateSubscriber(id) }
            }
        }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    // MARK: Lifecycle

    /// Follows the Tailscale address like the control API does.
    func start() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            for await address in TailscaleInterface.changes() {
                await self?.addressChanged(address)
            }
        }
    }

    /// Binds to an explicit address right away. Tests use 127.0.0.1 and port 0.
    func start(address: String, port: UInt16) {
        watcher?.cancel()
        watcher = Task {}
        self.port = port
        tearDownListener()
        listenerAddress = address
        startListener(on: address)
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        tearDownListener()
        state = .stopped
    }

    private func addressChanged(_ address: String?) {
        if address == listenerAddress, listener != nil { return }
        tearDownListener()
        listenerAddress = address
        guard let address else {
            state = .waitingForTailscale
            return
        }
        startListener(on: address)
    }

    private func startListener(on address: String) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { await self?.listenerStateChanged(listenerState, address: address) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed("Could not create listener: \(error)")
            MajoorLogger.error("Location endpoint listener failed: \(error)")
        }
    }

    private func listenerStateChanged(_ listenerState: NWListener.State, address: String) {
        switch listenerState {
        case .ready:
            if let actual = listener?.port?.rawValue { port = actual }
            state = .listening(address: address, port: port)
            MajoorLogger.log("📍 Location endpoint listening on \(address):\(port)")
        case .failed(let error):
            state = .failed("\(error)")
            MajoorLogger.error("Location endpoint listener failed: \(error)")
            tearDownListener()
        case .waiting(let error):
            state = .failed("Waiting: \(error)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func tearDownListener() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    // MARK: One request

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestReader.read(buffer, maxBody: Self.maxBodyBytes) {
            case .complete(let request):
                Task { await self.handle(request, on: connection) }
            case .tooLarge:
                if let declared = HTTPRequestReader.declaredLength(buffer), declared <= Self.drainLimit,
                   let received = HTTPRequestReader.bodyByteCount(buffer), received < declared, !isComplete, error == nil {
                    self.receive(connection, buffer: buffer)   // drain, then refuse
                } else {
                    Task { await self.respond(413, "{\"error\":\"payload too large\"}", on: connection, accepted: false) }
                }
            case .malformed:
                Task { await self.respond(400, "{\"error\":\"malformed request\"}", on: connection, accepted: false) }
            case .needMore:
                if isComplete || error != nil {
                    Task { await self.closeConnection(connection) }
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequestReader.Request, on connection: NWConnection) {
        guard request.method == "POST", request.path == Self.path else {
            respond(404, "{\"error\":\"not found\"}", on: connection, accepted: false)
            return
        }
        guard let token = request.headers[Self.tokenHeader], let deviceId = resolveDevice(token) else {
            respond(401, "{\"error\":\"unknown device token\"}", on: connection, accepted: false)
            return
        }
        guard let report = LocationReport.parse(request.body) else {
            respond(400, "{\"error\":\"body must be {event, latitude, longitude, accuracy, place}\"}", on: connection, accepted: false)
            return
        }
        reportContinuation.yield(AcceptedReport(deviceId: deviceId, report: report))
        respond(200, "{\"ok\":true}", on: connection, accepted: true)
    }

    private func respond(_ status: Int, _ body: String, on connection: NWConnection, accepted: Bool) {
        if accepted { acceptedCount += 1 } else { rejectedCount += 1 }
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(Data(body.utf8))
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { await self?.closeConnection(connection) }
        })
    }

    private func closeConnection(_ connection: NWConnection) {
        connection.cancel()
        connections[ObjectIdentifier(connection)] = nil
    }
}

// MARK: - Source

actor LocationSource: EventSource {

    static let sourceId = "location"
    static let cleanupInterval: Duration = .seconds(24 * 3600)

    nonisolated let id = LocationSource.sourceId
    nonisolated let dataClass: DataClass = .location
    nonisolated let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    let endpoint: LocationEndpoint
    private let fixes: LocationFixStore
    private let bind: Bind
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var cleanupTask: Task<Void, Never>?
    private(set) var lastFix: LocationFixRecord?

    nonisolated enum Bind: Sendable, Equatable {
        case tailscale
        case address(String, port: UInt16)
    }

    init(endpoint: LocationEndpoint, fixes: LocationFixStore, bind: Bind = .tailscale,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.fixes = fixes
        self.bind = bind
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async throws {
        lastFix = fixes.latest()
        fixes.deleteOlder(than: now().addingTimeInterval(-LocationFixStore.retention))
        switch bind {
        case .tailscale: await endpoint.start()
        case .address(let address, let port): await endpoint.start(address: address, port: port)
        }
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.cleanupInterval) } catch { return }
                await self?.cleanup()
            }
        }
        defer {
            cleanupTask?.cancel()
            cleanupTask = nil
        }
        for await accepted in endpoint.reports {
            try Task.checkCancellation()
            store(accepted)
        }
    }

    func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        await endpoint.stop()
    }

    /// Phase 2 cannot ask the phone for a fix yet (decision D10 is open); the
    /// location job degrades to "no fix, no message" and the brief says so.
    func requestFix() async -> LocationFixRecord? {
        MajoorLogger.log("📍 requestFix: on-demand location is not available until D10 is decided; using the last fix only")
        return nil
    }

    func latestFix() -> LocationFixRecord? { lastFix ?? fixes.latest() }

    private func cleanup() {
        let removed = fixes.deleteOlder(than: now().addingTimeInterval(-LocationFixStore.retention))
        if removed > 0 { MajoorLogger.log("📍 Deleted \(removed) location fixes older than 7 days") }
    }

    private func store(_ accepted: LocationEndpoint.AcceptedReport) {
        let report = accepted.report
        let fix = LocationFixRecord(id: nil, at: now(), latitude: report.latitude, longitude: report.longitude,
                                    accuracy: report.accuracy, place: report.place, event: report.event)
        do {
            let saved = try fixes.insert(fix)
            lastFix = saved
            continuation.yield(SourceEvent(sourceId: id, kind: .locationFix, at: saved.at, payload: Self.payload(saved, deviceId: accepted.deviceId)))
        } catch {
            MajoorLogger.error("Could not store a location fix: \(error)")
        }
    }

    /// Coordinates stay numbers; `place` is the only free text and it was
    /// cleaned at parse time. Nothing here is ever sent to tier P or F.
    static func payload(_ fix: LocationFixRecord, deviceId: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "deviceId": .string(deviceId),
            "event": .string(fix.event),
            "latitude": .number(fix.latitude),
            "longitude": .number(fix.longitude),
            "at": .string(ISO8601DateFormatter().string(from: fix.at)),
        ]
        if let accuracy = fix.accuracy { object["accuracy"] = .number(accuracy) }
        if let place = fix.place { object["place"] = .string(place) }
        return .object(object)
    }
}
