//
//  Account.swift
//  Maple
//
//  Created by Potter on 4/16/25.
//

import SwiftUI
import Foundation
import SwiftyJSON
import Alamofire
import SwiftVibrantium
// MARK: - Data Structures

// Structure to store cookie data
struct CookieData: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
}

struct LoginResponse: Codable {
    let success: Bool
    let serverUsername: String
    let serverID: String
    let response: Int
}

struct userResponse: Codable {
    let name: String
    let id: String
    let username: String
    let pfp: Data?
    let response: Int
}

struct Friend: Identifiable {
    let id: String
    let name: String
    let username: String
    let pfp: Data?
    let nowPlaying: NowPlaying
}

struct NowPlaying: Identifiable {
    let id: String
    let song: String
    let album: String
    let artist: String
    let discord: Bool
}
// MARK: - API Functions

func login(username: String, password: String) async throws -> LoginResponse {
    guard let url = URL(string: "https://maple.kolf.pro:3000/login") else {
        throw URLError(.badURL)
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Create the JSON parameters
    let parameters: [String: Any] = [
        "username": username,
        "password": password
    ]
    
    // Convert parameters to JSON data
    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
    // Create a URLSession with cookie handling
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)
    
    let (data, response) = try await session.data(for: request)
    
    // Print response headers for debugging
    if let httpResponse = response as? HTTPURLResponse {
        // print("Response Headers:")
        // for (key, value) in httpResponse.allHeaderFields {
        //     print("\(key): \(value)")
        // }
        
        // Print and save cookies after the request
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            // print("\nCookies after request:")
            // for cookie in cookies {
            //     print("Cookie: \(cookie.name) = \(cookie.value)")
            //     print("Domain: \(cookie.domain)")
            //     print("Path: \(cookie.path)")
            //     print("Expires: \(String(describing: cookie.expiresDate))")
            //     print("---")
            // }
            
            // Save cookies to UserDefaults
            let cookieData = cookies.map { cookie in
                CookieData(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expiresDate: cookie.expiresDate
                )
            }
            
            if let encoded = try? JSONEncoder().encode(cookieData) {
                UserDefaults.standard.set(encoded, forKey: "savedCookies")
                print("Cookies saved successfully")
            }
        }
    }
    
    // Check HTTP response
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    
    // Print response for debugging
    print("HTTP Status Code: \(httpResponse.statusCode)")
    
    // Handle different status codes
    switch httpResponse.statusCode {
    case 200...299:
        // Success - parse the response
        do {
            let json = try JSON(data: data)
            print("Response JSON: \(json)")
            
            // Try to decode the response
            let serverUsername = json["user"]["username"]
            let serverID = json["user"]["id"]
            let status = json["status"]
            print("Server Username: \(serverUsername)")
            print("Server ID: \(serverID)")
            print("Status: \(status)")
            if status.stringValue.lowercased() == "success" {
                return LoginResponse(success: true, serverUsername: serverUsername.stringValue, serverID: serverID.stringValue, response: httpResponse.statusCode)
            }
            else{
                return LoginResponse(success: false, serverUsername: "", serverID: "", response: httpResponse.statusCode)
            }
        } catch {
            print("Decoding error: \(error)")
            throw error
        }
    case 401:
        throw NSError(domain: "LoginError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid username or password"])
    case 400:
        throw NSError(domain: "LoginError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad request"])
    default:
        throw NSError(domain: "LoginError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: \(httpResponse.statusCode)"])
    }
}

func register(username: String, password: String) async throws -> String {
    guard let url = URL(string: "https://maple.kolf.pro:3000/login/create") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let parameters: [String: Any] = [
        "username": username,
        "password": password
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    print("Register Response: \(httpResponse.statusCode)")
    print("Register Response Data: \(String(data: data, encoding: .utf8))")
    print("Register Response Headers: \(httpResponse.allHeaderFields)")

    switch httpResponse.statusCode {
    case 200:
        return "Success! Please login using your new account: \(username)"
    default:
        throw NSError(domain: "RegisterError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: \(httpResponse.statusCode)"])
    }
}

