import Foundation

struct APIError: LocalizedError, Sendable {
    var message: String
    var status: Int = 0
    var errorDescription: String? { message }
}

/// REST + SSE client for one binaryd server.
final class APIClient: Sendable {
    let baseURL: URL
    let token: String
    private let session: URLSession
    private let streamSession: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        let scfg = URLSessionConfiguration.ephemeral
        // The server pings every 15s; anything quieter than this is a dead link.
        scfg.timeoutIntervalForRequest = 45
        scfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
        streamSession = URLSession(configuration: scfg)
    }

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(path, query))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Lets the server word activity and errors in the UI language.
        req.setValue(L10n.lang == .zh ? "zh-CN,zh;q=0.9,en;q=0.5" : "en", forHTTPHeaderField: "Accept-Language")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw APIError(message: msg, status: status)
        }
        return try WireDate.decoder.decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await perform(request("GET", path, query: query))
    }

    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        let enc = JSONEncoder()
        return try await perform(request(method, path, body: try enc.encode(body)))
    }

    /// DELETE; any 2xx counts, whatever the body.
    func delete(_ path: String) async throws {
        let (_, resp) = try await session.data(for: request("DELETE", path))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(message: HTTPURLResponse.localizedString(forStatusCode: status), status: status) }
    }

    /// Raw bytes, e.g. an image. Throws APIError with the status on failure.
    /// Raw bytes and their media type.
    func file(_ path: String, query: [String: String]) async throws -> (Data, String) {
        let (data, resp) = try await session.data(for: request("GET", path, query: query))
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw APIError(message: msg, status: status)
        }
        let mime = (http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream").components(separatedBy: ";")[0]
        return (data, mime)
    }

    func data(_ path: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request("GET", path))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(message: HTTPURLResponse.localizedString(forStatusCode: status), status: status) }
        return data
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await perform(request("POST", path, body: Data("{}".utf8)))
    }

    /// Server-sent events: yields the JSON payload of each `data:` line.
    func events(_ path: String, query: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        var req = request("GET", path, query: query)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = streamSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw APIError(message: status == 401 ? tr("Invalid token") : "HTTP \(status)", status: status)
                    }
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            continuation.yield(Data(line.dropFirst(6).utf8))
                        }
                    }
                    continuation.finish(throwing: APIError(message: tr("Connection closed")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct OK: Decodable { var ok: Bool? }

private struct ErrorBody: Decodable { var error: String }
