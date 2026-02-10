#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Shaper Compact - update.sh (rollback + pins + config deploy)
#
# Enforces pinned versions from versions.env (best-effort):
#   - Klipper (git)
#   - Moonraker (git)
#   - KlipperScreen (git) + GOLDEN X11 stack (service + launcher) + smoke test
#   - Crowsnest (git)
#   - Mainsail (git, only if MAINSAIL_REF is set and directory is a git repo)
#   - System OS: optional apt upgrade (NOT rollbackable)
#
# Deploys configs from this repo ./configs:
#   - root:  KlipperScreen.conf, crowsnest.conf, mainsail.cfg, moonraker.conf
#   - Configs/: macros.cfg, setup.cfg
#   - NO printer.cfg deployment (kept local for customer customization)
#
# Deploys UI customizations (NO backup, hard replace):
#   - Mainsail:      ./configs/Mainsail/* -> <printer_data>/config/.theme/
#       NOTE: customization.env is NOT deployed into .theme (assets-only).
#   - KlipperScreen: ./configs/KlipperScreen/velvet-darker -> ~/KlipperScreen/styles/velvet-darker
#   - Patch KlipperScreen theme CSS placeholders (e.g. %USER%) to absolute path
#
# Boot splash (Plymouth velvet) from repo ./configs/boot (best-effort):
#   - /usr/share/plymouth/themes/velvet/{velvet.plymouth,velvet.script,splash.png,splash2.png}
#   - /boot/firmware/{cmdline.txt,config.txt,initramfs8} updates + initramfs rebuild
#   - NOTE: backed up as *.bak-<timestamp>, but NOT auto-rolled back by script
#
# Backups:
#   - Only if destination existed and differed
#   - Stored in: <printer_data>/config/Backup/
#
# Rollback:
#   - If any step fails (except system upgrade), rollback restores:
#       * git repos to their previous HEAD (INCLUDING this repo shaper-compact)
#       * config files to their previous state (using backups created this run)
#   - NOTE: UI custom dirs are "no backup"; rollback does not revert them.
#
# Mainsail header label + branding:
#   - Force Mainsail Settings -> General -> Printer Name to a single space (" ")
#     via Moonraker DB so it shows nothing next to the logo.
#   - Force Mainsail uiSettings colors (read from repo configs/Mainsail/customization.env only)
# ------------------------------------------------------------

LOG="/tmp/shaper-compact-update.log"
exec > >(tee -a "$LOG") 2>&1

