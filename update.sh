#!/usr/bin/env bash
#
# ============================================================
# Shaper Compact – update.sh (Policy + Technical Plan)
# ============================================================
#
# PURPOSE
# -------
# This repository exposes ONLY Shaper Compact configs through Moonraker Update Manager.
# Core stack (Klipper, Moonraker, Mainsail, KlipperScreen, crowsnest, etc.) must stay
# PINNED to validated versions.
#
# This file documents HOW we will verify/enforce those pins later.
# It is a placeholder (no executable logic yet).
#
# ============================================================
# versions.conf (HOW IT WILL WORK)
# ============================================================
#
# We will store pinned versions in a file at repo root:
#
#   versions.conf
#
# Format: simple KEY="VALUE" shell variables.
# Example:
#
#   # Git-based components (use tags or exact commits)
#   KLIPPER_PATH="$HOME/klipper"
#   KLIPPER_REF="v0.12.0"              # or commit: "a1b2c3d4..."
#
#   MOONRAKER_PATH="$HOME/moonraker"
#   MOONRAKER_REF="v0.9.3"             # or commit
#
#   KSCREEN_PATH="$HOME/KlipperScreen"
#   KSCREEN_REF="v0.4.0"               # or commit
#
#   # Web UI (path depends on distro)
#   MAINSAIL_PATH="/var/www/mainsail"
#   MAINSAIL_REF="v2.12.0"             # or commit/tag (if git-managed)
#
#   # Package-based components (APT)
#   CROWSNEST_MODE="apt"               # "apt" or "git"
#   CROWSNEST_PKG="crowsnest"
#   CROWSNEST_PKG_VERSION="4.0.1-1"    # exact dpkg version string
#
# Optional additional pins:
#   OS_RELEASE_CODENAME="bookworm"
#   KERNEL_MIN="6.1"
#
# ============================================================
# update.sh MODES (FUTURE)
# ============================================================
#
# update.sh will support:
#
#   ./update.sh --check
#       - Read versions.conf
#       - Detect current installed versions
#       - Print a clear report:
#           OK / MISMATCH / NOT FOUND
#       - Exit codes:
#           0  = all OK
#           2  = mismatches found
#           3  = missing components/paths
#
#   ./update.sh --apply
#       - Enforce pinned versions
#       - MUST require explicit confirmation flag, e.g.:
#           ./update.sh --apply --i-know-what-im-doing
#       - MUST refuse if a print is running
#       - Actions:
#           * Git components:
#               - git fetch --all --tags
#               - git checkout <REF>
#               - optional: git submodule update --init --recursive
#           * APT components:
#               - sudo apt install <pkg>=<version>
#               - sudo apt-mark hold <pkg>   (optional)
#       - Restart only the necessary services:
#           - klipper, moonraker, nginx/lighttpd, KlipperScreen, crowsnest
#
#   ./update.sh --unhold
#       - If we use apt-mark hold, allow unhold during maintenance windows.
#
# ============================================================
# VERSION DETECTION (FUTURE IMPLEMENTATION DETAILS)
# ============================================================
#
# Git repos:
#   CURRENT_COMMIT = git -C <PATH> rev-parse HEAD
#   CURRENT_TAG    = git -C <PATH> describe --tags --always --dirty
# Comparison:
#   - If REF is a tag: compare "describe --tags" starts with that tag
#   - If REF is a commit: compare exact rev-parse
#
# APT packages:
#   CURRENT_VER = dpkg-query -W -f='${Version}' <PKG>
# Comparison:
#   - exact string match against *_PKG_VERSION
#
# ============================================================
# SAFETY / PRODUCTION RULES
# ============================================================
#
# - Normal operators MUST NOT run this script.
# - Default behavior should be --check only (no changes).
# - --apply must:
#     * refuse during active printing
#     * log actions and results
#     * create backups where relevant
#     * be idempotent (safe to run twice)
#
# ============================================================
# SCHEDULING (OPTIONAL)
# ============================================================
#
# Add a systemd timer to run CHECK ONLY (recommended):
#   - daily or weekly
#   - logs to journald
#   - if mismatch found: print instructions (do not auto-apply)
#
# ============================================================
# STATUS
# ============================================================
# Placeholder only. No executable logic yet.
# Do NOT remove/rename this file.
# ============================================================