func getUser(serverID: String) async throws -> userResponse {
    print("Getting user data for ID: \(serverID)")
    guard let url = URL(string: "https://maple.kolf.pro:3000/get/user/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Use the same session configuration as login
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)
    print("Request: \(request)")
    print("Request Headers: \(request.allHTTPHeaderFields)")
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    
    print("User data response status: \(httpResponse.statusCode)")
    
    switch httpResponse.statusCode {
    case 200:
        let json = try JSON(data: data)
        // print("User data JSON: \(json)")
        let name = json["name"]
        let id = json["id"]
        let username = json["username"]
        let pfpString = json["pfp"].stringValue
        guard let pfpData = Data(base64Encoded: pfpString) else {
            return userResponse(name: name.stringValue, id: id.stringValue, username: username.stringValue, pfp: nil, response: httpResponse.statusCode)
        }

        return userResponse(name: name.stringValue, id: id.stringValue, username: username.stringValue, pfp: pfpData, response: httpResponse.statusCode)
    case 401:
        throw NSError(domain: "Error", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized"])
    default:
        throw NSError(domain: "Error", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: \(httpResponse.statusCode)"])
    }
}

// func setAlbumArt(serverID: String, albumArt: String) async throws -> String {
//     let url = "https://maple.kolf.pro:3000/user/manage/setAlbumArt/\(serverID)/"
    
//     // Print current cookies for debugging
//     print("\nCurrent cookies before request:")
//     if let cookies = HTTPCookieStorage.shared.cookies {
//         for cookie in cookies {
//             print("Cookie: \(cookie.name) = \(cookie.value)")
//             print("Domain: \(cookie.domain)")
//             print("Path: \(cookie.path)")
//             print("---")
//         }
//     } else {
//         print("No cookies found in storage")
//     }
    
//     // Create a session configuration with cookie handling
//     let configuration = URLSessionConfiguration.default
//     configuration.httpShouldSetCookies = true
//     configuration.httpCookieAcceptPolicy = .always
//     configuration.httpCookieStorage = .shared
    
//     // Create a custom session with the configuration
//     let session = Session(configuration: configuration)
    
//     return try await withCheckedThrowingContinuation { continuation in
//         // Create headers
//         var headers: HTTPHeaders = [:]
        
//         // Add cookies to headers
//         if let cookies = HTTPCookieStorage.shared.cookies {
//             let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
//             print("Cookie String: \(cookieString)")
//             headers.add(name: "Cookie", value: cookieString)
//         }
        
//         session.upload(multipartFormData: { multipartFormData in
//             // Add the album art data to the form
//             if let imageData = Data(base64Encoded: albumArt) {
//                 print("Album Art Data Size: \(imageData.count) bytes")
//                 multipartFormData.append(imageData, withName: "albumArt", fileName: "albumArt.jpg", mimeType: "image/jpeg")
//             } else {
//                 print("Failed to decode album art from base64")
//             }
//             multipartFormData.append(Data(serverID.utf8), withName: "id")
//             print()
//             // Log the server ID
//             let serverIDData = Data(serverID.utf8)
//             print(Data(serverID.utf8))
//             multipartFormData.append(serverIDData, withName: "id")
//         }, to: url, method: .post, headers: headers)
//         .response { response in
//             // Print request headers
//             if let request = response.request {
//                 print("\nRequest Headers:")
//                 for (key, value) in request.allHTTPHeaderFields ?? [:] {
//                     print("\(key): \(value)")
//                 }
//                 print("--------")
//             }
            
//             // Print response headers for debugging
//             if let httpResponse = response.response {
//                 print("\nResponse Headers:")
//                 for (key, value) in httpResponse.allHeaderFields {
//                     print("\(key): \(value)")
//                 }
//             }
            
//             switch response.result {
//             case .success(let data):
//                 if let data = data,
//                    let responseString = String(data: data, encoding: .utf8) {
//                     continuation.resume(returning: responseString)
//                     print("Album art set successfully: \(responseString)")
//                 } else {
//                     continuation.resume(throwing: NSError(domain: "Error", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response"]))
//                 }
//             case .failure(let error):
//                 print("Error setting album art: \(error)")
//                 continuation.resume(throwing: error)
//             }
//         }
//     }
// }

func setAlbumArt(serverID: String, albumArt: Data) async throws -> String {
    guard let url = URL(string: "https://maple.kolf.pro:3000/user/manage/setAlbumArt/\(serverID)") else {
        throw URLError(.badURL)
    }
    // print("URL: \(url)")
    var request = URLRequest(url: url)
    // print("url: \(request)")
    request.httpMethod = "POST"
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let boundaryStart = "--\(boundary)\r\n"
    let boundaryEnd = "--\(boundary)--\r\n"
    // print("Album Art: \(albumArt)")
    // print(albumArt)

    // print("Boundary Start: \(boundaryStart)")
    // print("BSData: \(boundaryStart.data(using: .utf8)!)")
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"albumArt\"; filename=\"albumArt.jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(albumArt)
    body.append("\r\n".data(using: .utf8)!)
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"id\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(serverID)\r\n".data(using: .utf8)!)
    body.append(boundaryEnd.data(using: .utf8)!)


    // print("Body: \(body.count)")
        // Print the body as a string
    if let bodyString = String(data: body, encoding: .utf8) {
        print("Request Body: \n--------\n\(bodyString)\n--------")
    } else {
        print("Failed to convert body to string.")
    }
    request.httpBody = body

    // print("Request Headers: \(request.allHTTPHeaderFields)")
    // print("Request Body: \(request.httpBody)")

    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    // if let cookies = HTTPCookieStorage.shared.cookies {
    //     let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    //     print("Cookie String: \(cookieString)")
    //     request.addValue(cookieString, forHTTPHeaderField: "Cookie")
    // }
    request.addValue("\(body.count)", forHTTPHeaderField: "Content-Length")
    // print("Request Headers: \(request.allHTTPHeaderFields)")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    // print("BLAH TEXT")
    // print("Album Art Response: Code \(httpResponse.statusCode)")
    // print("Album Art Response Data: \(String(data: data, encoding: .utf8))")
    // print("Album Art Response Headers: \(httpResponse.allHeaderFields)")
    return "\(httpResponse.statusCode)"
    
    

    
}

func sendWebhook(song: Song, serverID: String) async throws -> String {
    let webhookURL = "https://discord.com/api/webhooks/1359887799628726453/qKNbOjF4KQ-ccv8JKpINPnDeUwUtGOKON83ZMsnbOoEkSQr8Na9ChcSrBr-wKIISa3A4"
    
    var uiImage: UIImage? = UIImage(named: "Maple")
    var artwork: Data? = uiImage?.pngData()
    let artworkPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(song.artwork ?? "images/maple.image")
    var songArtData  = UIImage(contentsOfFile: artworkPath.path)?.pngData()
    if let songArtwork = songArtData {
        artwork = songArtwork
    }
    
    guard let artworkData = artwork else {
        throw NSError(domain: "ArtworkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get artwork data"])
    }
    
    let albumData: [String: Any] = [
        "name": "Album",
        "value": song.album
    ]
    let yearData: [String: Any] = [
        "name": "Year",
        "value": "N/A"
    ]
    let trackNumberData: [String: Any] = [
        "name": "Track Number",
        "value": song.trackNumber ?? "N/A"
    ]
    let fields = [albumData, yearData, trackNumberData]
    let artURL: [String : Any] = ["url": "attachment://albumArt.jpg"]
    let embeds: [String: Any] = [
        "title": "Now Playing",
        "description": "**\(song.title)** by \(song.artist)",
        "color": "000000",
        "fields": fields,
        "image": artURL
    ]
    let payloadJSON: [String : Any] = [
        "embeds": [embeds],
        "username": "Maple-iOS",
        "avatar_url": "https://maple.kolf.pro:3000/public/get/pfp/\(serverID)"
    ]

    let songData = try JSONSerialization.data(withJSONObject: payloadJSON, options: [])
    
    guard let url = URL(string: webhookURL) else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    
    var body = Data()
    let boundaryStart = "--\(boundary)\r\n"
    let boundaryEnd = "--\(boundary)--\r\n"

    // Append the image data
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"albumArt.jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(artworkData)
    body.append("\r\n".data(using: .utf8)!)

    // Append the payload JSON
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n".data(using: .utf8)!)
    body.append(songData)
    body.append("\r\n".data(using: .utf8)!)
    body.append(boundaryEnd.data(using: .utf8)!)

    request.httpBody = body
    request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    
    print("Webhook Status Code: \(httpResponse.statusCode)")
    print("Webhook Response Data: \(String(data: data, encoding: .utf8) ?? "No response data")")
    
    return "Webhook Moment"
}