timestamp() { date +%Y%m%d-%H%M%S; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

need_cmd tee
need_cmd git
need_cmd sed
need_cmd cmp
need_cmd mktemp
need_cmd find
need_cmd id
need_cmd sudo
need_cmd systemctl
need_cmd grep
need_cmd readlink
need_cmd rm
need_cmd cp
need_cmd mkdir
need_cmd ps
need_cmd pgrep
need_cmd curl
need_cmd awk
need_cmd stat

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
VERSIONS_FILE="${REPO_DIR}/versions.env"
CONFIGS_SRC_DIR="${REPO_DIR}/configs"

if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "Missing versions.env: $VERSIONS_FILE" >&2
  exit 1
fi

if [[ ! -d "$CONFIGS_SRC_DIR" ]]; then
  echo "Missing configs directory: $CONFIGS_SRC_DIR" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$VERSIONS_FILE"

USER_NAME="$(whoami)"
HOME_DIR="$(eval echo "~${USER_NAME}")"

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

CONFIG_ROOT="${PRINTER_DATA}/config"
TARGET_CONFIGS_DIR="${CONFIG_ROOT}/Configs"
BACKUP_DIR="${CONFIG_ROOT}/Backup"
MOONRAKER_ASVC="${PRINTER_DATA}/moonraker.asvc"

mkdir -p "$CONFIG_ROOT" "$TARGET_CONFIGS_DIR" "$BACKUP_DIR"

# Flags
CHECK_ONLY="${CHECK_ONLY:-false}"            # "true" = no changes, only report
SYSTEM_UPDATE="${SYSTEM_UPDATE:-false}"      # "true" = apt-get upgrade (NOT rollbackable)

# ------------------------------------------------------------
# Mainsail customization.env (Moonraker DB) - READ ONLY
# ------------------------------------------------------------
load_mainsail_customization_env() {
  local cf="${REPO_DIR}/configs/Mainsail/customization.env"

  # Defaults (used if file missing or variables omitted)
  MAINSAIL_PRINTERNAME="${MAINSAIL_PRINTERNAME:-" "}"
  MAINSAIL_UI_LOGO="${MAINSAIL_UI_LOGO:-"#951DF0"}"
  MAINSAIL_UI_PRIMARY="${MAINSAIL_UI_PRIMARY:-"#D834E4"}"
  MAINSAIL_UI_THEME="${MAINSAIL_UI_THEME:-"mainsail"}"

  if [[ -f "$cf" ]]; then
    echo "[Mainsail] loading customization from repo (not deployed): $cf"
    # shellcheck disable=SC1090
    source "$cf"
  else
    echo "[Mainsail] customization.env not found (using defaults): $cf"
  fi

  # Ensure non-empty essentials
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
# Rollback state
# ------------------------------------------------------------

declare -A PREV_HEAD=()         # repo_dir -> previous_head
declare -a CREATED_BACKUPS=()   # "backup_path|dest_path"

CHANGED=0
ROLLBACK_IN_PROGRESS=0

is_git_repo() {
  [[ -d "$1/.git" ]]
}

git_head() {
  local dir="$1"
  git -C "$dir" rev-parse HEAD 2>/dev/null || echo ""
}

save_git_state() {
  local dir="$1"
  if is_git_repo "$dir"; then
    local h
    h="$(git_head "$dir")"
    if [[ -n "$h" ]]; then
      PREV_HEAD["$dir"]="$h"
    fi
  fi
}

restore_git_state() {
  local dir="$1"
  local h="${PREV_HEAD[$dir]:-}"
  if [[ -z "$h" ]]; then
    return 0
  fi
  if ! is_git_repo "$dir"; then
    return 0
  fi
  git -C "$dir" fetch --all --prune >/dev/null 2>&1 || true
  git -C "$dir" reset --hard "$h" >/dev/null 2>&1 || true
  git -C "$dir" clean -fd >/dev/null 2>&1 || true
}

create_backup_if_needed() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "$dst")"

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    return 1
  fi

  if [[ -f "$dst" ]]; then
    local b="${BACKUP_DIR}/${name}.bak-$(timestamp)"
    cp -a "$dst" "$b"
    CREATED_BACKUPS+=("${b}|${dst}")
  fi
  return 0
}

deploy_file() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"

  if ! create_backup_if_needed "$src" "$dst"; then
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would update: $dst"
    CHANGED=1
    return 0
  fi

  cp -a "$src" "$dst"
  chown "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
  CHANGED=1
}

render_moonraker_conf_to_tmp() {
  local src="$1"
  local tmp
  tmp="$(mktemp)"
  cp -a "$src" "$tmp"

  if [[ -n "${KLIPPER_REF:-}" ]]; then
    sed -i "s|_KLIPPER_PINNED_VERSION_|${KLIPPER_REF}|g" "$tmp"
  fi
  if [[ -n "${MOONRAKER_REF:-}" ]]; then
    sed -i "s|_MOONRAKER_PINNED_VERSION_|${MOONRAKER_REF}|g" "$tmp"
  fi

  echo "$tmp"
}

