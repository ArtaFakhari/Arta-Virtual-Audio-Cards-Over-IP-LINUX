# Arta Virtual Audio Cards Over IP — Linux

> Native PipeWire/WirePlumber virtual audio sink manager with TCP/RTP network streaming, volume control, and XDG-compliant persistence.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash%205%2B-blue)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)

---

## Features

| Feature | Detail |
|---|---|
| **Virtual Sink CRUD** | Create / list / delete PipeWire null-audio-sink nodes |
| **DE Visibility** | `media.class=Audio/Sink` + `node.description` ensures sinks appear in `pavucontrol`, GNOME, KDE, LXDE, and Raspberry Pi tray applets |
| **TCP Streaming** | `libpipewire-module-protocol-simple` — raw S16LE PCM over TCP; play with `ffplay` or VLC |
| **RTP Streaming** | `libpipewire-module-rtp-sink` — S16BE RTP unicast/multicast; play with VLC or GStreamer |
| **Volume Control** | `wpctl set-volume` with hard 0–100% clamp and mute toggle |
| **Port Management** | Live port updates without recreating the sink |
| **XDG Persistence** | Saves a `.conf` snippet to `~/.config/pipewire/pipewire.conf.d/` that survives reboots |
| **TUI Dashboard** | Refreshing table showing Node ID, name, description, volume, mute state, and stream address |

---

## Requirements

| Package | Binary | Purpose |
|---|---|---|
| `pipewire` | `pipewire`, `pw-cli`, `pw-dump` | Audio server + graph control |
| `wireplumber` | `wireplumber`, `wpctl` | Session/policy manager |
| `jq` | `jq` | JSON parsing of `pw-dump` output |
| `bc` | `bc` | Decimal volume math |
| `iproute2` | `ss` | Port-in-use checks |

### Debian / Ubuntu / Raspberry Pi OS

```bash
sudo apt install pipewire wireplumber pipewire-bin jq bc iproute2
systemctl --user enable --now pipewire wireplumber
```

### Arch Linux

```bash
sudo pacman -S pipewire wireplumber jq bc iproute2
systemctl --user enable --now pipewire wireplumber
```

---

## Installation

```bash
git clone https://github.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX.git
cd Arta-Virtual-Audio-Cards-Over-IP-LINUX
chmod +x virtual-audio-manager.sh
./virtual-audio-manager.sh
```

### One-line run

The script now supports interactive remote execution by reopening `/dev/tty` for prompts, so both of these work:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX/main/virtual-audio-manager.sh)

curl -fsSL https://raw.githubusercontent.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX/main/virtual-audio-manager.sh | bash
```

> **Do not run as root.** PipeWire is a per-user session service.

---

## Usage

The script presents an interactive TUI menu:

```
  ╔══════════════════════════════════════════════════════════════╗
  ║       Virtual Audio Card Manager  —  PipeWire/WirePlumber   ║
  ╚══════════════════════════════════════════════════════════════╝

  Active Virtual Sinks
  ──────────────────────────────────────────────────────────────
  ID     Name                         Description          Volume   Mute   Network Stream
  ──────────────────────────────────────────────────────────────
  42     virtual_studio               Studio Monitor       80%      live   tcp://0.0.0.0:8080
  ──────────────────────────────────────────────────────────────

  Menu
  1) Create virtual sink
  2) Delete virtual sink
  3) Volume control
  4) Expose sink to network (TCP/RTP)
  5) Update stream port
  6) Stop stream
  7) Save config to ~/.config/pipewire/pipewire.conf.d/virtual-audio-cards.conf
  q) Quit
```

### Listening to a TCP stream

```bash
# ffplay (ffmpeg)
ffplay -f s16le -ar 48000 -ac 2 tcp://192.168.1.10:8080

# VLC
vlc tcp://192.168.1.10:8080
```

### Listening to an RTP stream

```bash
# VLC
vlc rtp://@:8080

# GStreamer
gst-launch-1.0 udpsrc port=8080 caps="application/x-rtp" ! rtppcmdepay ! audioconvert ! autoaudiosink
```

---

## Persistence

Choose **7) Save config** to write a `pipewire.conf.d` fragment:

```ini
# virtual-audio-cards.conf
# Third-party GUIs / Web UIs can parse these comment keys:
#   # stream.<node_name>.protocol=<tcp|rtp>
#   # stream.<node_name>.address=<ipv4>
#   # stream.<node_name>.port=<port>

context.modules = [
  # Virtual Sink: virtual_studio
  # stream.virtual_studio.protocol=tcp
  # stream.virtual_studio.address=127.0.0.1
  # stream.virtual_studio.port=8080
  {   name = libpipewire-module-adapter
      args = {
          factory.name     = support.null-audio-sink
          node.name        = "virtual_studio"
          node.description = "Studio Monitor"
          media.class      = Audio/Sink
          audio.channels   = 2
          audio.position   = [ FL FR ]
          node.virtual     = true
          monitor.channel-volumes = true
          object.linger    = true
      }
  }
]
```

Apply without rebooting:

```bash
systemctl --user restart pipewire wireplumber
```

---

## Security

- Runs as the current user only — **root execution is blocked**
- Sink names are validated against `^[a-zA-Z0-9_-]+$`
- Ports are validated as integers in `[1024, 65535]`
- Port collision detection via `ss` before binding
- Node ID existence verified before every destructive action
- Config written to a temp file first, then atomically promoted via `mv`

---

## License

[MIT](LICENSE) © 2026 Arta
