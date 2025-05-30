//
//  Settings.swift
//  Maple
//
//  Created by Potter on 4/29/25.
//

import SwiftUI

struct Settings: View {
    @State private var webhookURL = ""
    var body: some View {
        VStack{
            VStack{
                Text("Webhook URL")
                TextField("\("https://discord.com/api/webhooks/...")", text: $webhookURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
            }
        }
    }
}

#Preview {
    Settings()
}
