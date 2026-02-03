#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Shaper Compact - USB Installer (USB-only)
# Goals:
#  - Auto-mount vfat/exfat USB drives on insert (udev + systemd)
#  - Expose ONLY *.gcode files in: ~/printer_data/gcodes/USB
#  - Keep mount point technical: /media/usb
#  - SAFE and future-proof cleanup:
#      * removes only folders previously managed by this installer
#      * plus legacy names we used in older versions (usb/USB mount mistakes)
# ------------------------------------------------------------

LOG="/tmp/shaper-compact-usb-install.log"
exec > >(tee -a "$LOG") 2>&1

timestamp() { date +%Y%m%d-%H%M%S; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Missing command: $1"
    exit 1
  }
}

backup_file_sudo() {
  local f="$1"
  if sudo test -f "$f"; then
    local b="${f}.bak-$(timestamp)"
    sudo cp -a "$f" "$b"
    echo "🗂️  Backup created: $b"
  fi
}

write_file_sudo() {
  local path="$1"
  local content="$2"
  sudo mkdir -p "$(dirname "$path")"
  backup_file_sudo "$path"
  printf "%s" "$content" | sudo tee "$path" >/dev/null
}

echo "===================================="
echo " Shaper Compact USB Installer"
echo "===================================="
echo "Log: $LOG"
echo ""

# Safety: do NOT run as root
if [[ "${EUID}" -eq 0 ]]; then
  echo "❌ Do not run as root."
  echo "Run as your normal user (e.g. velvet). This script will use sudo when needed."
  exit 1
fi

USER_NAME="$(whoami)"
HOME_DIR="$(eval echo "~${USER_NAME}")"

need_cmd sudo
need_cmd tee
need_cmd systemctl
need_cmd udevadm
need_cmd blkid
need_cmd find
need_cmd mount
need_cmd umount

echo "User:     $USER_NAME"
echo "Home:     $HOME_DIR"
echo "Hostname: $(hostname)"
echo ""

# Detect printer_data (MainsailOS standard)
PRINTER_DATA=""
if [[ -d "${HOME_DIR}/printer_data" ]]; then
  PRINTER_DATA="${HOME_DIR}/printer_data"
elif [[ -d "${HOME_DIR}/klipper_config" ]]; then
  PRINTER_DATA="${HOME_DIR}/klipper_config"
else
  echo "❌ Could not find printer_data in:"
  echo "   - ${HOME_DIR}/printer_data"
  echo "   - ${HOME_DIR}/klipper_config"
  exit 1
fi

GCODE_ROOT="${PRINTER_DATA}/gcodes"
USB_DIR="${GCODE_ROOT}/USB"          # FINAL user-visible folder (uppercase)
MOUNT_POINT="/media/usb"             # Technical mount point (lowercase)
MARKER_FILENAME=".managed_by_shaper_usb"

echo "printer_data: $PRINTER_DATA"
echo "gcodes root:  $GCODE_ROOT"
echo "USB folder:   $USB_DIR"
echo "mount point:  $MOUNT_POINT"
echo ""

echo "[1/9] Ensure required directories exist..."
mkdir -p "$USB_DIR"
sudo mkdir -p "$MOUNT_POINT"
sudo chown "${USER_NAME}:${USER_NAME}" "$MOUNT_POINT"

# ------------------------------------------------------------
# SAFE CLEANUP STRATEGY
#  - Unmount any old mounts that mistakenly mounted inside gcodes/*
#  - Remove only:
#     a) folders that contain our marker file (managed folders)
#     b) a small list of legacy folder names we used historically (usb, USB if it was used wrongly)
# ------------------------------------------------------------

echo "[2/9] Stop any running USB services (cleanup)..."
sudo systemctl stop "usb-gcode@*.service" 2>/dev/null || true
sudo systemctl reset-failed 2>/dev/null || true

echo "[3/9] Unmount stale mounts (if any)..."
# Unmount anything mounted at /media/usb
sudo umount "$MOUNT_POINT" 2>/dev/null || true

# Unmount anything mounted somewhere under gcodes root (legacy mistakes)
# We parse mount output and unmount targets inside GCODE_ROOT
while read -r dev on target type fstype rest; do
  if [[ "$target" == "$GCODE_ROOT"* ]]; then
    echo "⚠️  Unmounting legacy mount inside gcodes: $target"
    sudo umount "$target" 2>/dev/null || true
  fi
