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
#     - Backups are stored in <printer_data>/config/Backup/
#       and created only if destination existed and differed.
#     - Best-effort MCU serial injection into printer.cfg:
#         * _MCU_SERIAL_ -> /dev/serial/by-id/usb-Klipper_* (prefer stm32h723xx)
#         * _MCU_CONTROL_BOARD_SERIAL_ -> /dev/serial/by-id/usb-1a86_*
#       If not detectable or ambiguous, placeholders are kept (no error).
#  3) Moonraker update integration:
#     - Render moonraker.conf pinned_commit placeholders from versions.env:
#         * _KLIPPER_PINNED_VERSION_   -> KLIPPER_REF
#         * _MOONRAKER_PINNED_VERSION_ -> MOONRAKER_REF
#     - Install systemd oneshot service "shaper_compact" that runs update.sh
#     - Add "shaper_compact" to Moonraker allowed services:
#         * /home/velvet/printer_data/moonraker.asvc
#  4) Restart:
#     - If any config file changed, restart related services at the end.
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
need_cmd sed
need_cmd readlink
need_cmd mktemp
need_cmd grep
need_cmd chmod
need_cmd cat
need_cmd sort
need_cmd uniq

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

# IMPORTANT: on your system Moonraker reads allowlist here (not under config/)
MOONRAKER_ASVC="${PRINTER_DATA}/moonraker.asvc"

UID_NUM="$(id -u "${USER_NAME}")"
GID_NUM="$(id -g "${USER_NAME}")"

CONFIG_CHANGED=0

# -----------------------------
# Repo/versions helpers
# -----------------------------
KLIPPER_REF=""
MOONRAKER_REF=""

load_versions_env() {
  local vf="${REPO_DIR}/versions.env"
  if [[ -f "$vf" ]]; then
    # shellcheck disable=SC1090
    source "$vf"
  fi
}

render_moonraker_conf() {
  # usage: render_moonraker_conf SRC DST
  local src="$1"
  local dst="$2"
  cp -a "$src" "$dst"

  if [[ -n "${KLIPPER_REF:-}" ]]; then
    sed -i "s|_KLIPPER_PINNED_VERSION_|${KLIPPER_REF}|g" "$dst"
  fi
  if [[ -n "${MOONRAKER_REF:-}" ]]; then
    sed -i "s|_MOONRAKER_PINNED_VERSION_|${MOONRAKER_REF}|g" "$dst"
  fi
}

install_shaper_compact_service() {
  local unit_path="/etc/systemd/system/shaper_compact.service"
  local content
  content=$(cat <<EOF
[Unit]
Description=Shaper Compact Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${USER_NAME}
WorkingDirectory=${HOME_DIR}/shaper-compact
ExecStart=/usr/bin/env bash ${HOME_DIR}/shaper-compact/update.sh

EOF
)
  write_file_sudo "$unit_path" "$content"
  sudo systemctl daemon-reload

  if [[ -f "${HOME_DIR}/shaper-compact/update.sh" ]]; then
    chmod +x "${HOME_DIR}/shaper-compact/update.sh" 2>/dev/null || true
  fi
}

ensure_moonraker_allowed_service() {
  # moonraker.asvc is a newline list of allowed service names.
  # Ensure "shaper_compact" is present; backup only if file existed and changes.
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$MOONRAKER_ASVC" ]]; then
    cp -a "$MOONRAKER_ASVC" "$tmp"
  else
    : > "$tmp"
  fi

  {
    cat "$tmp"
    echo "shaper_compact"
  } | sed '/^[[:space:]]*$/d' | sort | uniq > "${tmp}.new"

  if [[ -f "$MOONRAKER_ASVC" ]] && cmp -s "${tmp}.new" "$MOONRAKER_ASVC"; then
    # Ensure lock-down even if already correct
    sudo chown root:root "$MOONRAKER_ASVC" 2>/dev/null || true
    sudo chmod 444 "$MOONRAKER_ASVC" 2>/dev/null || true
    rm -f "$tmp" "${tmp}.new"
    return 0
  fi

  if [[ -f "$MOONRAKER_ASVC" ]]; then
    cp -a "$MOONRAKER_ASVC" "${BACKUP_DIR}/moonraker.asvc.bak-$(timestamp)"
  fi

  cp -a "${tmp}.new" "$MOONRAKER_ASVC"
  sudo chown root:root "$MOONRAKER_ASVC"
  sudo chmod 444 "$MOONRAKER_ASVC"
  CONFIG_CHANGED=1

  rm -f "$tmp" "${tmp}.new"
}

