# shaper-compact
Installer, Updater and configuration files for Shaper Compact


How to launch the Installer from SSH:

```bash
cd ~ && \
if [ ! -d shaper-compact ]; then
  git clone https://github.com/johnconnor-1985/shaper-compact.git
  cd shaper-compact
else
  cd shaper-compact
  git fetch origin
  git reset --hard origin/main
fi && \
bash install.sh
```

Please launch the Updater only from Updated Manager in Maisail/KlipperScreen
