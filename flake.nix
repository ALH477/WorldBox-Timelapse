# Copyright 2025 DeMoD LLC

# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS” AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


{
  description = "WorldBox 24h Timelapse System Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";  # Change to "aarch64-linux" for ARM/Pi
    pkgs = import nixpkgs { inherit system; };
  in {
    nixosModules.timelapse = { config, lib, pkgs, ... }: let
      cfg = config.services.timelapse;
      inherit (lib) mkEnableOption mkIf mkOption types;

      # FIXED: Proper Nix string interpolation with escaping
      captureShContent = ''
        #!/usr/bin/env bash
        set -uo pipefail
        IFS=$'\n\t'

        # -------------------------- CONFIG ---------------------------------
        VIDEO_DEV="${cfg.videoDevice}"
        AUDIO_DEV="${if cfg.audioDevice != null then cfg.audioDevice else ""}"
        OUTPUT_DIR="/timelapse/raw"
        FINAL_DIR="/timelapse/final"
        LOG_DIR="/var/log/timelapse"
        LOCKFILE="/var/run/timelapse.lock"

        DURATION_SEC=$((24 * 3600))
        TARGET_MIN=90
        TARGET_SEC=$((TARGET_MIN * 60))
        MIN_FREE_SPACE_GB=15

        mkdir -p "$OUTPUT_DIR" "$FINAL_DIR" "$LOG_DIR"

        LOG="$LOG_DIR/capture_$(date +%Y%m%d_%H%M%S).log"
        exec > >(tee -a "$LOG") 2>&1

        echo "=========================================="
        echo "WorldBox Timelapse System Starting"
        echo "Date: $(date)"
        echo "=========================================="

        # -------------------------- FUNCTIONS -----------------------------
        log_error() { echo "ERROR: $1" >&2; }
        log_info() { echo "INFO: $1"; }

        cleanup_and_exit() {
            local exit_code=$1
            flock -u 200 2>/dev/null
            rm -f "$LOCKFILE"
            log_info "Cleanup complete. Exiting with code $exit_code"
            exit "$exit_code"
        }

        # -------------------------- ATOMIC LOCKING ------------------------
        exec 200>"$LOCKFILE"
        if ! flock -n 200; then
            log_error "Another instance is running. Lock file: $LOCKFILE"
            exit 1
        fi
        trap 'cleanup_and_exit $?' EXIT INT TERM

        # -------------------------- PRE-FLIGHT CHECKS ---------------------
        log_info "Running pre-flight checks..."

        AVAILABLE_GB=$(df --output=avail -BG "$OUTPUT_DIR" | tail -1 | tr -d 'G')
        if [[ $AVAILABLE_GB -lt $MIN_FREE_SPACE_GB ]]; then
            log_error "Insufficient disk space. Available: ''${AVAILABLE_GB}GB, Required: ''${MIN_FREE_SPACE_GB}GB"
            exit 1
        fi
        log_info "Disk space OK: ''${AVAILABLE_GB}GB available"

        if ! ${pkgs.v4l-utils}/bin/v4l2-ctl --device="$VIDEO_DEV" --get-fmt-video &>/dev/null; then
            log_error "Video device $VIDEO_DEV not available or not responding"
            exit 1
        fi
        log_info "Video device $VIDEO_DEV OK"

        log_info "ffmpeg found: $(${pkgs.ffmpeg}/bin/ffmpeg -version | head -1)"

        DEVICE_INFO=$(${pkgs.v4l-utils}/bin/v4l2-ctl --device="$VIDEO_DEV" --get-fmt-video 2>/dev/null)
        log_info "Device format: $DEVICE_INFO"

        # -------------------------- FILENAMES -----------------------------
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        RAW_FILE="$OUTPUT_DIR/raw_''${TIMESTAMP}.mp4"
        FINAL_FILE="$FINAL_DIR/worldbox_''${TIMESTAMP}.mp4"
        TEMP_FILE="$OUTPUT_DIR/temp_''${TIMESTAMP}.mp4"

        log_info "Starting 24h capture"
        log_info "Raw output: $RAW_FILE"
        log_info "Final output: $FINAL_FILE"

        # -------------------------- CAPTURE -------------------------------
        log_info "Starting capture with dual-speed filter..."

        CAPTURE_CMD="${pkgs.ffmpeg}/bin/ffmpeg -y \
          -f v4l2 -framerate 30 -video_size 1920x1080 -input_format yuyv422 -i \"$VIDEO_DEV\""

        if [[ -n "$AUDIO_DEV" ]]; then
            CAPTURE_CMD="$CAPTURE_CMD -f alsa -i \"$AUDIO_DEV\""
            AUDIO_MAP="-map 1:a -c:a aac -b:a 128k"
            log_info "Audio device enabled: $AUDIO_DEV"
        else
            AUDIO_MAP=""
            log_info "No audio device specified, video only"
        fi

        CAPTURE_CMD="$CAPTURE_CMD \
          -filter_complex \"\
            [0:v]split=2[timelapse][bursts]; \
            [timelapse]select='not(mod(t,900))*lt(mod(t,900),0.1)',setpts=N/(1/TB)[tl]; \
            [bursts]select='lt(mod(t,900),210)',setpts=PTS-STARTPTS+(floor(t/900)*900*TB)[br]; \
            [tl][br]concat=n=2:v=1:a=0[outv]\
          \" \
          -map \"[outv]\" $AUDIO_MAP \
          -c:v libx264 -preset veryfast -crf 23 -tune stillimage \
          -g 300 -bf 0 \
          -threads 0 \
          -t $DURATION_SEC \
          -movflags +faststart \
          \"$RAW_FILE\""

        log_info "Executing capture command..."

        if ! ${pkgs.coreutils}/bin/timeout $((DURATION_SEC + 600)) bash -c "$CAPTURE_CMD"; then
            log_error "Capture failed or timed out"
            exit 1
        fi

        if [[ ! -f "$RAW_FILE" ]]; then
            log_error "Raw file was not created: $RAW_FILE"
            exit 1
        fi

        RAW_SIZE=$(${pkgs.coreutils}/bin/du -h "$RAW_FILE" | cut -f1)
        RAW_SIZE_BYTES=$(${pkgs.coreutils}/bin/stat -c%s "$RAW_FILE")

        if [[ $RAW_SIZE_BYTES -lt 100000000 ]]; then
            log_error "Raw file too small ($RAW_SIZE), likely incomplete capture"
            exit 1
        fi

        log_info "Capture complete: $RAW_FILE ($RAW_SIZE)"

        # -------------------------- PROCESS TO 90 MIN --------------------
        log_info "Processing to 90-minute final with scene detection..."

        ${pkgs.ffmpeg}/bin/ffmpeg -i "$RAW_FILE" \
          -vf "scale=640:360:flags=lanczos,select='gte(scene\,0.35)',setpts=N/(30*TB)" \
          -vsync vfr \
          -c:v libx264 -crf 23 -preset fast \
          -an \
          -t $TARGET_SEC \
          -movflags +faststart \
          "$TEMP_FILE" 2>&1 | tee -a "$LOG"

        PROCESS_EXIT_CODE=''${PIPESTATUS[0]}

        if [[ $PROCESS_EXIT_CODE -ne 0 ]]; then
            log_error "Processing failed with exit code $PROCESS_EXIT_CODE"
            exit 1
        fi

        if [[ ! -f "$TEMP_FILE" ]]; then
            log_error "Final file was not created: $TEMP_FILE"
            exit 1
        fi

        TEMP_SIZE=$(${pkgs.coreutils}/bin/du -h "$TEMP_FILE" | cut -f1)
        TEMP_SIZE_BYTES=$(${pkgs.coreutils}/bin/stat -c%s "$TEMP_FILE")

        if [[ $TEMP_SIZE_BYTES -lt 10000000 ]]; then
            log_error "Final file too small ($TEMP_SIZE), processing may have failed"
            exit 1
        fi

        mv "$TEMP_FILE" "$FINAL_FILE"

        log_info "=========================================="
        log_info "SUCCESS: Processing complete"
        log_info "Final video: $FINAL_FILE ($TEMP_SIZE)"
        log_info "=========================================="

        DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FINAL_FILE" 2>/dev/null)
        log_info "Final video duration: ''${DURATION}s (target: ''${TARGET_SEC}s)"

        # -------------------------- CLEANUP OLD FILES ---------------------
        log_info "Cleaning up old files..."

        DELETED_RAW=$(${pkgs.findutils}/bin/find "$OUTPUT_DIR" -name "raw_*.mp4" -mtime +7 -type f 2>/dev/null | wc -l)
        ${pkgs.findutils}/bin/find "$OUTPUT_DIR" -name "raw_*.mp4" -mtime +7 -type f -delete 2>&1 | tee -a "$LOG_DIR/cleanup.log"
        log_info "Deleted $DELETED_RAW old raw files (>7 days)"

        DELETED_FINAL=$(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +30 -type f 2>/dev/null | wc -l)
        ${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +30 -type f -delete 2>&1 | tee -a "$LOG_DIR/cleanup.log"
        log_info "Deleted $DELETED_FINAL old final files (>30 days)"

        ${pkgs.findutils}/bin/find "$OUTPUT_DIR" -name "temp_*.mp4" -mtime +1 -type f -delete 2>/dev/null
        log_info "Cleaned temporary files"

        log_info "All operations complete. System ready for next run."
        exit 0
      '';

      cleanupShContent = ''
        #!/usr/bin/env bash
        set -uo pipefail
        IFS=$'\n\t'

        RAW_DIR="/timelapse/raw"
        FINAL_DIR="/timelapse/final"
        LOG_DIR="/var/log/timelapse"
        CLEANUP_LOG="$LOG_DIR/cleanup_$(date +%Y%m%d).log"
        ALERT_EMAIL="${cfg.alertEmail}"
        MIN_FREE_GB=20

        mkdir -p "$LOG_DIR"
        exec > >(tee -a "$CLEANUP_LOG") 2>&1

        log_info() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] INFO: $1"; }
        log_error() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] ERROR: $1" >&2; }

        AVAILABLE_GB=$(df --output=avail -BG "$RAW_DIR" | tail -1 | tr -d 'G')
        if [[ $AVAILABLE_GB -lt $MIN_FREE_GB ]]; then
            log_error "CRITICAL: Low disk space! Available: ''${AVAILABLE_GB}GB"
            echo "Low disk space on timelapse volume" | ${pkgs.mailutils}/bin/mail -s "TIMELAPSE DISK ALERT" "$ALERT_EMAIL"
            exit 1
        fi
        log_info "Disk space OK: ''${AVAILABLE_GB}GB available"

        DELETED_RAW=$(${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -mtime +7 -type f 2>/dev/null | wc -l)
        ${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -mtime +7 -type f -delete 2>/dev/null
        log_info "Deleted $DELETED_RAW raw files (>7 days)"

        DELETED_FINAL=$(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +30 -type f 2>/dev/null | wc -l)
        ${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +30 -type f -delete 2>/dev/null
        log_info "Deleted $DELETED_FINAL final files (>30 days)"

        ${pkgs.findutils}/bin/find "$RAW_DIR" -name "temp_*.mp4" -mtime +1 -type f -delete 2>/dev/null
        log_info "Cleaned temporary files"

        log_info "=== STORAGE REPORT ==="
        log_info "Raw files:   $(${pkgs.findutils}/bin/find "$RAW_DIR" -name "*.mp4" | wc -l) files, $(${pkgs.coreutils}/bin/du -sh "$RAW_DIR" | cut -f1)"
        log_info "Final files: $(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "*.mp4" | wc -l) files, $(${pkgs.coreutils}/bin/du -sh "$FINAL_DIR" | cut -f1)"
        log_info "Total usage: $(${pkgs.coreutils}/bin/du -sh /timelapse | cut -f1)"

        log_info "Cleanup complete."
        exit 0
      '';

      monitorShContent = ''
        #!/usr/bin/env bash
        set -uo pipefail
        IFS=$'\n\t'

        SERVICE="timelapse.service"
        LOG_DIR="/var/log/timelapse"
        HEALTH_LOG="$LOG_DIR/health_$(date +%Y-%m-%d).log"
        ALERT_EMAIL="${cfg.alertEmail}"

        mkdir -p "$LOG_DIR"
        exec > >(tee -a "$HEALTH_LOG") 2>&1

        log_info() { echo "[$(date +%H:%M:%S)] INFO: $1"; }
        log_error() { echo "[$(date +%H:%M:%S)] ERROR: $1" >&2; }

        if ! systemctl is-active --quiet "$SERVICE"; then
            log_error "SERVICE DOWN: $SERVICE is not running"
            echo "Timelapse service is DOWN" | ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: Service Down" "$ALERT_EMAIL"
            exit 1
        fi

        LATEST_FINAL=$(${pkgs.findutils}/bin/find /timelapse/final -name "worldbox_*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)
        if [[ -n "$LATEST_FINAL" ]]; then
            AGE_MIN=$(( ( $(date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$LATEST_FINAL") ) / 60 ))
            if [[ $AGE_MIN -gt 1440 ]]; then
                log_error "NO NEW OUTPUT in $AGE_MIN minutes"
                echo "No new timelapse in 24h" | ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: No Output" "$ALERT_EMAIL"
            else
                log_info "Latest output: $LATEST_FINAL ($AGE_MIN min ago)"
            fi
        else
            log_error "NO FINAL FILES found"
            echo "No final videos exist" | ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: No Files" "$ALERT_EMAIL"
        fi

        CPU=$(ps -C ffmpeg -o %cpu --no-headers 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        RAM=$(ps -C ffmpeg -o rss --no-headers 2>/dev/null | awk '{sum+=$1} END {print sum/1024 " MB"}')
        log_info "FFmpeg CPU: ''${CPU}% | RAM: $RAM"

        log_info "Health check passed."
        exit 0
      '';

      # FIXED: Use pkgs parameter instead of reconstructing
      captureSh = pkgs.writeScriptBin "capture.sh" captureShContent;
      cleanupSh = pkgs.writeScriptBin "cleanup.sh" cleanupShContent;
      monitorSh = pkgs.writeScriptBin "monitor.sh" monitorShContent;
    in {
      options.services.timelapse = {
        enable = mkEnableOption "WorldBox timelapse system";
        
        videoDevice = mkOption {
          type = types.str;
          default = "/dev/video0";
          description = "Path to video capture device (v4l2)";
        };
        
        audioDevice = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hw:1,0";
          description = "Optional ALSA audio device";
        };
        
        alertEmail = mkOption {
          type = types.str;
          default = "admin@example.com";
          description = "Email address for system alerts";
        };
      };

      config = mkIf cfg.enable {
        # Create system user
        users.users.timelapse = {
          isSystemUser = true;
          group = "timelapse";
          home = "/home/timelapse";
          createHome = true;
          shell = pkgs.bash;
          extraGroups = [ "video" "audio" ];  # FIXED: Added audio group
        };

        users.groups.timelapse = {};

        # FIXED: Include all required packages
        environment.systemPackages = with pkgs; [
          ffmpeg
          v4l-utils
          curl
          mailutils
          util-linux  # for flock
          coreutils
          findutils
          gawk
          procps  # for ps
        ];

        # Create directories with correct permissions
        systemd.tmpfiles.rules = [
          "d /timelapse/raw 0750 timelapse timelapse - -"
          "d /timelapse/final 0750 timelapse timelapse - -"
          "d /home/timelapse/timelapse 0750 timelapse timelapse - -"
          "d /var/log/timelapse 0750 timelapse timelapse - -"
        ];

        # FIXED: Use writeTextFile for proper script installation
        environment.etc = {
          "timelapse/capture.sh" = {
            text = captureShContent;
            mode = "0750";
            user = "timelapse";
            group = "timelapse";
          };
          "timelapse/cleanup.sh" = {
            text = cleanupShContent;
            mode = "0750";
            user = "timelapse";
            group = "timelapse";
          };
          "timelapse/monitor.sh" = {
            text = monitorShContent;
            mode = "0750";
            user = "timelapse";
            group = "timelapse";
          };
        };

        # FIXED: Better activation script
        system.activationScripts.setupTimelapseScripts = lib.stringAfter [ "etc" ] ''
          mkdir -p /home/timelapse/timelapse
          cp /etc/timelapse/*.sh /home/timelapse/timelapse/
          chmod +x /home/timelapse/timelapse/*.sh
          chown -R timelapse:timelapse /home/timelapse/timelapse
        '';

        # Main timelapse service
        systemd.services.timelapse = {
          description = "WorldBox 24h → 90min Timelapse System";
          after = [ "network-online.target" "systemd-udev-settle.service" ];
          wants = [ "network-online.target" "systemd-udev-settle.service" ];
          wantedBy = [ "multi-user.target" ];
          
          path = with pkgs; [
            ffmpeg
            v4l-utils
            coreutils
            util-linux
            findutils
            gawk
            bash
          ];
          
          serviceConfig = {
            Type = "simple";
            User = "timelapse";
            Group = "timelapse";
            WorkingDirectory = "/home/timelapse/timelapse";
            ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/timelapse/capture.sh";
            
            # Restart policy
            Restart = "on-failure";
            RestartSec = "60";
            StartLimitBurst = 3;
            StartLimitIntervalSec = 3600;
            
            # Timeouts
            TimeoutStartSec = 300;
            TimeoutStopSec = 300;
            
            # Resource limits
            LimitNOFILE = 65536;
            MemoryMax = "2G";
            CPUQuota = "200%";
            
            # Logging
            StandardOutput = "journal";
            StandardError = "journal";
            SyslogIdentifier = "timelapse";
            
            # Security hardening
            PrivateTmp = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ "/timelapse" "/var/log/timelapse" "/var/run" ];
            NoNewPrivileges = true;
            
            # FIXED: Only set OnFailure if email is configured
          } // (lib.optionalAttrs (cfg.alertEmail != "admin@example.com") {
            OnFailure = "timelapse-failure-notification.service";
          });
        };

        # FIXED: Conditional failure notification service
        systemd.services.timelapse-failure-notification = mkIf (cfg.alertEmail != "admin@example.com") {
          description = "Email notification for timelapse failure";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.bash}/bin/bash -c 'echo \"Timelapse service failed on $(hostname) at $(date)\" | ${pkgs.mailutils}/bin/mail -s \"SYSTEMD FAILURE: timelapse.service\" ${cfg.alertEmail}'";
          };
        };

        # Cleanup timer and service
        systemd.timers.timelapse-cleanup = {
          description = "Daily timelapse cleanup timer";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 03:00:00";
            Persistent = true;
          };
        };

        systemd.services.timelapse-cleanup = {
          description = "Timelapse storage cleanup";
          path = with pkgs; [ coreutils findutils gawk mailutils ];
          serviceConfig = {
            Type = "oneshot";
            User = "timelapse";
            Group = "timelapse";
            ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/timelapse/cleanup.sh";
          };
        };

        # Monitor timer and service
        systemd.timers.timelapse-monitor = {
          description = "Timelapse health monitor timer";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5m";
            OnUnitActiveSec = "15m";
            Persistent = true;
          };
        };

        systemd.services.timelapse-monitor = {
          description = "Timelapse health monitor";
          path = with pkgs; [ coreutils findutils gawk procps mailutils systemd ];
          serviceConfig = {
            Type = "oneshot";
            User = "timelapse";
            Group = "timelapse";
            ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/timelapse/monitor.sh";
          };
        };

        # Log rotation
        services.logrotate = {
          enable = true;
          settings.timelapse = {
            files = "/var/log/timelapse/*.log";
            frequency = "daily";
            rotate = 30;
            compress = true;
            delaycompress = true;
            missingok = true;
            notifempty = true;
            create = "640 timelapse timelapse";
          };
        };
      };
    };

    # FIXED: Add example configurations
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.timelapse
        {
          services.timelapse = {
            enable = true;
            videoDevice = "/dev/video0";
            audioDevice = null;  # or "hw:1,0" for audio
            alertEmail = "admin@example.com";
          };
        }
      ];
    };
  };
}
