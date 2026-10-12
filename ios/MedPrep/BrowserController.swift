import UIKit
import WebKit
import AVFoundation

// Android's Moodle content and themes remain server-owned. Native chrome uses
// the Android brand palette; the offline animated splash is shared verbatim.
enum Theme {
    static let background = UIColor(red: 30/255, green: 33/255, blue: 36/255, alpha: 1)
    static let card = UIColor(red: 47/255, green: 49/255, blue: 54/255, alpha: 1)
    static let orange = UIColor(red: 249/255, green: 128/255, blue: 18/255, alpha: 1)
}

@MainActor final class BrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let sites = SiteRegistry()
    private let identity = DeviceIdentity()
    private var web: WKWebView!
    private var splash: WKWebView?
    private let privacyCover = UIView()
    private let captureContainer = CaptureProtectedContentView()
    private var monitor: Timer?
    private var verifiedAt = -Double.infinity
    private let shield = UIView()
    private let panel = UIStackView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retry = UIButton(type: .system)
    private let progress = CubeSpinnerView(frame: .zero)
    private let illustration = UIImageView()
    private var progressObservation: NSKeyValueObservation?
    private var verification: Task<Void, Never>?
    private var contentOrigin: String?
    private var desiredURL: URL?
    private var failure: String?
    private var lastReports: [String: TimeInterval] = [:]
    private var mediaSuspended = false
    private var audioIsInterrupted = false
    private var lastGateIssue: String?
    private var active = false
    private var visible = false
    private var splashComplete = false
    private var verifying = false
    private var renewing = false
    private var awaitingPage = false
    private var awaitingNavigation: WKNavigation?
    private var lastScreenshotAt = -Double.infinity
    private var lastCaptureState = false
    private var policyRefresh: Task<Void, Never>?
    private var lastPolicyAttempt = -Double.infinity
    private var inlineDialog: UIView?
    private var dismissDialog: (() -> Void)?
    private var purging = false
    private var loggingOut = false
    private var captureEpoch = 0
    private var lastCaptureEvent = "screen_recording_detected"
    private var captureSession: (token: String, origin: URL)?

    private static let contentRestrictions = """
    (() => {
      const style = document.createElement('style');
      style.textContent = '*{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important}input,textarea,[contenteditable=true]{-webkit-user-select:text!important;user-select:text!important}';
      const prepare = () => {
        if (!style.isConnected && document.documentElement) document.documentElement.appendChild(style);
        document.querySelectorAll('input,textarea').forEach(e => {
          e.setAttribute('autocomplete','off'); e.setAttribute('autocorrect','off');
          e.setAttribute('autocapitalize','off'); e.setAttribute('spellcheck','false');
        });
        document.querySelectorAll('video').forEach(e => {
          e.setAttribute('playsinline',''); e.setAttribute('webkit-playsinline','');
          e.setAttribute('controlsList','nodownload nofullscreen noremoteplayback');
          e.disablePictureInPicture = true; e.disableRemotePlayback = true;
        });
      };
      ['copy','cut','contextmenu','dragstart'].forEach(name => document.addEventListener(name, e => e.preventDefault(), true));
      document.addEventListener('click', e => {
        const a = e.target.closest && e.target.closest('a[download]');
        if (a) { e.preventDefault(); e.stopImmediatePropagation(); }
      }, true);
      window.print = () => {};
      if (navigator.clipboard) {
        ['write','writeText'].forEach(k => {
          try { Object.defineProperty(navigator.clipboard,k,{value:() => Promise.reject(new Error('Copying disabled'))}); } catch (_) {}
        });
      }
      if (navigator.share) { try { Object.defineProperty(navigator,'share',{value:() => Promise.reject(new Error('Sharing disabled'))}); } catch (_) {} }
      [Element.prototype, HTMLVideoElement.prototype].forEach(p => {
        ['requestFullscreen','webkitRequestFullscreen','webkitEnterFullscreen','webkitEnterFullScreen'].forEach(k => {
          try { Object.defineProperty(p,k,{value:() => Promise.reject(new Error('Fullscreen disabled'))}); } catch (_) {}
        });
      });
      document.addEventListener('fullscreenchange', () => { if (document.fullscreenElement) document.exitFullscreen(); });
      document.addEventListener('DOMContentLoaded', prepare);
      new MutationObserver(prepare).observe(document,{childList:true,subtree:true}); prepare();
    })();
    """

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let captureLogo = UIImageView(image: UIImage(named: "app_logo"))
        captureLogo.contentMode = .scaleAspectFit
        captureLogo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureLogo)
        NSLayoutConstraint.activate([captureLogo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureLogo.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            captureLogo.widthAnchor.constraint(equalToConstant: 96),
            captureLogo.heightAnchor.constraint(equalToConstant: 96)])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = AppConfig.marker + " MedPrepIOS/1"
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: Self.contentRestrictions,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = ProtectedWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) { web.isInspectable = false }
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false; web.backgroundColor = Theme.background
        web.translatesAutoresizingMaskIntoConstraints = false
        captureContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureContainer)
        NSLayoutConstraint.activate([
            captureContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            captureContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            captureContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captureContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        // Never fall back to displaying Moodle outside the secure canvas.
        captureContainer.install(web)
        let refresh = UIRefreshControl()
        refresh.tintColor = Theme.orange
        refresh.addTarget(self, action: #selector(reloadPage), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.scrollView.dragInteractionEnabled = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 56), progress.heightAnchor.constraint(equalToConstant: 56)])
        progressObservation = web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress.isHidden = self.web.estimatedProgress >= 1
            }
        }
        buildShield()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                if self.lastGateIssue != nil && SecurityGate.issue == nil && !self.verifying {
                    self.authorize(self.desiredURL ?? self.web.url ?? self.sites.start)
                    return
                }
                if self.identity.token != nil && CACurrentMediaTime() - self.verifiedAt >= 300 {
                    self.renewing = false
                    if !self.verifying {
                        self.purgeContent()
                        self.failure = "Device verification expired. Connect to the internet and retry."
                    }
                }
                self.refreshCaptureState()
                self.refreshPolicyIfNeeded()
                self.renderShield()
                if SecurityGate.issue == nil && !self.captured && !self.verifying &&
                    self.identity.token != nil && CACurrentMediaTime() - self.verifiedAt > 240 {
                    self.authorize(self.desiredURL ?? self.web.url ?? self.sites.start, renewing: true)
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(captureChanged), name: UIScreen.capturedDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenshot), name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureChanged), name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureChanged), name: UIScreen.didDisconnectNotification, object: nil)
        if #available(iOS 18.0, *) {
            registerForTraitChanges([UITraitSceneCaptureState.self]) { (controller: BrowserController, _: UITraitCollection) in
                controller.captureChanged()
            }
        }
        showSplash()
        renderShield()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        pauseMedia(force: true)
        dismissDialog?(); UIPasteboard.general.items = []
        renderShield()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        // Mark only this sensitive screen after UIKit's transition completes.
        captureContainer.applyProtection()
        refreshCaptureState()
        renderShield()
    }
    private func buildShield() {
        shield.backgroundColor = Theme.background
        shield.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shield)
        NSLayoutConstraint.activate([shield.topAnchor.constraint(equalTo: view.topAnchor), shield.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shield.leadingAnchor.constraint(equalTo: view.leadingAnchor), shield.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        let backdropConfig = WKWebViewConfiguration()
        backdropConfig.websiteDataStore = .nonPersistent()
        backdropConfig.defaultWebpagePreferences.allowsContentJavaScript = false
        let backdrop = WKWebView(frame: .zero, configuration: backdropConfig)
        backdrop.isOpaque = false; backdrop.backgroundColor = Theme.background
        backdrop.isUserInteractionEnabled = false; backdrop.isAccessibilityElement = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(backdrop)
        NSLayoutConstraint.activate([backdrop.topAnchor.constraint(equalTo: shield.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: shield.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: shield.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: shield.trailingAnchor)])
        if let url = Bundle.main.url(forResource: "backdrop", withExtension: "html", subdirectory: "Branding") {
            backdrop.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(scroll)
        let content = UIView(); content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let preferredHeight = content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: shield.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: shield.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: shield.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: shield.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor), preferredHeight])
        panel.axis = .vertical; panel.spacing = 20; panel.alignment = .fill
        panel.backgroundColor = Theme.card; panel.layer.cornerRadius = 20
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 24, bottom: 28, trailing: 24)
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        NSLayoutConstraint.activate([panel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            panel.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24)])
        let logo = UIImageView(image: UIImage(named: "app_logo"))
        logo.contentMode = .scaleAspectFit; logo.heightAnchor.constraint(equalToConstant: 72).isActive = true
        panel.addArrangedSubview(logo)
        let brand = UILabel(); brand.text = "MedPrep"; brand.textColor = .white
        brand.font = .preferredFont(forTextStyle: .headline); brand.adjustsFontForContentSizeCategory = true
        brand.textAlignment = .center; panel.addArrangedSubview(brand)
        illustration.image = UIImage(named: "Branding/denied")
        illustration.contentMode = .scaleAspectFit
        illustration.heightAnchor.constraint(equalToConstant: 120).isActive = true
        panel.addArrangedSubview(illustration)
        titleLabel.font = .preferredFont(forTextStyle: .title1); titleLabel.textColor = .white
        titleLabel.adjustsFontForContentSizeCategory = true; titleLabel.numberOfLines = 0; titleLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body); messageLabel.textColor = .lightGray
        messageLabel.adjustsFontForContentSizeCategory = true; messageLabel.numberOfLines = 0
        panel.addArrangedSubview(titleLabel); panel.addArrangedSubview(messageLabel)
        retry.setTitle("Retry", for: .normal); retry.tintColor = Theme.orange
        retry.addTarget(self, action: #selector(retryVerification), for: .touchUpInside)
        panel.addArrangedSubview(retry)
        let privacy = UIButton(type: .system)
        privacy.setTitle("Privacy Policy", for: .normal); privacy.tintColor = .lightGray
        privacy.addTarget(self, action: #selector(openPrivacy), for: .touchUpInside)
        panel.addArrangedSubview(privacy)
    }
    private func showSplash() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "splash") else { splashComplete = true; return }
        let intro = WKWebView(frame: view.bounds)
        intro.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        intro.isOpaque = false; intro.backgroundColor = Theme.background
        intro.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        intro.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(endSplash)))
        splash = intro; view.addSubview(intro)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) { [weak self] in self?.endSplash() }
    }
    @objc private func endSplash() {
        splash?.removeFromSuperview(); splash = nil; splashComplete = true; renderShield()
    }
    private var captured: Bool {
        if UIScreen.screens.count > 1 { return true }
        if #available(iOS 18.0, *), traitCollection.sceneCaptureState == .active { return true }
        // An unattached view has no trustworthy screen state; keep content withheld.
        guard let screen = view.window?.windowScene?.screen else { return true }
        return screen.isCaptured
    }
    private func renderShield() {
        let gateIssue = SecurityGate.issue
        if active, let gateIssue, gateIssue != lastGateIssue { report("debugger_detected", gateIssue) }
        if gateIssue != nil && lastGateIssue == nil { purgeContent() }
        lastGateIssue = gateIssue
        let captureUnavailable = !captureContainer.containsProtected(web)
        let blocked = captureUnavailable || !active || !visible || captured || (verifying && !renewing) || awaitingPage || identity.token == nil || !identity.policyCurrent || purging || failure != nil || gateIssue != nil
        if blocked { dismissDialog?() }
        shield.isHidden = !blocked
        illustration.image = UIImage(named: failure != nil && identity.token != nil ? "Branding/connection" : "Branding/denied")
        web.isHidden = blocked
        if captureUnavailable { titleLabel.text = "Access Denied"; messageLabel.text = "Screen capture protection is unavailable on this iOS version." }
        else if let issue = gateIssue { titleLabel.text = "Access Denied"; messageLabel.text = issue }
        else if !identity.policyCurrent { titleLabel.text = "Access Denied"; messageLabel.text = "This iOS version or app build is not approved for protected content." }
        else if !active { titleLabel.text = "MedPrep"; messageLabel.text = "Content hidden while the app is inactive." }
        else if captured { titleLabel.text = "Access Denied"; messageLabel.text = "Stop screen recording or mirroring to continue." }
        else if verifying { titleLabel.text = "Verifying Device"; messageLabel.text = "Checking Apple device and app integrity…" }
        else if awaitingPage && failure == nil { titleLabel.text = "Loading MedPrep"; messageLabel.text = "Connecting to your site…" }
        else { titleLabel.text = failure != nil && identity.token != nil ? "Connection Lost" : "Access Denied"; messageLabel.text = failure ?? "Device verification is required." }
        retry.isHidden = verifying || awaitingPage || !active || captured
        if blocked || audioIsInterrupted { pauseMedia() }
        else if mediaSuspended {
            mediaSuspended = false
            web.setAllMediaPlaybackSuspended(false, completionHandler: {})
        }
        if (!active || captured || (verifying && !renewing) || gateIssue != nil), let window = view.window {
            privacyCover.frame = window.bounds
            privacyCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            privacyCover.backgroundColor = .black
            if privacyCover.subviews.isEmpty {
                let logo = UIImageView(image: UIImage(named: "app_logo"))
                logo.contentMode = .scaleAspectFit; logo.translatesAutoresizingMaskIntoConstraints = false
                privacyCover.addSubview(logo)
                NSLayoutConstraint.activate([logo.centerXAnchor.constraint(equalTo: privacyCover.centerXAnchor),
                    logo.centerYAnchor.constraint(equalTo: privacyCover.centerYAnchor),
                    logo.widthAnchor.constraint(equalToConstant: 96), logo.heightAnchor.constraint(equalToConstant: 96)])
            }
            // Only cover presented sheets; the root shield already explains the block.
            // Inactivity also requires a window-wide snapshot cover before UIKit snapshots.
            if !active || captured || presentedViewController != nil { window.addSubview(privacyCover) }
            else { privacyCover.removeFromSuperview() }
        } else { privacyCover.removeFromSuperview() }
        if !splashComplete, let splash { view.bringSubviewToFront(splash) }
        if !blocked, splashComplete, presentedViewController == nil, let notice = CrashDiagnostics.shared.takeNotice() {
            let alert = UIAlertController(title: "Previous crash", message: notice, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
    private func pauseMedia(force: Bool = false) {
        guard force || !mediaSuspended else { return }
        mediaSuspended = true
        web?.closeAllMediaPresentations(completionHandler: {})
        web?.pauseAllMediaPlayback(completionHandler: {})
        web?.setAllMediaPlaybackSuspended(true, completionHandler: {})
    }
    func resign() {
        active = false
        view.endEditing(true)
        dismissDialog?()
        UIPasteboard.general.items = []
        // Finish an in-flight enrollment instead of losing a one-use Apple
        // attestation. Completion cannot reveal content while inactive.
        identity.invalidate()
        renderShield()
    }
    func activate() {
        active = true
        captureContainer.applyProtection()
        refreshCaptureState()
        if verifying { renderShield(); return }
        authorize(desiredURL ?? web.url ?? sites.start)
    }
    @objc private func captureChanged() { refreshCaptureState() }
    private func refreshCaptureState() {
        let state = captured
        if state != lastCaptureState {
            lastCaptureState = state
            if state {
                captureViolation("screen_recording_detected", "Capture or external display active; playback stopped and native session invalidated.")
            } else {
                if active && !verifying { authorize(desiredURL ?? web.url ?? sites.start, reload: true) }
            }
        }
        // Reassert suspension while capture is active, even after a WebKit/media
        // process change. The poll interval is not a guaranteed audio-stop bound.
        if state { pauseMedia(force: true) }
        renderShield()
    }
    private func captureViolation(_ type: String, _ details: String) {
        captureEpoch += 1; lastCaptureEvent = type
        view.endEditing(true); dismissDialog?(); web?.stopLoading(); pauseMedia(force: true)
        // report snapshots the old bearer before local purge. The server revokes
        // only that bearer, leaving device registrations and accounts untouched.
        if let session = captureSession {
            submitReport(type, details, token: session.token, base: session.origin, captureState: true)
        } else { report(type, details, captureActive: true) }
        purgeContent()
        failure = "Capture detected. Stop recording or mirroring, then retry device verification."
        renderShield()
    }
    @objc private func screenshot() {
        let now = CACurrentMediaTime()
        guard now - lastScreenshotAt >= 0.5 else { return }
        lastScreenshotAt = now
        captureViolation("screenshot_attempt", "Screenshot notification received after capture; native session invalidated. Pixel exclusion outcome is not established by this notification.")
    }
    private func refreshPolicyIfNeeded() {
        guard active, policyRefresh == nil, let origin = identity.origin,
              CACurrentMediaTime() - lastPolicyAttempt >= 30 else { return }
        lastPolicyAttempt = CACurrentMediaTime()
        let policyToken = identity.token
        policyRefresh = Task { [weak self] in
            guard let self else { return }
            defer { self.policyRefresh = nil }
            do { try await self.identity.refreshPolicy(origin: origin) }
            catch {
                guard self.identity.token == policyToken, self.identity.origin == origin else { return }
                self.identity.invalidatePolicy()
            }
            guard self.identity.token == policyToken, self.identity.origin == origin else { return }
            if !self.identity.policyCurrent { self.purgeContent() }
            self.renderShield()
        }
    }
    private func purgeContent() {
        guard !purging else { return }
        purging = true
        web?.stopLoading(); pauseMedia(); dismissDialog?()
        identity.invalidate(); captureSession = nil; contentOrigin = nil; awaitingPage = false; awaitingNavigation = nil
        desiredURL = sites.start
        UIPasteboard.general.items = []
        web?.loadHTMLString("", baseURL: nil)
        let store = web.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor [weak self] in self?.purging = false; self?.renderShield() }
        }
    }
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        audioIsInterrupted = type == .began
        renderShield()
    }
    @objc private func openPrivacy() { UIApplication.shared.open(AppConfig.privacy) }
    @objc private func retryVerification() { authorize(desiredURL ?? web.url ?? sites.start, reload: true) }
    @objc private func reloadPage() {
        guard active, !captured, identity.token != nil else { web.scrollView.refreshControl?.endRefreshing(); return }
        failure = nil; web.reload()
    }
    private func origin(_ url: URL) -> String {
        "https://" + (url.host?.lowercased() ?? "")
    }
    private func authorize(_ url: URL, reload: Bool = false, renewing: Bool = false) {
        guard active, !captured, !purging, captureContainer.containsProtected(web), SecurityGate.issue == nil else { renderShield(); return }
        verification?.cancel()
        let authorizationEpoch = captureEpoch
        let previousOrigin = contentOrigin
        let previousKey = identity.signals?.appAttestKeyID
        let isRenewal = renewing && identity.token != nil && contentOrigin == origin(url)
        self.renewing = isRenewal
        if !isRenewal { identity.invalidate() }
        let needsLoad = reload || failure != nil || web.url != url
        desiredURL = url; verifying = true; failure = nil; renderShield()
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                await self.sites.refresh()
                let target = self.sites.allows(url) ? url : self.sites.start
                if isRenewal && self.origin(target) != self.contentOrigin {
                    self.renewing = false; self.identity.invalidate(); self.renderShield()
                }
                let identityOrigin = URL(string: self.origin(target))!
                let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                    self.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
                }
                try await self.identity.verify(origin: identityOrigin,
                    cookieHeader: Network.cookieHeader(cookies, for: identityOrigin.appendingPathComponent(AppConfig.identityPath)))
                try Task.checkCancellation()
                if self.captured || self.captureEpoch != authorizationEpoch {
                    // A proof can finish after the capture callback purged its
                    // predecessor. Revoke the freshly issued bearer too; it must
                    // never revive the page invalidated by that capture event.
                    self.verifying = false; self.renewing = false
                    if let issuedToken = self.identity.token {
                        self.submitReport(self.lastCaptureEvent, "Capture occurred during device verification; newly issued native session withheld.",
                            token: issuedToken, base: identityOrigin, captureState: true)
                    }
                    self.purgeContent(); self.renderShield()
                    return
                }
                guard self.active, SecurityGate.issue == nil, let token = self.identity.token else {
                    self.verifying = false; self.renewing = false; self.identity.invalidate(); self.renderShield()
                    return
                }
                // Retain only in memory for capture revocation if scene resignation
                // invalidates the access gate before capture starts in the background.
                self.captureSession = (token, identityOrigin)
                let nativeCookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie":
                    "MedPrepIOS=\(token); Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax"], for: target)
                guard let cookie = nativeCookies.first, cookie.isSecure, cookie.isHTTPOnly else {
                    throw URLError(.cannotParseResponse)
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
                }
                try Task.checkCancellation()
                if self.captured || self.captureEpoch != authorizationEpoch {
                    self.verifying = false; self.renewing = false
                    self.submitReport(self.lastCaptureEvent, "Capture occurred while propagating verification cookie; native session withheld.",
                        token: token, base: identityOrigin, captureState: true)
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.web.configuration.websiteDataStore.httpCookieStore.delete(cookie) { continuation.resume() }
                    }
                    self.purgeContent(); self.renderShield()
                    return
                }
                guard self.active, SecurityGate.issue == nil else {
                    self.verifying = false; self.renewing = false; self.identity.invalidate(); self.renderShield()
                    return
                }
                let changedOrigin = previousOrigin != self.origin(target)
                let changedKey = previousKey != nil && previousKey != self.identity.signals?.appAttestKeyID
                let shouldLoad = changedOrigin || changedKey || (!isRenewal && (needsLoad || self.web.url != target))
                self.contentOrigin = self.origin(target)
                if !isRenewal || changedOrigin { self.desiredURL = target }
                self.verifying = false; self.renewing = false; self.verifiedAt = CACurrentMediaTime()
                if self.captured {
                    self.captureViolation("screen_recording_detected", "Screen recording or mirroring became active during device verification; native session withheld.")
                } else if shouldLoad {
                    // A new key/origin must pass Moodle account/device authorization
                    // before cached HTML becomes visible. Never reuse a cached login
                    // response from a different installation or a restored backup.
                    self.web.stopLoading(); self.awaitingPage = true; self.renderShield()
                    self.awaitingNavigation = self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
                    if self.awaitingNavigation == nil { self.loadFailed("The page could not start. Retry to reconnect.") }
                } else {
                    self.renderShield(); self.shareDownloadIfSafe()
                }
            } catch is CancellationError { /* Inactive or superseded verification cannot reveal content. */ }
            catch {
                guard !Task.isCancelled else { return }
                self.verifying = false; self.renewing = false; self.purgeContent()
                self.failure = "Device verification failed. Check your connection or contact support. \(error.localizedDescription)"
                self.renderShield()
            }
        }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if PinnedTrust.accepts(challenge), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if purging && url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        let main = action.targetFrame?.isMainFrame ?? true
        guard active, !captured, !purging, identity.policyCurrent, (!verifying || renewing), SecurityGate.issue == nil, identity.token != nil else { decisionHandler(.cancel); return }
        if main, let host = url.host, sites.trusts(host: host), !sites.allows(url) {
            decisionHandler(.cancel)
            loadFailed("This site's address is not allowed. Use HTTPS on the standard port without embedded credentials.")
            return
        }
        if sites.allows(url) {
            if main && contentOrigin != origin(url) { decisionHandler(.cancel); authorize(url); return }
            if main { sites.remember(url); desiredURL = url }
            if action.shouldPerformDownload { decisionHandler(.cancel); return }
            if main && url.path == "/login/logout.php" {
                loggingOut = true
                UIPasteboard.general.items = []
                web.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache,
                    WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeIndexedDBDatabases], modifiedSince: .distantPast, completionHandler: {})
            }
            decisionHandler(.allow)
        } else if !main && sites.embedded(url) { decisionHandler(.allow) }
        else if !main && ["about", "blob", "data"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else {
            decisionHandler(.cancel)
            if main { openExternal(url, userInitiated: action.navigationType == .linkActivated) }
        }
    }
    private func openExternal(_ url: URL, userInitiated: Bool) {
        let scheme = url.scheme?.lowercased() ?? ""
        if userInitiated && ["mailto", "tel", "sms", "facetime", "facetime-audio"].contains(scheme) {
            UIApplication.shared.open(url)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, active, !captured, identity.policyCurrent, identity.token != nil {
            if sites.allows(url) || ["about", "blob", "data"].contains(url.scheme ?? "") { web.load(action.request) }
            else { openExternal(url, userInitiated: action.navigationType == .linkActivated) }
        }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = response.response.url, sites.allows(url) || ["about", "blob", "data"].contains(url.scheme ?? "") || (!response.isForMainFrame && sites.embedded(url)) else {
            decisionHandler(.cancel); return
        }
        guard active, !captured, !purging, identity.policyCurrent, (!verifying || renewing), SecurityGate.issue == nil else { decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, response.isForMainFrame,
           [401, 403].contains(http.statusCode) { purgeContent(); decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, response.isForMainFrame, http.statusCode >= 400 {
            decisionHandler(.cancel); loadFailed("The server returned HTTP \(http.statusCode)."); return
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(!response.canShowMIMEType || attachment ? .cancel : .allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loggingOut { loggingOut = false; purgeContent(); return }
        web.scrollView.refreshControl?.endRefreshing()
        if awaitingPage && navigation === awaitingNavigation {
            awaitingPage = false; awaitingNavigation = nil
            renderShield(); shareDownloadIfSafe()
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed(error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed(error.localizedDescription) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadFailed("The page stopped unexpectedly. Retry to reload it.") }
    private func loadFailed(_ message: String) {
        awaitingPage = false; awaitingNavigation = nil
        failure = message; web.scrollView.refreshControl?.endRefreshing(); renderShield()
        titleLabel.text = "Connection Lost"
        illustration.image = UIImage(named: "Branding/connection")
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    private func showProtectedDialog(message: String, defaultText: String? = nil,
                                     input: Bool = false, canCancel: Bool,
                                     completion: @escaping (Bool, String?) -> Void) {
        guard active, !captured, identity.policyCurrent, captureContainer.containsProtected(web),
              inlineDialog == nil, shield.isHidden else { completion(false, nil); return }
        let overlay = UIView(); overlay.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        captureContainer.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.topAnchor.constraint(equalTo: captureContainer.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: captureContainer.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: captureContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: captureContainer.trailingAnchor)])
        let box = UIStackView(); box.axis = .vertical; box.spacing = 16
        box.backgroundColor = Theme.card; box.layer.cornerRadius = 16
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        box.translatesAutoresizingMaskIntoConstraints = false; overlay.addSubview(box)
        NSLayoutConstraint.activate([box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            box.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            box.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24)])
        let label = UILabel(); label.text = message; label.numberOfLines = 0
        label.textColor = .white; label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true; box.addArrangedSubview(label)
        let field = ProtectedTextField()
        if input {
            field.text = defaultText; field.textColor = .white; field.borderStyle = .roundedRect
            field.autocorrectionType = .no; field.spellCheckingType = .no
            field.autocapitalizationType = .none; field.textContentType = .none
            box.addArrangedSubview(field)
        }
        inlineDialog = overlay
        let finish: (Bool) -> Void = { [weak self, weak field, weak overlay] accepted in
            guard let self, let overlay, self.inlineDialog === overlay else { return }
            self.dismissDialog = nil; self.inlineDialog = nil
            overlay.endEditing(true); overlay.removeFromSuperview()
            completion(accepted, accepted && input ? field?.text : nil)
        }
        dismissDialog = { finish(false) }
        if canCancel {
            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.addAction(UIAction { _ in finish(false) }, for: .touchUpInside)
            box.addArrangedSubview(cancel)
        }
        let ok = UIButton(type: .system); ok.setTitle("OK", for: .normal); ok.tintColor = Theme.orange
        ok.addAction(UIAction { _ in finish(true) }, for: .touchUpInside); box.addArrangedSubview(ok)
        UIAccessibility.post(notification: .screenChanged, argument: label)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showProtectedDialog(message: message, canCancel: false) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        showProtectedDialog(message: message, canCancel: true) { accepted, _ in completionHandler(accepted) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        showProtectedDialog(message: prompt, defaultText: defaultText, input: true, canCancel: true) { _, value in completionHandler(value) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel(completionHandler: { _ in }) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel(completionHandler: { _ in }) }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) { completionHandler(nil) }
    private func shareDownloadIfSafe() { /* Protected content exports are intentionally disabled. */ }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) { completionHandler(nil) }
    private func report(_ type: String, _ details: String, captureActive: Bool? = nil) {
        let key = type + details
        let now = CACurrentMediaTime()
        let isCapture = type == "screenshot_attempt" || type == "screen_recording_detected"
        // Never suppress revocation of a newly issued bearer with telemetry throttling.
        if !isCapture {
            if let last = lastReports[key], now - last < 3 { return }
            lastReports[key] = now
        }
        guard let token = identity.token, let base = identity.origin,
              contentOrigin == origin(base) else { return }
        submitReport(type, details, token: token, base: base, captureState: captureActive ?? captured)
    }
    private func submitReport(_ type: String, _ details: String, token: String, base: URL, captureState: Bool) {
        guard sites.allows(base) else { return }
        let deviceDescription = "iOS [\(identity.signals?.appAttestKeyID.prefix(12) ?? "unknown")]"
        Task {
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            var request = URLRequest(url: base.appendingPathComponent(AppConfig.reportPath))
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppConfig.marker + " MedPrepIOS/1", forHTTPHeaderField: "User-Agent")
            if let header = Network.cookieHeader(cookies, for: request.url!) {
                request.setValue(header, forHTTPHeaderField: "Cookie")
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": type, "details": details,
                "device": deviceDescription, "capture_active": captureState, "app_version": AppConfig.version,
                "ts": Int(Date().timeIntervalSince1970)])
            do {
                let (_, response) = try await Network.session.data(for: request)
                #if DEBUG
                if (response as? HTTPURLResponse)?.statusCode != 200 { NSLog("Security report rejected") }
                #endif
            } catch {
                #if DEBUG
                NSLog("Security report delivery failed")
                #endif
            }
        }
    }
    deinit { monitor?.invalidate(); NotificationCenter.default.removeObserver(self) }
}


// Best-effort capture exclusion using UIKit's secure-text rendering canvas.
// This is undocumented for arbitrary views, not an Apple security guarantee.
// Keep view/layer ownership aligned; never reparent UIWindow's CALayer.
@MainActor private final class CaptureProtectedContentView: UIView {
    private(set) var protectionReady = false
    func install(_ content: UIView) {
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    func applyProtection() { protectionReady = MedPrepProtectLayer(layer) }
    func containsProtected(_ content: UIView) -> Bool {
        protectionReady && content.superview === self
    }
}

// Editing remains available for forms, but content cannot enter the copy/share menu.
@MainActor private final class ProtectedWebView: WKWebView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}


@MainActor private final class ProtectedTextField: UITextField {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