func getFriendList(serverID: String) async throws -> ([[String : JSON]], [Data?]) {
    guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/get/friends/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    // print("Friend List Response: \(httpResponse.statusCode)")
    // print("Friend List Response Data: \(String(data: data, encoding: .utf8))")
    // print("Friend List Response Headers: \(httpResponse.allHeaderFields)")

    let json = try JSON(data: data)
    let friends = json.arrayValue.compactMap { friend in
        friend["friend_id"].stringValue == serverID ? friend["user_id"].stringValue : friend["friend_id"].stringValue
    }
    // print("Friends: \n\(friends)\n\n")

    var userInfoArray: [[String : JSON]] = []
    var pfps: [Data?] = []
    for friend in friends {
        let publicUser = try await publicUserId(serverID: friend)
        userInfoArray.append(publicUser)
        let pfp = try await getPublicPfp(serverID: friend)
        if pfp != nil {
            pfps.append(pfp)
        }
        else {
            pfps.append(nil)
        }
        print("PFP: \(pfps)")
    }
    // print("User Info Array: \(userInfoArray)")

    return (userInfoArray, pfps)
}

func publicUserId(serverID: String) async throws -> [String : JSON] {
    guard let url = URL(string: "https://maple.kolf.pro:3000/public/get/user/id/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    let json = try JSON(data: data)
    let user = json.dictionaryValue

    // print("Public User: \(user)")

    return user
    
    
}

func publicUser(username: String) async throws -> [String: JSON] {
    guard let url = URL(string: "https://maple.kolf.pro:3000/public/get/user/\(username)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    let json = try JSON(data: data)
    let user = json.dictionaryValue

    // print("Public User: \(user)")

    return user
}

func getPublicPfp(serverID: String) async throws -> Data? {
    guard let url = URL(string: "https://maple.kolf.pro:3000/public/get/pfp/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    // if 
    return data
    
}

func addFriend(username: String) async throws -> String {
    print("addFriend")
    let user = try await publicUser(username: username)
    print(user)

    if let error = user["error"]?.stringValue {
        print(error)
        return error
    }
    else {
        // print("blah")
        let id: String = user["id"]?.stringValue ?? ""

        guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/add/\(id)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        print(parameters)
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            print(message)
            return message
        }
        else if let error = dict["error"]?.stringValue {
            print(error)
            return error
        }
        
        return "Else Statement Concluded with Invalid Route?"
    }
    return "Function Concluded with Invalid Route?"
}

func acceptFriend(id: String) async throws -> String {

        guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/accept/\(id)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        print(parameters)
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            print(message)
            return message
        }
        else if let error = dict["error"]?.stringValue {
            print(error)
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func rejectFriend(id: String) async throws -> String {

        guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/decline/\(id)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        print(parameters)
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            print(message)
            return message
        }
        else if let error = dict["error"]?.stringValue {
            print(error)
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func removeFriend(id: String) async throws -> String {

        guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/remove/\(id)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        print(parameters)
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            print(message)
            return message
        }
        else if let error = dict["error"]?.stringValue {
            print(error)
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func getReqList(serverID: String) async throws -> ([[String : JSON]], [Data?]) {
    guard let url = URL(string: "https://maple.kolf.pro:3000/user/friends/get/requests/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    // print("Friend List Response: \(httpResponse.statusCode)")
    // print("Friend List Response Data: \(String(data: data, encoding: .utf8))")
    // print("Friend List Response Headers: \(httpResponse.allHeaderFields)")

    let json = try JSON(data: data)
    let friends = json.arrayValue.compactMap { friend in
        friend["friend_id"].stringValue == serverID ? friend["user_id"].stringValue : friend["friend_id"].stringValue
    }
    // print("Friends: \n\(friends)\n\n")

    var userInfoArray: [[String : JSON]] = []
    var pfps: [Data?] = []
    for friend in friends {
        let publicUser = try await publicUserId(serverID: friend)
        userInfoArray.append(publicUser)
        let pfp = try await getPublicPfp(serverID: friend)
        if pfp != nil {
            pfps.append(pfp)
        }
        else {
            pfps.append(nil)
        }
        print("PFP: \(pfps)")
    }
    // print("User Info Array: \(userInfoArray)")

    return (userInfoArray, pfps)
}

// MARK: - Views

struct Login: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isLoggedIn = false
    @State private var serverUsername: String = ""
    @State private var serverID: String = ""
    @State private var userStatus: Int? = nil
    
    // Load saved cookies and serverID on init
    init() {
        if let savedCookies = loadCookies() {
            restoreCookies(savedCookies)
        }
        
        // Load saved serverID
      if let savedServerID = UserDefaults.standard.string(forKey: "savedServerID") {
            _serverID = State(initialValue: savedServerID)
        }  
    }
    
    var body: some View {
        if isLoggedIn {
            LoggedIn(isLoggedIn: $isLoggedIn)
        } else {
            VStack {
                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .disableAutocorrection(true)
                    .onSubmit {
                        Task {
                            await handleLogin()
                        }
                    }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                }
                
                Button(action: {
                    Task {
                        await handleLogin()
                    }
                }) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Login")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .disabled(isLoading)

                Button(action: {
                    Task {
                        do {
                            let response = try await register(username: username, password: password)
                            print("Register Response: \(response)")
                        } catch {
                            print("Error registering: \(error)")
                        }
                    }
                }) {
                    Text("Register")
                }
            }
            .padding()
            .onAppear {
                Task {
                    await fetchUserData()
                }
            }
        }
    }
    
    private func handleLogin() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await login(username: username, password: password)
            serverUsername = response.serverUsername
            serverID = response.serverID
            
            // Save serverID to UserDefaults
            UserDefaults.standard.set(serverID, forKey: "savedServerID")
            
            print("Login successful: \(response)")
            isLoggedIn = response.success
            
            // Save cookies after successful login
            if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://maple.kolf.pro:3000")!) {
                saveCookies(cookies)
            }
            await AppSocketManager.shared.connect()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
            print("Login error: \(error)")
        }
        
        isLoading = false
    }
    
    // Save cookies to UserDefaults
    private func fetchUserData() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }
        
        do {
            let response = try await getUser(serverID: savedServerID)
            userStatus = response.response
            if userStatus == 200 {
                isLoggedIn = true
            }
        } catch {
            print("Error fetching user data: \(error)")
        }
    }
}


