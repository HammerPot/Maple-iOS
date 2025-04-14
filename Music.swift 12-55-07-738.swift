//
//  Music.swift
//  Maple
//
//  Created by Potter on 3/24/25.
//

import Foundation
import StoreKit
import MusicKit

struct Music {
    func authorize() async {
        let status = await MusicAuthorization.request()
        
        switch status {
        case .authorized:
            print("Authorized")
        case .denied:
            print("Denied")
        case .notDetermined:
            print("Not Determined")
        case .restricted:
            print("Restricted")
        @unknown default:
            print("Unknown")
        }
    }
    
}
