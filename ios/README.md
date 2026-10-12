# MedPrep for iOS

Native UIKit/WKWebView port of the Android Moodle wrapper. Requires iOS 16+
and Xcode 16+ on macOS. Android sources and the supplied plugin archive remain
unchanged; the updated plugin is in `Plugin/source/devicelock`.

## Build and sign

1. Open `MedPrep.xcodeproj`. Choose your Apple Developer team for **both targets**.
   Register the explicit `com.med.prep` bundle ID, or change the bundle ID in
   Xcode and the backend together. Enable App Attest in the provisioning profile.
2. Keep the team, bundle ID and Keychain access group stable across updates.
   Never put an Apple `.p8` private key or a server credential in the app.
3. Debug uses the **development** App Attest environment; Release uses
   **production**. Test Debug against a separate staging Moodle installation
   configured for development. TestFlight and App Store use production.
4. Launch on a physical device **without an attached debugger**. The shared Run
   scheme disables debugger attachment. Simulator access is intentionally blocked.
5. Opt out of Mac and Apple Vision Pro availability in App Store Connect.
   Runtime/build restrictions do not change that account setting.
6. Archive the Release scheme, then use Xcode Organizer to validate and distribute.

Command-line checks on macOS:

```sh
xcodebuild -project MedPrep.xcodeproj -scheme MedPrep \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MedPrep.xcodeproj -scheme MedPrep \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The simulator can run routing unit tests despite the app's device gate. It cannot
prove App Attest/DeviceCheck or capture behavior. There is no security bypass
switch. The Linux workspace has neither Xcode nor Apple's SDK: the iOS target
has not been compiled or run here.

## Install the updated server plugin

Back up Moodle's database and existing `auth/devicelock` directory. Install
`Plugin/LockGuard_v3_11_1_apple.zip` through your normal Moodle plugin upgrade
process, or replace the plugin directory with `Plugin/source/devicelock` and run
Moodle's upgrade. This extension is marked beta until Apple/Moodle integration is verified.
The current plugin version is `2026101406` (the identity schema was introduced in `2026101402`); the
`auth_devicelock_ios_state` table does not rewrite existing device registrations.

Configure **each allowed Moodle site**, including those supplied by the site
switcher. Each origin has its own App Attest key and verification cookie.
Append this configuration to Moodle's server-side `config.php` before its final
`require_once`. Store the referenced files outside the web root:

```php
$CFG->auth_devicelock_ios = [
    'team_id' => 'YOUR_APPLE_TEAM_ID',
    'bundle_id' => 'com.med.prep',
    'devicecheck_key_id' => 'YOUR_DEVICECHECK_KEY_ID',
    'devicecheck_private_key' => '/secure/apple/AuthKey_YOUR_KEY_ID.p8',
    'app_attest_root_ca' => '/secure/apple/Apple_App_Attestation_Root_CA.pem',
    'development' => false,
];
// Keep disabled until physical-device capture tests pass for each exact version.
$CFG->auth_devicelock_ios_capture = [
    'enabled' => false,
    'reviewed_os_versions' => [],
    'minimum_build' => 11,
];
```

Download Apple's App Attestation root CA from Apple's certificate authority
site, through a trusted connection. Do not substitute a root supplied by a
client. Obtain a DeviceCheck-enabled private key from your Apple Developer
account. Restrict its filesystem permissions to the Moodle service account.
The server needs PHP OpenSSL, outbound HTTPS access to Apple's DeviceCheck API,
a correct clock and working Moodle distributed locks. Validate the vendor/team
and environment on the staging server before production enrollment.

Keep LockGuard enabled, the app-only restriction enabled, and its configured
UA marker matching the existing `MedoPrepo2121` marker. The native iOS marker is
`MedPrepIOS/1`. iOS markers and legacy app keys **alone do not authenticate this
client**; the server requires a proof-derived, expiring session token. Existing
Android/Windows authentication contracts are retained. Attested iOS clients do
not load LockGuard's browser canvas/audio fingerprint collector. Device
registration now serializes account device-count checks and rejects blocked
matches; unregistered native sessions cannot bypass a failed registration.

Rollback: restore the backed-up plugin **and database together**. Keep a backup
of Apple key records; losing them requires device recovery. Never downgrade the
plugin files while leaving the database/version in a newer state.

## Features and themes

- Moodle sign-in, sessions, course content and server themes remain in WKWebView.
- The original offline animated splash, logo, dark palette, starry/hills backdrop,
  denied/connection illustrations and two-cube loading animation are included.
- Branded, scrollable error/security cards support Dynamic Type and VoiceOver;
  animations respect Reduce Motion. Native iOS pull-to-refresh replaces the
  Android refresh gesture chrome.
- HTTPS site switching, validated cached host lists and the last selected site.
  Removed sites return to the main site after the list refreshes.
- Back/forward swipe, in-app trusted popups, external mail/phone/message links,
  JavaScript alerts/confirmations/prompts inside the protected content layer and
  native upload pickers. Copy, drag, sharing, printing and downloads/exports are
  disabled for protected content. Camera/microphone web capture is denied. Native attachment
  pickers may request camera/photo/microphone access only after the user chooses
  that attachment source.
- WebKit's inline media playback retains Moodle cookies. Scripts disable fullscreen
  requests and remote playback; native behavior must be tested on physical devices.
  Backgrounding, debugger detection or capture pauses playback; resuming never
  automatically restarts the media. AirPlay, picture-in-picture and WebView
  inspection are disabled.
- OS-delivered MetricKit crash diagnostics produce a one-time previous-crash
  notice. Delivery can be delayed; this does not intercept Swift fatal errors.
- Security events carry the existing LockGuard wire types and are attributed
  using Moodle cookies and the verified native session. Delivery failures are
  logged, not represented as successfully delivered. Pre-verification failures
  remain local because an unauthenticated event is not trustworthy.

Apple's WebKit controls third-party cookie restrictions; an app cannot turn off
its tracking prevention to reproduce Android's third-party-cookie setting.
YouTube iframe navigation is allowed only on the configured HTTPS embed domains,
while main-frame YouTube links open externally. Test consent/cookie flows on an
actual iPhone and iPad.

## Security guarantees and platform limits

| Android behavior | iOS implementation / limit |
| --- | --- |
| Cleartext denied; default TLS validation | ATS, HTTPS-only trusted origins, platform certificate validation; API redirects refused |
| Secure background/recents preview | Content and presented sheets covered on inactivity; media paused |
| Screen recording / mirroring | Scene capture traits plus legacy screen state checked on activation and change; content hidden, fullscreen playback closed, all WK media suspended |
| Screenshot exclusion | Per-screen content layer marked using secure UITextField canvas layer substitution; setup failure blocks content. Black/logo sibling remains capturable. Undocumented behavior; physical-device validation required |
| Android developer/ADB/wireless-debug settings | No supported API to inspect iOS Developer Mode or those Android settings. Attached debugger is detected through Darwin process state |
| Platform checks | Simulator, iOS-on-Mac and Vision idiom denied locally; unsupported/unverified App Attest devices denied server-side |
| Playback-capture opt-out and foreign microphone scan | No general public iOS equivalent. Capture detection suspends playback; audio interruptions pause it. Cannot detect all other apps' microphone use |
| Microphone lock | Not implemented: Android currently has `REQUIRE_MIC_PERMISSION = false`; iOS cannot reserve all microphones against other apps |
| Native voice-route player | WebKit native playback plus suspension; no false claim of an iOS voice-route audio-capture block |
| App integrity | Apple-root chain, certificate nonce, app ID, environment/AAGUID, credential/public key and monotonic assertion-counter validation |
| App-only device identity | Server-owned fingerprint from the verified App Attest key; legacy browser tokens and fuzzy hardware matches cannot impersonate Apple registrations |

TLS requires both platform certificate validation and a matching leaf SPKI pin.
Each requested HTTPS hostname must have at least two distinct SHA-256 SPKI pins
(current and backup) in `Info.plist`'s `NSPinnedDomains`. The four supplied Moodle hostnames now contain the user-supplied current leaf
pins and the generated backup public-key pin from `public-pins.json`. Live trust
and backup-certificate validation remain required. Additional embed/resource
hosts need their own pins. External third-party embeds may require
additional resource/CDN hosts and can remain unavailable under strict pinning.

Capture callbacks can race the first captured frame. Inactivity callbacks and
covering native fullscreen presentations require physical-device tests. No
client-side mechanism guarantees protection against jailbreaks, external cameras
or room microphones. Downloads/exports and external content navigation are now disabled. Attachment
pickers and OS keyboards remain outside the content layer.

For actual screenshot-resistant protected video, a separate FairPlay Streaming
content/license pipeline is required. It does not protect ordinary Moodle HTML.
Android's programmatic Close App button is replaced by standard iOS Home/app
switcher behavior.

### Additional secure-canvas exclusion

The sensitive content container, including inline JavaScript dialogs, is marked
using a private secure UITextField canvas and temporary layer substitution. This
is an independent implementation of the per-layer technique reviewed in
[Telegram's UIKitRuntimeUtils](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIKitUtils.m).
The field is not inserted into the view hierarchy; the UIWindow is never
reparented. Setup happens after screen appearance/transitions, and on activation.
The black background and branding logo are outside the protected layer.

UIKit does not document this as capture exclusion for arbitrary views. Successful
setup is not evidence that captured pixels were excluded. OS updates can retain
the private view and change behavior. The server's exact reviewed-version allowlist
is empty/disabled by default; see [SECURITY-REPORT.md](SECURITY-REPORT.md) for setup,
remaining requirements and device acceptance tests. OS/build values are signed
app claims, not independently Apple-certified OS measurements.

Capture detection also runs on appearance, activation, notification and a
0.5-second foreground timer. Any external display is treated as capture. Active
capture refuses navigation and device authorization, pauses media and shows an
opaque black/logo cover. Suspension is reasserted every foreground poll while
capture remains active, and on disappearance. Screen state belongs to the
window scene; a missing window is treated as unsafe. Screenshots are reported after capture with 0.5-second
deduplication; no screenshot callback can prevent the image that triggered it.
Both screenshot and active recording events purge native content and invalidate
access locally. Authenticated reports revoke only the reporting native bearer on
the server, before telemetry throttling. Stopped-recording reports do not revoke
replacement sessions. A new proof is required before content can return.
Verification completing after capture cannot revive the invalidated page.
Network failure can prevent remote revocation; local access stays withheld and
the unrevoked server bearer expires within its original five-minute lifetime.
The secure visual layer does not prevent system audio capture. Apple documents
that even FairPlay video exclusion does not exclude audio; see
[QA1970](https://developer.apple.com/library/archive/qa/qa1970/_index.html).
The 0.5-second timer is not a maximum audio-leak duration: OS notifications,
main-thread scheduling and asynchronous WebKit suspension can add delay.

Native keyboards and attachment sheets are outside the protected content layer.
Fullscreen requests are disabled by injected script, but WebKit/native video
behavior still requires device verification. Capture detection covers presented
surfaces during recording and inactivity, with possible callback delay. Captures
of these surfaces are not guaranteed safe. No FairPlay pipeline is installed.

The original Android/Windows UA/shared-key authentication remains weaker than
Apple proofs. A spoofed legacy marker can still satisfy the existing legacy
app-only policy, although it cannot select an Apple device registration. A
whole-platform authenticity guarantee requires migrating those clients to their
own server-verified attestation protocol too.

## Identity lifecycle and privacy

| Signal | What survives / what it means |
| --- | --- |
| IDFV | Usually survives OS/app updates. Can change after all apps from the vendor are removed. Can temporarily be nil |
| Keychain UUID | Device-only, non-synchronizing Keychain item; normally survives app/OS updates and may survive reinstall. Not guaranteed after erase, restore, signing/access-group changes or policy changes |
| DeviceCheck | Fresh opaque token validated by Apple on the server; two vendor-wide bits are read, never changed. **Not a unique device ID** and never an automatic merge key |
| App Attest | Hardware-backed per-install, per-origin key. Normal updates retain it; reinstall can invalidate it. New key means a new server device |

The configured HTTPS Moodle origin is bound into the proof to prevent cross-site
proof transplantation. Signals are collected before sign-in and included in the bytes covered by the
Apple proof. The server stores hashed IDFV/UUID, the public key, receipt, counter
and DeviceCheck metadata; DeviceCheck tokens are not retained. Identity is keyed
by the App Attest key, **never automatically merged using user-claimed UUID or
IDFV**. OS/model/version changes therefore do not change a healthy registration.
A changed corroborating UUID/IDFV does not remap an existing verified key.

If Apple reports an invalid key/input (including interrupted enrollment), the client creates one replacement key and
retries once. Existing device-count limits may then require an administrator to
reset the account's device registration. Do not bypass that limit or silently
claim two installations are the same physical device. No guaranteed immutable
physical identifier is available to ordinary iOS apps after an erase/reinstall.

The device-ID collection, UserDefaults reason and within-app monotonic timer
reason are declared in
`PrivacyInfo.xcprivacy`. Moodle's full personal-data collection and actual upload
features must also match your published privacy policy and App Store privacy
answers. The plugin privacy provider exports linked Apple metadata and deletes
unshared keys during account erasure. Challenges expire after 120 seconds,
verified sessions after five minutes (renewed with fresh Apple proof without
reloading a healthy foreground page at four minutes); expired ephemeral rows are cleaned when a new
challenge is issued. Public keys remain to preserve registrations; protect and
back up this database as account-associated pseudonymous data.

## Validation status and release proof

Linux checks:

```sh
php -d open_basedir=/srv/MedPrep:/tmp ../Plugin/tests/apple_attest_test.php
php -d open_basedir=/srv/MedPrep:/tmp ../Plugin/tests/ios_identity_test.php
php -d open_basedir=/srv/MedPrep:/tmp ../Plugin/tests/ios_capture_policy_test.php
php -d open_basedir=/srv/MedPrep:/tmp ../Plugin/tests/ios_request_gate_test.php
```

Synthetic certificates exercise chain trust, app/key/environment binding, nonce
tampering, forged assertions, counter replay and malformed CBOR. In-memory
Moodle doubles exercise session authentication, reserved Apple fingerprints,
existing-device block preservation, challenge consumption and rate limiting.
Capture-policy tests cover strict reviewed-version/build checks and immediate
revocation. Isolated bootstrap tests cover fail-closed Moodle PHP/file request
gating, database errors and the public-bootstrap boundary. These do **not** replace real Apple evidence, Moodle database/upgrade tests or
multi-process lock tests. The verifier needs independent security review and
real App Attest/DeviceCheck fixtures before production use.

On staging, prove at least:

1. Fresh physical-device enrollment and subsequent assertion; DeviceCheck errors
   and unavailable verification must keep content blocked. Verify the first-time
   DeviceCheck bit-state response for your Apple environment.
2. Wrong app/team/environment, forged chain, changed client claims, repeated
   nonce, reused counter, unknown/expired cookie and copied browser fingerprints
   are rejected. Two simultaneous assertions cannot roll the stored counter back.
3. Existing student device limits, administrator bans/device blocks, logout,
   password reset, browser reset and privacy export/erase still work.
4. App/OS update retains identity. Reinstall/recovery produces the documented
   new-key behavior; no automatic account/device merge occurs.
5. Recorder already active before launch, recorder started during playback,
   mirroring, fullscreen/iframe audio, screenshots, Control Center, app switcher,
   phone interruptions and capture stop/recovery.
6. Upload/chooser cancellation, denied downloads/exports, redirects, trusted popups,
   JavaScript dialogs, external links, dynamic sites, offline retry, login/theme
   switching, landscape, iPad, large text and VoiceOver. Upload form state must
   survive leaving/returning to the app; foreground re-verification does not
   reload an already loaded healthy page.

Run `scripts/verify-release.sh /path/to/MedPrep.app` on the signed Release app.
The audit refuses debugger-enabled signing, non-production App Attest, missing
pins and bundled private keys/source/dSYM. Keep dSYM privately outside the app
for crash symbolication. No signed IPA or production deployment has been produced
in this workspace.

Apple reference documentation: [App Attest server validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server),
[DeviceCheck server API](https://developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data),
and [Apple certificate authority](https://www.apple.com/certificateauthority/).