done < <(mount | awk '{print $1, $2, $3, $4, $5, $6}')

echo "[4/9] Remove previously managed folders (safe)..."
# Remove any folder under GCODE_ROOT that contains our marker file, except the final USB_DIR
# (This makes it future-proof without deleting unrelated customer folders.)
while IFS= read -r marker; do
  dir="$(dirname "$marker")"
  if [[ "$dir" != "$USB_DIR" ]]; then
    echo "🧹 Removing managed folder: $dir"
    rm -rf "$dir"
  fi
done < <(find "$GCODE_ROOT" -maxdepth 2 -type f -name "$MARKER_FILENAME" 2>/dev/null || true)

echo "[5/9] Handle legacy folders we used in the past (minimal + safe)..."
# If there is a legacy "usb" folder (lowercase), archive it instead of deleting (non-destructive)
LEGACY_USB="${GCODE_ROOT}/usb"
if [[ -d "$LEGACY_USB" ]]; then
  ARCHIVE="${LEGACY_USB}_old-$(timestamp)"
  echo "⚠️  Found legacy folder: $LEGACY_USB"
  echo "➡️  Archiving it to: $ARCHIVE"
  mv "$LEGACY_USB" "$ARCHIVE"
fi

# Ensure final USB folder exists
mkdir -p "$USB_DIR"

# Mark the final folder as "managed"
touch "${USB_DIR}/${MARKER_FILENAME}"

echo "[6/9] Install exFAT support (if missing)..."
sudo apt update
sudo apt install -y exfat-fuse exfatprogs

echo "[7/9] Install/Update usb-gcode handler script..."
USB_GCODE_SH_CONTENT=$(cat <<EOF
#!/bin/bash
set -e

ACTION=\$1
DEV=\$2

MOUNT_POINT="${MOUNT_POINT}"
KLIPPER_DIR="${USB_DIR}"

# detect fs type (vfat/exfat)
FSTYPE=\$(blkid -o value -s TYPE "\$DEV" 2>/dev/null || true)

if [ "\$ACTION" = "add" ]; then
  if [ "\$FSTYPE" = "vfat" ] || [ "\$FSTYPE" = "exfat" ]; then
    # mount read-only for safety
    mount -o ro,uid=${USER_NAME},gid=${USER_NAME},umask=000 "\$DEV" "\$MOUNT_POINT"

    # Clean user-visible folder (files only)
    rm -f "\$KLIPPER_DIR"/*

    # Link ONLY *.gcode from the root of the USB drive
    find "\$MOUNT_POINT" -maxdepth 1 -type f -iname "*.gcode" \\
      -exec ln -s {} "\$KLIPPER_DIR"/ \\;
  fi
fi

if [ "\$ACTION" = "remove" ]; then
  rm -f "\$KLIPPER_DIR"/*
  umount "\$MOUNT_POINT" 2>/dev/null || true
fi
EOF
)

write_file_sudo "/usr/local/bin/usb-gcode.sh" "$USB_GCODE_SH_CONTENT"
sudo chmod +x /usr/local/bin/usb-gcode.sh

echo "[8/9] Install/Update systemd service + udev rule..."
USB_SERVICE_CONTENT=$(cat <<'EOF'
[Unit]
Description=USB Gcode automount (%i)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gcode.sh add /dev/%i
ExecStop=/usr/local/bin/usb-gcode.sh remove /dev/%i
RemainAfterExit=yes
EOF
)
write_file_sudo "/etc/systemd/system/usb-gcode@.service" "$USB_SERVICE_CONTENT"

UDEV_RULE='ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}=="vfat|exfat", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gcode@%k.service"'
write_file_sudo "/etc/udev/rules.d/99-usb-gcode.rules" "${UDEV_RULE}"$'\n'

echo "[9/9] Reload systemd + udev..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger

echo ""
echo "✅ USB installer completed successfully."
echo ""
echo "TEST:"
echo "  1) Insert a FAT32 or exFAT USB stick with *.gcode files in the ROOT"
echo "  2) Wait 2–3 seconds"
echo "  3) Run:"
echo "     ls -la \"${USB_DIR}\""
echo ""
echo "Debug:"
echo "  mount | grep \"${MOUNT_POINT}\""
echo "  systemctl status usb-gcode@sda1.service"
echo ""
