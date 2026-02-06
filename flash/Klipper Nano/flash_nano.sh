#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

# Klipper installation directory (default: ~/klipper)
KLIPPER_DIR="${KLIPPER_DIR:-$HOME/klipper}"

# Only detect CH340/CH341 USB serial devices (Arduino Nano clones)
SERIAL_BY_ID_DIR="/dev/serial/by-id"
PORT_GLOB="$SERIAL_BY_ID_DIR/usb-1a86_*"

# Directory where this script is located (handles spaces in path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nano firmware config stored next to this script
NANO_CONFIG="${NANO_CONFIG:-$SCRIPT_DIR/nano_atmega328p_16mhz_250k.config}"

# Skip "make clean" if set to 1
SKIP_CLEAN="${SKIP_CLEAN:-0}"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

# Ensure required command exists
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command '$1' not found."
    exit 1
  }
}

# Check if Klipper system service exists
have_klipper_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files | grep -q "^klipper\.service" && return 0 || return 1
  else
    service --status-all 2>/dev/null | grep -q "klipper" && return 0 || return 1
  fi
}

# Stop Klipper service if present
stop_klipper_if_present() {
  if have_klipper_service; then
    echo "==> Stopping Klipper service"
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl stop klipper
    else
      sudo service klipper stop
    fi
  else
    echo "==> Klipper service not found (skipping stop/start)"
  fi
}

# Start Klipper service if present
start_klipper_if_present() {
  if have_klipper_service; then
    echo "==> Starting Klipper service"
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl start klipper
    else
      sudo servic