struct LoggedIn: View {
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var name: String = ""
    @State private var id: String = ""
    @State private var username: String = ""
    @State private var pfp: Data? = nil
    @Binding var isLoggedIn: Bool
    // @State private var userInfoArray: [[String : JSON]] = []
    // @State private var userInfoArrayReq: [[String : JSON]] = []
    // @State private var pfpArray: [Data?] = []
    // @State private var pfpArrayReq: [Data?] = []
    // @State private var friends: [Friend] = []
    // @State private var requests: [Friend] = []
    // @State private var fUsername: String = ""

    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else if let error = error {
                Text(error)
                    .foregroundColor(.red)
            } else {
                if let pfp = pfp, let uiImage = UIImage(data: pfp) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                }
                Text("\(username)")
                    .font(.title)
                Text("\(name)")
                    .font(.title2)
                Text("\(id)")
                    .font(.subheadline)
                // Button(action: {
                //     Task {
                //         do {
                //             if let pfp = pfp {
                //                 try await setAlbumArt(serverID: id, albumArt: pfp)
                //             }
                //         } catch {
                //             print("Error setting album art: \(error)")
                //         }
                //     }
                // }) {
                //     Text("Album Art Test")
                // }
                Spacer()

                
                // List {
                //     Section{
                //         HStack {
                //             Text("Add Friend:")
                //             TextField("username", text: $fUsername)
                //             .onSubmit {
                //             Task {
                //                 // let response: String = try await addFriend(username: fUsername)
                //                 await addF(username: fUsername)
                //                 // print ("AddFriend Response: \(response)")
                //                 await friendMoment()
                //             }
                //     }
                //         }
                //     } header: {
                //         Text("Manage")
                //     }
                    
