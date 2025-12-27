# WorldBox Timelapse System v2.0 - Production Edition

[![NixOS](https://img.shields.io/badge/NixOS-unstable-blue.svg)](https://nixos.org/)
[![License](https://img.shields.io/badge/License-BSD%203--Clause-green.svg)](LICENSE)

A production-ready NixOS flake for creating cinematic 90-minute timelapses from 24 hours of game footage. Designed for WorldBox but works with any HDMI-captured content.

## 🎯 What This Does

- **Captures** 24 hours of 1080p30 video from a capture card
- **Processes** intelligently using adaptive scene detection
- **Produces** a polished 90-minute timelapse at 720p
- **Self-heals** with automatic restart, health monitoring, and email alerts
- **Zero maintenance** with automated cleanup and log rotation

## ✨ Key Improvements in v2.0

### Reliability
- **Chunked capture**: 4-hour segments instead of one 24-hour capture (prevents data loss)
- **Two-pass processing**: Analyzes scenes first, then creates optimal output
- **File verification**: Integrity checks at every step
- **Better error handling**: Graceful degradation and detailed logging

### Performance
- **Hardware acceleration**: Optional VAAPI support for faster encoding
- **Adaptive scene detection**: Automatically adjusts threshold based on content
- **Resource limits**: Prevents runaway CPU/memory usage
- **I/O priority**: Background cleanup doesn't interfere with capture

### Operations
- **State tracking**: Monitor capture progress in real-time
- **Better alerts**: Contextual email notifications with actual errors
- **Health monitoring**: Checks service status, disk space, and output freshness
- **Configurable retention**: Separate settings for raw and final videos

## 📋 Requirements

### Hardware
- NixOS system (x86_64-linux or aarch64-linux)
- USB/PCIe HDMI capture card (V4L2 compatible)
- **Minimum**: 100GB free disk space, 2GB RAM
- **Recommended**: 200GB+ disk, 4GB+ RAM, GPU with VAAPI support

## 🚀 Quick Start

### 1. Add to your flake

```nix
{
  inputs.worldbox-timelapse.url = "github:ALH477/WorldBox-Timelapse";
  
  outputs = { nixpkgs, worldbox-timelapse, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      modules = [
        worldbox-timelapse.nixosModules.timelapse
        {
          services.timelapse = {
            enable = true;
            videoDevice = "/dev/video0";
            hardwareAcceleration = true;  # Recommended!
          };
        }
      ];
    };
  };
}
```

### 2. Rebuild

```bash
sudo nixos-rebuild switch
```

### 3. Monitor

```bash
journalctl -u timelapse.service -f
cat /var/run/timelapse.state
```

## 📊 Configuration

```nix
services.timelapse = {
  enable = true;
  videoDevice = "/dev/video0";
  audioDevice = null;  # or "hw:1,0"
  alertEmail = "you@example.com";
  
  # Performance
  hardwareAcceleration = true;
  hwaccelDevice = "/dev/dri/renderD128";
  
  # Storage
  minDiskSpaceGB = 30;
  rawRetentionDays = 7;
  finalRetentionDays = 60;
};
```

See full documentation in repository for advanced usage, troubleshooting, and examples.