ensure_moonraker_allowed_service() {
  local service_name="shaper_compact"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$MOONRAKER_ASVC" ]]; then
    cat "$MOONRAKER_ASVC" > "$tmp"
  fi

  if ! grep -qx "$service_name" "$tmp" 2>/dev/null; then
    echo "$service_name" >> "$tmp"
  fi

  if [[ -f "$MOONRAKER_ASVC" ]] && cmp -s "$tmp" "$MOONRAKER_ASVC"; then
    sudo chown root:root "$MOONRAKER_ASVC" 2>/dev/null || true
    sudo chmod 444 "$MOONRAKER_ASVC" 2>/dev/null || true
    rm -f "$tmp"
  else
    if [[ "$CHECK_ONLY" == "true" ]]; then
      echo "Would update: $MOONRAKER_ASVC"
      CHANGED=1
      rm -f "$tmp"
    else
      cp -a "$tmp" "$MOONRAKER_ASVC"
      sudo chown root:root "$MOONRAKER_ASVC" 2>/dev/null || true
      sudo chmod 444 "$MOONRAKER_ASVC" 2>/dev/null || true
      CHANGED=1
      rm -f "$tmp"
    fi
  fi

  sudo rm -f "${CONFIG_ROOT}/moonraker.asvc" 2>/dev/null || true
}

git_enforce_ref() {
  local name="$1"
  local dir="$2"
  local ref="$3"

  if [[ -z "$ref" ]]; then
    echo "Skipping $name: empty ref"
    return 0
  fi
  if ! is_git_repo "$dir"; then
    echo "Skipping $name: not a git repo at $dir"
    return 0
  fi

  save_git_state "$dir"
  git -C "$dir" fetch --all --prune >/dev/null 2>&1 || true

  local current
  current="$(git_head "$dir")"

  if [[ "$current" == "$ref" ]]; then
    echo "$name already at pinned ref: $ref"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would set $name to pinned ref: $ref (current: ${current:-unknown})"
    CHANGED=1
    return 0
  fi

  git -C "$dir" reset --hard "$ref" >/dev/null
  git -C "$dir" clean -fd >/dev/null 2>&1 || true
  CHANGED=1
  echo "$name set to pinned ref: $ref"
}

system_best_effort_update() {
  if [[ "$SYSTEM_UPDATE" != "true" ]]; then
    echo "System update disabled."
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would run: apt-get update && apt-get -y upgrade"
    CHANGED=1
    return 0
  fi

  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  CHANGED=1
}

restart_services() {
  local -a services=( klipper moonraker KlipperScreen crowsnest nginx )
  local s
  for s in "${services[@]}"; do
    sudo systemctl restart "$s" 2>/dev/null || true
  done
}