                //     Section{
                //         ForEach(requests) { friend in
                //             HStack {
                //                 // if let pfpData = friend["pfp"]?.stringValue.data(using: .utf8),
                //                 if let pfp = friend.pfp, let uiImage = UIImage(data: pfp) {
                //                     Image(uiImage: uiImage)
                //                         .resizable()
                //                         .scaledToFit()
                //                         .frame(width: 40, height: 40)
                //                         .clipShape(Circle())
                //                 }
                //                 VStack(alignment: .leading) {
                                    
                //                 Text(friend.name)
                //                     .font(.headline)
                //                 Text("@" + friend.username)
                //                     .font(.subheadline)
                //                     .foregroundColor(.secondary)
                //                 Text(friend.nowPlaying.song + " - " + friend.nowPlaying.artist)
                //                     .font(.subheadline)
                //                     .foregroundColor(.secondary)
                //                 }
                //                 Spacer()
                //                 Button(action: {
                //                     Task {
                //                         // let response: String = try await addFriend(id: friend.id)
                //                         await acceptF(id: friend.id)
                //                         await friendMoment()
                //                     }
                //                 }) {
                //                     Image(systemName: "checkmark.circle.fill")
                //                         .resizable()
                //                         .scaledToFit()
                //                         .frame(width: 25, height: 25)
                //                     }
                //                     .buttonStyle(.borderless)
                //                 // Divider()
                //                 Button(action: {
                //                     Task {
                //                         // let response = try await rejectFriend(id: friend.id)
                //                         await rejectF(id: friend.id)
                //                         await friendMoment()
                //                     }
                //                 }) {
                //                     Image(systemName: "x.circle.fill")
                //                         .resizable()
                //                         .scaledToFit()
                //                         .frame(width: 25, height: 25)
                //                     }
                //                     .buttonStyle(.borderless)
                //             }
                //             .padding(.vertical, 4)
                //         }
                //     } header: {
                //         Text("Requests")
                //     }
                //     // Spacer()
                //     // Divider()
                //     Section{
                //         ForEach(friends) { friend in
                //             HStack {
                //                 // if let pfpData = friend["pfp"]?.stringValue.data(using: .utf8),
                //                 if let pfp = friend.pfp, let uiImage = UIImage(data: pfp) {
                //                     Image(uiImage: uiImage)
                //                         .resizable()
                //                         .scaledToFit()
                //                         .frame(width: 40, height: 40)
                //                         .clipShape(Circle())
                //                 }
                //                 VStack(alignment: .leading) {
                                    
