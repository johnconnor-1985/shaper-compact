cat > flash/Klipper-Nano/flash_nano.sh <<'EOF'
#!/usr/bin/env bash
set -e

echo "==> flash_nano.sh started"

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
  echo "ERROR: Config file not found: $NANO_CONFIG"
  exit 1
fi

# ---- DETECT NANO PORT (strict) ----
PORTS=( $PORT_GLOB )

if [ "${#PORTS[@]}" -eq 0 ]; then
  echo "ERROR: No CH340 device found ($PORT_GLOB). Plug the Nano and retry."
  exit 1
fi

if [ "${#PORTS[@]}" -gt 1 ]; then
  echo "ERROR: Multiple CH340 devices detected. Disconnect extras:"
  for p in "${PORTS[@]}"; do
    echo "  $p"
  done
  exit 1
fi

PORT="${PORTS[0]}"

echo "==> Nano detected at: $PORT"
echo "==> Using config:     $NANO_CONFIG"
echo "==> Klipper dir:      $KLIPPER_DIR"

# ---- BUILD ----
cd "$KLIPPER_DIR"

echo "==> Copying config to Klipper .config"
cp "$NANO_CONFIG" .config

echo "==> make clean"
make clean

echo "==> make"
make

# ---- STOP KLIPPER (only if service exists) ----
if systemctl list-unit-files 2>/dev/null | grep -q '^klipper\.service'; then
  echo "==> Stopping Klipper service"
  sudo systemctl stop klipper
else
  echo "==> Klipper service not found (skipping stop/start)"
fi

# ---- FLASH ----
echo "==> Flashing Nano..."
make flash FLASH_DEVICE="$PORT"

# ---- START KLIPPER (only if service exists) ----
if systemctl list-unit-files 2>/dev/null | grep -q '^klipper\.service'; then
  echo "==> Starting Klipper service"
  sudo systemctl start klipper
fi

echo "✅ Flash complete."
EOF