# ------------------------------------------------------------
# Mainsail header label + branding (best-effort)
# ------------------------------------------------------------
set_mainsail_ui_branding() {
  local url="http://127.0.0.1:7125"

  if [[ "$CHECK_ONLY" == "true" ]]; then
    return 0
  fi

  for _ in {1..30}; do
    if curl -fsS "${url}/server/info" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  curl -fsS -X POST "${url}/server/database/item" \
    -H "Content-Type: application/json" \
    -d "{\"namespace\":\"mainsail\",\"key\":\"general\",\"value\":{\"printername\":\"${MAINSAIL_PRINTERNAME}\"}}" \
    >/dev/null 2>&1 || true

  curl -fsS -X POST "${url}/server/database/item" \
    -H "Content-Type: application/json" \
    -d "{\"namespace\":\"mainsail\",\"key\":\"uiSettings\",\"value\":{\"logo\":\"${MAINSAIL_UI_LOGO}\",\"primary\":\"${MAINSAIL_UI_PRIMARY}\",\"theme\":\"${MAINSAIL_UI_THEME}\"}}" \
    >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Boot splash (Plymouth velvet) from repo configs/boot
# ------------------------------------------------------------
backup_file_sudo() {
  local f="$1"
  if sudo test -f "$f"; then
    sudo cp -a "$f" "${f}.bak-$(timestamp)"
  fi
}

install_boot_splash_velvet() {
  local boot="/boot"
  [[ -d /boot/firmware ]] && boot="/boot/firmware"

  local src="${CONFIGS_SRC_DIR}/boot"
  local theme_dst="/usr/share/plymouth/themes/velvet"

  local cfg="${boot}/config.txt"
  local cmd="${boot}/cmdline.txt"

  local req=(
    "${src}/velvet.plymouth"
    "${src}/velvet.script"
    "${src}/splash.png"
    "${src}/splash2.png"
  )
  local f
  for f in "${req[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "[boot] Missing in repo: $f" >&2
      exit 1
    fi
  done

  # Sanity check: avoid 2-byte broken file scenario
  local s2_size
  s2_size="$(stat -c%s "${src}/splash2.png" 2>/dev/null || echo 0)"
  if [[ "$s2_size" -lt 1024 ]]; then
    echo "[boot] ERROR: repo splash2.png looks corrupted (size=${s2_size} bytes). Refusing to install." >&2
    exit 1
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "[boot] Would install plymouth theme velvet from: $src"
    echo "[boot] Would patch: ${cfg}, ${cmd} and rebuild initramfs8 under: ${boot}"
    CHANGED=1
    return 0
  fi

  echo "[boot] Installing Plymouth + initramfs-tools..."
  sudo apt-get update
  sudo apt-get install -y plymouth plymouth-themes initramfs-tools >/dev/null 2>&1 || true

  echo "[boot] Deploying Plymouth theme: velvet"
  sudo rm -rf "$theme_dst" 2>/dev/null || true
  sudo mkdir -p "$theme_dst"
  sudo cp -a "${src}/velvet.plymouth" "${theme_dst}/velvet.plymouth"
  sudo cp -a "${src}/velvet.script"   "${theme_dst}/velvet.script"
  sudo cp -a "${src}/splash.png"      "${theme_dst}/splash.png"
  sudo cp -a "${src}/splash2.png"     "${theme_dst}/splash2.png"
  sudo chown -R root:root "$theme_dst" 2>/dev/null || true
  sudo chmod 0644 "${theme_dst}/"*.plymouth "${theme_dst}/"*.script "${theme_dst}/"*.png 2>/dev/null || true

  # Initramfs: include KMS modules (Pi4 Bookworm)
  echo "[boot] Ensuring initramfs KMS modules..."
  sudo sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

  local m
  for m in vc4 drm drm_kms_helper; do
    grep -q "^${m}$" /etc/initramfs-tools/modules || echo "$m" | sudo tee -a /etc/initramfs-tools/modules >/dev/null
  done

  echo "[boot] Patching config.txt (kernel8 + initramfs8 + auto_initramfs + disable_splash)..."
  backup_file_sudo "$cfg"

  if sudo grep -q '^kernel=' "$cfg"; then
    sudo sed -i 's/^kernel=.*/kernel=kernel8.img/' "$cfg"
  else
    echo 'kernel=kernel8.img' | sudo tee -a "$cfg" >/dev/null
  fi

  if sudo grep -q '^auto_initramfs=' "$cfg"; then
    sudo sed -i 's/^auto_initramfs=.*/auto_initramfs=1/' "$cfg"
  else
    echo 'auto_initramfs=1' | sudo tee -a "$cfg" >/dev/null
  fi

  sudo grep -q '^initramfs initramfs8 followkernel' "$cfg" || echo 'initramfs initramfs8 followkernel' | sudo tee -a "$cfg" >/dev/null
  sudo grep -q '^disable_splash=1' "$cfg" || echo 'disable_splash=1' | sudo tee -a "$cfg" >/dev/null

  echo "[boot] Patching cmdline.txt (quiet+splash, hide cursor, hide systemd status, console tty3)..."
  backup_file_sudo "$cmd"
  local line
  line="$(cat "$cmd" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/[[:space:]]+$//')"
  line="${line/console=tty1/console=tty3}"

  local t
  for t in quiet splash loglevel=0 vt.global_cursor_default=0 logo.nologo \
           plymouth.ignore-serial-consoles systemd.show_status=0 rd.systemd.show_status=0
  do
    echo "$line" | grep -qE "(^| )${t}( |$)" || line="${line} ${t}"
  done

  printf "%s\n" "$line" | sudo tee "$cmd" >/dev/null

  echo "[boot] Setting Plymouth default theme..."
  sudo plymouth-set-default-theme velvet >/dev/null 2>&1 || true

  echo "[boot] Rebuilding initramfs..."
  sudo update-initramfs -u >/dev/null 2>&1 || true

  echo "[boot] Copying initrd -> ${boot}/initramfs8"
  sudo cp -f "/boot/initrd.img-$(uname -r)" "${boot}/initramfs8"
  sudo sync

  CHANGED=1
  echo "[boot] ✅ Plymouth velvet installed"
}

# ------------------------------------------------------------
# KlipperScreen GOLDEN X11 stack enforcement (service + launcher)
#   - includes Xorg -quiet to hide banner "X.Org X Server ... protocol ..."
# ------------------------------------------------------------
write_file_sudo() {
  local path="$1"
  local content="$2"
  sudo mkdir -p "$(dirname "$path")"
  printf "%s" "$content" | sudo tee "$path" >/dev/null
}

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
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would ensure packages: xinit xserver-xorg* libgtk-3-0 gir1.2-gtk-3.0 python3-venv python3-pip python3-dev"
    CHANGED=1
  else
    sudo apt-get update
    sudo apt-get install -y \
      xinit xserver-xorg xserver-xorg-legacy xserver-xorg-core \
      xserver-xorg-input-libinput xserver-xorg-input-evdev \
      libgtk-3-0 gir1.2-gtk-3.0 python3-venv python3-pip python3-dev \
      >/dev/null 2>&1 || true
  fi

  if [[ ! -d "$venv_dir" ]]; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      echo "Would create venv: $venv_dir"
      CHANGED=1
    else
      echo "[KlipperScreen] creating venv: $venv_dir"
      python3 -m venv "$venv_dir"
      "$venv_dir/bin/pip" install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
      if [[ -f "$ks_dir/scripts/KlipperScreen-requirements.txt" ]]; then
        "$venv_dir/bin/pip" install -r "$ks_dir/scripts/KlipperScreen-requirements.txt" >/dev/null 2>&1 || true
      fi
      chown -R "${USER_NAME}:${USER_NAME}" "$venv_dir" 2>/dev/null || true
    fi
  fi

  echo "[KlipperScreen] writing start script: $start_sh"
  local start_content
  start_content=$(cat <<EOF
#!/usr/bin/env bash
set -e

# -quiet removes the "X.Org X Server ... protocol ..." banner on startup
exec /usr/bin/openvt -s -w -f -c 7 -- /bin/su - ${USER_NAME} -c 'cd ${ks_dir} && exec /usr/bin/xinit ${venv_dir}/bin/python ${ks_dir}/screen.py -- :0 -quiet -nolisten tcp vt7'
EOF
)
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would write: $start_sh"
    CHANGED=1
  else
    printf "%s" "$start_content" > "$start_sh"
    chmod +x "$start_sh"
    chown "${USER_NAME}:${USER_NAME}" "$start_sh" 2>/dev/null || true
  fi

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
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would write: $unit_path"
    CHANGED=1
    return 0
  fi

  write_file_sudo "$unit_path" "$unit_content"
  sudo systemctl daemon-reload
  sudo systemctl enable KlipperScreen >/dev/null 2>&1 || true

  sudo systemctl stop KlipperScreen 2>/dev/null || true
  sudo pkill -f "${ks_dir}/screen.py" 2>/dev/null || true
  sudo pkill -f "xinit.*${ks_dir}/screen.py" 2>/dev/null || true
  sudo pkill -f "Xorg :0" 2>/dev/null || true
  sudo rm -f /tmp/.X11-unix/X0 2>/dev/null || true

  sudo systemctl restart KlipperScreen

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
    ls -lah /tmp/.X11-unix/ || true
    ps aux | egrep "openvt|Xorg|xinit|screen.py" | grep -v grep || true
    journalctl -t KlipperScreenX11 -n 200 --no-pager || true
    sudo systemctl status KlipperScreen --no-pager -l || true
    exit 1
  fi

  echo "✅ [KlipperScreen] UI OK"
}

