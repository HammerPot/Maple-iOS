//
//  Account.swift
//  Maple
//
//  Created by Potter on 4/16/25.
//

import SwiftUI

struct Account: View {
    @State private var username: String = ""
    @State private var password: String = ""
    var body: some View {
        TextField("Username", text: $username)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding()
            .disableAutocorrection(true)
        SecureField("Password", text: $password)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding()
            .disableAutocorrection(true)
            .onSubmit {
                handleLogin(username: username, password: password)
            }
        Button(action: {
            handleLogin(username: username, password: password)
        }) {
            Text("Login")
                .frame(maxWidth: .infinity)
                .padding()
        }
        
        
    }


    private func handleLogin(username: String, password: String) {
        // print("Login attempt with username: \(username) and password: \(password)")
        
    }
}

#Preview {
    Account()
}

