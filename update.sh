#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Shaper Compact - update.sh (Step 1: rollback + pins + config deploy)
#
# Enforces pinned versions from versions.env (best-effort):
#   - Klipper (git)
#   - Moonraker (git)
#   - KlipperScreen (git)
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
#   - KlipperScreen: ./configs/KlipperScreen/velvet-darker -> ~/KlipperScreen/styles/velvet-darker
#
# Backups:
#   - Only if destination existed and differed
#   - Stored in: <printer_data>/config/Backup/
#
# Rollback:
#   - If any step fails (except system upgrade), rollback restores:
#       * git repos to their previous HEAD
#       * config files to their previous state (using backups created this run)
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

# Prevent "dirty" status due to executable bit changes on embedded systems
git -C "${REPO_DIR}" config core.fileMode false 2>/dev/null || true

echo "Shaper Compact Update"
echo "Log: $LOG"
echo "Repo: $REPO_DIR"
echo "Printer data: $PRINTER_DATA"
echo "CHECK_ONLY: $CHECK_ONLY"
echo "SYSTEM_UPDATE: $SYSTEM_UPDATE"
echo

# ------------------------------------------------------------
# Rollback state
# ------------------------------------------------------------

# Map: repo_dir -> previous_head
declare -A PREV_HEAD=()

# Lists of backups created in this run: "backup_path|dest_path"
declare -a CREATED_BACKUPS=()

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
  # If dst exists and differs from src, create backup and record it.
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

  # Replace placeholders if present
  if [[ -n "${KLIPPER_REF:-}" ]]; then
    sed -i "s|_KLIPPER_PINNED_VERSION_|${KLIPPER_REF}|g" "$tmp"
  fi
  if [[ -n "${MOONRAKER_REF:-}" ]]; then
    sed -i "s|_MOONRAKER_PINNED_VERSION_|${MOONRAKER_REF}|g" "$tmp"
  fi

  echo "$tmp"
}

ensure_moonraker_allowed_service() {
  # Ensure Moonraker can manage shaper_compact service via allowlist.
  # No backup desired for moonraker.asvc.
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

  # Remove any stray duplicate under config/ (no backup)
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
  # Not rollbackable.
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
  # Keep conservative. Do not fail on restart errors.
  local -a services=( klipper moonraker KlipperScreen crowsnest nginx )
  local s
  for s in "${services[@]}"; do
    sudo systemctl restart "$s" 2>/dev/null || true
  done
}

# -------------------------------
# UI customization deployment
# -------------------------------

deploy_dir_replace() {
  # Hard replace directory (no backups):
  #   deploy_dir_replace <src_dir> <dst_dir> <label>
  local src="$1"
  local dst="$2"
  local label="${3:-dir}"

  if [[ ! -d "$src" ]]; then
    echo "Skipping ${label}: missing source dir: $src"
    return 0
  fi

  # ensure src has something
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
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  chown -R "${USER_NAME}:${USER_NAME}" "$dst" 2>/dev/null || true
  CHANGED=1
  echo "Replaced ${label}: $dst"
}

deploy_ui_customizations() {
  # Mainsail .theme
  local mainsail_src="${CONFIGS_SRC_DIR}/Mainsail"
  local mainsail_dst="${CONFIG_ROOT}/.theme"
  deploy_dir_replace "$mainsail_src" "$mainsail_dst" "Mainsail theme (.theme)"

  # KlipperScreen theme (velvet-darker)
  local kscreen_src="${CONFIGS_SRC_DIR}/KlipperScreen/velvet-darker"
  local kscreen_styles_dir="${KSCREEN_DIR:-/home/${USER_NAME}/KlipperScreen}/styles"
  local kscreen_dst="${kscreen_styles_dir}/velvet-darker"
  deploy_dir_replace "$kscreen_src" "$kscreen_dst" "KlipperScreen theme (velvet-darker)"
}

rollback() {
  # Restore configs (from backups created during this run) and git HEADs.
  if [[ "$ROLLBACK_IN_PROGRESS" -eq 1 ]]; then
    return 0
  fi
  ROLLBACK_IN_PROGRESS=1

  echo
  echo "ERROR: update failed. Starting rollback..."

  # Restore configs from backups (reverse order)
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

  # Restore git repos
  local dir
  for dir in "${!PREV_HEAD[@]}"; do
    restore_git_state "$dir"
  done

  # NOTE: UI custom dirs are "no backup"; rollback does not revert them.

  # Best-effort restart after rollback
  restart_services

  echo "Rollback completed."
}

on_error() {
  # Only rollback when we actually applied changes.
  if [[ "$CHECK_ONLY" != "true" ]]; then
    rollback
  fi
}
trap on_error ERR

# ------------------------------------------------------------
# 1) Enforce pinned versions (git)
# ------------------------------------------------------------
echo "[1/4] Enforcing pinned versions..."

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

# System update (optional, NOT rollbackable)
system_best_effort_update

# ------------------------------------------------------------
# 2) Deploy configs (NO printer.cfg) + UI customizations
# ------------------------------------------------------------
echo
echo "[2/4] Deploying configuration..."

# Source files (must exist)
ROOT_FILES=( "KlipperScreen.conf" "crowsnest.conf" "mainsail.cfg" "moonraker.conf" )
CONFIGS_FILES=( "macros.cfg" "setup.cfg" )

for f in "${ROOT_FILES[@]}"; do
  [[ -f "${CONFIGS_SRC_DIR}/${f}" ]] || { echo "Missing: ${CONFIGS_SRC_DIR}/${f}" >&2; exit 1; }
done
for f in "${CONFIGS_FILES[@]}"; do
  [[ -f "${CONFIGS_SRC_DIR}/${f}" ]] || { echo "Missing: ${CONFIGS_SRC_DIR}/${f}" >&2; exit 1; }
done

# Deploy root files; moonraker.conf is templated
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

# Deploy Configs/ files
for f in "${CONFIGS_FILES[@]}"; do
  src="${CONFIGS_SRC_DIR}/${f}"
  dst="${TARGET_CONFIGS_DIR}/${f}"
  deploy_file "$src" "$dst"
done

# Deploy UI customizations (NO BACKUP, hard replace)
deploy_ui_customizations

# Allow Moonraker to manage shaper_compact service (no backup)
ensure_moonraker_allowed_service

# ------------------------------------------------------------
# 3) Final checks / hygiene
# ------------------------------------------------------------
echo
echo "[3/4] Hygiene..."
git -C "${REPO_DIR}" config core.fileMode false 2>/dev/null || true

# ------------------------------------------------------------
# 4) Restart services if needed
# ------------------------------------------------------------
echo
echo "[4/4] Finalizing..."

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

echo
echo "Update completed."
