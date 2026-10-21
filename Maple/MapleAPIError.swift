import Foundation

struct MapleAPIError: LocalizedError {
    let statusCode: Int
    let message: String

    init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = json?["error"] as? String, !error.isEmpty {
            message = error
        } else if statusCode == 401 || statusCode == 403 {
            message = "Your Maple session has expired. Please log in again."
        } else if statusCode == 429 {
            message = "Too many requests. Please try again shortly."
        } else {
            message = "Maple returned an error (\(statusCode)). Please try again."
        }
    }

    var errorDescription: String? { message }
}
