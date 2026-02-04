#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Shaper Compact - Installer
# Features:
#  1) USB G-code workflow:
#     - Auto-mount vfat/exfat USB drives on insert (udev + systemd)
#     - Expose ONLY *.gcode files in:  ~/printer_data/gcodes/USB
#     - Use technical mount point:     /media/usb
#     - Cleanup gcodes root: delete everything except "USB"
#  2) Deploy config from Git:
#     - Pull shaper-compact repo (or use local repo if running inside it)
#     - Copy files from repo ./configs to Klipper config directories:
#         * macros.cfg, setup.cfg -> <printer_data>/config/Configs/
#         * all others            -> <printer_data>/config/
#     - Create backups only if destination existed and differed:
#         * backups are stored in <printer_data>/config/Backup/
# ------------------------------------------------------------

LOG="/tmp/shaper-compact-install.log"
exec > >(tee -a "$LOG") 2>&1

timestamp() { date +%Y%m%d-%H%M%S; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

backup_file_sudo() {
  local f="$1"
  if sudo test -f "$f"; then
    local b="${f}.bak-$(timestamp)"
    sudo cp -a "$f" "$b"
  fi
}

write_file_sudo() {
  local path="$1"
  local content="$2"
  sudo mkdir -p "$(dirname "$path")"
  backup_file_sudo "$path"
  printf "%s" "$content" | sudo tee "$path" >/dev/null
}

echo "Shaper Compact Installer"
echo "Log: $LOG"
echo

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not run as root. Run as the normal user (e.g. velvet)." >&2
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
need_cmd awk
need_cmd git
need_cmd id
need_cmd mountpoint
need_cmd cmp

# Detect printer_data (MainsailOS standard)
PRINTER_DATA=""
if [[ -d "${HOME_DIR}/printer_data" ]]; then
  PRINTER_DATA="${HOME_DIR}/printer_data"
elif [[ -d "${HOME_DIR}/klipper_config" ]]; then
  PRINTER_DATA="${HOME_DIR}/klipper_config"
else
  echo "Could not find printer_data directory under:" >&2
  echo "  - ${HOME_DIR}/printer_data" >&2
  echo "  - ${HOME_DIR}/klipper_config" >&2
  exit 1
fi

GCODE_ROOT="${PRINTER_DATA}/gcodes"
USB_DIR="${GCODE_ROOT}/USB"
MOUNT_POINT="/media/usb"

CONFIG_ROOT="${PRINTER_DATA}/config"
TARGET_CONFIGS_DIR="${CONFIG_ROOT}/Configs"
BACKUP_DIR="${CONFIG_ROOT}/Backup"

UID_NUM="$(id -u "${USER_NAME}")"
GID_NUM="$(id -g "${USER_NAME}")"

# ------------------------------------------------------------
# Step 1: Ensure directories
# ------------------------------------------------------------
echo "[1/5] Preparing directories..."
mkdir -p "$GCODE_ROOT" "$USB_DIR"
mkdir -p "$CONFIG_ROOT" "$TARGET_CONFIGS_DIR" "$BACKUP_DIR"
sudo mkdir -p "$MOUNT_POINT"

# ------------------------------------------------------------
# Step 2: Sync repo and deploy config files
# ------------------------------------------------------------
echo "[2/5] Syncing repository and deploying configuration..."

REPO_URL="https://github.com/johnconnor-1985/shaper-compact.git"
REPO_BRANCH="main"
DEFAULT_REPO_DIR="${HOME_DIR}/shaper-compact"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$DEFAULT_REPO_DIR"

# Prefer local repo if script is executed from within shaper-compact
if [[ -d "${SCRIPT_DIR}/configs" ]]; then
  REPO_DIR="${SCRIPT_DIR}"
else
  if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" checkout "${REPO_BRANCH}" >/dev/null 2>&1 || true
    git -C "${REPO_DIR}" pull --ff-only
  else
    rm -rf "${REPO_DIR}" 2>/dev/null || true
    git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${REPO_DIR}"
  fi
fi

SRC_DIR="${REPO_DIR}/configs"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Missing directory in repo: ${SRC_DIR}" >&2
  exit 1
fi

require_file() {
  local f="$1"
  if [[ ! -f "${SRC_DIR}/${f}" ]]; then
    echo "Missing file in repo: ${SRC_DIR}/${f}" >&2
    exit 1
  fi
}

deploy_file() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "$dst")"

  mkdir -p "$(dirname "$dst")"

  # Destination exists and is identical: do nothing
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    return 0
  fi

  # Destination exists and differs: backup
  if [[ -f "$dst" ]]; then
    cp -a "$dst" "${BACKUP_DIR}/${name}.bak-$(timestamp)"
  fi

  cp -a "$src" "$dst"
  chown "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
}

