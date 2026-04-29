import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case noData
    case http(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noData: return "No response data"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let err): return "Decoding error: \(err.localizedDescription)"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    /// Read base URL from Info.plist key "ApiBaseURL". Set per-build in project.yml.
    var baseURL: URL = {
        let str = Bundle.main.object(forInfoDictionaryKey: "ApiBaseURL") as? String
            ?? "http://localhost:8000"
        return URL(string: str)!
    }()

    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Backend may return ISO 8601 with or without timezone, with or without fractional seconds.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            for fmt in [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ss",
            ] {
                let f = DateFormatter()
                f.dateFormat = fmt
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = fmt.contains("ZZZZZ") ? nil : TimeZone(identifier: "UTC")
                if let date = f.date(from: str) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(str)")
        }
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Resolve a path-with-query like "/v1/app/history?limit=100" to a URL
    /// without percent-encoding the '?'. (URL.appendingPathComponent treats
    /// the entire string as a path segment and turns '?' into %3F, which the
    /// server then 404s.)
    private func resolve(_ path: String) -> URL {
        if let direct = URL(string: path, relativeTo: baseURL)?.absoluteURL {
            return direct
        }
        return baseURL.appendingPathComponent(path)
    }

    func post<T: Decodable, U: Encodable>(
        _ path: String,
        body: U,
        sessionToken: String? = nil
    ) async throws -> T {
        var req = URLRequest(url: resolve(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    func get<T: Decodable>(_ path: String, sessionToken: String? = nil) async throws -> T {
        var req = URLRequest(url: resolve(path))
        if let token = sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    func delete(_ path: String, sessionToken: String? = nil) async throws {
        var req = URLRequest(url: resolve(path))
        req.httpMethod = "DELETE"
        if let token = sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.noData
        }
        if http.statusCode == 401 && req.value(forHTTPHeaderField: "Authorization") != nil {
            await MainActor.run { NotificationCenter.default.post(name: .headsupSessionInvalid, object: nil) }
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

extension Notification.Name {
    static let headsupSessionInvalid = Notification.Name("headsupSessionInvalid")
    /// Posted when push history likely changed (incoming push, or user tapped
    /// an action). Views showing history should reload.
    static let headsupHistoryChanged = Notification.Name("headsupHistoryChanged")
}
