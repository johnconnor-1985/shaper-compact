#!/usr/bin/env bash
set -e

echo "=== Velvet Plymouth Splash Setup ==="

THEME_SRC="/home/velvet/shaper-compact/configs/KlipperScreen/boot"
THEME_DST="/usr/share/plymouth/themes/velvet"
BOOT="/boot"
[ -d /boot/firmware ] && BOOT="/boot/firmware"

echo "Boot path: $BOOT"

# -----------------------------
# Install packages
# -----------------------------

sudo apt update
sudo apt install -y plymouth plymouth-themes initramfs-tools

# -----------------------------
# Copy theme
# -----------------------------

echo "Installing velvet Plymouth theme..."

sudo rm -rf "$THEME_DST"
sudo mkdir -p "$THEME_DST"
sudo cp -r "$THEME_SRC/"* "$THEME_DST/"

# -----------------------------
# Configure boot (config.txt)
# -----------------------------

CONFIG="$BOOT/config.txt"
CMDLINE="$BOOT/cmdline.txt"

sudo cp -f "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
sudo cp -f "$CMDLINE" "$CMDLINE.bak.$(date +%Y%m%d_%H%M%S)"

# Force kernel + initramfs

grep -q '^kernel=' "$CONFIG" \
  && sudo sed -i 's/^kernel=.*/kernel=kernel8.img/' "$CONFIG" \
  || echo 'kernel=kernel8.img' | sudo tee -a "$CONFIG" >/dev/null

grep -q '^auto_initramfs=' "$CONFIG" \
  && sudo sed -i 's/^auto_initramfs=.*/auto_initramfs=1/' "$CONFIG" \
  || echo 'auto_initramfs=1' | sudo tee -a "$CONFIG" >/dev/null

grep -q '^initramfs initramfs8 followkernel' "$CONFIG" \
  || echo 'initramfs initramfs8 followkernel' | sudo tee -a "$CONFIG" >/dev/null

grep -q '^disable_splash=1' "$CONFIG" \
  || echo 'disable_splash=1' | sudo tee -a "$CONFIG" >/dev/null

# -----------------------------
# Configure cmdline
# -----------------------------

LINE="$(cat "$CMDLINE")"

LINE="${LINE/console=tty1/console=tty3}"

for t in quiet splash loglevel=0 vt.global_cursor_default=0 logo.nologo \
         plymouth.ignore-serial-consoles systemd.show_status=0 rd.systemd.show_status=0
do
  echo "$LINE" | grep -q "$t" || LINE="$LINE $t"
done

printf "%s\n" "$LINE" | sudo tee "$CMDLINE" >/dev/null

# -----------------------------
# Initramfs modules
# -----------------------------

sudo sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

grep -q '^vc4$' /etc/initramfs-tools/modules || sudo tee -a /etc/initramfs-tools/modules > /dev/null <<EOF
vc4
drm
drm_kms_helper
EOF

# -----------------------------
# Activate theme
# -----------------------------

sudo plymouth-set-default-theme velvet

# -----------------------------
# Rebuild initramfs
# -----------------------------

sudo update-initramfs -u
sudo cp -f /boot/initrd.img-$(uname -r) "$BOOT/initramfs8"

# -----------------------------
# Silence Xorg banner
# -----------------------------

if systemctl list-unit-files | grep -q -i klipperscreen; then
  SERVICE=$(systemctl list-unit-files | grep -i klipperscreen | awk '{print $1}' | head -n1)

  sudo systemctl edit "$SERVICE" <<EOF
[Service]
StandardOutput=null
StandardError=null
EOF

  sudo systemctl daemon-reload
fi

echo "=== Splash setup complete ==="
echo "Reboot recommended."
