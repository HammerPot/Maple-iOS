# Maple 5 foundation

The app keeps iOS 18 deployment and Swift 5 language mode. Sources and resource catalogs live in the synchronized `Maple/` group; new Swift files need no project-file entries. Existing library JSON and media locations are unchanged.

## Layout

- `App/`: `MapleApp`, `AppServices`, existing `ContentView`.
- `Core/API/`: transport, typed REST routes, Codable wire models, upload validation, errors.
- `Core/Auth/`: observable session, BetterAuthSwift adapter, Keychain storage, native passkey ceremony.
- `Core/Realtime/`: socket transport/events, playback reporter, observable friends.
- `Core/Support/`: existing opt-in webhook support.
- `DesignSystem/`: artwork/avatar views, transient banner, duration and relative-time formatting.
- `Features/{Account,Friends,Library,Player,AppleMusic,Search,Settings}/`: screens and existing feature code.
- `Resources/`: both asset catalogs and Icon Composer app icon.

## Feature-facing services

All UI-facing models are `@MainActor @Observable`. Obtain them through SwiftUI `@Environment(Type.self)`. `AppServices` owns one instance of each core service, injects them, and binds the existing singleton players to the reporter. Feature agents can replace those legacy players without changing the network layer.

| Type | Surface |
| --- | --- |
| `AppServices` | Composition root: `api`, `http`, `auth`, `friends`, `realtime`, `playback`, `toasts`; `syncSocket()` applies the existing socket setting immediately. |
| `AuthSessionModel` | `state` (`signedOut`, `needsEmailVerification`, `signedIn(MapleUser)`), `user`, `isRestoring`, `needsLegacyEnrollment`; async `restore`, `refresh`, `signIn(identifier:password:)`, `signUp`, `resendVerification`, `enrollLegacy`, password-reset/email/password changes, session listing/revocation, account listing, sign-out/deletion, passkey register/sign-in/list/delete/rename. |
| `MapleAPI` | Async `me`, `friends`, `requests`, public profile lookup by username/ID, avatar/artwork bytes, display name/listening visibility changes, avatar/album art upload, all friend request/friend mutation routes, account deletion. |
| `MapleHTTP` | Shared ephemeral URLSession and Keychain-backed cookie jar; Origin on every request; `request`, `raw`, `image`, `sessionCookies`. |
| `MapleError` | HTTP `status`, optional server `code`, `error`, `message`, `LocalizedError` text; `normalize` adapts library errors. |
| `MapleUser`, `Profile`, `ListeningProfile` | Typed user/profile response shapes. `profile.label` falls back to the username when the display name is absent. |
| `Listening`, `CurrentPlayback`, `LastPlayed`, `FriendRequests` | Current/previous listening and incoming/outgoing request snapshots; private listening decodes as nil. |
| `FriendsModel` | Observable `friends`, `requests`, `lastEvent`; refresh, send by username, accept, decline/cancel, remove. Applies realtime listening and friendship updates. |
| `MapleRealtime` | Authenticated Socket.IO transport, connection state, typed ownership/listening/friendship/RPC callbacks; revalidates sessions after terminal connection failures/server disconnects (the native SDK calls a server disconnect `Got Disconnect`). |
| `PlaybackReporter` | `update(TrackSnapshot, artwork: Data?, force: Bool)`, `sendUpdate()`, `stop()`, `snapshotProvider`; observable playback ID and ownership. New track identity claims; state changes do not reclaim lost ownership. `force: true` reports explicit seeks of any size. |
| `TrackSnapshot` | Player-neutral identity/title/artist/album/duration/playing/position/rate. Prefix identity with the player source; seconds are finite and clamped to the server limits. |
| `PlaybackTransport` | Injectable socket boundary for reporter tests (`connected`, async typed send/ack). |
| `ToastCenter` | `show(Error)` / `show(String)`; one transient native material banner. |
| `ArtworkView`, `AvatarView` | Remote/local artwork and authenticated avatar requests with SF Symbol fallbacks; images are decorative for accessibility. |
| `MapleFormat` | Safe duration strings and localized relative times. |

## Auth/package decisions

BetterAuthSwift **2.1.0** is adopted (`BetterAuth`, `BetterAuthUsername`, `BetterAuthPasskey`). Evaluated source at tag v2.1.0 / d7bbc6c. Adaptations are deliberate:

- Its stock middleware does not run on every route. `BetterAuthHTTP` sends all SDK calls through `MapleHTTP`, setting Maple's required Origin regardless of route.
- The library cookie filter requires a `/` URL path; the API base is canonicalized with a trailing slash so Socket.IO receives root-path session cookies. A unit test covers this.
- Stock `getCookie()` only recognizes `better-auth.session_token`. The app reads the actual `__Secure-maple.session_token` from the library cookie jar for Socket.IO instead. No token/cookie goes into UserDefaults.
- The cookie store accepts a `StorageProtocol`; `MapleKeychainStorage` supplies an app-specific Keychain service with add/update semantics and AfterFirstUnlockThisDeviceOnly accessibility. The library cookie store serializes persistence and filters expiry.
- Maple-specific legacy enrollment uses the shared transport directly. Typed app errors retain HTTP status and server code.
- SDK date decoding is replaced with a decoder accepting fractional and nonfractional ISO dates.
- SDK passkey convenience methods incorrectly use the API host as rpID and UTF-8 encode base64url credential identifiers. `MaplePasskeyCeremony` uses AuthenticationServices, the server's rpID/options and decoded credential IDs, then the SDK's typed verification/management endpoints.

