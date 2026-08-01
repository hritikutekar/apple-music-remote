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

The server talks to Windows' **GSMTC** (Global System Media Transport Controls) — the same media-session API the Windows lock screen uses. The official Apple Music Windows app registers there, so play/pause/skip and now-playing metadata (title, artist, album, artwork) work without automating the app itself. Volume control adjusts the Windows system volume.

## Features

- **Zero-config discovery** — the server announces itself via mDNS/Bonjour and the Mac app finds it automatically; no IP addresses to type
- Now playing in your Mac menu bar: `♪ Title — Artist`, with artwork in the dropdown
- Play / pause, next, previous
- System volume slider + mute
- Polls every 2 seconds; shows "Offline" when the PC is unreachable

## Setup — Windows PC (server)

Prerequisites:

1. **Node.js LTS** — https://nodejs.org
2. **Visual Studio Build Tools** with the "Desktop development with C++" workload — needed to compile the NodeRT native module. Install via https://visualstudio.microsoft.com/visual-cpp-build-tools/ (or `winget install Microsoft.VisualStudio.2022.BuildTools` and add the C++ workload).

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
```

Discovery also needs mDNS (UDP 5353), which Windows allows by default on Private networks. Make sure your network profile is set to **Private** (*Settings → Network & internet → Wi-Fi/Ethernet → your network*), not Public — discovery is blocked on Public profiles.

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

If discovery fails (e.g. the Windows network profile is Public), the app falls back to asking for the PC's address — find it with `ipconfig` on the PC and enter it as `192.168.1.50:4789`. A manually set address always takes priority; choose **Use Auto-Discovery** in the menu to switch back.

The app is unsigned, so if Gatekeeper blocks it: *System Settings → Privacy & Security → Open Anyway*.

## How it works

| Piece | Where | Tech |
|---|---|---|
| Media control + now playing | `server/src/media.ts` | `@nodert-win11/windows.media.control` (WinRT GSMTC bindings) |
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
- If several apps are playing media, the server prefers the Apple Music session and falls back to the system's current session.
- If `npm install` fails on the NodeRT step, the C++ Build Tools are missing or incomplete — install the "Desktop development with C++" workload and retry.
