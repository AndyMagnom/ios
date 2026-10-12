# Capture protection implementation and release report

## Outcome

The source now implements layered capture protection and a server-operated,
fail-closed release policy. It is not a verified production release. No Xcode,
Apple SDK, physical iPhone/iPad, Apple credentials, live TLS certificate access or running Moodle
integration were available here. A successful UIKit operation is not proof that
screenshots or recording frames omitted the content. Do not advertise guaranteed
prevention before device tests, and do not treat those tests as a guarantee against
compromised devices or external cameras.

## Research

Reviewed the actual [Telegram per-layer implementation](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIKitUtils.m)
and [capture detection implementation](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/ScreenCaptureDetection/Sources/ScreenCaptureDetection.swift).
Telegram temporarily substitutes the secure canvas layer, toggles secure text
entry, then restores the original layer. Its missing-canvas branch does not prove
protection. The implementation here returns a failure instead of silently
allowing content, catches Objective-C exceptions and restores the original layer.
It is independently implemented; no Telegram dependency or source bundle was copied.

Apple documents [isSecureTextEntry](https://developer.apple.com/documentation/uikit/uitextinputtraits/issecuretextentry)
for text input, not arbitrary content capture exclusion. Review the
[Apple forum discussion](https://developer.apple.com/forums/thread/719978) and
[reported iOS 17 breakage](https://developer.apple.com/forums/thread/736112).
The private structure and inferred compositor behavior can change. App Review
acceptance remains unresolved. There is no claim that this is the only possible
non-DRM technique or that Telegram's behavior establishes this app's behavior.

Apple also documents [SPKI pinning](https://developer.apple.com/news/?id=g9ejcf8y),
[App Attest validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server),
[Mac availability controls](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon),
and [Vision Pro availability controls](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-apple-vision-pro/).
Moodle's [after_config hook](https://github.com/moodle/moodle/blob/MOODLE_500_STABLE/lib/classes/hook/after_config.php)
runs after session initialization and covers PHP requests that never render a page.

## Implemented changes

| Requirement | Implementation | Verification/limit |
| --- | --- | --- |
| Per-screen secure layer | Marks only the content container using temporary secure-canvas layer substitution; no UIWindow reparenting or hidden text field in the live hierarchy | Setup failure blocks content; physical compositor behavior untested |
| Black background and logo in captures | Normal black root with logo beneath protected content; black/logo privacy cover | Actual screenshot/video appearance untested |
| Safe lifecycle attachment | Setup after view appearance, with reapplication on activation; no navigation push transitions exist in this wrapper | UIKit transitions and keyboard interaction need device tests |
| Capture detection | Scene capture trait, screen notifications, appearance/activation checks and 0.5-second foreground polling | Reaction can race initial frames |
| Capture already running | Refuses authorization/navigation, stops loading and media, shows opaque cover | Detection depends on OS-reported capture state |
| Screenshot forensics | After-capture reporting with 0.5-second duplicate suppression | Does not inspect screenshot pixels or claim successful exclusion |
| Background snapshots | Window-level opaque cover on scene resignation, removed when safe | Inspect actual SplashBoard snapshots on devices |
| External screens | Any additional UIScreen blocks content, with connect/disconnect observation | Wireless/USB/HDMI/mirroring tests required |
| Sensitive JavaScript dialogs | Inline dialogs inside the protected content container | Native keyboard/attachment picker remains outside |
| Copy/selection/drag | Content CSS, cancel copy/cut/drag/context-menu events, native action/context-menu rejection, drag disabled | Input selection remains available for editing; page scripts and accessibility are not a DRM boundary |
| Clipboard | JS clipboard writes blocked where redefinable; app never writes course data; pasteboard cleared on inactivity, disappearance, logout and purge | Clearing removes the user's existing clipboard contents too; compromised/page code can evade UI restrictions |
| Share/print/export | Download policy denied, downloads cancelled, no share sheet, JS share/print suppression, external content links not opened | Forms/uploads retained; server-side export features require separate Moodle policy |
| Device storage | Nonpersistent WK store, ephemeral URLSession with no URLCache, device-only WhenUnlocked Keychain, no offline content bundle/cache | WebKit/OS temporary storage still requires forensic inspection; no encrypted offline feature is offered |
| Purge | Clears WebKit website data, cookies, page and pasteboard on policy failure, integrity failure, protected-page 401/403 and logout completion | Loaded non-DRM media/OS-managed attachment data may persist outside app control |
| Logs/diagnostics | Release-native delivery logs removed; crash notice stores timestamp only | Moodle's existing server activity/audit logging is retained |
| OS kill switch | Exact server-reviewed OS versions and minimum build, disabled/empty by default; server rechecks existing sessions; client polls at 30 seconds and expires policy after 60 seconds | OS/build are proof-bound app claims, not independently Apple-certified measurements; downloaded pixels cannot be remotely erased instantly |
| Platform restrictions | Simulator/Mac/Vision idiom gates, build destination restrictions | App Store Connect opt-out is still an account action |
| Integrity checks | Jailbreak paths, sandbox write probe, suspicious loaded libraries/environment, package-manager URL checks, Darwin debugger state | All local checks are bypassable and can produce false positives |
| App Attest/DeviceCheck | Existing server chain/nonce/app/environment/key/counter checks retained; device identity proof now covers OS/build too | Real Apple fixtures and independent review still required |
| Native request policy | Moodle after_config hook checks the verified session, current capture policy and restricted account/device state for PHP/AJAX/file requests | Static/CDN delivery and spoofable legacy Android/Windows paths remain separate boundaries |
| Account/device revocation | Sessions bind to Moodle-authenticated user, not a client user claim; bound bearer checks account suspension/deletion and device removal/block; polling purges native data after rejection | Up to poll delay for already displayed content; Moodle integration untested |
| Short-lived access | Five-minute native bearer; new Apple proof at four minutes; old key sessions retired on verification | No reusable refresh token is used; stolen bearer remains a bearer during its short lifetime |
| TLS and pinning | Default TLS/hostname/CA validation plus exact leaf SPKI hash; requires distinct current/backup pins; URLSession and WK auth challenges gated; ATS pinned-domain entries | Supplied pins installed for all four Moodle hosts; live/backup certificate and resource-host validation still required |
| Release hardening | Release stripping flags, production App Attest, signed-app audit script rejecting get-task-allow and bundled keys/source/dSYM | Signing/audit not run here; dSYM retained privately for crash symbolication |

## Configuration still required

The user supplied these Moodle origins:

- `https://new.medpreparation.com/` (main/junior)
- `https://med.medpreparation.com/` (senior)
- `https://test.medpreparation.com/`
- `https://moodle.cooky.theworkpc.com/`

They seed the initial trusted site list. Subsequent validated site-list responses
can remove non-main sites. All four now have the supplied current leaf SPKI pins
and the supplied backup public-key pin, stored in `public-pins.json` and installed
in Info.plist. Shared CA/intermediate hashes from the supplied chain output were
not included. DNS/TLS retrieval failed here, so current certificates were not
independently checked against these values. The backup key is staged for future
rotation; no replacement certificate deployment was shown.

The same generated backup key is accepted for each hostname, but a replacement
leaf certificate must still pass normal hostname, CA and expiry validation. Keep
its private key in protected operator/server storage, outside this repository and
the app. Provision appropriate certificates and test rotation before switching
production keys. No controlled CDN/media hosts were identified.

For each current and replacement public PEM certificate, run:

```sh
ios/scripts/spki-pin.sh /path/to/public-certificate.pem
```

For a PEM public key instead of a certificate:

```sh
openssl pkey -pubin -in /path/to/public-key.pem -outform DER | openssl dgst -sha256 -binary | openssl base64 -A
```

Create a JSON map from each exact hostname to its current/backup base64 pins;
include all four Moodle hosts plus every approved content/resource host. Run:

```sh
python3 ios/scripts/configure-pins.py /path/to/reviewed-public-pins.json
```

Ship new backup pins before switching server keys. Retain old pins during rollout
until old app versions are retired. Do not add public shared intermediate CA pins
as a substitute for a controlled backup leaf key. Test both permitted certificates,
wrong-host/expired/untrusted certificates and an unrelated valid certificate.

Install `Plugin/LockGuard_v3_10_3_ios.zip` on staging after backup. Supply Apple
configuration as documented in README. Add the server capture policy:

```php
$CFG->auth_devicelock_ios_capture = [
    'enabled' => false,
    'reviewed_os_versions' => [],
    'minimum_build' => 11,
];
```

Only after tests pass, enable and add exact tested `major.minor.patch` strings.
Remove a version or set `enabled` false if capture behavior regresses. Existing
sessions are denied on their next server request. Apply the configuration to each
Moodle site. Policy is anonymous metadata; authenticated polls additionally
validate the bearer and its server-bound Moodle account.

## Requested work not completed by this source change

| Item | Why it remains |
| --- | --- |
| App Attest assertion on every sensitive subresource request | WKWebView owns HTML/image/media/AJAX requests; session gating is implemented, not per-resource assertions. This needs a controlled content gateway/native request pipeline and Moodle resource integration, not just a navigation delegate header |
| Device/user-bound 30–60-second signed URLs, CDN token auth and IP reuse rejection | No CDN/media configuration or controlled delivery service supplied. Existing Moodle permissions remain; no signed delivery pipeline is claimed. IP binding also needs a mobile-network change policy |
| Small-piece course delivery, AES-128 HLS and authenticated key server | Requires changing Moodle's content delivery/media packaging. This wrapper still receives ordinary Moodle pages/media; non-DRM keys/pixels are extractable on compromised devices |
| FairPlay protected video | No content packaging, license server or Apple FairPlay credentials supplied |
| Encrypted offline AES-GCM cache/Enclave key wrapping | Offline caching is disabled rather than adding an unused cache/key system |
| ptrace, self-binary hash, general hook-proof signing checks and obfuscation | Not claimed. Platform signing and App Attest are used; local heuristics do not establish a clean device. Commercial runtime protection requires a chosen licensed vendor/build pipeline |
| Mac/Vision App Store availability | Runtime/build refusal is implemented; App Store Connect must also opt out |
| Verified capture prevention, live deployment, signing and App Review | Requires macOS/Xcode, physical-device evidence, server credentials and actual review. None performed here |

## Device acceptance checklist

Keep the allowlist disabled until each supported physical device/OS combination
passes. Review actual saved media, not just callbacks or a setup-success Boolean.

| Test | Required evidence | Result |
| --- | --- | --- |
| Hardware and AssistiveTouch screenshots of courses, images, forms and dialogs | Sensitive pixels absent; intended black/logo background visible | Pending |
| Recording before launch, during navigation and while playing inline video/audio | No sensitive frames; content loading/playback refused during reported capture | Pending |
| Mirroring, AirPlay, wired external display | Content withheld on detection and capture output inspected | Pending |
| Control Center, notification pull, app switcher and incoming calls | Window snapshots contain only privacy branding; inspect stored snapshots | Pending |
| Keyboard, camera/photo/file picker, autofill, VoiceOver, rotation and iPad | Usability retained; no course-data leakage through native surfaces | Pending |
| Fullscreen/PiP/AirPlay controls on all media types | Fullscreen/remote escapes blocked or unsafe media refused | Pending |
| Logout, blocked/removed device, suspended/deleted account, policy removal, offline polling | Access denied and website data cleared; previously loaded pixels withheld | Pending |
| New install, app update, OS patch update, key replacement and WebKit restart | Correct identity lifecycle and reviewed-version fail-closed behavior | Pending |
| Current/backup/wrong/untrusted TLS key and every resource hostname | Allowed pins work; all invalid trust/pin cases fail | Pending |
| Release artifact | Run verify-release.sh; confirm production attestation and account availability opt-outs | Pending |

## Automated evidence

The standalone PHP cryptographic, identity, capture-policy and isolated bootstrap
suites are executable without Apple/Moodle production credentials. They use
synthetic certificates and database/process doubles. Native XCTest coverage adds
policy and pin-parser cases (including synthetic RSA/EC OpenSSL fixtures), but cannot run in this Linux workspace. These tests
are not proof of real UIKit compositor behavior or distributed Moodle locking.

Latest local results: 101 PHP checks passed (20 cryptographic/parser, 48 identity/
enforcement, 23 capture policy, 10 bootstrap gate); all 46 plugin PHP files lint
clean. Pin tools matched OpenSSL for synthetic RSA and EC certificates, rejected
missing/duplicate/malformed pin maps without changing configuration, and installed
valid maps in an isolated fixture. Native project/plist/XML integration and shell/
Python script syntax checks passed. Native XCTest, Xcode compilation, signing,
real Apple fixtures, real Moodle concurrency and device capture tests remain unrun.
Immediate bearer retirement during renewal may reject in-flight requests using
the old cookie before the new cookie propagates; verify renewal behavior on staging.


## Telegram audio follow-up

Verified the current [ChatController capture handler](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Sources/ChatController.swift):
it reacts to capture by pausing view-once voice playback. Line numbers changed
from the supplied reference. [Apple QA1970](https://developer.apple.com/library/archive/qa/qa1970/_index.html)
explicitly distinguishes FairPlay video exclusion from audio capture. Neither
our secure visual layer nor FairPlay establishes system audio exclusion.

The app now reads its own window-scene screen, treats an unattached view as
unsafe, and reasserts WebKit media suspension on every 0.5-second foreground
poll while captured. It also suspends playback when the controller disappears.
Appearance/activation checks, recording notifications and separate screenshot
notifications remain in place. No redundant global-screen KVO dependency was
added to the existing scene/notification path.

Screenshot and active recording events immediately purge local content and
invalidate native access. The report snapshots the relevant bearer before purge;
the last verified bearer is retained only in memory for revocation when capture
starts after scene resignation. The server revokes only that bearer, before
telemetry throttling/logging, and attributes events using the server-bound user
where available. A stopped-recording event cannot revoke a replacement bearer.
No permanent device/account ban or guaranteed remote logout is introduced.

An event generation counter prevents an in-flight verification response or
asynchronous cookie propagation from restoring content after a capture event.
Freshly issued affected bearers are reported for revocation too; stale cookies
are explicitly deleted after propagation. These native race guards have only
structural verification here. Server tests cover capture start/stop, strict Boolean
validation, unrelated events, duplicate revocation, replacement-bearer isolation,
screenshot revocation and lock release. Real Moodle concurrency remains untested.

A remote revocation requires successful authenticated report delivery. On failure,
local content remains withheld but the server bearer retains its original expiry
(up to five minutes). The 0.5-second polling interval is not a hard upper bound on
audio captured before suspension. Scheduling and asynchronous WebKit/OS behavior
can increase latency. Measure HTML audio/video, iframe media and Web Audio on
physical devices; no guarantee of zero captured audio is made.
