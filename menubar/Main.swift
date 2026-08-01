import Cocoa
import Carbon.HIToolbox

// MARK: - Model

struct NowPlaying: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let status: String // "playing" | "paused" | "stopped"
    let positionSec: Double
    let durationSec: Double
    let artwork: String? // data URL
    let volume: Int?
    let muted: Bool?
}

// MARK: - Server client

final class RemoteClient {
    /// Discovered via Bonjour; used when no manual address is set.
    var discoveredBaseURL: URL?
    /// Human-readable name of the discovered PC, for the menu.
    var discoveredName: String?

    var manualHost: String? {
        get { UserDefaults.standard.string(forKey: "serverHost") }
        set { UserDefaults.standard.set(newValue, forKey: "serverHost") }
    }

    var baseURL: URL? {
        if let host = manualHost, !host.isEmpty {
            return URL(string: "http://\(host)")
        }
        return discoveredBaseURL
    }

    var sourceDescription: String {
        if let host = manualHost, !host.isEmpty { return "\(host) (manual)" }
        if let name = discoveredName { return "\(name) (auto)" }
        return "searching…"
    }

    func fetchNowPlaying(completion: @escaping (Result<NowPlaying, Error>) -> Void) {
        guard let url = baseURL?.appendingPathComponent("now-playing") else {
            completion(.failure(NSError(domain: "RemoteClient", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "No PC address set"])))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else {
                completion(.failure(NSError(domain: "RemoteClient", code: 2)))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(NowPlaying.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func post(_ path: String, body: [String: Any]? = nil) {
        guard let url = baseURL?.appendingPathComponent(path) else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - Bonjour discovery

/// Browses the LAN for `_amremote._tcp` services published by the Windows server.
final class ServiceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onFound: (_ name: String, _ url: URL) -> Void = { _, _ in }

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_amremote._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Prefer the resolved hostname; fall back to a raw IPv4 address from
        // the service's address records (some advertisers publish a hostname
        // that isn't resolvable).
        var host = sender.hostName
        if host == nil, let addresses = sender.addresses {
            host = firstIPv4Address(in: addresses)
        }
        guard var h = host else { return }
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        if let url = URL(string: "http://\(h):\(sender.port)") {
            onFound(sender.name, url)
        }
    }

    private func firstIPv4Address(in addresses: [Data]) -> String? {
        for data in addresses {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = data.withUnsafeBytes { ptr -> Int32 in
                guard let base = ptr.baseAddress else { return -1 }
                return getnameinfo(base.assumingMemoryBound(to: sockaddr.self),
                                   socklen_t(data.count),
                                   &name, socklen_t(name.count),
                                   nil, 0, NI_NUMERICHOST)
            }
            if err == 0 {
                let s = String(cString: name)
                if s.contains(".") { return s } // IPv4 dotted quad
            }
        }
        return nil
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
}

// MARK: - Global hotkeys

/// System-wide hotkeys via Carbon RegisterEventHotKey — works while any app
/// is focused and needs no accessibility permissions.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var eventHandlerInstalled = false

    /// 'AMRT'
    private static let signature: OSType = 0x414D5254

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        handlers[id] = handler
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            NSLog("RegisterEventHotKey failed for id \(id): \(status)")
        }
        refs.append(ref)
    }

    private func installHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async {
                HotKeyManager.shared.handlers[hotKeyID.id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Media key capture (F7/F8/F9)

/// Intercepts the keyboard's media keys (⏮ ⏯ ⏭) via a CGEventTap and
/// consumes them before macOS routes them to local "Now Playing" apps.
/// Requires Accessibility permission.
final class MediaKeyCapture {
    static let shared = MediaKeyCapture()

    /// Called on the main queue with 16 = play/pause, 17 = next, 18 = previous.
    var onKey: ((Int) -> Void)?

    private(set) var enabled = false
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // NX key codes (NX_KEYTYPE_*). Modern macOS keyboards emit FAST (19)
    // and REWIND (20) for the F9/F7 keys rather than NEXT (17)/PREVIOUS (18),
    // so we accept both pairs.
    static let playPause = 16
    static let next = 17
    static let previous = 18
    static let fastForward = 19
    static let rewind = 20

    // kCGEventSystemDefined — not exposed in Swift's CGEventType enum
    static let systemDefinedType: UInt32 = 14

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { enabled = true; return true }
        let mask = CGEventMask(1 << MediaKeyCapture.systemDefinedType)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: nil
        ) else {
            NSLog("MediaKeyCapture: tapCreate FAILED (no Accessibility permission?)")
            return false // no Accessibility permission
        }
        NSLog("MediaKeyCapture: event tap started")
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        enabled = true
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        enabled = false
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS may disable the tap under load — re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = MediaKeyCapture.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == MediaKeyCapture.systemDefinedType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    let keyState = (data1 & 0x0000_FF00) >> 8 // 0xA = key down, 0xB = key up

    guard keyState == 0xA,
          [MediaKeyCapture.playPause, MediaKeyCapture.next, MediaKeyCapture.previous,
           MediaKeyCapture.fastForward, MediaKeyCapture.rewind].contains(keyCode)
    else {
        return Unmanaged.passUnretained(event)
    }

    DispatchQueue.main.async {
        MediaKeyCapture.shared.onKey?(keyCode)
    }
    return nil // consume the event so macOS doesn't also handle it
}

// MARK: - Design

/// Apple Music–inspired palette and helpers.
private enum Theme {
    /// Apple Music red.
    static let accent = NSColor(calibratedRed: 0.98, green: 0.18, blue: 0.33, alpha: 1)
    static let trackBackground = NSColor.systemGray.withAlphaComponent(0.22)

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

/// Thin, rounded playback progress bar (non-interactive — the server has no
/// seek endpoint, so this only displays position).
private final class ProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 4
        let y = (bounds.height - h) / 2
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: h),
                     xRadius: h / 2, yRadius: h / 2).setClip()
        Theme.trackBackground.setFill()
        bounds.fill()
        let w = max(0, min(1, fraction)) * bounds.width
        if w > 0 {
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: w, height: bounds.height).fill()
        }
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = RemoteClient()
    private let discovery = ServiceDiscovery()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var progressTimer: Timer?
    private var current: NowPlaying?
    private var reachable = false
    private var mediaKeysWanted = true

