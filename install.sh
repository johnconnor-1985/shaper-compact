#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Shaper Compact - Installer
#
#  0) Sync shaper-compact repo (or use local repo if running inside it)
#  1) ENSURE + PIN all required software to versions.env:
#       - Klipper (git)
#       - Moonraker (git)
#       - Crowsnest (git)          (optional but supported)
#       - KlipperScreen (git)      (deterministic X11 stack + smoke test)
#       - Mainsail: shipped by MainsailOS (web bundle) -> no pin here
#       - System OS: NOT pinned here (apt upgrades are not rollbackable)
#  2) Deploy config files from repo ./configs to printer_data:
#       - macros.cfg, setup.cfg -> <printer_data>/config/Configs/
#       - others (incl. printer.cfg) -> <printer_data>/config/
#       - printer.cfg: best-effort MCU serial injection for placeholders
#  3) Moonraker update integration:
#       - Render moonraker.conf placeholders from versions.env:
#           _KLIPPER_PINNED_VERSION_   -> KLIPPER_REF
#           _MOONRAKER_PINNED_VERSION_ -> MOONRAKER_REF
#       - Install systemd oneshot service "shaper_compact" -> runs update.sh
#       - Add "shaper_compact" to Moonraker allowlist:
#           <printer_data>/moonraker.asvc (root:root 444)
#  4) Themes:
#       - Mainsail: ./configs/Mainsail/* -> <printer_data>/config/.theme/ (replace, no backup)
#       - KlipperScreen: ./configs/KlipperScreen/velvet-darker -> ~/KlipperScreen/styles/velvet-darker (replace, no backup)
#       - Patch KlipperScreen theme CSS placeholders (e.g. %USER%) to absolute path
#  5) USB G-code workflow:
#       - udev + systemd template to mount USB vfat/exfat to /media/usb (RO)
#       - expose only root/*.gcode as symlinks in: <printer_data>/gcodes/USB
#       - IMPORTANT: only triggers on ID_BUS=="usb" (won't hit mmcblk0p1)
#  6) Restart:
#       - Always enforce KlipperScreen X11 golden stack (UI refresh + smoke test)
#       - Restart other services only if configs/themes changed
#
#  7) Mainsail header label + branding:
#       - Force Mainsail "Printer Name" to a single space (" ") via Moonraker DB
#         so it shows nothing next to the logo (no hostname fallback).
#       - Force Mainsail uiSettings colors (from configs/Mainsail/customization.env)
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

is_git_repo() { [[ -d "$1/.git" ]]; }

is_hex40() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{40}$ ]]
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
need_cmd rm
need_cmd cp
need_cmd mkdir
need_cmd ps
need_cmd pgrep
need_cmd curl     # <-- added

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
THEME_DIR="${CONFIG_ROOT}/.theme"

# IMPORTANT: Moonraker reads allowlist here (not under config/)
MOONRAKER_ASVC="${PRINTER_DATA}/moonraker.asvc"

UID_NUM="$(id -u "${USER_NAME}")"
GID_NUM="$(id -g "${USER_NAME}")"

CONFIG_CHANGED=0

# ------------------------------------------------------------
# Repo bootstrap (self)
# ------------------------------------------------------------
REPO_URL="https://github.com/johnconnor-1985/shaper-compact.git"
REPO_BRANCH="main"
DEFAULT_REPO_DIR="${HOME_DIR}/shaper-compact"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$DEFAULT_REPO_DIR"

sync_self_repo() {
  if [[ -d "${SCRIPT_DIR}/configs" && -f "${SCRIPT_DIR}/versions.env" ]]; then
    REPO_DIR="${SCRIPT_DIR}"
    return 0
  fi

  if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" checkout "${REPO_BRANCH}" >/dev/null 2>&1 || true
    git -C "${REPO_DIR}" pull --ff-only
  else
    rm -rf "${REPO_DIR}" 2>/dev/null || true
    git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${REPO_DIR}"
  fi
}

