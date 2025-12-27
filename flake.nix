# Copyright 2025 DeMoD LLC
# SPDX-License-Identifier: BSD-3-Clause
#
# Production-ready WorldBox 24h Timelapse System
# Improvements: Two-pass capture, hardware accel, better error handling, chunked capture

{
  description = "WorldBox 24h Timelapse System - Production Edition";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: {
      # Make the module available as an overlay
      nixosModules.default = self.nixosModules.timelapse;
    }) // {
      nixosModules.timelapse = { config, lib, pkgs, ... }: let
        cfg = config.services.timelapse;
        inherit (lib) mkEnableOption mkIf mkOption types mkDefault;

        captureShContent = ''
          #!/usr/bin/env bash
          set -euo pipefail
          IFS=$'\n\t'

          # ==================== CONFIGURATION ====================
          VIDEO_DEV="${cfg.videoDevice}"
          AUDIO_DEV="${if cfg.audioDevice != null then cfg.audioDevice else ""}"
          OUTPUT_DIR="/timelapse/raw"
          CHUNKS_DIR="/timelapse/chunks"
          FINAL_DIR="/timelapse/final"
          LOG_DIR="/var/log/timelapse"
          LOCKFILE="/var/run/timelapse.lock"
          STATE_FILE="/var/run/timelapse.state"

          DURATION_SEC=$((24 * 3600))
          CHUNK_DURATION_SEC=$((4 * 3600))  # 4-hour chunks for reliability
          TARGET_MIN=90
          TARGET_SEC=$((TARGET_MIN * 60))
          MIN_FREE_SPACE_GB=${toString cfg.minDiskSpaceGB}
          
          HWACCEL_ENABLE="${if cfg.hardwareAcceleration then "true" else "false"}"
          HWACCEL_DEVICE="${cfg.hwaccelDevice}"

          mkdir -p "$OUTPUT_DIR" "$CHUNKS_DIR" "$FINAL_DIR" "$LOG_DIR"

          LOG="$LOG_DIR/capture_$(date +%Y%m%d_%H%M%S).log"
          exec > >(tee -a "$LOG") 2>&1

          # ==================== FUNCTIONS ====================
          log_error() {
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
          }

          log_info() {
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
          }

          log_warn() {
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"
          }

          update_state() {
              echo "$1" > "$STATE_FILE"
          }

          cleanup_and_exit() {
              local exit_code=$?
              update_state "STOPPED"
              flock -u 200 2>/dev/null || true
              rm -f "$LOCKFILE"
              
              if [[ $exit_code -ne 0 ]]; then
                  log_error "Exiting with error code $exit_code"
                  # Send alert if configured
                  if [[ "${cfg.alertEmail}" != "admin@example.com" ]]; then
                      echo "Timelapse capture failed. Check logs at $LOG" | \
                          ${pkgs.mailutils}/bin/mail -s "TIMELAPSE FAILURE" "${cfg.alertEmail}" 2>/dev/null || true
                  fi
              fi
              
              exit "$exit_code"
          }

          verify_video_file() {
              local file="$1"
              local min_size="$2"
              
              if [[ ! -f "$file" ]]; then
                  log_error "File does not exist: $file"
                  return 1
              fi
              
              local size=$(${pkgs.coreutils}/bin/stat -c%s "$file")
              if [[ $size -lt $min_size ]]; then
                  log_error "File too small: $file ($size bytes < $min_size bytes)"
                  return 1
              fi
              
              # Verify file integrity with ffprobe
              if ! ${pkgs.ffmpeg}/bin/ffprobe -v error -select_streams v:0 \
                  -count_packets -show_entries stream=nb_read_packets \
                  -of csv=p=0 "$file" &>/dev/null; then
                  log_error "File is corrupted or unreadable: $file"
                  return 1
              fi
              
              log_info "File verification passed: $file ($size bytes)"
              return 0
          }

          # ==================== BANNER ====================
          cat << 'EOF'
          ╔═══════════════════════════════════════════════════════════╗
          ║   WorldBox 24h → 90min Timelapse System v2.0             ║
          ║   Production Edition with Chunked Capture                 ║
          ╚═══════════════════════════════════════════════════════════╝
          EOF
          log_info "Start time: $(date)"

          # ==================== ATOMIC LOCKING ====================
          exec 200>"$LOCKFILE"
          if ! flock -n 200; then
              log_error "Another instance is running. Lock: $LOCKFILE"
              exit 1
          fi
          trap cleanup_and_exit EXIT INT TERM HUP

          update_state "STARTING"

          # ==================== PRE-FLIGHT CHECKS ====================
          log_info "Running pre-flight checks..."

          # Check disk space
          AVAILABLE_GB=$(df --output=avail -BG "$OUTPUT_DIR" | tail -1 | tr -d 'G')
          REQUIRED_GB=$((MIN_FREE_SPACE_GB + 50))  # Account for worst-case raw footage
          
          if [[ $AVAILABLE_GB -lt $REQUIRED_GB ]]; then
              log_error "Insufficient disk space. Available: ''${AVAILABLE_GB}GB, Required: ''${REQUIRED_GB}GB"
              exit 1
          fi
          log_info "Disk space OK: ''${AVAILABLE_GB}GB available (minimum: ''${REQUIRED_GB}GB)"

          # Check video device
          if [[ ! -c "$VIDEO_DEV" ]]; then
              log_error "Video device not found: $VIDEO_DEV"
              exit 1
          fi

          if ! ${pkgs.v4l-utils}/bin/v4l2-ctl --device="$VIDEO_DEV" --get-fmt-video &>/dev/null; then
              log_error "Video device $VIDEO_DEV not responding"
              exit 1
          fi
          
          DEVICE_INFO=$(${pkgs.v4l-utils}/bin/v4l2-ctl --device="$VIDEO_DEV" --get-fmt-video 2>/dev/null)
          log_info "Video device OK: $VIDEO_DEV"
          log_info "Device format: $DEVICE_INFO"

          # Check audio device if configured
          if [[ -n "$AUDIO_DEV" ]]; then
              if ${pkgs.alsa-utils}/bin/arecord -L | grep -q "^$AUDIO_DEV\$"; then
                  log_info "Audio device OK: $AUDIO_DEV"
              else
                  log_warn "Audio device not found: $AUDIO_DEV (continuing without audio)"
                  AUDIO_DEV=""
              fi
          fi

          # Check hardware acceleration
          HWACCEL_ARGS=""
          if [[ "$HWACCEL_ENABLE" == "true" ]]; then
              if [[ -e "$HWACCEL_DEVICE" ]]; then
                  log_info "Hardware acceleration enabled: $HWACCEL_DEVICE"
                  HWACCEL_ARGS="-hwaccel vaapi -hwaccel_device $HWACCEL_DEVICE -hwaccel_output_format vaapi"
              else
                  log_warn "Hardware acceleration device not found: $HWACCEL_DEVICE (using software)"
                  HWACCEL_ENABLE="false"
              fi
          fi

          log_info "FFmpeg version: $(${pkgs.ffmpeg}/bin/ffmpeg -version | head -1)"

          # ==================== CHUNKED CAPTURE ====================
          TIMESTAMP=$(date +%Y%m%d_%H%M%S)
          CHUNK_FILES=()
          NUM_CHUNKS=$((DURATION_SEC / CHUNK_DURATION_SEC))
          
          log_info "Starting chunked capture: $NUM_CHUNKS chunks of $((CHUNK_DURATION_SEC / 3600))h each"
          update_state "CAPTURING"

          for ((chunk=0; chunk<NUM_CHUNKS; chunk++)); do
              CHUNK_NUM=$(printf "%02d" $chunk)
              CHUNK_FILE="$CHUNKS_DIR/chunk_''${TIMESTAMP}_''${CHUNK_NUM}.mp4"
              
              log_info "====== Chunk $((chunk + 1))/$NUM_CHUNKS ======"
              log_info "Output: $CHUNK_FILE"
              
              # Build FFmpeg command
              FFMPEG_CMD=(
                  ${pkgs.ffmpeg}/bin/ffmpeg
                  -hide_banner
                  -loglevel warning
                  -stats
                  -y
              )
              
              # Add hardware acceleration if enabled
              if [[ "$HWACCEL_ENABLE" == "true" ]]; then
                  FFMPEG_CMD+=($HWACCEL_ARGS)
              fi
              
              # Video input
              FFMPEG_CMD+=(
                  -f v4l2
                  -framerate 30
                  -video_size 1920x1080
                  -input_format yuyv422
                  -i "$VIDEO_DEV"
              )
              
              # Audio input if configured
              if [[ -n "$AUDIO_DEV" ]]; then
                  FFMPEG_CMD+=(
                      -f alsa
                      -i "$AUDIO_DEV"
                  )
              fi
              
              # Video encoding
              if [[ "$HWACCEL_ENABLE" == "true" ]]; then
                  FFMPEG_CMD+=(
                      -c:v h264_vaapi
                      -qp 23
                  )
              else
                  FFMPEG_CMD+=(
                      -c:v libx264
                      -preset veryfast
                      -crf 23
                  )
              fi
              
              # Common encoding options
              FFMPEG_CMD+=(
                  -g 300
                  -bf 2
                  -threads 0
              )
              
              # Audio encoding if present
              if [[ -n "$AUDIO_DEV" ]]; then
                  FFMPEG_CMD+=(
                      -c:a aac
                      -b:a 128k
                  )
              fi
              
              # Duration and output
              FFMPEG_CMD+=(
                  -t "$CHUNK_DURATION_SEC"
                  -movflags +faststart
                  "$CHUNK_FILE"
              )
              
              # Execute with timeout
              TIMEOUT=$((CHUNK_DURATION_SEC + 600))
              if ! ${pkgs.coreutils}/bin/timeout "$TIMEOUT" "''${FFMPEG_CMD[@]}" 2>&1 | tee -a "$LOG"; then
                  log_error "Chunk $CHUNK_NUM capture failed or timed out"
                  exit 1
              fi
              
              # Verify chunk
              MIN_CHUNK_SIZE=$((500 * 1024 * 1024))  # 500MB minimum
              if ! verify_video_file "$CHUNK_FILE" "$MIN_CHUNK_SIZE"; then
                  log_error "Chunk $CHUNK_NUM verification failed"
                  exit 1
              fi
              
              CHUNK_FILES+=("$CHUNK_FILE")
              CHUNK_SIZE=$(${pkgs.coreutils}/bin/du -h "$CHUNK_FILE" | cut -f1)
              log_info "Chunk $CHUNK_NUM complete: $CHUNK_SIZE"
              
              # Brief pause between chunks
              sleep 5
          done

          log_info "All chunks captured successfully"
          update_state "PROCESSING"

          # ==================== MERGE CHUNKS ====================
          RAW_FILE="$OUTPUT_DIR/raw_''${TIMESTAMP}.mp4"
          CONCAT_LIST="$CHUNKS_DIR/concat_''${TIMESTAMP}.txt"
          
          log_info "Merging ''${#CHUNK_FILES[@]} chunks into: $RAW_FILE"
          
          # Create concat list
          for chunk_file in "''${CHUNK_FILES[@]}"; do
              echo "file '$chunk_file'" >> "$CONCAT_LIST"
          done
          
          # Merge chunks
          if ! ${pkgs.ffmpeg}/bin/ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" \
              -c copy -movflags +faststart "$RAW_FILE" 2>&1 | tee -a "$LOG"; then
              log_error "Chunk merging failed"
              exit 1
          fi
          
          if ! verify_video_file "$RAW_FILE" $((1000 * 1024 * 1024)); then
              log_error "Merged raw file verification failed"
              exit 1
          fi
          
          RAW_SIZE=$(${pkgs.coreutils}/bin/du -h "$RAW_FILE" | cut -f1)
          log_info "Raw merge complete: $RAW_FILE ($RAW_SIZE)"
          
          # Clean up chunks
          rm -f "$CONCAT_LIST"
          for chunk_file in "''${CHUNK_FILES[@]}"; do
              rm -f "$chunk_file"
          done
          log_info "Temporary chunks removed"

          # ==================== TWO-PASS PROCESSING ====================
          FINAL_FILE="$FINAL_DIR/worldbox_''${TIMESTAMP}.mp4"
          TEMP_FILE="$OUTPUT_DIR/temp_''${TIMESTAMP}.mp4"
          
          log_info "Processing to 90-minute final with adaptive scene detection..."
          
          # First pass: analyze scenes to determine optimal threshold
          log_info "Pass 1/2: Scene analysis..."
          SCENE_DATA="$OUTPUT_DIR/scenes_''${TIMESTAMP}.txt"
          
          ${pkgs.ffmpeg}/bin/ffmpeg -i "$RAW_FILE" \
              -vf "select='gte(scene\,0.2)',metadata=print:file=$SCENE_DATA" \
              -f null - 2>&1 | tee -a "$LOG" || true
          
          # Count potential scenes
          SCENE_COUNT=$(grep -c "pts_time" "$SCENE_DATA" 2>/dev/null || echo "0")
          log_info "Detected $SCENE_COUNT scene changes at 0.2 threshold"
          
          # Adjust threshold based on scene count
          # Target: ~2700 frames for 90 min at 30fps (5400s / 2s per frame)
          TARGET_FRAMES=2700
          if [[ $SCENE_COUNT -gt $((TARGET_FRAMES * 2)) ]]; then
              SCENE_THRESHOLD="0.35"
          elif [[ $SCENE_COUNT -gt $((TARGET_FRAMES + 500)) ]]; then
              SCENE_THRESHOLD="0.28"
          else
              SCENE_THRESHOLD="0.2"
          fi
          
          log_info "Using scene threshold: $SCENE_THRESHOLD"
          
          # Second pass: create final video
          log_info "Pass 2/2: Creating final video..."
          
          ${pkgs.ffmpeg}/bin/ffmpeg -i "$RAW_FILE" \
              -vf "select='gte(scene\,$SCENE_THRESHOLD)',scale=1280:720:flags=lanczos,setpts=N/(30*TB)" \
              -vsync vfr \
              -c:v libx264 \
              -crf 21 \
              -preset slow \
              -tune film \
              -an \
              -movflags +faststart \
              "$TEMP_FILE" 2>&1 | tee -a "$LOG"
          
          if [[ ''${PIPESTATUS[0]} -ne 0 ]]; then
              log_error "Final processing failed"
              exit 1
          fi
          
          if ! verify_video_file "$TEMP_FILE" $((20 * 1024 * 1024)); then
              log_error "Final file verification failed"
              exit 1
          fi
          
          # Get actual duration
          ACTUAL_DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v error \
              -show_entries format=duration \
              -of default=noprint_wrappers=1:nokey=1 "$TEMP_FILE" 2>/dev/null)
          ACTUAL_DURATION_MIN=$(echo "$ACTUAL_DURATION / 60" | ${pkgs.bc}/bin/bc)
          
          mv "$TEMP_FILE" "$FINAL_FILE"
          
          FINAL_SIZE=$(${pkgs.coreutils}/bin/du -h "$FINAL_FILE" | cut -f1)
          
          log_info "╔═════════════════════════════════════════════════╗"
          log_info "║           PROCESSING COMPLETE                   ║"
          log_info "╚═════════════════════════════════════════════════╝"
          log_info "Final video: $FINAL_FILE"
          log_info "File size: $FINAL_SIZE"
          log_info "Duration: ''${ACTUAL_DURATION_MIN} minutes (target: $TARGET_MIN min)"
          log_info "Scene threshold: $SCENE_THRESHOLD"
          
          # Clean up scene data
          rm -f "$SCENE_DATA"
          
          update_state "CLEANUP"

          # ==================== CLEANUP OLD FILES ====================
          log_info "Cleaning up old files..."
          
          DELETED_RAW=$(${pkgs.findutils}/bin/find "$OUTPUT_DIR" -name "raw_*.mp4" -mtime +${toString cfg.rawRetentionDays} -type f 2>/dev/null | wc -l)
          ${pkgs.findutils}/bin/find "$OUTPUT_DIR" -name "raw_*.mp4" -mtime +${toString cfg.rawRetentionDays} -type f -delete 2>/dev/null || true
          log_info "Deleted $DELETED_RAW old raw files (>${toString cfg.rawRetentionDays} days)"
          
          DELETED_FINAL=$(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +${toString cfg.finalRetentionDays} -type f 2>/dev/null | wc -l)
          ${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +${toString cfg.finalRetentionDays} -type f -delete 2>/dev/null || true
          log_info "Deleted $DELETED_FINAL old final files (>${toString cfg.finalRetentionDays} days)"
          
          # Clean any temp files
          ${pkgs.findutils}/bin/find "$OUTPUT_DIR" "$CHUNKS_DIR" -name "temp_*.mp4" -o -name "chunk_*.mp4" -o -name "scenes_*.txt" -mtime +1 -type f -delete 2>/dev/null || true
          
          update_state "COMPLETE"
          log_info "All operations complete. Ready for next run."
          exit 0
        '';

        cleanupShContent = ''
          #!/usr/bin/env bash
          set -euo pipefail
          IFS=$'\n\t'

          RAW_DIR="/timelapse/raw"
          CHUNKS_DIR="/timelapse/chunks"
          FINAL_DIR="/timelapse/final"
          LOG_DIR="/var/log/timelapse"
          CLEANUP_LOG="$LOG_DIR/cleanup_$(date +%Y%m%d).log"
          MIN_FREE_GB=${toString cfg.minDiskSpaceGB}

          mkdir -p "$LOG_DIR"
          exec > >(tee -a "$CLEANUP_LOG") 2>&1

          log_info() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] INFO: $*"; }
          log_error() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] ERROR: $*" >&2; }
          log_warn() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] WARN: $*"; }

          # Check disk space
          AVAILABLE_GB=$(df --output=avail -BG "$RAW_DIR" | tail -1 | tr -d 'G')
          USED_PERCENT=$(df --output=pcent "$RAW_DIR" | tail -1 | tr -d ' %')
          
          log_info "Disk usage: ''${USED_PERCENT}% used, ''${AVAILABLE_GB}GB available"
          
          if [[ $AVAILABLE_GB -lt $MIN_FREE_GB ]]; then
              log_error "CRITICAL: Low disk space! Available: ''${AVAILABLE_GB}GB"
              if [[ "${cfg.alertEmail}" != "admin@example.com" ]]; then
                  echo "Low disk space on timelapse volume: ''${AVAILABLE_GB}GB remaining" | \
                      ${pkgs.mailutils}/bin/mail -s "TIMELAPSE DISK ALERT" "${cfg.alertEmail}" 2>/dev/null || true
              fi
          fi

          # Aggressive cleanup if disk is really low
          if [[ $AVAILABLE_GB -lt 10 ]]; then
              log_warn "Emergency cleanup: removing files older than 3 days"
              ${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -mtime +3 -type f -delete 2>/dev/null || true
          fi

          # Normal cleanup
          DELETED_RAW=$(${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -mtime +${toString cfg.rawRetentionDays} -type f 2>/dev/null | wc -l)
          ${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -mtime +${toString cfg.rawRetentionDays} -type f -delete 2>/dev/null || true
          log_info "Deleted $DELETED_RAW raw files (>${toString cfg.rawRetentionDays} days)"

          DELETED_FINAL=$(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +${toString cfg.finalRetentionDays} -type f 2>/dev/null | wc -l)
          ${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -mtime +${toString cfg.finalRetentionDays} -type f -delete 2>/dev/null || true
          log_info "Deleted $DELETED_FINAL final files (>${toString cfg.finalRetentionDays} days)"

          # Clean temporary files
          ${pkgs.findutils}/bin/find "$RAW_DIR" "$CHUNKS_DIR" \( -name "temp_*.mp4" -o -name "chunk_*.mp4" -o -name "concat_*.txt" -o -name "scenes_*.txt" \) -mtime +1 -type f -delete 2>/dev/null || true
          log_info "Cleaned temporary files"

          # Clean old logs
          ${pkgs.findutils}/bin/find "$LOG_DIR" -name "*.log" -mtime +60 -type f -delete 2>/dev/null || true

          log_info "=== STORAGE REPORT ==="
          log_info "Raw files:   $(${pkgs.findutils}/bin/find "$RAW_DIR" -name "raw_*.mp4" -type f 2>/dev/null | wc -l) files, $(${pkgs.coreutils}/bin/du -sh "$RAW_DIR" 2>/dev/null | cut -f1)"
          log_info "Final files: $(${pkgs.findutils}/bin/find "$FINAL_DIR" -name "worldbox_*.mp4" -type f 2>/dev/null | wc -l) files, $(${pkgs.coreutils}/bin/du -sh "$FINAL_DIR" 2>/dev/null | cut -f1)"
          log_info "Total usage: $(${pkgs.coreutils}/bin/du -sh /timelapse 2>/dev/null | cut -f1)"
          log_info "Cleanup complete"
          exit 0
        '';

        monitorShContent = ''
          #!/usr/bin/env bash
          set -euo pipefail
          IFS=$'\n\t'

          SERVICE="timelapse.service"
          LOG_DIR="/var/log/timelapse"
          HEALTH_LOG="$LOG_DIR/health_$(date +%Y%m%d).log"
          STATE_FILE="/var/run/timelapse.state"

          mkdir -p "$LOG_DIR"
          exec > >(tee -a "$HEALTH_LOG") 2>&1

          log_info() { echo "[$(date +%H:%M:%S)] INFO: $*"; }
          log_error() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }
          log_warn() { echo "[$(date +%H:%M:%S)] WARN: $*"; }

          # Check service status
          if ! systemctl is-active --quiet "$SERVICE"; then
              # Check if it's supposed to be running
              if [[ -f "$STATE_FILE" ]]; then
                  STATE=$(cat "$STATE_FILE")
                  if [[ "$STATE" != "COMPLETE" ]]; then
                      log_error "SERVICE DOWN: $SERVICE is not running (state: $STATE)"
                      if [[ "${cfg.alertEmail}" != "admin@example.com" ]]; then
                          echo "Timelapse service is DOWN (state: $STATE)" | \
                              ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: Service Down" "${cfg.alertEmail}" 2>/dev/null || true
                      fi
                      exit 1
                  fi
              fi
          else
              if [[ -f "$STATE_FILE" ]]; then
                  STATE=$(cat "$STATE_FILE")
                  log_info "Service running (state: $STATE)"
              else
                  log_info "Service running (state: unknown)"
              fi
          fi

          # Check for recent output
          LATEST_FINAL=$(${pkgs.findutils}/bin/find /timelapse/final -name "worldbox_*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
          if [[ -n "$LATEST_FINAL" ]]; then
              AGE_MIN=$(( ( $(date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$LATEST_FINAL") ) / 60 ))
              HOURS=$((AGE_MIN / 60))
              MINS=$((AGE_MIN % 60))
              
              if [[ $AGE_MIN -gt 1680 ]]; then  # 28 hours (allow some margin)
                  log_error "NO NEW OUTPUT in ''${HOURS}h ''${MINS}m"
                  if [[ "${cfg.alertEmail}" != "admin@example.com" ]]; then
                      echo "No new timelapse in >28h (last: ''${HOURS}h ''${MINS}m ago)" | \
                          ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: No Output" "${cfg.alertEmail}" 2>/dev/null || true
                  fi
              else
                  log_info "Latest output: $(basename "$LATEST_FINAL") (''${HOURS}h ''${MINS}m ago)"
              fi
          else
              log_warn "NO FINAL FILES found"
          fi

          # Check resource usage
          if pgrep -x ffmpeg > /dev/null; then
              CPU=$(ps -C ffmpeg -o %cpu --no-headers 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
              RAM_KB=$(ps -C ffmpeg -o rss --no-headers 2>/dev/null | awk '{sum+=$1} END {print sum}')
              RAM_MB=$((RAM_KB / 1024))
              log_info "FFmpeg resources: CPU=''${CPU}%, RAM=''${RAM_MB}MB"
              
              # Alert if using too much memory
              if [[ $RAM_MB -gt 4096 ]]; then
                  log_warn "High memory usage: ''${RAM_MB}MB"
              fi
          fi

          # Check disk health
          DISK_USAGE=$(df --output=pcent /timelapse | tail -1 | tr -d ' %')
          log_info "Disk usage: ''${DISK_USAGE}%"
          
          if [[ $DISK_USAGE -gt 90 ]]; then
              log_error "Disk usage critical: ''${DISK_USAGE}%"
              if [[ "${cfg.alertEmail}" != "admin@example.com" ]]; then
                  echo "Disk usage critical: ''${DISK_USAGE}%" | \
                      ${pkgs.mailutils}/bin/mail -s "TIMELAPSE ALERT: Disk Full" "${cfg.alertEmail}" 2>/dev/null || true
              fi
          fi

          log_info "Health check complete"
          exit 0
        '';

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
            description = "Optional ALSA audio device for capture";
          };

          alertEmail = mkOption {
            type = types.str;
            default = "admin@example.com";
            description = "Email address for system alerts";
          };

          hardwareAcceleration = mkOption {
            type = types.bool;
            default = false;
            description = "Enable hardware acceleration (VAAPI) for encoding";
          };

          hwaccelDevice = mkOption {
            type = types.str;
            default = "/dev/dri/renderD128";
            description = "Hardware acceleration device path";
          };

          minDiskSpaceGB = mkOption {
            type = types.int;
            default = 20;
            description = "Minimum free disk space in GB before cleanup";
          };

          rawRetentionDays = mkOption {
            type = types.int;
            default = 7;
            description = "Days to keep raw capture files";
          };

          finalRetentionDays = mkOption {
            type = types.int;
            default = 30;
            description = "Days to keep final processed videos";
          };
        };

        config = mkIf cfg.enable {
          # System user
          users.users.timelapse = {
            isSystemUser = true;
            group = "timelapse";
            home = "/home/timelapse";
            createHome = true;
            shell = pkgs.bash;
            extraGroups = [ "video" "audio" "render" ];
          };

          users.groups.timelapse = {};

          # Required packages
          environment.systemPackages = with pkgs; [
            ffmpeg
            v4l-utils
            alsa-utils
            bc
            curl
            mailutils
            util-linux
            coreutils
            findutils
            gawk
            procps
          ];

          # Directory structure
          systemd.tmpfiles.rules = [
            "d /timelapse 0755 timelapse timelapse - -"
            "d /timelapse/raw 0750 timelapse timelapse - -"
            "d /timelapse/chunks 0750 timelapse timelapse - -"
            "d /timelapse/final 0755 timelapse timelapse - -"
            "d /var/log/timelapse 0750 timelapse timelapse - -"
            "d /home/timelapse/scripts 0750 timelapse timelapse - -"
          ];

          # Install scripts
          environment.etc = {
            "timelapse/capture.sh" = {
              text = captureShContent;
              mode = "0750";
            };
            "timelapse/cleanup.sh" = {
              text = cleanupShContent;
              mode = "0750";
            };
            "timelapse/monitor.sh" = {
              text = monitorShContent;
              mode = "0750";
            };
          };

          system.activationScripts.timelapseSetup = lib.stringAfter [ "etc" "users" ] ''
            mkdir -p /home/timelapse/scripts
            cp /etc/timelapse/*.sh /home/timelapse/scripts/
            chmod 750 /home/timelapse/scripts/*.sh
            chown -R timelapse:timelapse /home/timelapse/scripts
          '';

          # Main service
          systemd.services.timelapse = {
            description = "WorldBox 24h → 90min Timelapse System (Chunked Capture)";
            after = [ "network-online.target" "systemd-udev-settle.service" ];
            wants = [ "network-online.target" "systemd-udev-settle.service" ];
            wantedBy = [ "multi-user.target" ];

            path = with pkgs; [
              ffmpeg
              v4l-utils
              alsa-utils
              bc
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
              WorkingDirectory = "/home/timelapse/scripts";
              ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/scripts/capture.sh";

              # Restart policy
              Restart = "on-failure";
              RestartSec = "5m";
              StartLimitBurst = 3;
              StartLimitIntervalSec = "12h";

              # Timeouts
              TimeoutStartSec = "5m";
              TimeoutStopSec = "10m";
              KillMode = "mixed";
              KillSignal = "SIGTERM";

              # Resource limits
              LimitNOFILE = 65536;
              MemoryMax = "4G";
              CPUQuota = "250%";
              IOWeight = 500;

              # Logging
              StandardOutput = "journal";
              StandardError = "journal";
              SyslogIdentifier = "timelapse";

              # Security
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [ "/timelapse" "/var/log/timelapse" "/var/run" "/home/timelapse" ];
              NoNewPrivileges = true;
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              RestrictRealtime = true;
              LockPersonality = true;
              
              # Device access
              DeviceAllow = [
                "/dev/video0 rw"
                "/dev/dri/renderD128 rw"
              ];
            } // (lib.optionalAttrs (cfg.alertEmail != "admin@example.com") {
              OnFailure = "timelapse-failure-notification.service";
            });
          };

          # Failure notification
          systemd.services.timelapse-failure-notification = mkIf (cfg.alertEmail != "admin@example.com") {
            description = "Timelapse failure email notification";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "notify-failure" ''
                echo "Timelapse service failed on $(${pkgs.nettools}/bin/hostname) at $(${pkgs.coreutils}/bin/date). Check journal: journalctl -u timelapse.service -n 100" | \
                ${pkgs.mailutils}/bin/mail -s "TIMELAPSE SERVICE FAILURE" ${cfg.alertEmail}
              '';
            };
          };

          # Cleanup timer
          systemd.timers.timelapse-cleanup = {
            description = "Daily timelapse cleanup";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "daily";
              OnBootSec = "15m";
              Persistent = true;
              RandomizedDelaySec = "30m";
            };
          };

          systemd.services.timelapse-cleanup = {
            description = "Timelapse storage cleanup";
            path = with pkgs; [ coreutils findutils gawk mailutils bash ];
            serviceConfig = {
              Type = "oneshot";
              User = "timelapse";
              Group = "timelapse";
              ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/scripts/cleanup.sh";
              IOSchedulingClass = "idle";
              CPUSchedulingPolicy = "idle";
            };
          };

          # Health monitor timer
          systemd.timers.timelapse-monitor = {
            description = "Timelapse health monitoring";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "10m";
              OnUnitActiveSec = "30m";
              Persistent = true;
            };
          };

          systemd.services.timelapse-monitor = {
            description = "Timelapse health monitor";
            path = with pkgs; [ coreutils findutils gawk procps mailutils systemd bash ];
            serviceConfig = {
              Type = "oneshot";
              User = "timelapse";
              Group = "timelapse";
              ExecStart = "${pkgs.bash}/bin/bash /home/timelapse/scripts/monitor.sh";
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
              create = "0640 timelapse timelapse";
              postrotate = "systemctl kill -s HUP rsyslog.service 2>/dev/null || true";
            };
          };

          # Kernel tuning for video capture
          boot.kernel.sysctl = {
            "vm.swappiness" = mkDefault 10;
            "vm.vfs_cache_pressure" = mkDefault 50;
          };
        };
      };

      # Example configuration
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.timelapse
          {
            services.timelapse = {
              enable = true;
              videoDevice = "/dev/video0";
              audioDevice = null;
              alertEmail = "admin@example.com";
              hardwareAcceleration = false;
              minDiskSpaceGB = 30;
              rawRetentionDays = 7;
              finalRetentionDays = 60;
            };
          }
        ];
      };
    };
}