# ------------------------------------------------------------
# Step 1: Ensure directories
# ------------------------------------------------------------
echo "[1/7] Preparing directories..."
mkdir -p "$GCODE_ROOT" "$USB_DIR"
mkdir -p "$CONFIG_ROOT" "$TARGET_CONFIGS_DIR" "$BACKUP_DIR"
sudo mkdir -p "$MOUNT_POINT"

# ------------------------------------------------------------
# Step 2: Sync repo and deploy config files
# ------------------------------------------------------------
echo "[2/7] Syncing repository and deploying configuration..."

REPO_URL="https://github.com/johnconnor-1985/shaper-compact.git"
REPO_BRANCH="main"
DEFAULT_REPO_DIR="${HOME_DIR}/shaper-compact"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$DEFAULT_REPO_DIR"

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

git -C "${REPO_DIR}" config core.fileMode false 2>/dev/null || true

SRC_DIR="${REPO_DIR}/configs"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Missing directory in repo: ${SRC_DIR}" >&2
  exit 1
fi

load_versions_env

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

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    return 0
  fi

  if [[ -f "$dst" ]]; then
    cp -a "$dst" "${BACKUP_DIR}/${name}.bak-$(timestamp)"
  fi

  cp -a "$src" "$dst"
  chown "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
  CONFIG_CHANGED=1
}

find_optional_one_by_glob() {
  local pattern="$1"
  local -a matches=()
  local p

  shopt -s nullglob
  for p in $pattern; do
    if [[ -e "$p" ]] && readlink -f "$p" >/dev/null 2>&1; then
      matches+=("$p")
    fi
  done
  shopt -u nullglob

  if [[ "${#matches[@]}" -ne 1 ]]; then
    return 1
  fi

  echo "${matches[0]}"
  return 0
}

apply_printer_cfg_serials_best_effort() {
  local printer_cfg_path="$1"

  [[ -f "$printer_cfg_path" ]] || return 0
  grep -q "_MCU_SERIAL_" "$printer_cfg_path" || return 0
  grep -q "_MCU_CONTROL_BOARD_SERIAL_" "$printer_cfg_path" || return 0

  local mcu_serial=""
  local control_serial=""

  mcu_serial="$(find_optional_one_by_glob "/dev/serial/by-id/usb-Klipper_stm32h723xx_*" || true)"
  if [[ -z "$mcu_serial" ]]; then
    mcu_serial="$(find_optional_one_by_glob "/dev/serial/by-id/usb-Klipper_*" || true)"
  fi

  control_serial="$(find_optional_one_by_glob "/dev/serial/by-id/usb-1a86_*" || true)"

  if [[ -z "$mcu_serial" && -z "$control_serial" ]]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cp -a "$printer_cfg_path" "$tmp"

  if [[ -n "$mcu_serial" ]]; then
    sed -i "s|_MCU_SERIAL_|${mcu_serial}|g" "$tmp"
  fi
  if [[ -n "$control_serial" ]]; then
    sed -i "s|_MCU_CONTROL_BOARD_SERIAL_|${control_serial}|g" "$tmp"
  fi

  if ! cmp -s "$tmp" "$printer_cfg_path"; then
    cp -a "$printer_cfg_path" "${BACKUP_DIR}/printer.cfg.bak-$(timestamp)"
    cp -a "$tmp" "$printer_cfg_path"
    chown "${USER_NAME}:${USER_NAME}" "$printer_cfg_path" 2>/dev/null || true
    CONFIG_CHANGED=1
  fi

  rm -f "$tmp"
}