Alamofire and SwiftyJSON are removed. Socket.IO is pinned exactly to **16.1.1** instead of master. Other existing packages are retained. Lockfile is updated. The `webcredentials:maple.music` associated-domain entitlement is enabled and compiles for the designated simulator; physical-device provisioning has not been tested.

## Playback behavior and migration

Starts generate a UUID, require a successful acknowledgment and matching ownership broadcast, then start a 25-second heartbeat (90-second server lease). Pause/resume, explicit seeks, rate/duration changes and RPC-setting changes send updates. Heartbeats sample the active player afresh. Stop emits the active playback ID and clears local ownership. Rejected updates, ownership loss and disconnect release reporting. Reconnect does not steal back a previous playback; a track loaded while awaiting the initial connection can start once connected. Cover writes are serialized and guarded by current playback ID, with the server providing the final ownership check.

Both legacy players feed this API. Apple Music also polls SystemMusicPlayer state once per second to catch changes that its legacy notification layer misses. Existing `mapleRPC`, `socketIO`, `musicKit`, `webhookURL` preferences remain; the configured local-player webhook is sent once per acknowledged track. Stale `savedCookies` and `savedServerID` are removed: a pre-5.0 installation signs in again. New secure sessions survive relaunch. Library persistence files are untouched by this implementation.

Email verification/reset complete in the browser because Maple only permits trusted web callback URLs. Return to the app and sign in again. Passkey end-to-end verification remains blocked by upstream's missing AASA file (and possibly native-origin allowlisting). Passwords are not retained to implement background sign-in retries.

## Verification

Remote host: M1 iMac, Xcode 26.0.1; only the designated SweetPad Maple Test simulator was selected. Xcode's initial default parallel test cloning failed before assertions; subsequent test runs disable parallel device cloning.

- App/test compilation succeeds with the associated-domain entitlement. Incremental app build: zero errors, 14 existing feature warnings (an earlier full test build had 52 existing feature warnings). No new core warnings were observed.
- Final full scheme test run on the committed implementation: **19 passed, zero failed, zero skipped**, `data.passed: true` (16 Swift Testing unit tests and 3 existing UI tests).
- Separate final unit run including route encoding and secure root-cookie regression: 16 passed, zero failed, `data.passed: true`.
- Test account signs in through the simulator app. Friends screen contains the owner's account. Relaunch restores the signed-in profile from Keychain. App sign-out returns to the login form; the simulator is left signed out.
- A generated 180-second silent WAV was seeded into the designated simulator's existing `Documents/tracks` format because it had no music. No library implementation was changed.
- With the existing socket setting enabled in Settings, `/get/me` reported `Maple Foundation Check` / `Maple Test` / `Foundation Verification`, duration 180, playing true, rate 1, advancing position. The app received a successful start acknowledgment and matching ownership broadcast. Pausing changed the server's current playback to playing false at position 63.956 seconds.
- Pressing Stop changed `/get/me.listening.current` to null while retaining the fixture in lastPlayed.
- Every temporary REST verification session was signed out in a finally block. No production accounts, passwords, email addresses, or friendships were deleted/changed.

## Limits for subsequent feature agents

- Passkeys are implemented client-side but cannot be verified end to end until upstream deploys the AASA entry for this app and confirms native WebAuthn origins. Only simulator signing/building of the entitlement was verified.
- Apple Music reporting compiles and is connected to SystemMusicPlayer state. Actual subscription playback cannot be exercised on this simulator, whose MusicKit authorization is not determined. Keep the player-neutral snapshot interface when replacing the legacy player.
- Account security methods are exposed in the core; the retained basic account screens do not present session management, email/password changes, passkey management, or listening visibility UI. Those belong to the next account feature agent.
- Dangerous account deletion, password/email changes, and friendship removal were not exercised against production. No registration was attempted because creating production test accounts was prohibited.
- SwiftPM and the existing legacy feature code still use ObservableObject, deprecated APIs and print statements. Newly written core/UI models use Observation, async/await and Logger. Library data code was only moved.
- The library cookie store logs persistence failures and keeps the in-memory session usable. On a Keychain write failure, persistence can be retried on the next cookie mutation. The OSStatus is preserved by the app's storage error and no cookie value is logged by new code.
- No discrepancy with the supplied API contract was found. The native Socket.IO SDK's server disconnect reason is `Got Disconnect`, unlike the web client's `io server disconnect` string; the adapter handles both.

## Implementation references

- Supplied Maple API 5.0 contract and upstream web auth, UserManager, socketManager and playback implementations.
- BetterAuthSwift v2.1.0 source, including HTTPClientProtocol, CookieStorage/StorageProtocol and passkey models/ceremony.
- Better Auth passkey 1.7.13 source, checked against the SDK's verification response shapes.
- SweetPad remote/build skills for synchronization, diagnostics and test result interpretation.
- Swift concurrency/testing/SwiftUI skills; Swift security references `keychain-fundamentals.md` and `credential-storage-patterns.md` for Keychain add/update, accessibility and error semantics.
