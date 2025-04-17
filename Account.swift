//
//  Account.swift
//  Maple
//
//  Created by Potter on 4/16/25.
//

import SwiftUI
import Foundation
import SwiftyJSON

// Structure to store cookie data
struct CookieData: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
}

struct Login: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isLoggedIn = false
    @State private var serverUsername: String = ""
    @State private var serverID: String = ""
    
    // Load saved cookies on init
    init() {
        if let savedCookies = loadCookies() {
            restoreCookies(savedCookies)
        }
    }
    
    var body: some View {
        if isLoggedIn {
            LoggedIn(serverUsername: $serverUsername, serverID: $serverID)
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
        }
    }
    
    private func handleLogin() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await login(username: username, password: password)
            serverUsername = response.serverUsername
            serverID = response.serverID
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
}

struct LoginResponse: Codable {
    let success: Bool
    let serverUsername: String
    let serverID: String
}

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
                return LoginResponse(success: true, serverUsername: serverUsername.stringValue, serverID: serverID.stringValue)
            }
            else{
                return LoginResponse(success: false, serverUsername: "", serverID: "")
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


struct LoggedIn: View {
    @Binding var serverUsername: String
    @Binding var serverID: String
    var body: some View {
        Text("Logged in")
        Text("Username: \(serverUsername)")
        Text("ID: \(serverID)")
    }
}

