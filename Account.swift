//
//  Account.swift
//  Maple
//
//  Created by Potter on 4/16/25.
//

import SwiftUI
import Foundation
import SwiftyJSON

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

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    
    print("User data response status: \(httpResponse.statusCode)")
    
    switch httpResponse.statusCode {
    case 200:
        let json = try JSON(data: data)
        print("User data JSON: \(json)")
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
            LoggedIn()
        }
        else{
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
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
            print("Login error: \(error)")
        }
        
        isLoading = false
    }
    
    // Save cookies to UserDefaults
    private func saveCookies(_ cookies: [HTTPCookie]) {
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
    private func loadCookies() -> [CookieData]? {
        guard let data = UserDefaults.standard.data(forKey: "savedCookies"),
              let cookieData = try? JSONDecoder().decode([CookieData].self, from: data) else {
            return nil
        }
        return cookieData
    }
    
    // Restore cookies to HTTPCookieStorage
    private func restoreCookies(_ cookieData: [CookieData]) {
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
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else if let error = error {
                Text(error)
                    .foregroundColor(.red)
            } else {
                Text("Name: \(name)")
                Text("ID: \(id)")
                Text("Username: \(username)")
                if let pfp = pfp, let uiImage = UIImage(data: pfp) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                }
                Button(action: {
                    Task {
                        await setAlbumArt()
                    }
                }) {
                    Text("Album Art Test")
                }
            }
        }
        .onAppear {
            Task {
                await fetchUserData()
            }
        }
    }
    
    private func setAlbumArt() async {
        print("Setting album art")
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
}

// MARK: - Preview

#Preview {
    Login()
}

