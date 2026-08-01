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

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = RemoteClient()
    private let discovery = ServiceDiscovery()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var current: NowPlaying?
    private var reachable = false

    // Menu items we update live
    private var artworkItem: NSMenuItem!
    private var trackItem: NSMenuItem!
    private var pcItem: NSMenuItem!
    private var playPauseItem: NSMenuItem!
    private var volumeSlider: NSSlider!
    private var muteItem: NSMenuItem!
    private var volumeDebounce: Timer?
    private var mediaKeysItem: NSMenuItem!
    private var mediaKeysWanted = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setTitle("♪ …")
        buildMenu()
        registerHotKeys()
        setupMediaKeyCapture()
        startDiscovery()
        startPolling()
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
        refreshMediaKeysItem()
    }

    private func refreshMediaKeysItem() {
        if MediaKeyCapture.shared.enabled {
            mediaKeysItem.state = .on
            mediaKeysItem.title = "Capture Media Keys (F7–F9)"
        } else if AXIsProcessTrusted() {
            mediaKeysItem.state = .off
            mediaKeysItem.title = "Capture Media Keys (F7–F9)"
        } else {
            mediaKeysItem.state = .off
            mediaKeysItem.title = "Capture Media Keys (F7–F9) — needs Accessibility permission"
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
                self.updatePCItem()
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

    // MARK: Menu construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        artworkItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        artworkItem.isEnabled = false
        menu.addItem(artworkItem)

        trackItem = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)

        menu.addItem(.separator())

        playPauseItem = NSMenuItem(title: "Play / Pause  ⌃⌥Space", action: #selector(onPlayPause), keyEquivalent: "")
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let prevItem = NSMenuItem(title: "⏮ Previous  ⌃⌥←", action: #selector(onPrevious), keyEquivalent: "")
        prevItem.target = self
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "⏭ Next  ⌃⌥→", action: #selector(onNext), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        menu.addItem(.separator())

        // Volume slider inside a menu item view
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        volumeSlider = NSSlider(frame: NSRect(x: 16, y: 2, width: 168, height: 24))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.target = self
        volumeSlider.action = #selector(onVolumeChanged(_:))
        volumeSlider.isContinuous = true
        sliderView.addSubview(volumeSlider)
        let volumeItem = NSMenuItem()
        volumeItem.view = sliderView
        menu.addItem(volumeItem)

        muteItem = NSMenuItem(title: "Mute", action: #selector(onToggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(.separator())

        mediaKeysItem = NSMenuItem(title: "Capture Media Keys (F7–F9)", action: #selector(toggleMediaKeys), keyEquivalent: "")
        mediaKeysItem.target = self
        refreshMediaKeysItem()
        menu.addItem(mediaKeysItem)

        pcItem = NSMenuItem(title: "PC: searching…", action: nil, keyEquivalent: "")
        pcItem.isEnabled = false
        menu.addItem(pcItem)

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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Polling

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
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
                    self.updatePCItem()
                case .failure:
                    self.reachable = false
                    self.current = nil
                    self.setTitle("♪ Offline")
                    self.trackItem.title = self.client.baseURL == nil
                        ? "Looking for PC on the network…"
                        : "PC unreachable"
                    self.artworkItem.image = nil
                }
            }
        }
    }

    private func updateUI(_ np: NowPlaying) {
        let hasTrack = np.title != nil && np.status != "stopped"
        if hasTrack {
            let title = np.title ?? "Unknown"
            let artist = np.artist ?? ""
            setTitle("♪ " + truncate(artist.isEmpty ? title : "\(title) — \(artist)", max: 40))
            trackItem.title = [np.title, np.artist, np.album]
                .compactMap { $0 }.joined(separator: " — ")
            playPauseItem.title = np.status == "playing" ? "⏸ Pause  ⌃⌥Space" : "▶️ Play  ⌃⌥Space"
        } else {
            setTitle("♪ Not playing")
            trackItem.title = "Nothing playing"
            playPauseItem.title = "▶️ Play  ⌃⌥Space"
        }

        if let dataURL = np.artwork,
           let marker = dataURL.range(of: ";base64,"),
           let data = Data(base64Encoded: String(dataURL[marker.upperBound...])),
           let image = NSImage(data: data) {
            image.size = NSSize(width: 32, height: 32)
            artworkItem.image = image
        } else {
            artworkItem.image = nil
        }

        if let v = np.volume { volumeSlider.integerValue = v }
        muteItem.state = (np.muted ?? false) ? .on : .off
    }

    private func setTitle(_ text: String) {
        statusItem.button?.title = text
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
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
        client.post("mute", body: ["muted": muteItem.state != .on])
        refreshSoon()
    }

    private func refreshSoon() {
        // Give the server a beat to apply the change, then re-poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.poll()
        }
    }

    private func updatePCItem() {
        pcItem.title = "PC: \(client.sourceDescription)"
    }

    @objc private func useAutoDiscovery() {
        client.manualHost = nil
        updatePCItem()
        poll()
    }

    @objc private func promptForHost() {
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
                updatePCItem()
                poll()
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMediaKeysItem()
        poll()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
