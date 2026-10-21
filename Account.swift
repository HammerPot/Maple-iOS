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
import SwiftUISnackbar

struct CookieData: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    var isSecure: Bool? = nil
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
    let data = try await MapleAPI.shared.request(["login"], method: "POST", json: ["username": username, "password": password])
    let json = try JSON(data: data)
    guard json["status"].stringValue.lowercased() == "success",
          let id = json["user"]["id"].string, !id.isEmpty,
          let username = json["user"]["username"].string else { throw URLError(.badServerResponse) }
    saveCookies(HTTPCookieStorage.shared.cookies(for: MapleAPI.baseURL) ?? [])
    return LoginResponse(success: true, serverUsername: username, serverID: id, response: 200)
}

func register(username: String, password: String) async throws -> String {
    _ = try await MapleAPI.shared.request(["login", "create"], method: "POST", json: ["username": username, "password": password])
    return "Success! Please login using your new account: \(username)"
}

func getUser(serverID: String) async throws -> userResponse {
    let data = try await MapleAPI.shared.request(["get", "user", serverID])
    let json = try JSON(data: data)
    guard let id = json["id"].string, !id.isEmpty, let username = json["username"].string else {
        throw URLError(.badServerResponse)
    }
    return userResponse(name: json["name"].stringValue, id: id, username: username,
                        pfp: json["pfp"].string.flatMap { Data(base64Encoded: $0) }, response: 200)
}

