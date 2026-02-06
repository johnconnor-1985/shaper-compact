Klipper flash script for Arduino Nano based on CH30

Launch from SSH:

```bash
cd ~ && \
( [ -d shaper-compact ] || git clone https://github.com/johnconnor-1985/shaper-compact.git ) && \
cd shaper-compact && \
git fetch origin && \
git reset --hard origin/main && \
./flash/"Kipper Nano"/flash_nano.sh
```