# Prevent "dirty" status due to executable bit differences on embedded systems
set_repo_filemode_false() {
  git -C "$1" config core.fileMode false 2>/dev/null || true
}

# ------------------------------------------------------------
# versions.env
# ------------------------------------------------------------
load_versions_env() {
  local vf="${REPO_DIR}/versions.env"
  if [[ ! -f "$vf" ]]; then
    echo "Missing versions.env in repo: $vf" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$vf"
}

validate_versions_env() {
  # required pins (you can relax these if you want)
  for v in KLIPPER_REF MOONRAKER_REF KSCREEN_REF CROWSNEST_REF; do
    local val="${!v:-}"
    if [[ -n "$val" ]] && ! is_hex40 "$val"; then
      echo "versions.env error: $v is not a 40-hex commit: '$val'" >&2
      exit 1
    fi
  done
}

# ------------------------------------------------------------
# customization.env (Mainsail UI customization)
# ------------------------------------------------------------
load_mainsail_customization_env() {
  local cf="${REPO_DIR}/configs/Mainsail/customization.env"

  # Defaults (used if file missing or variables omitted)
  MAINSAIL_PRINTERNAME="${MAINSAIL_PRINTERNAME:-" "}"
  MAINSAIL_UI_LOGO="${MAINSAIL_UI_LOGO:-"#951DF0"}"
  MAINSAIL_UI_PRIMARY="${MAINSAIL_UI_PRIMARY:-"#D834E4"}"
  MAINSAIL_UI_THEME="${MAINSAIL_UI_THEME:-"mainsail"}"

  if [[ -f "$cf" ]]; then
    echo "[Mainsail] loading customization from: $cf"
    # shellcheck disable=SC1090
    source "$cf"
  else
    echo "[Mainsail] customization.env not found (using defaults): $cf"
  fi

  # Ensure non-empty essentials (keep behavior deterministic)
  if [[ -z "${MAINSAIL_PRINTERNAME:-}" ]]; then
    MAINSAIL_PRINTERNAME=" "
  fi
  if [[ -z "${MAINSAIL_UI_THEME:-}" ]]; then
    MAINSAIL_UI_THEME="mainsail"
  fi
  if [[ -z "${MAINSAIL_UI_LOGO:-}" ]]; then
    MAINSAIL_UI_LOGO="#951DF0"
  fi
  if [[ -z "${MAINSAIL_UI_PRIMARY:-}" ]]; then
    MAINSAIL_UI_PRIMARY="#D834E4"
  fi
}

# ------------------------------------------------------------
# Pinned git repos (ensure + pin)
# ------------------------------------------------------------
ensure_and_pin_repo() {
  # usage: ensure_and_pin_repo NAME DIR ORIGIN BRANCH PIN
  local name="$1"
  local dir="$2"
  local origin="$3"
  local branch="$4"
  local pin="$5"

  if [[ -z "$pin" ]]; then
    echo "[$name] pin empty -> skipping"
    return 0
  fi
  if ! is_hex40 "$pin"; then
    echo "[$name] invalid pin (not 40-hex): $pin" >&2
    exit 1
  fi

  if ! is_git_repo "$dir"; then
    echo "[$name] not installed -> cloning into $dir"
    rm -rf "$dir" 2>/dev/null || true
    git clone --branch "$branch" --depth 1 "$origin" "$dir"
  fi

  set_repo_filemode_false "$dir"

  echo "[$name] fetching..."
  git -C "$dir" fetch --all --prune >/dev/null 2>&1 || true

  local cur=""
  cur="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"

  if [[ "$cur" != "$pin" ]]; then
    echo "[$name] pinning to $pin (was: ${cur:-unknown})"
    git -C "$dir" reset --hard "$pin" >/dev/null
    git -C "$dir" clean -fd >/dev/null 2>&1 || true
  else
    echo "[$name] already pinned: $pin"
  fi
}