# ------------------------------------------------------------
# Patch KlipperScreen theme CSS paths
# ------------------------------------------------------------
patch_klipperscreen_theme_paths() {
  local css="${HOME_DIR}/KlipperScreen/styles/velvet-darker/style.css"

  if [[ ! -f "$css" ]]; then
    echo "[KlipperScreen] style.css not found (skip patch): $css"
    return 0
  fi

  echo "[KlipperScreen] patching theme CSS paths in: $css"

  sed -i "s|%USER%|${USER_NAME}|g" "$css"
  sed -i "s|/home/[^/]\+/KlipperScreen/styles/velvet-darker/|/home/${USER_NAME}/KlipperScreen/styles/velvet-darker/|g" "$css"
}

# -------------------------------
# UI customization deployment
# -------------------------------
deploy_dir_replace() {
  local src="$1"
  local dst="$2"
  local label="${3:-dir}"

  if [[ ! -d "$src" ]]; then
    echo "Skipping ${label}: missing source dir: $src"
    return 0
  fi

  if ! find "$src" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "Skipping ${label}: source dir is empty: $src"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would replace ${label}: $dst (from $src)"
    CHANGED=1
    return 0
  fi

  rm -rf "$dst" 2>/dev/null || true
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
  chown -R "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
  CHANGED=1
  echo "Replaced ${label}: $dst"
}

