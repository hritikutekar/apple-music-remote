# Apple Music Remote

Control Apple Music playing on a **Windows PC** from your **MacBook's menu bar**, over your local network.

```
┌──────────────┐        HTTP (LAN)         ┌─────────────────────┐
│  MacBook     │  ◄──────────────────────►  │  Windows PC         │
│  menu bar    │   now playing / controls   │  Node server ──►    │
│  app (Swift) │                            │  Apple Music (GSMTC)│
└──────────────┘                            └─────────┬───────────┘
                                                      │ audio
                                               Edifier MR4 speakers
```

The server reads Windows' **GSMTC** (Global System Media Transport Controls) — the same media-session API the Windows lock screen uses — via a prebuilt .NET bridge, so now-playing metadata (title, artist, album, artwork) works without automating the app itself. Play/pause/skip are sent as hardware-style media key presses, and volume control adjusts the Windows system volume. No compilers or build tools needed on the PC — just Node.js.

## Features

- **Zero-config discovery** — the server announces itself via mDNS/Bonjour and the Mac app finds it automatically; no IP addresses to type
- Now playing in your Mac menu bar: `♪ Title — Artist`, with artwork in the dropdown
- Play / pause, next, previous
- **Keyboard media keys (F7 ⏮ · F8 ⏯ · F9 ⏭) control the PC** — captured system-wide before macOS sees them; toggleable in the menu. Requires a one-time Accessibility permission grant (see below). Bonus shortcuts without any permission: `⌃⌥Space` play/pause, `⌃⌥→` next, `⌃⌥←` previous
- System volume slider + mute
- Polls every 2 seconds; shows "Offline" when the PC is unreachable

## Setup — Windows PC (server)

Prerequisite: **Node.js LTS** — https://nodejs.org. That's it.

Then:

```powershell
cd server
npm install
npm run build
npm start
```

You should see:

```
apple-music-remote server listening on http://0.0.0.0:4789
```

**Firewall:** on first run Windows will ask whether to allow Node.js through the firewall — allow it on Private networks. If you missed the prompt: *Windows Security → Firewall & network protection → Allow an app through firewall*, or run (admin PowerShell):

```powershell
New-NetFirewallRule -DisplayName "Apple Music Remote" -Direction Inbound -Protocol TCP -LocalPort 4789 -Action Allow
New-NetFirewallRule -DisplayName "Apple Music Remote mDNS" -Direction Inbound -Protocol UDP -LocalPort 5353 -Action Allow
```

Discovery also needs mDNS (UDP 5353), so make sure your network profile is set to **Private** (*Settings → Network & internet → Wi-Fi/Ethernet → your network*), not Public — discovery is blocked on Public profiles.

### Autostart (optional)

To start the server automatically at login, create a scheduled task (admin PowerShell):

```powershell
schtasks /create /tn "AppleMusicRemote" /tr "node C:\path\to\apple-music-remote\server\dist\index.js" /sc onlogon /rl highest
```

## Setup — MacBook (menu bar app)

Prerequisites: Xcode Command Line Tools (`xcode-select --install`).

```sh
cd menubar
./build.sh
open AppleMusicRemote.app
```

On first launch the app searches the network for the PC automatically — within a few seconds the menu should show `PC: Apple Music Remote (YOUR-PC) (auto)`. No configuration needed.

macOS will ask for **Local Network** permission on first launch — allow it, otherwise discovery is silently blocked. If you denied it earlier: *System Settings → Privacy & Security → Local Network → AppleMusicRemote → on*, then restart the app.

If discovery fails, run this in a Mac terminal to see whether the PC's announcement is reaching the Mac at all:

```sh
dns-sd -B _amremote._tcp
```

- Service appears → the Mac app is the problem (check Local Network permission above).
- Nothing appears → the PC side: server running with the `mDNS: advertising` line in its console, Windows network profile set to Private, UDP 5353 allowed (firewall rule above). Some routers also block multicast between devices ("AP/client isolation" — disable it).

Manual fallback: find the PC's address with `ipconfig` and enter it as `192.168.1.50:4789` via **Set PC Address…**. A manually set address always takes priority; choose **Use Auto-Discovery** in the menu to switch back.

The app is unsigned, so if Gatekeeper blocks it: *System Settings → Privacy & Security → Open Anyway*.

### Media keys (F7/F8/F9)

To make the keyboard's media keys control the PC, open the app menu and click **Capture Media Keys (F7–F9)**. macOS will ask for **Accessibility** permission — grant it in *System Settings → Privacy & Security → Accessibility → AppleMusicRemote*, then toggle the menu item again (or wait a couple of seconds; it starts automatically once permission is granted).

While capture is on, F7/F8/F9 control the PC and no longer trigger local Mac apps. Toggle the menu item off to return them to macOS.

## How it works

| Piece | Where | Tech |
|---|---|---|
| Now playing | `server/src/media.ts` | `windows-media-sessions` (prebuilt .NET GSMTC bridge — no native build) |
| Transport controls | `server/src/media.ts` | media key presses (`VK_MEDIA_*`) via a persistent PowerShell helper |
| System volume | `server/src/volume.ts` | `loudness` |
| HTTP API | `server/src/index.ts` | Express, port `4789` (override with `PORT` env var) |
| LAN discovery | server + Mac app | mDNS/Bonjour (`bonjour-service` on Windows, `NetServiceBrowser` on macOS), service type `_amremote._tcp` |
| Menu bar app | `menubar/Main.swift` | AppKit `NSStatusItem`, no dependencies |

### API

- `GET /now-playing` → `{ title, artist, album, status, positionSec, durationSec, artwork, volume, muted }` (`artwork` is a base64 data URL)
- `POST /play-pause` · `POST /next` · `POST /previous`
- `POST /volume { "level": 0-100 }` · `POST /mute { "muted": true|false }`
- `GET /health`

Anything that can speak HTTP can drive it — e.g. from any device: `curl -X POST http://PC_IP:4789/next`.

## Limitations & notes

- Both machines must be on the same LAN.
- The API is unauthenticated — fine on a trusted home network; don't expose the port beyond it.
- If several apps are playing media, the server prefers the Apple Music session and falls back to whatever is currently playing. Media key presses go to the system, same as your keyboard's media keys.
- Apple Music only registers a media session with Windows once something has started playing — if `GET /now-playing` reports "stopped", hit play once on the PC.