func setAlbumArt(serverID: String, albumArt: Data, artworkRequestId: String? = nil) async throws -> String {
    let data = try await MapleAPI.shared.upload(["user", "manage", "setAlbumArt", serverID], field: "albumArt", image: albumArt, artworkRequestId: artworkRequestId)
    return try JSON(data: data)["message"].stringValue
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

func getFriendList(serverID: String) async throws -> ([[String: JSON]], [Data?]) {
    try await fetchRelationships(serverID: serverID, kind: "friends")
}

private func fetchRelationships(serverID: String, kind: String) async throws -> ([[String: JSON]], [Data?]) {
    let data = try await MapleAPI.shared.request(["user", "friends", "get", kind, serverID])
    let json = try JSON(data: data)
    guard let relationships = json.array else { throw URLError(.badServerResponse) }
    var users: [[String: JSON]] = []
    var pictures: [Data?] = []
    for relationship in relationships {
        let id = relationship["friend_id"].stringValue == serverID ? relationship["user_id"].stringValue : relationship["friend_id"].stringValue
        guard !id.isEmpty else { throw URLError(.badServerResponse) }
        users.append(try await publicUserId(serverID: id))
        pictures.append(try await getPublicPfp(serverID: id))
    }
    return (users, pictures)
}

func publicUserId(serverID: String) async throws -> [String: JSON] {
    let data = try await MapleAPI.shared.request(["public", "get", "user", "id", serverID])
    var user = try JSON(data: data).dictionaryValue
    // The SQL JSON column can be returned as either an object or a JSON string.
    if let value = user["nowPlaying"]?.string, let encoded = value.data(using: .utf8) {
        user["nowPlaying"] = try JSON(data: encoded)
    }
    return user
}

func publicUser(username: String) async throws -> [String: JSON] {
    let data = try await MapleAPI.shared.request(["public", "get", "user", username])
    return try JSON(data: data).dictionaryValue
}

func getPublicPfp(serverID: String) async throws -> Data? {
    let data = try await MapleAPI.shared.request(["public", "get", "pfp", serverID], allowMissing: true)
    return data.isEmpty ? nil : data
}

private func friendAction(_ action: String, id: String) async throws -> String {
    guard let serverID = UserDefaults.standard.string(forKey: "savedServerID"), !serverID.isEmpty else {
        throw MapleAPIError(statusCode: 401, data: Data())
    }
    let data = try await MapleAPI.shared.request(["user", "friends", action, serverID], method: "POST", json: ["friendId": id])
    return try JSON(data: data)["message"].stringValue
}

func addFriend(username: String) async throws -> String {
    let user = try await publicUser(username: username)
    guard let id = user["id"]?.string, !id.isEmpty else { throw URLError(.badServerResponse) }
    return try await friendAction("add", id: id)
}

func acceptFriend(id: String) async throws -> String { try await friendAction("accept", id: id) }
func rejectFriend(id: String) async throws -> String { try await friendAction("decline", id: id) }
func removeFriend(id: String) async throws -> String { try await friendAction("remove", id: id) }

func getReqList(serverID: String) async throws -> ([[String: JSON]], [Data?]) {
    try await fetchRelationships(serverID: serverID, kind: "requests")
}

func uploadPfp(serverID: String, pfp: Data) async throws -> String {
    let data = try await MapleAPI.shared.upload(["user", "manage", "setProfile", serverID], field: "pfp", image: pfp)
    return try JSON(data: data)["message"].stringValue
}

func uploadName(serverID: String, name: String) async throws -> String {
    let data = try await MapleAPI.shared.request(["user", "manage", "setDisplayName", serverID], method: "POST", json: ["displayName": name])
    return try JSON(data: data)["message"].stringValue
}

func deleteAccount(serverID: String) async throws -> String {
    let data = try await MapleAPI.shared.request(["user", "manage", "delete", serverID], method: "DELETE")
    return try JSON(data: data)["message"].stringValue
}

@MainActor
func logout() async throws {
    AppSocketManager.shared.disconnect()
    defer { clearMapleSession() }
    if let id = UserDefaults.standard.string(forKey: "savedServerID"), !id.isEmpty {
        _ = try await MapleAPI.shared.request(["get", "logout", id])
    }
}

struct Login: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var isLoggedIn = false
    @State private var serverUsername: String = ""
    @State private var serverID: String = ""
    @State private var userStatus: Int? = nil

    @State private var snackbarSuccess: Snackbar?
    @State private var snackbarError: Snackbar?

    @State private var showSuccessMessage = false
    @State private var showErrorMessage = false
    @State private var showRegisterSheet = false

    
    init() {
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
                
                // if let errorMessage = errorMessage {
                //     Text(errorMessage)
                //         .foregroundColor(.red)
                //         .padding()
                // }

                // if let successMessage = successMessage {
                //     Text(successMessage)
                //         .foregroundColor(.green)
                //         .padding()
                // }
                
                Button(action: {
                    Task {
                        await handleLogin()
                        // successMessage = "Login successful! Please wait."
                        // showSuccessMessage = true
                        
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

                Button("Register") {
                    showRegisterSheet = true
                }
            }
            .padding()
            .snackbarView(snackbar: $snackbarSuccess)
            .snackbarView(snackbar: $snackbarError)
            // .snackbar(isShowing: $showSuccessMessage, title: "Success", text: successMessage, style: .custom(.green))
            // .snackbar(isShowing: $showErrorMessage, title: "Error", text: errorMessage, style: .custom(.red))
            .sheet(isPresented: $showRegisterSheet) {
                RegisterSheet { newUsername, newPassword in
                    // optionally prefill the login form
                    username = newUsername
                    password = newPassword
                    snackbarSuccess = Snackbar(title: "Success", message: "Registration successful! Please login.")
                }
            }
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
            AppSocketManager.shared.connect()
            snackbarSuccess = Snackbar(title: "Success", message: "Login successful! Please wait.")
        } catch {
            // errorMessage = "Login failed: \(error.localizedDescription)"
            // showErrorMessage = true
            snackbarError = Snackbar(title: "Error", message: "Login failed: \(error.localizedDescription)")
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
                AppSocketManager.shared.connect()
            }
        } catch let error as MapleAPIError where error.statusCode == 401 || error.statusCode == 403 {
            await deleteCookies()
        } catch {
            snackbarError = Snackbar(title: "Unable to restore session", message: error.localizedDescription)
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
    @State private var showingDeleteAlert = false

    @State private var snackbar: Snackbar?
    
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
                
                FriendList(isLoggedIn: $isLoggedIn, showingAlert: $showingAlert, snackbar: $snackbar)

            }
        }
        .snackbarView(snackbar: $snackbar)
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
                    snackbar = Snackbar(title: "Success", message: "Profile picture uploaded successfully!")
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItem, matching: .images)
        .sheet(isPresented: $showNameSheet) {
            ChangeNameSheet(newName: $newName, currentName: name, onSave: {
                Task {
                    await updateName()
                    snackbar = Snackbar(title: "Success", message: "Name updated successfully!")
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
                    Button(role: .destructive) {
                        print("delete account")
                        showingDeleteAlert = true
                    } label: {
                        Text("Delete Account")
                        // .foregroundColor(.red)
                    }
                }
            }
        }
        .alert("Warning!", isPresented: $showingDeleteAlert, actions: { 
            Button(role: .destructive) {
                Task {
                    await deleteUserAccount()
                }

            } label: {
                Text("Delete Account")
                .foregroundColor(.red)
            }
            

            Button("Cancel", role: .cancel) {

            }
        }, message: {
            Text("This will DELETE your account and all data associated with it. This action is irreversible!")
        })
    }
    
    private func deleteUserAccount() async {
        guard let serverID = UserDefaults.standard.string(forKey: "savedServerID"), !serverID.isEmpty else {
            error = "No server ID found"
            return
        }
        
        do {
            let response = try await deleteAccount(serverID: serverID)
            if response.lowercased().contains("success") {
                await deleteCookies()
                isLoggedIn = false
            } else {
                snackbar = Snackbar(title: "Error", message: "Error deleting account: \(response)")
            }
        } catch {
            print(error)
            snackbar = Snackbar(title: "Error", message: "Error deleting account: \(error.localizedDescription)")
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

struct RegisterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var snackbar: Snackbar?

    let onSuccess: (String, String) -> Void

    var body: some View {
        NavigationView {
            VStack() {
                Text("Create Account")
                    .font(.title2)
                    .fontWeight(.semibold)

                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disableAutocorrection(true)
                    .autocapitalization(.none)

                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disableAutocorrection(true)
                    .onSubmit { Task { await createAccount() } }

                Spacer()
                Text("Password must meet the following requirements:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("1. Contains at least 8 characters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("2. Contains at least 1 uppercase letter")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("3. Contains at least 1 lowercase letter")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("4. Contains at least 1 number")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("5. Contains at least 1 special character")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .navigationTitle("Register")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await createAccount() } }
                    }
                }
            }
        }
        .snackbarView(snackbar: $snackbar)
    }

    private func createAccount() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await register(username: username, password: password)
            if response.lowercased().contains("success") {
                onSuccess(username, password)
                dismiss()
            } else {
                snackbar = Snackbar(title: "Error", message: "Registration failed.")
            }
        } catch {
            snackbar = Snackbar(title: "Error", message: "Registration failed: \(error.localizedDescription)")
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
            expiresDate: cookie.expiresDate,
            isSecure: cookie.isSecure
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
        guard data.domain == "api.maple.music" || data.domain == ".maple.music" else { continue }
        if let expiry = data.expiresDate, expiry <= Date() { continue }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: data.name,
            .value: data.value,
            .domain: data.domain,
            .path: data.path,
            .secure: data.isSecure ?? true
        ]
        
        if let expiresDate = data.expiresDate {
            properties[.expires] = expiresDate
        }
        
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