deploy_ui_customizations() {
  local mainsail_src="${CONFIGS_SRC_DIR}/Mainsail"
  local mainsail_dst="${CONFIG_ROOT}/.theme"
  deploy_dir_replace "$mainsail_src" "$mainsail_dst" "Mainsail theme (.theme)"

  # Keep .theme assets-only: NEVER deploy customization.env (config for installer/update only)
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Would remove: ${mainsail_dst}/customization.env (assets-only theme dir)"
  else
    rm -f "${mainsail_dst}/customization.env" 2>/dev/null || true
  fi

  local kscreen_src="${CONFIGS_SRC_DIR}/KlipperScreen/velvet-darker"
  local kscreen_styles_dir="${KSCREEN_DIR:-/home/${USER_NAME}/KlipperScreen}/styles"
  local kscreen_dst="${kscreen_styles_dir}/velvet-darker"
  deploy_dir_replace "$kscreen_src" "$kscreen_dst" "KlipperScreen theme (velvet-darker)"

  patch_klipperscreen_theme_paths
}

# ------------------------------------------------------------
# Rollback
# ------------------------------------------------------------
rollback() {
  if [[ "$ROLLBACK_IN_PROGRESS" -eq 1 ]]; then
    return 0
  fi
  ROLLBACK_IN_PROGRESS=1

  echo
  echo "ERROR: update failed. Starting rollback..."

  local i item backup dst
  for (( i=${#CREATED_BACKUPS[@]}-1; i>=0; i-- )); do
    item="${CREATED_BACKUPS[$i]}"
    backup="${item%%|*}"
    dst="${item#*|}"
    if [[ -f "$backup" ]]; then
      cp -a "$backup" "$dst" 2>/dev/null || true
      chown "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
    fi
  done

  local dir
  for dir in "${!PREV_HEAD[@]}"; do
    restore_git_state "$dir"
  done

  restart_services

  echo "Rollback completed."
}

on_error() {
  if [[ "$CHECK_ONLY" != "true" ]]; then
    rollback
  fi
}
trap on_error ERR

git -C "${REPO_DIR}" config core.fileMode false 2>/dev/null || true
save_git_state "${REPO_DIR}"

echo "Shaper Compact Update"
echo "Log: $LOG"
echo "Repo: $REPO_DIR"
echo "Printer data: $PRINTER_DATA"
echo "CHECK_ONLY: $CHECK_ONLY"
echo "SYSTEM_UPDATE: $SYSTEM_UPDATE"
echo

# Load Mainsail customization.env early (for DB writes)
load_mainsail_customization_env

# ------------------------------------------------------------
# 1) Enforce pinned versions (git)
# ------------------------------------------------------------
echo "[1/5] Enforcing pinned versions..."

KLIPPER_DIR="${KLIPPER_DIR:-/home/${USER_NAME}/klipper}"
MOONRAKER_DIR="${MOONRAKER_DIR:-/home/${USER_NAME}/moonraker}"
KSCREEN_DIR="${KSCREEN_DIR:-/home/${USER_NAME}/KlipperScreen}"
CROWSNEST_DIR="${CROWSNEST_DIR:-/home/${USER_NAME}/crowsnest}"
MAINSAIL_DIR="${MAINSAIL_DIR:-/home/${USER_NAME}/mainsail}"

git_enforce_ref "Klipper"       "$KLIPPER_DIR"   "${KLIPPER_REF:-}"
git_enforce_ref "Moonraker"     "$MOONRAKER_DIR" "${MOONRAKER_REF:-}"
git_enforce_ref "KlipperScreen" "$KSCREEN_DIR"   "${KSCREEN_REF:-}"
git_enforce_ref "Crowsnest"     "$CROWSNEST_DIR" "${CROWSNEST_REF:-}"

if [[ -n "${MAINSAIL_REF:-}" ]]; then
  if is_git_repo "$MAINSAIL_DIR"; then
    git_enforce_ref "Mainsail" "$MAINSAIL_DIR" "$MAINSAIL_REF"
  else
    echo "Skipping Mainsail pin: $MAINSAIL_DIR is not a git repo."
  fi
else
  echo "Skipping Mainsail pin: MAINSAIL_REF is empty."
fi

system_best_effort_update

echo
echo "[2/5] Enforcing KlipperScreen X11 stack..."
ensure_klipperscreen_x11_stack

# ------------------------------------------------------------
# 3) Deploy configs (NO printer.cfg) + UI customizations
# ------------------------------------------------------------
echo
echo "[3/5] Deploying configuration..."

ROOT_FILES=( "KlipperScreen.conf" "crowsnest.conf" "mainsail.cfg" "moonraker.conf" )
CONFIGS_FILES=( "macros.cfg" "setup.cfg" )

for f in "${ROOT_FILES[@]}"; do
  [[ -f "${CONFIGS_SRC_DIR}/${f}" ]] || { echo "Missing: ${CONFIGS_SRC_DIR}/${f}" >&2; exit 1; }
done
for f in "${CONFIGS_FILES[@]}"; do
  [[ -f "${CONFIGS_SRC_DIR}/${f}" ]] || { echo "Missing: ${CONFIGS_SRC_DIR}/${f}" >&2; exit 1; }
done

for f in "${ROOT_FILES[@]}"; do
  src="${CONFIGS_SRC_DIR}/${f}"
  dst="${CONFIG_ROOT}/${f}"

  if [[ "$f" == "moonraker.conf" ]]; then
    tmp="$(render_moonraker_conf_to_tmp "$src")"
    deploy_file "$tmp" "$dst"
    rm -f "$tmp"
  else
    deploy_file "$src" "$dst"
  fi
done

for f in "${CONFIGS_FILES[@]}"; do
  src="${CONFIGS_SRC_DIR}/${f}"
  dst="${TARGET_CONFIGS_DIR}/${f}"
  deploy_file "$src" "$dst"
done

deploy_ui_customizations
ensure_moonraker_allowed_service

# ------------------------------------------------------------
# 4) Boot splash (Plymouth velvet)
# ------------------------------------------------------------
echo
echo "[4/5] Boot splash (Plymouth velvet)..."
install_boot_splash_velvet

echo
echo "[5/5] Finalizing..."

patch_klipperscreen_theme_paths

if [[ "$CHANGED" -eq 1 ]]; then
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Check-only mode: changes detected (no changes applied)."
  else
    echo "Changes applied. Restarting services..."
    restart_services
  fi
else
  echo "No changes detected."
fi

# Always enforce Mainsail header + branding (best-effort)
set_mainsail_ui_branding

echo
echo "Update completed."
