#!/bin/bash
set -u

echo "===== KERNEL ====="
uname -r

echo
echo "===== ALSA CARDS ====="
cat /proc/asound/cards

echo
echo "===== AUDIO MODULES ====="
lsmod | grep -E 'pcm5102a|snd_aloop|snd_soc' || true

echo
echo "===== INSTALLED PCM5102A DRIVER ====="
modinfo -n snd-soc-pcm5102a
modinfo -F vermagic snd-soc-pcm5102a
sha256sum "$(modinfo -n snd-soc-pcm5102a)"

echo
echo "===== CROSSOVER SERVICE ====="
systemctl status crossoverd --no-pager

echo
echo "===== CROSSOVER LOG ====="
journalctl -u crossoverd -b -n 30 --no-pager