# ------------------------------------------------------------
# KlipperScreen X11 Stack (GOLDEN, deterministic)
# ------------------------------------------------------------
ensure_klipperscreen_x11_stack() {
  local ks_dir="${KSCREEN_DIR:-${HOME_DIR}/KlipperScreen}"
  local venv_dir="${HOME_DIR}/.KlipperScreen-env"
  local start_sh="${HOME_DIR}/ks-start.sh"
  local unit_path="/etc/systemd/system/KlipperScreen.service"

  if [[ ! -d "$ks_dir" ]]; then
    echo "[KlipperScreen] repo missing at $ks_dir -> skipping UI stack"
    return 0
  fi

  echo "[KlipperScreen] ensuring X11 prerequisites..."
  sudo apt-get update
  sudo apt-get install -y \
    xinit xserver-xorg xserver-xorg-legacy xserver-xorg-core \
    xserver-xorg-input-libinput xserver-xorg-input-evdev \
    libgtk-3-0 gir1.2-gtk-3.0 python3-venv python3-pip python3-dev \
    >/dev/null 2>&1 || true

  # Ensure venv exists (deterministic)
  if [[ ! -d "$venv_dir" ]]; then
    echo "[KlipperScreen] creating venv: $venv_dir"
    python3 -m venv "$venv_dir"
    "$venv_dir/bin/pip" install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
    if [[ -f "$ks_dir/scripts/KlipperScreen-requirements.txt" ]]; then
      "$venv_dir/bin/pip" install -r "$ks_dir/scripts/KlipperScreen-requirements.txt" >/dev/null 2>&1 || true
    fi
  fi

  echo "[KlipperScreen] writing start script: $start_sh"
  cat > "$start_sh" <<EOF
#!/usr/bin/env bash
set -e

exec /usr/bin/openvt -s -w -f -c 7 -- /bin/su - ${USER_NAME} -c 'cd ${ks_dir} && exec /usr/bin/xinit ${venv_dir}/bin/python ${ks_dir}/screen.py -- :0 -nolisten tcp vt7'
EOF
  chmod +x "$start_sh"
  chown "${USER_NAME}:${USER_NAME}" "$start_sh" 2>/dev/null || true

  echo "[KlipperScreen] writing systemd unit: $unit_path"
  local unit_content
  unit_content=$(cat <<EOF
[Unit]
Description=KlipperScreen (X11)
After=network-online.target moonraker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${start_sh}
Restart=always
RestartSec=2
KillMode=mixed
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=KlipperScreenX11

[Install]
WantedBy=multi-user.target
EOF
)
  write_file_sudo "$unit_path" "$unit_content"

  echo "[KlipperScreen] (re)loading + enabling service..."
  sudo systemctl daemon-reload
  sudo systemctl enable KlipperScreen >/dev/null 2>&1 || true

  # Cleanup old instances to avoid duplicates/conflicts on :0
  echo "[KlipperScreen] stopping/cleaning old instances..."
  sudo systemctl stop KlipperScreen 2>/dev/null || true
  sudo pkill -f "${ks_dir}/screen.py" 2>/dev/null || true
  sudo pkill -f "xinit.*${ks_dir}/screen.py" 2>/dev/null || true
  sudo pkill -f "Xorg :0" 2>/dev/null || true
  sudo rm -f /tmp/.X11-unix/X0 2>/dev/null || true

  echo "[KlipperScreen] starting..."
  sudo systemctl restart KlipperScreen

  # Smoke test (hard fail if UI doesn't come up)
  echo "[KlipperScreen] smoke test..."
  local ok=0
  for _ in {1..20}; do
    if [[ -S /tmp/.X11-unix/X0 ]] && pgrep -f "${ks_dir}/screen.py" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 0.5
  done

  if [[ "$ok" -ne 1 ]]; then
    echo "❌ [KlipperScreen] ERROR: UI did not come up."
    echo "   - /tmp/.X11-unix:"
    ls -lah /tmp/.X11-unix/ || true
    echo "   - processes:"
    ps aux | egrep "openvt|Xorg|xinit|screen.py" | grep -v grep || true
    echo "   - last logs (KlipperScreenX11):"
    journalctl -t KlipperScreenX11 -n 200 --no-pager || true
    echo "   - service status:"
    sudo systemctl status KlipperScreen --no-pager -l || true
    exit 1
  fi

  echo "✅ [KlipperScreen] UI OK"
}

