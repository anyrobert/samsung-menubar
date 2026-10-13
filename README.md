# Samsung-menubar

A native macOS menu bar remote for Samsung Tizen TVs. Navigate, launch apps, set the volume, type into the TV, send media files and keep your TV controls a click away.

This is a personal project, independent of Samsung. It is a port of [LGwebOS-menubar](https://github.com/gabrielgreco1/LGwebOS-menubar) (MIT), which targets LG webOS TVs.

> **Compatibility:** tested on a **Samsung QN55Q60R** (2019, Tizen). Samsung TVs from 2016 onward use the same local API, but other models are not verified.

## Tested models

| Model | Year | Status |
| --- | --- | --- |
| Samsung QN55Q60RAGXZD | 2019 | Works: discovery, pairing, keys, apps, volume, on-screen app detection, icons |

## Requirements

- A Mac running macOS 14 or later.
- Xcode Command Line Tools with Swift 5.9 or later (`xcode-select --install`).
- A Samsung Tizen TV on the same Wi-Fi or Ethernet network as your Mac.

## Build and run

```sh
bash scripts/build.sh
open "dist/Samsung-menubar.app"
```

The build is signed locally and is not notarized. On first launch macOS asks to let the app find devices on your local network; choose **Allow**.

## Pair your TV

1. Open Settings in the panel and choose **Find TVs on your network**, or enter the TV's IPv4 address.
2. Approve the certificate prompt on the Mac. The TV's certificate fingerprint is pinned in the Keychain.
3. Choose **Allow** for "Samsung-menubar" on the TV within about 30 seconds.

The TV's access token is stored in the Keychain. A TV whose certificate changes is refused; use **Forget pairing** to pair again after checking the device.

## Features

- Remote: arrows, OK, Home, Back, Menu, Exit, playback keys, channel up/down, a number pad (also for codes such as Developer Mode), a swipe pad that turns swipes into arrow presses, and keyboard control (arrow keys, Return, Delete) while the panel is open.
- Sources: Source, HDMI and Live TV keys.
- Apps: every installed app with its real icon, favorites, search, and the app currently on screen.
- Volume: exact level and mute through the TV's DLNA RenderingControl, plus volume keys.
- Keyboard: send text to the field open on the TV, or send the Mac clipboard in one click with **Paste to TV**.
- Cast: send a video, song or photo from the Mac over DLNA. AirPlay mirroring is a Control Center shortcut.
- Activity: local screen time per app, recorded only while the Mac is awake and connected.
- Power: turn the TV off, or wake it over Wi-Fi. The app sends Wake-on-LAN to the subnet broadcast address until the TV reports it is on, and sends the power key once the TV is reachable in standby. The Wi-Fi MAC is read from the TV. Turn on **Power On with Mobile** (Settings › General › Network › Expert Settings) on the TV.

There is no picture-settings tab: Samsung TVs do not expose those settings on the local network.

## How it talks to the TV

| Channel | Port | Used for |
| --- | --- | --- |
| WebSocket `wss://TV:8002/api/v2/channels/samsung.remote.control` | 8002 | Pairing, keys, text, installed apps, icons, app launch |
| REST `https://TV:8002/api/v2/` | 8002 | Power state, model, on-screen app (`visible`) |
| REST `http://TV:8001/api/v2/` | 8001 | Discovery description (no pairing needed) |
| DLNA `http://TV:9197/dmr` | 9197 | Volume and mute (RenderingControl), media casting (AVTransport) |
| SSDP | 1900 | Discovery |
| Wake-on-LAN | 9 (UDP) | Waking the TV |

Everything stays on the local network: no accounts, analytics or cloud services. The app only connects to private IPv4 addresses.

## Offline checks and diagnostics

```sh
"dist/Samsung-menubar.app/Contents/MacOS/SamsungMenubar" --self-check
python3 scripts/privacy-check.py
```

`--diagnose --host <tv-ip> --report <file>` runs read-only checks against a TV. Start it with `open` so it gets its own Local Network permission:

```sh
open -n dist/Samsung-menubar.app --args --diagnose --host <tv-ip> --trust-new-tv --report /tmp/samsung-diag.json
```

Diagnostic reports contain local device information. Keep IP addresses, MAC addresses, serial numbers and tokens out of public issues.

## Local data

- Settings: `defaults read br.local.SamsungRemote`
- Event history, screen time and cached app icons: `~/Library/Application Support/br.local.SamsungRemote/`
- Token and certificate pin: Keychain items `br.local.SamsungRemote` and `br.local.SamsungRemote.Certificate`
