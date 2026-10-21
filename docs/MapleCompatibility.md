# Maple networking and RPC compatibility

The iOS client follows upstream Maple commit [`e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2`](https://github.com/cattn/maple/tree/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2), checked on October 21, 2026. The API remains `https://api.maple.music`. The existing iOS 18 deployment target and Swift 5 language mode are retained; verification uses Xcode 26.0.1 / Swift 6.2.

## REST and authentication

`MapleAPI` shares a cookie-enabled URLSession with a 15-second request timeout. Every REST operation validates HTTP status before decoding success data, and preserves server JSON error messages. Plain-text authorization errors, throttling, and missing optional profile pictures are handled explicitly. Each path component is encoded independently.

Login uses the secure `token` cookie returned by `/login`. Stored cookies are restored before the UI and socket start; expired cookies are skipped and their Secure attribute is retained. Login and session restoration connect realtime features only when enabled. Socket managers are rebuilt with current, API-scoped cookies rather than a cookie snapshot captured before login.

Logout calls `/get/logout/:id`, which disconnects the account's server-side sockets, then clears local Maple cookies and the saved user ID even if the network request fails. Account deletion only clears the local session after the server confirms success. Profile, artwork, friend, and account routes retain the upstream methods and multipart field names.

Contract sources: [authentication](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/api/auth/login.js), [session routes](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/api/get/get.js), [profile/artwork routes](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/api/user/manageUser.js).

## Playback and RPC

The client requests `rpcOwnership` with `rpcOwnershipRequest`, waits for its generation token, and fences every `playbackState` report with that token. Play, resume, seek, and settings changes can claim ownership. A token broadcast from a different owner updates the token without automatically reclaiming playback; a confirmed handoff to this client resamples the current player.

Playback reports include `playing`, `discord`, `position`, optional `duration`, and a positive `playbackRate`. Pausing, stopping, finishing, errors, logout, and disabling sharing clear presence. A 15-second heartbeat resamples the active player while Discord sharing and playback are enabled. This refreshes the upstream server's 90-second producer lease. Foregrounding also resamples playback; reconnects request new ownership.

The `nowPlaying` social envelope includes current playback fields, `id`, `source`, and UTC `timePlayed`. Friend requests, accepted requests, and friends' now-playing events update the visible list without restarting. Local and Apple Music players use the same reporting pipeline; a delayed stop from the other player cannot clear the active source.

Each track's cover has its own `artworkRequestId`, `artworkReady`, and bounded `artworkWait`. Multipart uploads carry the same request ID. Writes are serialized, obsolete queued uploads are skipped, and late completions or `albumArtUploaded` events are checked against the current track and account. Playback reporting continues when artwork uploads fail.

Contract sources: [server RPC ownership and leases](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/api/iomanager/rpc.js), [reference web client](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/src/lib/rpc.ts), [social events](https://github.com/cattn/maple/blob/e0ce72d8823c1ddaa98fa5f13b5153c618ac57e2/api/maple.js).

## Running checks

For deterministic networking and ownership regression tests plus the account/settings UI check:

```sh
sweetpad test --scheme Maple --on '<simulator name or UDID>' \
  --only-testing MapleTests \
  --only-testing MapleUITests/MapleNetworkingUITests \
  -o json --non-interactive -- -parallel-testing-enabled NO
```

Add `--remote '<saved Mac name>'` when building from Linux or another machine. Use `sweetpad test build` first after editing tests. This project was verified on the saved M1 iMac connection and its dedicated iOS 26 simulator.

Live tests are opt-in. Supply `MapleLiveTestCredentials.json` as an ignored resource in both `MapleTests` and `MapleUITests`, containing `username` and `password` for a dedicated test account. The tests do not create accounts. They change that account's display name and profile picture, publish test playback, and log out its sockets, so use a test account only. Remove the resource files afterward. The files are never included in the shipping app target.

The October 21 verification passed all 15 selected tests with live testing enabled, including the native audio and simulator UI checks. Temporary credential resources were removed afterward.

The live tests cover login, secure-cookie restoration, authenticated profile/friend reads, profile updates, RPC play/pause/seek/stop, the 15-second heartbeat, artwork request changes/readiness, competing-client ownership, immediate Discord disablement, and logout. They also check native local audio using a generated silent WAV file and exercise login/relaunch/logout through the simulator UI.

Apple Music reporting is compiled and wired to its playback/item notifications and seek controls. Playing subscription content and observing Discord on an actual desktop require the corresponding Apple Music authorization and desktop MapleRPC client; those are separate manual checks. VoiceOver and maximum Dynamic Type remain manual checks for the account/settings flows.
