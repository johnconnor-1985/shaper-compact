# shaper-compact
Installer, Updater and configuration files for Shaper Compact


How to launch the Installer from SSH:

```bash
cd ~ && \
( [ -d shaper-compact ] || git clone https://github.com/johnconnor-1985/shaper-compact.git ) && \
cd shaper-compact && \
git fetch origin && \
git reset --hard origin/main && \
bash install.sh
```

Please launch the Updater only from Update Manager in Mainsail/KlipperScreen
