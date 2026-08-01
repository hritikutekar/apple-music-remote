import Cocoa

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
        guard let hostName = sender.hostName else { return }
        // hostName looks like "DESKTOP-ABC.local." — trim the trailing dot.
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        if let url = URL(string: "http://\(host):\(sender.port)") {
            onFound(sender.name, url)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setTitle("♪ …")
        buildMenu()
        startDiscovery()
        startPolling()
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

        playPauseItem = NSMenuItem(title: "Play / Pause", action: #selector(onPlayPause), keyEquivalent: "")
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let prevItem = NSMenuItem(title: "⏮ Previous", action: #selector(onPrevious), keyEquivalent: "")
        prevItem.target = self
        menu.addItem(prevItem)

        let nextItem = NSMenuItem(title: "⏭ Next", action: #selector(onNext), keyEquivalent: "")
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
            playPauseItem.title = np.status == "playing" ? "⏸ Pause" : "▶️ Play"
        } else {
            setTitle("♪ Not playing")
            trackItem.title = "Nothing playing"
            playPauseItem.title = "▶️ Play"
        }

        if let dataURL = np.artwork,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
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
        poll()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