    // Popover UI
    private let popover = NSPopover()
    private var artworkView: NSImageView!
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var progressBar: ProgressBar!
    private var elapsedLabel: NSTextField!
    private var remainingLabel: NSTextField!
    private var playPauseButton: NSButton!
    private var volumeSlider: NSSlider!
    private var muteButton: NSButton!
    private var statusLabel: NSTextField!

    private var volumeDebounce: Timer?
    private var displayedPosition: Double = 0
    private var displayedDuration: Double = 0
    private var placeholderArtwork: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Theme.symbol("music.note", size: 14, weight: .medium)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
        buildPopover()
        registerHotKeys()
        setupMediaKeyCapture()
        startDiscovery()
        startPolling()
    }

    // MARK: Popover construction

    private func buildPopover() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Artwork with rounded corners and a soft shadow.
        let artworkContainer = NSView()
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.shadowColor = NSColor.black.cgColor
        artworkContainer.layer?.shadowOpacity = 0.28
        artworkContainer.layer?.shadowRadius = 12
        artworkContainer.layer?.shadowOffset = NSSize(width: 0, height: -5)

        artworkView = NSImageView()
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 10
        artworkView.layer?.masksToBounds = true
        artworkView.imageScaling = .scaleAxesIndependently
        artworkContainer.addSubview(artworkView)

        titleLabel = makeLabel(font: .systemFont(ofSize: 13, weight: .semibold),
                               color: .labelColor, alignment: .center)
        artistLabel = makeLabel(font: .systemFont(ofSize: 11, weight: .regular),
                                color: Theme.accent, alignment: .center)

        progressBar = ProgressBar()
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel = makeLabel(font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                 color: .secondaryLabelColor, alignment: .left)
        remainingLabel = makeLabel(font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                   color: .secondaryLabelColor, alignment: .right)

        let prevButton = transportButton("backward.fill", size: 18, action: #selector(onPrevious))
        playPauseButton = transportButton("play.fill", size: 26, action: #selector(onPlayPause))
        let nextButton = transportButton("forward.fill", size: 18, action: #selector(onNext))
        let transport = NSStackView(views: [prevButton, playPauseButton, nextButton])
        transport.orientation = .horizontal
        transport.spacing = 34
        transport.alignment = .centerY
        transport.translatesAutoresizingMaskIntoConstraints = false

        muteButton = NSButton(image: Theme.symbol("speaker.fill", size: 12) ?? NSImage(),
                              target: self, action: #selector(onToggleMute))
        muteButton.isBordered = false
        muteButton.contentTintColor = .secondaryLabelColor
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        volumeSlider = NSSlider()
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.controlSize = .small
        volumeSlider.trackFillColor = Theme.accent
        volumeSlider.target = self
        volumeSlider.action = #selector(onVolumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        let speakerHigh = NSImageView(image: Theme.symbol("speaker.wave.2.fill", size: 12) ?? NSImage())
        speakerHigh.contentTintColor = .secondaryLabelColor
        speakerHigh.translatesAutoresizingMaskIntoConstraints = false

        let volumeRow = NSStackView(views: [muteButton, volumeSlider, speakerHigh])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8
        volumeRow.alignment = .centerY
        volumeRow.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = makeLabel(font: .systemFont(ofSize: 10, weight: .regular),
                                color: .secondaryLabelColor, alignment: .left)
        statusLabel.stringValue = "Searching for PC…"
        // Truncate instead of colliding with the gear button on long names.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let gearButton = NSButton(image: Theme.symbol("gearshape", size: 13) ?? NSImage(),
                                  target: self, action: #selector(showSettings(_:)))
        gearButton.isBordered = false
        gearButton.contentTintColor = .secondaryLabelColor
        gearButton.translatesAutoresizingMaskIntoConstraints = false

        let subviews: [NSView] = [artworkContainer, titleLabel, artistLabel, progressBar,
                                  elapsedLabel, remainingLabel, transport, volumeRow,
                                  separator, statusLabel, gearButton]
        for v in subviews {
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 300),

            artworkContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            artworkContainer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            artworkContainer.widthAnchor.constraint(equalToConstant: 200),
            artworkContainer.heightAnchor.constraint(equalToConstant: 200),
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 16),
            progressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            progressBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            progressBar.heightAnchor.constraint(equalToConstant: 6),

            elapsedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            elapsedLabel.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor),

            transport.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: 10),
            transport.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            volumeRow.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 12),
            volumeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            volumeRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            separator.topAnchor.constraint(equalTo: volumeRow.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: gearButton.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            gearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            gearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])

        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true

        showPlaceholderArtwork()
    }

    private func makeLabel(font: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: Selector) -> NSButton {
        let button = NSButton(image: Theme.symbol(symbol, size: size, weight: .medium) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        return button
    }

    private func showPlaceholderArtwork() {
        if placeholderArtwork == nil {
            let size: CGFloat = 200
            placeholderArtwork = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSColor.systemGray.withAlphaComponent(0.18).setFill()
                rect.fill()
                if let note = Theme.symbol("music.note", size: size * 0.35, weight: .light) {
                    let s = size * 0.4
                    let r = NSRect(x: (size - s) / 2, y: (size - s) / 2, width: s, height: s)
                    note.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.45)
                }
                return true
            }
        }
        artworkView.image = placeholderArtwork
    }

    // MARK: Popover toggle & settings menu

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            poll()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func showSettings(_ sender: NSButton) {
        let menu = NSMenu()

        let mediaKeysItem = NSMenuItem(title: "", action: #selector(toggleMediaKeys), keyEquivalent: "")
        mediaKeysItem.target = self
        configureMediaKeysItem(mediaKeysItem)
        menu.addItem(mediaKeysItem)

        menu.addItem(.separator())

        let hostItem = NSMenuItem(title: "Set PC Address…", action: #selector(promptForHost), keyEquivalent: "")
        hostItem.target = self
        menu.addItem(hostItem)

        let autoItem = NSMenuItem(title: "Use Auto-Discovery", action: #selector(useAutoDiscovery), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(poll), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Apple Music Remote",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    // MARK: Media keys (F7/F8/F9)

    private func setupMediaKeyCapture() {
        NSLog("MediaKeyCapture: launch, AXIsProcessTrusted=\(AXIsProcessTrusted())")
        MediaKeyCapture.shared.onKey = { [weak self] key in
            switch key {
            case MediaKeyCapture.playPause:
                self?.onPlayPause()
            case MediaKeyCapture.next, MediaKeyCapture.fastForward:
                self?.onNext()
            case MediaKeyCapture.previous, MediaKeyCapture.rewind:
                self?.onPrevious()
            default:
                break
            }
        }
        if AXIsProcessTrusted() {
            MediaKeyCapture.shared.start()
        }
    }

    @objc private func toggleMediaKeys() {
        NSLog("MediaKeyCapture: toggle clicked, enabled=\(MediaKeyCapture.shared.enabled) trusted=\(AXIsProcessTrusted())")
        if MediaKeyCapture.shared.enabled {
            mediaKeysWanted = false
            MediaKeyCapture.shared.stop()
        } else {
            mediaKeysWanted = true
            guard AXIsProcessTrusted() else {
                // Triggers the system prompt directing the user to
                // Settings → Privacy & Security → Accessibility.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                return
            }
            MediaKeyCapture.shared.start()
        }
    }

    private func configureMediaKeysItem(_ item: NSMenuItem) {
        if MediaKeyCapture.shared.enabled {
            item.state = .on
            item.title = "Capture Media Keys (F7–F9)"
        } else if AXIsProcessTrusted() {
            item.state = .off
            item.title = "Capture Media Keys (F7–F9)"
        } else {
            item.state = .off
            item.title = "Capture Media Keys (F7–F9) — needs Accessibility permission"
        }
    }

    // MARK: Hotkeys
    //
    // ⌃⌥Space play/pause · ⌃⌥→ next · ⌃⌥← previous
    // (⌃⌥ = Control+Option; chosen to avoid clashing with macOS shortcuts)

    private func registerHotKeys() {
        let mods = UInt32(controlKey | optionKey)
        HotKeyManager.shared.register(keyCode: UInt32(kVK_Space), modifiers: mods, id: 1) { [weak self] in
            self?.onPlayPause()
        }
        HotKeyManager.shared.register(keyCode: UInt32(kVK_RightArrow), modifiers: mods, id: 2) { [weak self] in
            self?.onNext()
        }
        HotKeyManager.shared.register(keyCode: UInt32(kVK_LeftArrow), modifiers: mods, id: 3) { [weak self] in
            self?.onPrevious()
        }
    }

    // MARK: Discovery

    private func startDiscovery() {
        discovery.onFound = { [weak self] name, url in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // A manually entered address always wins over auto-discovery.
                guard self.client.manualHost?.isEmpty != false else { return }
                self.client.discoveredBaseURL = url
                self.client.discoveredName = name
                self.updateStatusLabel()
                self.poll()
            }
        }
        discovery.start()

        // If nothing was discovered and no manual address exists after a few
        // seconds, fall back to asking for the address.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.client.baseURL == nil else { return }
            self.promptForHost()
        }
    }

    // MARK: Polling

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Advance the progress bar between polls for smooth playback.
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
        poll()
    }

    @objc private func poll() {
        // Permission may have been granted since the last tick — start the
        // event tap automatically once it is.
        if mediaKeysWanted && !MediaKeyCapture.shared.enabled && AXIsProcessTrusted() {
            NSLog("MediaKeyCapture: permission granted, starting tap")
            MediaKeyCapture.shared.start()
        }
        client.fetchNowPlaying { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let np):
                    self.reachable = true
                    self.current = np
                    self.updateUI(np)
                    self.updateStatusLabel()
                case .failure:
                    self.reachable = false
                    self.current = nil
                    self.titleLabel.stringValue = self.client.baseURL == nil
                        ? "Looking for PC on the network…"
                        : "PC unreachable"
                    self.artistLabel.stringValue = ""
                    self.showPlaceholderArtwork()
                    self.displayedPosition = 0
                    self.displayedDuration = 0
                    self.updateProgressUI()
                    self.setPlayPauseSymbol(playing: false)
                }
            }
        }
    }

    private func tickProgress() {
        guard let np = current, np.status == "playing" else { return }
        if displayedDuration > 0 {
            displayedPosition = min(displayedPosition + 0.5, displayedDuration)
        }
        updateProgressUI()
    }

    private func updateUI(_ np: NowPlaying) {
        let hasTrack = np.title != nil && np.status != "stopped"
        if hasTrack {
            titleLabel.stringValue = np.title ?? "Unknown"
            artistLabel.stringValue = [np.artist, np.album].compactMap { $0 }.joined(separator: " — ")
            setPlayPauseSymbol(playing: np.status == "playing")
        } else {
            titleLabel.stringValue = "Nothing playing"
            artistLabel.stringValue = ""
            setPlayPauseSymbol(playing: false)
        }

        displayedPosition = np.positionSec
        displayedDuration = np.durationSec
        updateProgressUI()

        if let dataURL = np.artwork,
           let marker = dataURL.range(of: ";base64,"),
           let data = Data(base64Encoded: String(dataURL[marker.upperBound...])),
           let image = NSImage(data: data) {
            image.size = NSSize(width: 200, height: 200)
            artworkView.image = image
        } else {
            showPlaceholderArtwork()
        }

        if let v = np.volume { volumeSlider.integerValue = v }
        let muted = np.muted ?? false
        muteButton.image = Theme.symbol(muted ? "speaker.slash.fill" : "speaker.fill", size: 12)
    }

    private func updateProgressUI() {
        progressBar.fraction = displayedDuration > 0 ? displayedPosition / displayedDuration : 0
        elapsedLabel.stringValue = formatTime(displayedPosition)
        remainingLabel.stringValue = displayedDuration > 0
            ? "-" + formatTime(max(0, displayedDuration - displayedPosition))
            : "--:--"
    }

    private func setPlayPauseSymbol(playing: Bool) {
        playPauseButton.image = Theme.symbol(playing ? "pause.fill" : "play.fill", size: 26, weight: .medium)
    }

    private func formatTime(_ sec: Double) -> String {
        let total = max(0, Int(sec.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Actions

    @objc private func onPlayPause() {
        client.post("play-pause")
        refreshSoon()
    }

    @objc private func onNext() {
        client.post("next")
        refreshSoon()
    }

    @objc private func onPrevious() {
        client.post("previous")
        refreshSoon()
    }

    @objc private func onVolumeChanged(_ sender: NSSlider) {
        let level = sender.integerValue
        volumeDebounce?.invalidate()
        volumeDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.client.post("volume", body: ["level": level])
        }
    }

    @objc private func onToggleMute() {
        let muted = !(current?.muted ?? false)
        client.post("mute", body: ["muted": muted])
        refreshSoon()
    }

    private func refreshSoon() {
        // Give the server a beat to apply the change, then re-poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.poll()
        }
    }

    private func updateStatusLabel() {
        statusLabel.stringValue = reachable
            ? "Connected to \(client.sourceDescription)"
            : "PC: \(client.sourceDescription)"
    }

    @objc private func useAutoDiscovery() {
        client.manualHost = nil
        updateStatusLabel()
        poll()
    }

    @objc private func promptForHost() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Windows PC address"
        alert.informativeText = "Only needed if auto-discovery doesn't find your PC. Enter its IP (and port if changed), e.g. 192.168.1.50:4789"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "192.168.1.50:4789"
        field.stringValue = client.manualHost ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty {
                client.manualHost = host
                updateStatusLabel()
                poll()
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