# ------------------------------------------------------------
# Config deploy helpers
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Moonraker update integration (service + allowlist)
# ------------------------------------------------------------
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
# Mainsail header label + branding (best-effort)
# ------------------------------------------------------------
set_mainsail_ui_branding() {
  # Values come from configs/Mainsail/customization.env (loaded once in MAIN)
  # - Hide printer label: general.printername = MAINSAIL_PRINTERNAME (usually " ")
  # - Set uiSettings colors: logo + primary + theme
  local url="http://127.0.0.1:7125"

  # Wait for Moonraker to be up (handles restarts during install)
  for _ in {1..30}; do
    if curl -fsS "${url}/server/info" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  # Hide printer label (and avoid hostname fallback)
  curl -fsS -X POST "${url}/server/database/item" \
    -H "Content-Type: application/json" \
    -d "{\"namespace\":\"mainsail\",\"key\":\"general\",\"value\":{\"printername\":\"${MAINSAIL_PRINTERNAME}\"}}" \
    >/dev/null 2>&1 || true

  # Force UI colors deterministically (no jq dependency).
  # NOTE: this overwrites uiSettings as a whole; include theme so it remains stable.
  curl -fsS -X POST "${url}/server/database/item" \
    -H "Content-Type: application/json" \
    -d "{\"namespace\":\"mainsail\",\"key\":\"uiSettings\",\"value\":{\"logo\":\"${MAINSAIL_UI_LOGO}\",\"primary\":\"${MAINSAIL_UI_PRIMARY}\",\"theme\":\"${MAINSAIL_UI_THEME}\"}}" \
    >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Themes
# ------------------------------------------------------------
deploy_mainsail_theme() {
  local src_theme="${SRC_DIR}/Mainsail"
  if [[ ! -d "$src_theme" ]]; then
    return 0
  fi
  rm -rf "$THEME_DIR" 2>/dev/null || true
  mkdir -p "$THEME_DIR"
  cp -a "$src_theme"/. "$THEME_DIR"/
  chown -R "${USER_NAME}:${USER_NAME}" "$THEME_DIR" 2>/dev/null || true
  CONFIG_CHANGED=1
}

deploy_klipperscreen_theme() {
  local src="${SRC_DIR}/KlipperScreen/velvet-darker"
  local dst="${HOME_DIR}/KlipperScreen/styles/velvet-darker"

  if [[ ! -d "$src" ]]; then
    return 0
  fi

  mkdir -p "${HOME_DIR}/KlipperScreen/styles"
  rm -rf "$dst" 2>/dev/null || true
  cp -a "$src" "$dst"
  chown -R "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
  CONFIG_CHANGED=1
}

patch_klipperscreen_theme_paths() {
  # Make CSS deterministic by expanding %USER% placeholders to absolute paths.
  local css="${HOME_DIR}/KlipperScreen/styles/velvet-darker/style.css"

  if [[ ! -f "$css" ]]; then
    echo "[KlipperScreen] style.css not found (skip patch): $css"
    return 0
  fi

  echo "[KlipperScreen] patching theme CSS paths in: $css"

  sed -i "s|%USER%|${USER_NAME}|g" "$css"
  sed -i "s|/home/[^/]\+/KlipperScreen/styles/velvet-darker/|/home/${USER_NAME}/KlipperScreen/styles/velvet-darker/|g" "$css"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

echo "[1/8] Preparing directories..."
mkdir -p "$GCODE_ROOT" "$USB_DIR"
mkdir -p "$CONFIG_ROOT" "$TARGET_CONFIGS_DIR" "$BACKUP_DIR"
sudo mkdir -p "$MOUNT_POINT"

echo "[2/8] Syncing shaper-compact repository..."
sync_self_repo
set_repo_filemode_false "$REPO_DIR"

SRC_DIR="${REPO_DIR}/configs"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "Missing directory in repo: ${SRC_DIR}" >&2
  exit 1
fi

echo "[3/8] Loading and validating versions.env..."
load_versions_env
validate_versions_env

echo "[3b/8] Loading Mainsail customization.env..."
load_mainsail_customization_env

# Defaults if missing from versions.env
KLIPPER_DIR="${KLIPPER_DIR:-/home/${USER_NAME}/klipper}"
MOONRAKER_DIR="${MOONRAKER_DIR:-/home/${USER_NAME}/moonraker}"
CROWSNEST_DIR="${CROWSNEST_DIR:-/home/${USER_NAME}/crowsnest}"
KSCREEN_DIR="${KSCREEN_DIR:-/home/${USER_NAME}/KlipperScreen}"
MAINSAIL_DIR="${MAINSAIL_DIR:-/home/${USER_NAME}/mainsail}"

echo "[4/8] Ensuring and pinning required software..."
ensure_and_pin_repo "Klipper"       "$KLIPPER_DIR"   "https://github.com/Klipper3d/klipper.git"             "master" "${KLIPPER_REF:-}"
ensure_and_pin_repo "Moonraker"     "$MOONRAKER_DIR" "https://github.com/Arksine/moonraker.git"            "master" "${MOONRAKER_REF:-}"
ensure_and_pin_repo "Crowsnest"     "$CROWSNEST_DIR" "https://github.com/mainsail-crew/crowsnest.git"      "master" "${CROWSNEST_REF:-}"
ensure_and_pin_repo "KlipperScreen" "$KSCREEN_DIR"   "https://github.com/KlipperScreen/KlipperScreen.git"  "master" "${KSCREEN_REF:-}"

echo "[5/8] Deploying configuration files..."
require_file() {
  local f="$1"
  if [[ ! -f "${SRC_DIR}/${f}" ]]; then
    echo "Missing file in repo: ${SRC_DIR}/${f}" >&2
    exit 1
  fi
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

echo "[6/8] Installing Moonraker update integration..."
install_shaper_compact_service
ensure_moonraker_allowed_service
sudo rm -f "${CONFIG_ROOT}/moonraker.asvc" 2>/dev/null || true

echo "[7/8] Deploying themes..."
deploy_mainsail_theme
deploy_klipperscreen_theme
patch_klipperscreen_theme_paths

echo "[8/8] Installing USB handler + exFAT + udev/systemd..."
sudo apt-get update
sudo apt-get install -y exfat-fuse exfatprogs

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
# Restart / Finalize
# ------------------------------------------------------------
echo
echo "Finalizing..."

patch_klipperscreen_theme_paths

echo "Ensuring KlipperScreen X11 stack (UI refresh + stability)..."
ensure_klipperscreen_x11_stack

if [[ "${CONFIG_CHANGED}" -eq 1 ]]; then
  echo "Configuration/themes changed. Restarting core services..."
  sudo systemctl restart klipper 2>/dev/null || true
  sudo systemctl restart moonraker 2>/dev/null || true
  sudo systemctl restart crowsnest 2>/dev/null || true
  sudo systemctl restart nginx 2>/dev/null || true
fi

# Always enforce Mainsail header + branding (best-effort)
set_mainsail_ui_branding

echo
echo "Installation completed."
echo
echo "Pins enforced from: ${REPO_DIR}/versions.env"
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
echo "Mainsail theme deployed to:"
echo "  ${THEME_DIR}/ (replaced; no backups)"
echo
echo "KlipperScreen theme deployed to:"
echo "  ${HOME_DIR}/KlipperScreen/styles/velvet-darker (replaced; no backups)"
echo
echo "Config deployed to:"
echo "  ${CONFIG_ROOT}/ (printer.cfg, mainsail.cfg, crowsnest.conf, KlipperScreen.conf, moonraker.conf)"
echo "  ${TARGET_CONFIGS_DIR}/ (macros.cfg, setup.cfg)"
echo "Backups (only when changed):"
echo "  ${BACKUP_DIR}/"
echo