                //                 Text(friend.name)
                //                     .font(.headline)
                //                 Text("@" + friend.username)
                //                     .font(.subheadline)
                //                     .foregroundColor(.secondary)
                //                 Text(friend.nowPlaying.song + " - " + friend.nowPlaying.artist)
                //                     .font(.subheadline)
                //                     .foregroundColor(.secondary)
                //                 }
                                    
                //             }
                //             .onDelete(perform: {
                //                 Task {
                //                     await removeF(id: friend.id)
                //                 }
                //             })
                //             .padding(.vertical, 4)
                //         }
                //     } header: {
                //         Text("Friends")
                //     }
                // }
                // .refreshable {
                //     // friends.removeAll()
                //     // requests.removeAll()
                //     // Task {
                //     //     await friendList()
                //     //     await reqList()
                //     //     // await fetchUserData()
                //     // }
                //     await friendMoment()
                // }
                // .onAppear {
                //     // friends.removeAll()
                //     Task {
                //         // await friendList()
                //     }
                // }
                
                FriendList()

                Button(action: {
                    Task {
                        await deleteCookies()
                        await AppSocketManager.shared.disconnect()
                        isLoggedIn = false
                    }
                }) {
                    Text("Logout")
                }
            }
        }
        .onAppear {
            // friends.removeAll()
            // requests.removeAll()
            Task {
                // await friendList()
                // await reqList()
                // await friendMoment()
                await fetchUserData()
            }
        }
    }
    
    
    private func fetchUserData() async {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID"), !serverID.isEmpty else { 
            error = "No server ID found"
            return 
        }
        
        isLoading = true
        error = nil
        
        do {
            let response = try await getUser(serverID: serverID)
            name = response.name
            id = response.id
            username = response.username
            pfp = response.pfp
        } catch {
            self.error = "Error: \(error.localizedDescription)"
            print("Error fetching user data: \(error)")
        }
        
        isLoading = false
    }

    // private func friendList() async {
    //     guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

    //     do {
    //         let (response, pfps) = try await getFriendList(serverID: savedServerID)

    //         print("Friend List: \(response)")
    //         userInfoArray = response
    //         pfpArray = pfps
    //         for (index, friend) in userInfoArray.enumerated() {
    //             // let nowPlaying = NowPlaying(id: "", song: "", album: "", artist: "", discord: false)
    //             let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
    //             // let nowPlaying = NowPlaying(id: friend["id"].stringValue ?? "", song: friend["nowPlaying"]["title"].stringValue ?? "Unknown Song", album: friend["nowPlaying"]["album"].stringValue ?? "Unknown Album", artist: friend["nowPlaying"]["artist"].stringValue ?? "Unknown Artist", discord: friend["nowPlaying"]["discord"].boolValue ?? false)
    //             let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
    //             // let nowPlayingSong = friend["nowPlaying"]["title"]?.stringValue
    //             // let nowPlayingArtist = friend["nowPlaying"]["artist"]?.stringValue
    //             // let nowPlaying = nowPlayingSong + " - " + nowPlayingArtist
    //             // if let 
    //             friends.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArray[index], nowPlaying: nowPlaying))
    //         }
    //     } catch {
    //         print("Error getting friend list: \(error)")
    //     }
    // }

    // private func reqList() async {
    //     guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

    //     do {
    //         let (response, pfps) = try await getReqList(serverID: savedServerID)

    //         print("Friend List: \(response)")
    //         userInfoArrayReq = response
    //         pfpArrayReq = pfps
    //         for (index, friend) in userInfoArrayReq.enumerated() {
    //             // let nowPlaying = NowPlaying(id: "", song: "", album: "", artist: "", discord: false)
    //             let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
    //             // let nowPlaying = NowPlaying(id: friend["id"].stringValue ?? "", song: friend["nowPlaying"]["title"].stringValue ?? "Unknown Song", album: friend["nowPlaying"]["album"].stringValue ?? "Unknown Album", artist: friend["nowPlaying"]["artist"].stringValue ?? "Unknown Artist", discord: friend["nowPlaying"]["discord"].boolValue ?? false)
    //             let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
    //             // let nowPlayingSong = friend["nowPlaying"]["title"]?.stringValue
    //             // let nowPlayingArtist = friend["nowPlaying"]["artist"]?.stringValue
    //             // let nowPlaying = nowPlayingSong + " - " + nowPlayingArtist
    //             // if let 
    //             requests.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArrayReq[index], nowPlaying: nowPlaying))
    //         }
    //     } catch {
    //         print("Error getting friend list: \(error)")
    //     }
    // }

    // private func acceptF(id: String) async {
    //     do {
    //         let response = try await acceptFriend(id: id)
    //         print("acceptF: \(response)")
    //     } catch {
    //         print("acceptF E: \(error)")
    //     }
    // }

    // private func rejectF(id: String) async {
    //     do {
    //         let response = try await rejectFriend(id: id)
    //         print("rejectF: \(response)")
    //     } catch {
    //         print("rejectF E: \(error)")
    //     }
    // }

    // private func addF(username: String) async {
    //     do {
    //         let response = try await addFriend(username: username)
    //         print("addF: \(response)")
    //     }
    //     catch {
    //         print("addF E: \(error)")
    //     }
    // }

    // private func removeF(id: String, at offsets: IndexSet) async {
    //     do {
    //         let response = try await removeFriend(id: id)
    //         print("removeF: \(response)")
    //     } catch {
    //         print("removeF E: \(error)")
    //     }
    // }



    // private func friendMoment() async {
    //     friends.removeAll()
    //     requests.removeAll()
    //     Task {
    //         await friendList()
    //         await reqList()
    //         // await fetchUserData()
    //     }
    // }
}



