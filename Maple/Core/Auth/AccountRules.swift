import Foundation

/// Client-side mirror of the server's account rules (`api/validation/account.ts`).
/// Each check returns the server's own message for the first problem, or nil when the value is valid.
/// Lengths count UTF-16 code units, like the server's zod schemas.
enum AccountRules {
    static let usernameLength = 2...32
    static let passwordLength = 8...128
    static let displayNameLength = 1...64
    static let emailMaxLength = 254

    static let usernameHint = "2–32 letters, digits, dots, dashes or underscores."
    static let passwordHint = "8–128 characters with an uppercase and a lowercase letter."

    static func usernameProblem(_ value: String) -> String? {
        let count = value.utf16.count
        if count < usernameLength.lowerBound { return "Username must be at least 2 characters." }
        if count > usernameLength.upperBound { return "Username must be at most 32 characters." }
        if value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            return "Username may only use letters, digits, dots, dashes and underscores."
        }
        return nil
    }

    static func passwordProblem(_ value: String) -> String? {
        let count = value.utf16.count
        if count < passwordLength.lowerBound { return "Password must be at least 8 characters." }
        if count > passwordLength.upperBound { return "Password must be at most 128 characters." }
        if value.range(of: "[A-Z]", options: .regularExpression) == nil { return "Password needs an uppercase letter." }
        if value.range(of: "[a-z]", options: .regularExpression) == nil { return "Password needs a lowercase letter." }
        return nil
    }

    /// zod 4's default `z.email()` pattern, plus the server's 254-character cap.
    static func emailProblem(_ value: String) -> String? {
        isEmail(value) ? nil : "Enter a valid email address."
    }

    static func isEmail(_ value: String) -> Bool {
        let pattern = #"^(?!\.)(?!.*\.\.)([A-Za-z0-9_'+\-\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$"#
        return value.utf16.count <= emailMaxLength && value.range(of: pattern, options: .regularExpression) != nil
    }

    /// The server trims, then requires 1–64 characters.
    static func displayNameProblem(_ value: String) -> String? {
        let count = value.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        if count < displayNameLength.lowerBound { return "Display name is required." }
        if count > displayNameLength.upperBound { return "Display name must be at most 64 characters." }
        return nil
    }
}
