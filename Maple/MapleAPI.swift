import Foundation

/// Shared cookie-authenticated transport for Maple's REST API.
struct MapleAPI {
    static let baseURL = URL(string: "https://api.maple.music")!
    static let shared = MapleAPI()

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = Self.baseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpCookieStorage = .shared
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    func request(_ path: [String], method: String = "GET", json: [String: Any]? = nil,
                 body: Data? = nil, contentType: String? = nil, allowMissing: Bool = false) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let encodedPath = try path.map { component in
            guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else { throw URLError(.badURL) }
            return encoded
        }.joined(separator: "/")
        components?.percentEncodedPath += "/" + encodedPath
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if allowMissing && response.statusCode == 404 { return Data() }
        guard (200..<300).contains(response.statusCode) else {
            throw MapleAPIError(statusCode: response.statusCode, data: data)
        }
        return data
    }

    func upload(_ path: [String], field: String, image: Data, artworkRequestId: String? = nil) async throws -> Data {
        let boundary = UUID().uuidString
        // Callers may provide PNG or JPEG data; preserve the actual media type.
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let filename = isPNG ? "image.png" : "image.jpg"
        let mimeType = isPNG ? "image/png" : "image/jpeg"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        body.append(image)
        body.append(Data("\r\n".utf8))
        if let artworkRequestId {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"artworkRequestId\"\r\n\r\n\(artworkRequestId)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await request(path, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
