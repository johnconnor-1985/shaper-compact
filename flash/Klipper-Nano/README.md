Klipper flash script for Arduino Nano based on CH340.

Connect your Nano to Raspberry, unconnect any other USB device,
launch from SSH:

```bash
cd ~ && \
( [ -d shaper-compact ] || git clone https://github.com/johnconnor-1985/shaper-compact.git ) && \
cd shaper-compact && \
git fetch origin && \
git reset --hard origin/main && \
./flash/"Klipper-Nano"/flash_nano.sh
```
