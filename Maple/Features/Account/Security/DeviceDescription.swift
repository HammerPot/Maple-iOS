import Foundation

/// A readable name and symbol for a session's user agent, e.g. "Safari on Mac" or "Maple for iOS".
struct DeviceDescription: Equatable, Sendable {
    let title: String
    let systemImage: String

    init(title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }

    init(userAgent: String?) {
        guard let agent = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty else {
            self.init(title: "Unknown Device", systemImage: "questionmark.circle"); return
        }
        // Native apps using URLSession: "Maple/1 CFNetwork/3826.500.111.2.2 Darwin/24.4.0".
        if agent.contains("CFNetwork/"), agent.contains("Darwin/"), !agent.contains("Mozilla/") {
            let app = agent.split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? "App"
            let name = app.hasPrefix("Maple") ? "Maple" : app
            self.init(title: "\(name) for iOS", systemImage: "iphone"); return
        }
        let platform = Self.platform(agent)
        if let browser = Self.browser(agent) {
            self.init(title: platform.map { "\(browser) on \($0.name)" } ?? browser,
                      systemImage: platform?.symbol ?? "globe"); return
        }
        if let platform { self.init(title: platform.name, systemImage: platform.symbol); return }
        self.init(title: "Other Device", systemImage: "network")
    }

    private static func contains(_ agent: String, _ needles: String...) -> Bool {
        needles.contains { agent.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static func browser(_ agent: String) -> String? {
        if contains(agent, "Discord") { return "Discord" }
        if contains(agent, "Edg/", "EdgiOS", "EdgA/") { return "Edge" }
        if contains(agent, "OPR/", "Opera") { return "Opera" }
        if contains(agent, "Firefox/", "FxiOS") { return "Firefox" }
        if contains(agent, "CriOS", "Chrome/", "Chromium/") { return "Chrome" }
        if contains(agent, "Safari/", "AppleWebKit/") { return "Safari" }
        return nil
    }
    private static func platform(_ agent: String) -> (name: String, symbol: String)? {
        if contains(agent, "iPad") { return ("iPad", "ipad") }
        if contains(agent, "iPhone", "iPod") { return ("iPhone", "iphone") }
        if contains(agent, "Android") { return ("Android", "candybarphone") }
        if contains(agent, "Macintosh", "Mac OS X") { return ("Mac", "laptopcomputer") }
        if contains(agent, "Windows") { return ("Windows", "pc") }
        if contains(agent, "CrOS") { return ("ChromeOS", "laptopcomputer") }
        if contains(agent, "Linux", "X11") { return ("Linux", "desktopcomputer") }
        return nil
    }
}
