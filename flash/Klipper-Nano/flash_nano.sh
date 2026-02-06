#!/usr/bin/env bash
set -e

# ---- CONFIG ----

KLIPPER_DIR="$HOME/klipper"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANO_CONFIG="$SCRIPT_DIR/nano_atmega328p_16mhz_250k.config"

PORT_GLOB="/dev/serial/by-id/usb-1a86_*"

# ---- CHECK KLIPPER ----

if [ ! -d "$KLIPPER_DIR" ]; then
  echo "ERROR: Klipper not found in $KLIPPER_DIR"
  exit 1
fi

# ---- CHECK CONFIG ----

if [ ! -f "$NANO_CONFIG" ]; then
  echo "ERROR: Config file not found:"
  echo "$NANO_CONFIG"
  exit 1
fi

# ---- DETECT NANO PORT ----

PORTS=( $PORT_GLOB )

if [ ${#PORTS[@]} -eq 0 ]; then
  echo "ERROR: No Arduino Nano detected."
  echo "Plug it in and try again."
  exit 1
fi

if [ ${#PORTS[@]} -gt 1 ]; then
  echo "ERROR: Multiple Nano devices detected:"
  for p in "${PORTS[@]}"; do
    echo "  $p"
  done
  echo "Disconnect extras and retry."
  exit 1
fi

PORT="${PORTS[0]}"

echo "Nano detected at:"
echo "  $PORT"

# ---- BUILD ----

cd "$KLIPPER_DIR"

echo "Copying config..."
cp "