ROOT_FILES=(
  "printer.cfg"
  "crowsnest.conf"
  "mainsail.cfg"
  "KlipperScreen.conf"
  "moonraker.conf"
)

CONFIGS_FILES=(
  "macros.cfg"
  "setup.cfg"
)

for f in "${ROOT_FILES[@]}"; do
  require_file "$f"

  if [[ "$f" == "moonraker.conf" ]]; then
    tmp="$(mktemp)"
    render_moonraker_conf "${SRC_DIR}/${f}" "$tmp"
    deploy_file "$tmp" "${CONFIG_ROOT}/${f}"
    rm -f "$tmp"
  else
    deploy_file "${SRC_DIR}/${f}" "${CONFIG_ROOT}/${f}"
  fi
done

for f in "${CONFIGS_FILES[@]}"; do
  require_file "$f"
  deploy_file "${SRC_DIR}/${f}" "${TARGET_CONFIGS_DIR}/${f}"
done

apply_printer_cfg_serials_best_effort "${CONFIG_ROOT}/printer.cfg"

# ------------------------------------------------------------
# Step 3: Moonraker update integration (update button -> update.sh)
# ------------------------------------------------------------
echo "[3/7] Installing shaper_compact service and Moonraker allowlist..."
install_shaper_compact_service
ensure_moonraker_allowed_service
sudo rm -f "${CONFIG_ROOT}/moonraker.asvc" 2>/dev/null || true

# ------------------------------------------------------------
# Step 4: Cleanup and USB service reset
# ------------------------------------------------------------
echo "[4/7] Cleaning gcodes root and resetting USB services..."

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
# Step 5: Ensure exFAT support
# ------------------------------------------------------------
echo "[5/7] Installing exFAT support..."
sudo apt-get update
sudo apt-get install -y exfat-fuse exfatprogs

# ------------------------------------------------------------
# Step 6: Install usb-gcode handler + systemd + udev
# ------------------------------------------------------------
echo "[6/7] Installing USB handler, systemd unit, and udev rules..."

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

# Trigger only on USB block devices (prevents matching the SD-card boot partition mmcblk0p1).
UDEV_RULES_CONTENT=$(cat <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="vfat",  TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gcode@%k.service"
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="exfat", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-gcode@%k.service"
EOF
)
write_file_sudo "/etc/udev/rules.d/99-usb-gcode.rules" "${UDEV_RULES_CONTENT}"$'\n'

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger

# ------------------------------------------------------------
# Step 7: Restart services if configuration changed
# ------------------------------------------------------------
echo "[7/7] Finalizing..."

if [[ "${CONFIG_CHANGED}" -eq 1 ]]; then
  echo "Configuration changed. Restarting services..."
  sudo systemctl restart klipper 2>/dev/null || true
  sudo systemctl restart moonraker 2>/dev/null || true
  sudo systemctl restart KlipperScreen 2>/dev/null || true
  sudo systemctl restart crowsnest 2>/dev/null || true
  sudo systemctl restart nginx 2>/dev/null || true
fi

echo
echo "Installation completed."
echo
echo "USB test:"
echo "  1) Insert a FAT32 or exFAT USB drive with *.gcode files in the root directory"
echo "  2) Wait a few seconds"
echo "  3) Check:"
echo "     ls -la \"${USB_DIR}\""
echo
echo "Update Manager integration:"
echo "  - Systemd service installed: shaper_compact.service"
echo "  - Moonraker allowlist updated: ${MOONRAKER_ASVC}"
echo
echo "Config deployed to:"
echo "  ${CONFIG_ROOT}/ (printer.cfg, mainsail.cfg, crowsnest.conf, KlipperScreen.conf, moonraker.conf)"
echo "  ${TARGET_CONFIGS_DIR}/ (macros.cfg, setup.cfg)"
echo "Backups (only when changed):"
echo "  ${BACKUP_DIR}/"
echo