# Files to deploy to <printer_data>/config (root)
ROOT_FILES=(
  "printer.cfg"
  "crowsnest.conf"
  "mainsail.cfg"
  "KlipperScreen.conf"
  "moonraker.conf"
)

# Files to deploy to <printer_data>/config/Configs
CONFIGS_FILES=(
  "macros.cfg"
  "setup.cfg"
)

for f in "${ROOT_FILES[@]}"; do
  require_file "$f"
  deploy_file "${SRC_DIR}/${f}" "${CONFIG_ROOT}/${f}"
done

for f in "${CONFIGS_FILES[@]}"; do
  require_file "$f"
  deploy_file "${SRC_DIR}/${f}" "${TARGET_CONFIGS_DIR}/${f}"
done

# ------------------------------------------------------------
# Step 3: Cleanup and USB service reset
# ------------------------------------------------------------
echo "[3/5] Cleaning gcodes root and resetting USB services..."

sudo systemctl stop "usb-gcode@*.service" 2>/dev/null || true
sudo systemctl reset-failed 2>/dev/null || true

sudo umount "$MOUNT_POINT" 2>/dev/null || true

while read -r dev on target type fstype rest; do
  if [[ "$target" == "$GCODE_ROOT"* ]]; then
    sudo umount "$target" 2>/dev/null || true
  fi
done < <(mount | awk '{print $1, $2, $3, $4, $5, $6}')

find "$GCODE_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "USB" -exec rm -rf {} + 2>/dev/null || true
find "$GCODE_ROOT" -mindepth 1 -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null || true
rm -f "$USB_DIR"/* 2>/dev/null || true

# ------------------------------------------------------------
# Step 4: Ensure exFAT support
# ------------------------------------------------------------
echo "[4/5] Installing exFAT support..."
sudo apt-get update
sudo apt-get install -y exfat-fuse exfatprogs

# ------------------------------------------------------------
# Step 5: Install usb-gcode handler + systemd + udev
# ------------------------------------------------------------
echo "[5/5] Installing USB handler, systemd unit, and udev rules..."

USB_GCODE_SH_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

ACTION="\${1:-}"
DEV="\${2:-}"

MOUNT_POINT="${MOUNT_POINT}"
KLIPPER_DIR="${USB_DIR}"

UID_NUM=${UID_NUM}
GID_NUM=${GID_NUM}

FSTYPE=\$(blkid -o value -s TYPE "\$DEV" 2>/dev/null || true)

mount_usb() {
  if mountpoint -q "\$MOUNT_POINT"; then
    return 0
  fi
  mount -o ro,uid=\$UID_NUM,gid=\$GID_NUM,umask=022 "\$DEV" "\$MOUNT_POINT"
}

case "\$ACTION" in
  add)
    if [[ "\$FSTYPE" == "vfat" || "\$FSTYPE" == "exfat" ]]; then
      mount_usb
      rm -f "\$KLIPPER_DIR"/* 2>/dev/null || true
      find "\$MOUNT_POINT" -maxdepth 1 -type f -iname "*.gcode" -exec ln -s {} "\$KLIPPER_DIR"/ \\; 2>/dev/null || true
    fi
    ;;
  remove)
    rm -f "\$KLIPPER_DIR"/* 2>/dev/null || true
    umount "\$MOUNT_POINT" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
EOF
)

write_file_sudo "/usr/local/bin/usb-gcode.sh" "$USB_GCODE_SH_CONTENT"
sudo chmod +x /usr/local/bin/usb-gcode.sh

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

UDEV_RULES_CONTENT=$(cat <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}=="vfat",  TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gcode@%k.service"
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}=="exfat", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gcode@%k.service"
EOF
)
write_file_sudo "/etc/udev/rules.d/99-usb-gcode.rules" "${UDEV_RULES_CONTENT}"$'\n'

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger

echo
echo "Installation completed."
echo
echo "USB test:"
echo "  1) Insert a FAT32 or exFAT USB drive with *.gcode files in the root directory"
echo "  2) Wait a few seconds"
echo "  3) Check:"
echo "     ls -la \"${USB_DIR}\""
echo
echo "Debug:"
echo "  mount | grep \"${MOUNT_POINT}\""
echo "  systemctl status usb-gcode@sda1.service"
echo
echo "Config deployed to:"
echo "  ${CONFIG_ROOT}/ (printer.cfg, mainsail.cfg, crowsnest.conf, KlipperScreen.conf, moonraker.conf)"
echo "  ${TARGET_CONFIGS_DIR}/ (macros.cfg, setup.cfg)"
echo "Backups (only when changed):"
echo "  ${BACKUP_DIR}/"
echo
