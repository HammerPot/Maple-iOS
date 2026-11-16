import Foundation
import UIKit
import AuthenticationServices
import BetterAuth
import BetterAuthPasskey

/// Uses Apple's native ceremony and BetterAuthSwift's typed options/verification routes.
/// Stock convenience methods use api.maple.music as rpID; Maple's actual rpID is maple.music.
@MainActor
final class MaplePasskeyCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func register(client: BetterAuthClient, name: String?) async throws {
        let options = try await client.passkey.generateRegisterOptions(with: .init(name: name, authenticatorAttachment: .platform)).data
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rp.id ?? "maple.music")
        let request = provider.createCredentialRegistrationRequest(challenge: try decode(options.challenge), name: options.user.name, userID: try decode(options.user.id))
        request.displayName = options.user.displayName
        if let excluded = options.excludeCredentials {
            request.excludedCredentials = try excluded.map { .init(credentialID: try decode($0.id)) }
        }
        let result = try await perform(request)
        guard let credential = result.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else { throw URLError(.cannotParseResponse) }
        let id = encode(credential.credentialID)
        _ = try await client.passkey.verifyRegistration(with: .init(response: .init(id: id, rawId: id,
            response: .init(clientDataJSON: encode(credential.rawClientDataJSON), attestationObject: credential.rawAttestationObject.map(encode)),
            authenticatorAttachment: .platform, clientExtensionResults: .init(), type: .publicKey), name: name))
    }
    func signIn(client: BetterAuthClient) async throws {
        let options = try await client.passkey.generateAuthenticateOptions().data
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId ?? "maple.music")
        let request = provider.createCredentialAssertionRequest(challenge: try decode(options.challenge))
        if let allowed = options.allowCredentials { request.allowedCredentials = try allowed.map { .init(credentialID: try decode($0.id)) } }
        let result = try await perform(request)
        guard let credential = result.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw URLError(.cannotParseResponse) }
        let id = encode(credential.credentialID)
        _ = try await client.passkey.verifyAuthentication(with: .init(response: .init(id: id, rawId: id,
            response: .init(clientDataJSON: encode(credential.rawClientDataJSON), authenticatorData: encode(credential.rawAuthenticatorData), signature: encode(credential.signature), userHandle: encode(credential.userID)),
            authenticatorAttachment: .platform, clientExtensionResults: .init(), type: .publicKey)))
    }
    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self; controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.controller?.cancel() } }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let pending = continuation; continuation = nil; self.controller = nil; pending?.resume(returning: authorization)
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let pending = continuation; continuation = nil; self.controller = nil; pending?.resume(throwing: (error as? ASAuthorizationError)?.code == .canceled ? CancellationError() : error)
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func decode(_ text: String) throws -> Data {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { throw URLError(.cannotDecodeContentData) }
        return data
    }
    private func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
