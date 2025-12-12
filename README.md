# WorldBox Timelapse System — NixOS Flake  
**24h → 90min Cinematic Timelapse with Real-Time Bursts**  
*Declarative • Reproducible • Production-Ready*

---

[![NixOS](https://img.shields.io/badge/NixOS-24.05-blue.svg)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Flakes-Enabled-green.svg)](https://nixos.wiki/wiki/Flakes)
[![License: BSD3](https://img.shields.io/badge/License-BSD-yellow.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-ALH477%2Fworldbox--timelapse-8A2BE2)](https://github.com/ALH477/WorldBox-Timelapse)

---

## Overview

This **NixOS flake** provides a **fully declarative**, **self-healing**, and **zero-maintenance** timelapse system for **WorldBox** (or any HDMI-captured game). It turns **24 hours of gameplay** into a **90-minute cinematic video** with:

- **1 fps timelapse** (30× speed)
- **3.5 min real-time burst every 15 min**
- **Scene-aware auto-trim** to 90 min
- **Email alerts**, **cleanup**, **monitoring**
- **Hardened security**, **log rotation**, **resource limits**

All with **one line** in your NixOS config.

---

## Features

| Feature | Status |
|-------|--------|
| 24h → 90min cinematic output | Yes |
| Dual-speed capture (timelapse + real-time) | Yes |
| Scene detection (`scene > 0.35`) | Yes |
| Email alerts on failure/no output | Yes |
| Daily cleanup (raw: 7d, final: 30d) | Yes |
| 15-min health checks | Yes |
| Systemd hardening & resource limits | Yes |
| Log rotation (30 days) | Yes |
| Raspberry Pi 4 / ARM64 support | Yes |
| Declarative NixOS module | Yes |
| No manual setup | Yes |

---

## Architecture

```
[HDMI Capture] → /dev/video0 → ffmpeg (dual-speed)
        ↓
   raw_*.mp4 (24h, ~3–5 GB)
        ↓
   scene detection → trim to 90 min
        ↓
   worldbox_*.mp4 (~450 MB)
        ↓
   monitor.sh → email if stale
   cleanup.sh → delete old files
```

---

## Quick Start

```nix
# In your flake.nix
inputs.timelapse.url = "github:ALH477/worldbox-timelapse";

outputs = { self, nixpkgs, timelapse }: {
  nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
    modules = [
      timelapse.nixosModules.timelapse
      {
        services.timelapse = {
          enable = true;
          videoDevice = "/dev/video0";
          alertEmail = "you@example.com";
        };
      }
    ];
  };
};
```

```bash
sudo nixos-rebuild switch --flake .#mybox
```

**Done.** The system starts automatically.

---

## Configuration Options

```nix
services.timelapse = {
  enable = true;

  videoDevice = "/dev/video0";     # v4l2 device
  audioDevice = null;              # or "hw:1,0"
  alertEmail = "admin@example.com";
};
```

| Option | Type | Default | Description |
|-------|------|---------|-------------|
| `enable` | bool | `false` | Enable the timelapse system |
| `videoDevice` | string | `"/dev/video0"` | Path to HDMI capture device |
| `audioDevice` | null or string | `null` | ALSA audio device (optional) |
| `alertEmail` | string | `"admin@example.com"` | Email for alerts |

---

## Directory Structure

```
/timelapse/
├── raw/      → raw_20251212_000000.mp4
├── final/    → worldbox_20251212.mp4

/var/log/timelapse/
├── capture_*.log
├── cleanup_*.log
├── health_*.log

/home/timelapse/timelapse/
├── capture.sh
├── cleanup.sh
└── monitor.sh
```

---

## Systemd Services

| Service | Purpose | Schedule |
|--------|--------|----------|
| `timelapse.service` | Main capture & processing | On boot |
| `timelapse-cleanup.timer` | Daily cleanup | 3:00 AM |
| `timelapse-monitor.timer` | Health check | Every 15 min |
| `timelapse-failure-notification` | Email on crash | On failure |

---

## Installation

### 1. **Add to Your Flake**

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    timelapse.url = "github:ALH477/worldbox-timelapse";
  };

  outputs = { self, nixpkgs, timelapse }: {
    nixosConfigurations.hostname = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        timelapse.nixosModules.timelapse
      ];
    };
  };
}
```

### 2. **Enable in Config**

```nix
# configuration.nix
{ config, pkgs, ... }: {
  imports = [ ./flake.nix ];

  services.timelapse = {
    enable = true;
    videoDevice = "/dev/video0";
    alertEmail = "admin@example.com";
  };
}
```

### 3. **Deploy**

```bash
sudo nixos-rebuild switch
```

---

## Device Setup

### Find Video Device

```bash
v4l2-ctl --list-devices
```

### Test Capture

```bash
ffmpeg -f v4l2 -i /dev/video0 -t 5 test.mp4
```

### Find Audio Device (Optional)

```bash
aplay -l
# Use: hw:CARD,DEV
```

---

## Email Alerts

### Configure Postfix (SMTP)

```nix
services.postfix = {
  enable = true;
  setSendmail = true;
  relayHost = "smtp.gmail.com";
  relayPort = 587;
  config = {
    smtp_sasl_auth_enable = "yes";
    smtp_sasl_password_maps = "hash:/etc/postfix/sasl_passwd";
    smtp_use_tls = "yes";
  };
};
```

---

## Raspberry Pi 4 / ARM64

```nix
system = "aarch64-linux";

services.timelapse = {
  enable = true;
  videoDevice = "/dev/video0";
};

# Lower resource limits
systemd.services.timelapse.serviceConfig = {
  CPUQuota = "150%";
  MemoryMax = "1G";
};
```

---

## Testing

### 5-Minute Test

```bash
# Edit script
sudo nano /home/timelapse/timelapse/capture.sh
# Change:
DURATION_SEC=300
TARGET_SEC=120

# Run
sudo -u timelapse /home/timelapse/timelapse/capture.sh
```

---

## Monitoring

```bash
# Live logs
journalctl -u timelapse.service -f

# Health logs
tail -f /var/log/timelapse/health_*.log

# Disk usage
df -h /timelapse
```

---

## Troubleshooting

| Issue | Fix |
|------|-----|
| `Device not found` | `ls -l /dev/video*` → check USB |
| `Permission denied` | `groups timelapse` → should include `video` |
| `FFmpeg error` | Test: `ffmpeg -f v4l2 -i /dev/video0 -t 5 test.mp4` |
| `No email` | Test: `echo test | mail -s test admin@example.com` |

---

## Security

- `PrivateTmp=true`
- `ProtectSystem=strict`
- `NoNewPrivileges=true`
- `ReadWritePaths` limited
- Dedicated `timelapse` user
- `CPUQuota=200%`, `MemoryMax=2G`

---

## Customization

### Change Duration

```nix
# Edit generated script
sudo nano /home/timelapse/timelapse/capture.sh
# TARGET_MIN=60
```

### Use H.265 (50% smaller)

```nix
# In capture.sh
-c:v libx264 → -c:v libx265 -crf 28
```

### Add YouTube Upload

```nix
# In capture.sh
rclone copy "$FINAL_FILE" gdrive:timelapse/
```

---

## Maintenance

```bash
# Update flake
nix flake update

# Rebuild
sudo nixos-rebuild switch

# Reset
sudo systemctl stop timelapse.service
sudo rm -rf /timelapse/*
```

---

## License

[BSD3 License](LICENSE)

---

## Author

**ALH477**  
*Built with NixOS, for the long run.*

---

**Deploy once. Watch civilizations rise and fall — forever.**  
*No maintenance. No drift. Just timelapse.*
