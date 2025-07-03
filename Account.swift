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
import PhotosUI

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
    guard let url = URL(string: "https://api.maple.music/login") else {
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
    
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)
    
    let (data, response) = try await session.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
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
    }
    
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    
    switch httpResponse.statusCode {
    case 200...299:
        do {
            let json = try JSON(data: data)
            
            let serverUsername = json["user"]["username"]
            let serverID = json["user"]["id"]
            let status = json["status"]
            if status.stringValue.lowercased() == "success" {
                return LoginResponse(success: true, serverUsername: serverUsername.stringValue, serverID: serverID.stringValue, response: httpResponse.statusCode)
            }
            else{
                return LoginResponse(success: false, serverUsername: "", serverID: "", response: httpResponse.statusCode)
            }
        } catch {
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
    guard let url = URL(string: "https://api.maple.music/login/create") else {
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

    switch httpResponse.statusCode {
    case 200:
        return "Success! Please login using your new account: \(username)"
    default:
        throw NSError(domain: "RegisterError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: \(httpResponse.statusCode)"])
    }
}

func getUser(serverID: String) async throws -> userResponse {
    guard let url = URL(string: "https://api.maple.music/get/user/\(serverID)") else {
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
    
    switch httpResponse.statusCode {
    case 200:
        let json = try JSON(data: data)
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


func setAlbumArt(serverID: String, albumArt: Data) async throws -> String {
    guard let url = URL(string: "https://api.maple.music/user/manage/setAlbumArt/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let boundaryStart = "--\(boundary)\r\n"
    let boundaryEnd = "--\(boundary)--\r\n"

    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"albumArt\"; filename=\"albumArt.jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(albumArt)
    body.append("\r\n".data(using: .utf8)!)
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"id\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(serverID)\r\n".data(using: .utf8)!)
    body.append(boundaryEnd.data(using: .utf8)!)

    request.httpBody = body

    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)
    request.addValue("\(body.count)", forHTTPHeaderField: "Content-Length")

    let (data, response) = try await session.data(for: request)
    print("Set Album Art Data: \(String(data: data, encoding: .utf8))")
    print("Set Album Art Response: \(response)")

                            print("There were \(albumArt.count) bytes")
                            let bcf = ByteCountFormatter()
                            bcf.allowedUnits = [.useMB] // optional: restricts the units to MB only
                            bcf.countStyle = .file
                            let string = bcf.string(fromByteCount: Int64(albumArt.count))
                            print("formatted result: \(string)")
                        
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    return "\(httpResponse)"
}

func sendWebhook(song: Song, serverID: String) async throws -> String {
    let webhookURL = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
    
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
        "avatar_url": "https://api.maple.music/public/get/pfp/\(serverID)"
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

    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"albumArt.jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(artworkData)
    body.append("\r\n".data(using: .utf8)!)

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
    
    return "Webhook Moment"
}

func getFriendList(serverID: String) async throws -> ([[String : JSON]], [Data?]) {
    guard let url = URL(string: "https://api.maple.music/user/friends/get/friends/\(serverID)") else {
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
    let friends = json.arrayValue.compactMap { friend in
        friend["friend_id"].stringValue == serverID ? friend["user_id"].stringValue : friend["friend_id"].stringValue
    }

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
    }

    return (userInfoArray, pfps)
}

func publicUserId(serverID: String) async throws -> [String : JSON] {
    guard let url = URL(string: "https://api.maple.music/public/get/user/id/\(serverID)") else {
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

    return user
}

func publicUser(username: String) async throws -> [String: JSON] {
    guard let url = URL(string: "https://api.maple.music/public/get/user/\(username)") else {
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

    return user
}

func getPublicPfp(serverID: String) async throws -> Data? {
    guard let url = URL(string: "https://api.maple.music/public/get/pfp/\(serverID)") else {
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
    return data
    
}

func addFriend(username: String) async throws -> String {
    let user = try await publicUser(username: username)

    if let error = user["error"]?.stringValue {
        return error
    }
    else {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID") else {
            throw URLError(.badURL)
        }
        let id: String = user["id"]?.stringValue ?? ""

        guard let url = URL(string: "https://api.maple.music/user/friends/add/\(serverID)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        print("Add Friend Data: \(String(data: data, encoding: .utf8))")
        print("Add Friend Response: \(response)")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            return message
        }
        else if let error = dict["error"]?.stringValue {
            return error
        }
        
        return "Else Statement Concluded with Invalid Route?"
    }
    return "Function Concluded with Invalid Route?"
}

func acceptFriend(id: String) async throws -> String {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID") else {
            throw URLError(.badURL)
        }
        guard let url = URL(string: "https://api.maple.music/user/friends/accept/\(serverID)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        print("Accept Friend Data: \(String(data: data, encoding: .utf8))")
        print("Accept Friend Response: \(response)")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            return message
        }
        else if let error = dict["error"]?.stringValue {
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func rejectFriend(id: String) async throws -> String {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID") else {
            throw URLError(.badURL)
        }
        guard let url = URL(string: "https://api.maple.music/user/friends/decline/\(serverID)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        print("Reject Friend Data: \(String(data: data, encoding: .utf8))")
        print("Reject Friend Response: \(response)")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            return message
        }
        else if let error = dict["error"]?.stringValue {
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func removeFriend(id: String) async throws -> String {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID") else {
            throw URLError(.badURL)
        }
        guard let url = URL(string: "https://api.maple.music/user/friends/remove/\(serverID)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String : Any] = [
            "friendId": id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        print("Remove Friend Data: \(String(data: data, encoding: .utf8))")
        print("Remove Friend Response: \(response)")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let json = try JSON(data: data)
        let dict = json.dictionaryValue
        if let message = dict["message"]?.stringValue {
            return message
        }
        else if let error = dict["error"]?.stringValue {
            return error
        }
    return "Function ran but did not end in a valid route?"
}

func getReqList(serverID: String) async throws -> ([[String : JSON]], [Data?]) {
    guard let url = URL(string: "https://api.maple.music/user/friends/get/requests/\(serverID)") else {
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
    let friends = json.arrayValue.compactMap { friend in
        friend["friend_id"].stringValue == serverID ? friend["user_id"].stringValue : friend["friend_id"].stringValue
    }

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
    }
    return (userInfoArray, pfps)
}

func uploadPfp(serverID: String, pfp: Data) async throws -> String {
    guard let url = URL(string: "https://api.maple.music/user/manage/setProfile/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let boundaryStart = "--\(boundary)\r\n"
    let boundaryEnd = "--\(boundary)--\r\n"

    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"pfp\"; filename=\"pfp.jpg\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(pfp)
    body.append("\r\n".data(using: .utf8)!)
    body.append(boundaryStart.data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"id\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(serverID)\r\n".data(using: .utf8)!)
    body.append(boundaryEnd.data(using: .utf8)!)

    request.httpBody = body

    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.httpCookieStorage = .shared
    let session = URLSession(configuration: config)
    request.addValue("\(body.count)", forHTTPHeaderField: "Content-Length")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    return "\(httpResponse)"
}

func uploadName(serverID: String, name: String) async throws -> String {
    guard let url = URL(string: "https://api.maple.music/user/manage/setDisplayName/\(serverID)") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let parameters: [String : Any] = [
        "displayName" : name
    ]
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
    return "\(httpResponse)"
}


struct Login: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isLoggedIn = false
    @State private var serverUsername: String = ""
    @State private var serverID: String = ""
    @State private var userStatus: Int? = nil
    
    init() {
        if let savedCookies = loadCookies() {
            restoreCookies(savedCookies)
        }
        
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
                        } catch {
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
            
            UserDefaults.standard.set(serverID, forKey: "savedServerID")
            
            isLoggedIn = response.success
            
            if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://api.maple.music")!) {
                saveCookies(cookies)
            }
            await AppSocketManager.shared.connect()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    private func fetchUserData() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }
        
        do {
            let response = try await getUser(serverID: savedServerID)
            userStatus = response.response
            if userStatus == 200 {
                isLoggedIn = true
            }
        } catch {
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
    @State private var showingAlert = false
    @State private var showPhotoPicker = false
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var showNameSheet = false
    @State private var newName: String = ""
    
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
                Button("\(username)"){
                    UIPasteboard.general.string = username
                }
                    .font(.title)
                    .foregroundColor(.primary)
                Button("\(name)"){
                    UIPasteboard.general.string = name
                }
                    .font(.title2)
                    .foregroundColor(.primary)
                Button("\(id)"){
                    UIPasteboard.general.string = id
                }
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Spacer()
                
                FriendList(isLoggedIn: $isLoggedIn, showingAlert: $showingAlert)

            }
        }
        .onAppear {
            Task {
                await fetchUserData()
            }
        }
        .onChange(of: selectedItem) {
            Task {
                if let data = try? await selectedItem?.loadTransferable(type: Data.self) {
                    selectedImageData = data
                    await uploadProfilePicture()
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItem, matching: .images)
        .sheet(isPresented: $showNameSheet) {
            ChangeNameSheet(newName: $newName, currentName: name, onSave: {
                Task {
                    await updateName()
                }
            })
        }
        .toolbar {
            ToolbarItem{
                Menu("Manage Account") {
                    Button("Upload Profile Picture", action: {
                        showPhotoPicker = true
                    })
                    Button("Change Your Name", action: {
                        newName = name
                        showNameSheet = true
                    })
                }
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
        }
        
        isLoading = false
    }

    private func uploadProfilePicture() async {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID"), !serverID.isEmpty else {
            error = "No server ID found"
            return
        }
        guard let imageData = selectedImageData else {
            error = "No image data"
            return
        }

        isLoading = true
        do {
            _ = try await uploadPfp(serverID: serverID, pfp: imageData)
            await fetchUserData()
        } catch {
            self.error = "Error uploading pfp: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    private func updateName() async {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID"), !serverID.isEmpty else {
            error = "No server ID found"
            return
        }
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Name cannot be empty"
            return
        }

        isLoading = true
        do {
            _ = try await uploadName(serverID: serverID, name: newName)
            await fetchUserData()
            showNameSheet = false
        } catch {
            self.error = "Error updating name: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct ChangeNameSheet: View {
    @Binding var newName: String
    let currentName: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Change Your Name")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Current name: \(currentName)")
                    .foregroundColor(.secondary)
                
                TextField("Enter new name", text: $newName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    dismiss()
                },
                trailing: Button("Save") {
                    onSave()
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )
        }
    }
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

func loadCookies() -> [CookieData]? {
    guard let data = UserDefaults.standard.data(forKey: "savedCookies"),
            let cookieData = try? JSONDecoder().decode([CookieData].self, from: data) else {
        return nil
    }
    return cookieData
}

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
    if let cookies = HTTPCookieStorage.shared.cookies {
        for cookie in cookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
    UserDefaults.standard.removeObject(forKey: "savedCookies")
}




struct FriendList: View {
    @Binding var isLoggedIn: Bool
    @Binding var showingAlert: Bool
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
                        await addF(username: fUsername)
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
                        Button(action: {
                            Task {
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
            Section{
                ForEach(friends) { friend in
                    HStack {
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
                            
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: delete)
            } header: {
                Text("Friends")
            }
            Section{
                Button(action: {
                        showingAlert = true
                    }) {
                        Text("Logout")
                        .foregroundStyle(.red)
                    }
                    .alert("Warning!", isPresented: $showingAlert, actions: { 
                        Button(role: .destructive) {
                            Task {
                                await deleteCookies()
                                await AppSocketManager.shared.disconnect()
                                isLoggedIn = false
                            }

                        } label: {
                            Text("Logout")
                            .foregroundColor(.red)
                        }
                        

                        Button("Cancel", role: .cancel) {

                        }
                }, message: {
                    Text("This will log you out of Maple and delete all saved cookies within the app. This will not modify your library in any way!")
                })
            }
        }
        .refreshable {
            await friendMoment()
        }
        .onAppear {
            Task {
                await friendMoment()
            }
        }
    }

    private func friendList() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

        do {
            let (response, pfps) = try await getFriendList(serverID: savedServerID)

            userInfoArray = response
            pfpArray = pfps
            for (index, friend) in userInfoArray.enumerated() {
                let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
                let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
                friends.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArray[index], nowPlaying: nowPlaying))
            }
        } catch {
        }
    }

    private func reqList() async {
        guard let savedServerID = UserDefaults.standard.string(forKey: "savedServerID"), !savedServerID.isEmpty else { return }

        do {
            let (response, pfps) = try await getReqList(serverID: savedServerID)

            userInfoArrayReq = response
            pfpArrayReq = pfps
            for (index, friend) in userInfoArrayReq.enumerated() {
                let nowPlayingDict = friend["nowPlaying"]?.dictionaryValue
                let nowPlaying = NowPlaying(id: nowPlayingDict?["id"]?.stringValue ?? "", song: nowPlayingDict?["title"]?.stringValue ?? "Unknown Song", album: nowPlayingDict?["album"]?.stringValue ?? "Unknown Album", artist: nowPlayingDict?["artist"]?.stringValue ?? "Unknown Artist", discord: nowPlayingDict?["discord"]?.boolValue ?? false)
                requests.append(Friend(id: friend["id"]?.stringValue ?? "", name: friend["name"]?.stringValue ?? "", username: friend["username"]?.stringValue ?? "", pfp: pfpArrayReq[index], nowPlaying: nowPlaying))
            }
        } catch {
        }
    }

    private func acceptF(id: String) async {
        do {
            let response = try await acceptFriend(id: id)
        } catch {
        }
    }

    private func rejectF(id: String) async {
        do {
            let response = try await rejectFriend(id: id)
        } catch {
        }
    }

    private func addF(username: String) async {
        do {
            let response = try await addFriend(username: username)
        }
        catch {
        }
    }

    private func removeF(id: String) async {
        do {
            let response = try await removeFriend(id: id)
        } catch {
        }
    }

    private func delete(at offsets: IndexSet){
        let index = offsets[offsets.startIndex]
        let id = friends[index].id
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
        }
    }

}

#Preview {
    Login()
}