func saveCookies(_ cookies: [HTTPCookie]) {
    let cookieData = cookies.map { cookie in
        CookieData(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresDate: cookie.expiresDate
        )
    }
    
    if let encoded = try? JSONEncoder().encode(cookieData) {
        UserDefaults.standard.set(encoded, forKey: "savedCookies")
    }
}

// Load cookies from UserDefaults
func loadCookies() -> [CookieData]? {
    guard let data = UserDefaults.standard.data(forKey: "savedCookies"),
            let cookieData = try? JSONDecoder().decode([CookieData].self, from: data) else {
        return nil
    }
    return cookieData
}

// Restore cookies to HTTPCookieStorage
func restoreCookies(_ cookieData: [CookieData]) {
    for data in cookieData {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: data.name,
            .value: data.value,
            .domain: data.domain,
            .path: data.path
        ]
        
        if let expiresDate = data.expiresDate {
            properties[.expires] = expiresDate
        }
        
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

func deleteCookies() async {
    // Delete all cookies
    if let cookies = HTTPCookieStorage.shared.cookies {
        for cookie in cookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
    UserDefaults.standard.removeObject(forKey: "savedCookies")
}




struct FriendList: View {

        @State private var userInfoArray: [[String : JSON]] = []
        @State private var userInfoArrayReq: [[String : JSON]] = []
        @State private var pfpArray: [Data?] = []
        @State private var pfpArrayReq: [Data?] = []
        @State private var friends: [Friend] = []
        @State private var requests: [Friend] = []
        @State private var fUsername: String = ""

    var body: some View {
        List {
            Section{
                HStack {
                    Text("Add Friend:")
                    TextField("username", text: $fUsername)
                    .onSubmit {
                    Task {
                        // let response: String = try await addFriend(username: fUsername)
                        await addF(username: fUsername)
                        // print ("AddFriend Response: \(response)")
                        await friendMoment()
                    }
            }
                }
            } header: {
                Text("Manage")
            }
            
            Section{
                ForEach(requests) { friend in
                    HStack {
                        // if let pfpData = friend["pfp"]?.stringValue.data(using: .utf8),
                        if let pfp = friend.pfp, let uiImage = UIImage(data: pfp) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        }
                        VStack(alignment: .leading) {
                            
                        Text(friend.name)
                            .font(.headline)
                        Text("@" + friend.username)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(friend.nowPlaying.song + " - " + friend.nowPlaying.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            Task {
                                // let response: String = try await addFriend(id: friend.id)
                                await acceptF(id: friend.id)
                                await friendMoment()
                            }
                        }) {
                            Image(systemName: "checkmark.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 25, height: 25)
                            }
                            .buttonStyle(.borderless)
                        // Divider()
                        Button(action: {
                            Task {
                                // let response = try await rejectFriend(id: friend.id)
                                await rejectF(id: friend.id)
                                await friendMoment()
                            }
                        }) {
                            Image(systemName: "x.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 25, height: 25)
                            }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Requests")
            }
            // Spacer()
            // Divider()
            Section{
                ForEach(friends) { friend in
                    HStack {
                        // if let pfpData = friend["pfp"]?.stringValue.data(using: .utf8),
                        if let pfp = friend.pfp, let uiImage = UIImage(data: pfp) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        }
                        VStack(alignment: .leading) {
                            
                        Text(friend.name)
                            .font(.headline)
                        Text("@" + friend.username)
                        // Text(friend.username)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(friend.nowPlaying.song + " - " + friend.nowPlaying.artist)
                        // Text(friend.nowPlaying.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                            
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: delete)
                // .onDelete(perform: removeF)
            } header: {
                Text("Friends")
            }
        }
        .refreshable {
            // friends.removeAll()
            // requests.removeAll()
            // Task {
            //     await friendList()
            //     await reqList()
            //     // await fetchUserData()
            // }
            await friendMoment()
        }
        .onAppear {
            // friends.removeAll()
            Task {
                await friendList()
            }
        }
    }

    private func friendList() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

        do {
            let (response, pfps) = try await getFriendList(serverID: savedServerID)

            print("Friend List: \(response)")
            userInfoArray = response
            pfpArray = pfps
            for (index, friend) in userInfoArray.enumerated() {
                // let nowPlaying = NowPlaying(id: "", song: "", album: "", artist: "", discord: false)
                let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
                // let nowPlaying = NowPlaying(id: friend["id"].stringValue ?? "", song: friend["nowPlaying"]["title"].stringValue ?? "Unknown Song", album: friend["nowPlaying"]["album"].stringValue ?? "Unknown Album", artist: friend["nowPlaying"]["artist"].stringValue ?? "Unknown Artist", discord: friend["nowPlaying"]["discord"].boolValue ?? false)
                let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
                // let nowPlayingSong = friend["nowPlaying"]["title"]?.stringValue
                // let nowPlayingArtist = friend["nowPlaying"]["artist"]?.stringValue
                // let nowPlaying = nowPlayingSong + " - " + nowPlayingArtist
                // if let 
                friends.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArray[index], nowPlaying: nowPlaying))
            }
        } catch {
            print("Error getting friend list: \(error)")
        }
    }

    private func reqList() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

        do {
            let (response, pfps) = try await getReqList(serverID: savedServerID)

            print("Friend List: \(response)")
            userInfoArrayReq = response
            pfpArrayReq = pfps
            for (index, friend) in userInfoArrayReq.enumerated() {
                // let nowPlaying = NowPlaying(id: "", song: "", album: "", artist: "", discord: false)
                let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
                // let nowPlaying = NowPlaying(id: friend["id"].stringValue ?? "", song: friend["nowPlaying"]["title"].stringValue ?? "Unknown Song", album: friend["nowPlaying"]["album"].stringValue ?? "Unknown Album", artist: friend["nowPlaying"]["artist"].stringValue ?? "Unknown Artist", discord: friend["nowPlaying"]["discord"].boolValue ?? false)
                let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
                // let nowPlayingSong = friend["nowPlaying"]["title"]?.stringValue
                // let nowPlayingArtist = friend["nowPlaying"]["artist"]?.stringValue
                // let nowPlaying = nowPlayingSong + " - " + nowPlayingArtist
                // if let 
                requests.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArrayReq[index], nowPlaying: nowPlaying))
            }
        } catch {
            print("Error getting friend list: \(error)")
        }
    }

    private func acceptF(id: String) async {
        do {
            let response = try await acceptFriend(id: id)
            print("acceptF: \(response)")
        } catch {
            print("acceptF E: \(error)")
        }
    }

    private func rejectF(id: String) async {
        do {
            let response = try await rejectFriend(id: id)
            print("rejectF: \(response)")
        } catch {
            print("rejectF E: \(error)")
        }
    }

    private func addF(username: String) async {
        do {
            let response = try await addFriend(username: username)
            print("addF: \(response)")
        }
        catch {
            print("addF E: \(error)")
        }
    }

    private func removeF(id: String) async {
        do {
            let response = try await removeFriend(id: id)
            print("removeF: \(response)")
        } catch {
            print("removeF E: \(error)")
        }
    }

    private func delete(at offsets: IndexSet){
        print("BLAH")
        let index = offsets[offsets.startIndex]
        print("bLAH: \(index)")
        let id = friends[index].id
        print(id)
        Task {
            await removeF(id: id)
            await friendMoment()
        }
    }


    private func friendMoment() async {
        friends.removeAll()
        requests.removeAll()
        Task {
            await friendList()
            await reqList()
            // await fetchUserData()
        }
    }

}


// MARK: - Preview

#Preview {
    Login()
}