func clearMapleSession() {
    for cookie in HTTPCookieStorage.shared.cookies(for: MapleAPI.baseURL) ?? [] {
        HTTPCookieStorage.shared.deleteCookie(cookie)
    }
    UserDefaults.standard.removeObject(forKey: "savedCookies")
    UserDefaults.standard.removeObject(forKey: "savedServerID")
}

@MainActor
func deleteCookies() async {
    AppSocketManager.shared.disconnect()
    clearMapleSession()
}

struct FriendList: View {
    @ObservedObject private var socketManager = AppSocketManager.shared
    @Binding var isLoggedIn: Bool
    @Binding var showingAlert: Bool
        @State private var userInfoArray: [[String : JSON]] = []
        @State private var userInfoArrayReq: [[String : JSON]] = []
        @State private var pfpArray: [Data?] = []
        @State private var pfpArrayReq: [Data?] = []
        @State private var friends: [Friend] = []
        @State private var requests: [Friend] = []
        @State private var fUsername: String = ""

        @Binding var snackbar: Snackbar?

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
                                do { try await logout() }
                                catch { snackbar = Snackbar(title: "Logout", message: error.localizedDescription) }
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
        .onChange(of: socketManager.friendsRevision) { _, _ in
            Task { await friendMoment() }
        }
        .onChange(of: socketManager.friendPlayback) { _, updates in
            friends = friends.map { friend in
                guard let update = updates[friend.id] else { return friend }
                let playing = NowPlaying(id: friend.id, song: update["title"].stringValue,
                                         album: update["album"].stringValue, artist: update["artist"].stringValue,
                                         discord: update["discord"].boolValue)
                return Friend(id: friend.id, name: friend.name, username: friend.username, pfp: friend.pfp, nowPlaying: playing)
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
            friends = []
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
            requests = []
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
            snackbar = Snackbar(title: "Accept Friend", message: "\(response)")
        } catch {
            snackbar = Snackbar(title: "Accept Friend", message: "\(error.localizedDescription)")
        }
    }

    private func rejectF(id: String) async {
        do {
            let response = try await rejectFriend(id: id)
            snackbar = Snackbar(title: "Reject Friend", message: "\(response)")
        } catch {
            snackbar = Snackbar(title: "Reject Friend", message: "\(error.localizedDescription)")
        }
    }

    private func addF(username: String) async {
        do {
            let response = try await addFriend(username: username)
            snackbar = Snackbar(title: "Add Friend", message: "\(response)")
        }
        catch {
            snackbar = Snackbar(title: "Add Friend", message: "\(error.localizedDescription)")
        }
    }

    private func removeF(id: String) async {
        do {
            let response = try await removeFriend(id: id)   
            snackbar = Snackbar(title: "Remove Friend", message: "\(response)")
        } catch {
            snackbar = Snackbar(title: "Remove Friend", message: "\(error.localizedDescription)")
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
        await friendList()
        await reqList()
    }

}

#Preview {
    Login()
}

