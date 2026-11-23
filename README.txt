ROCK PI S AUDIO SYSTEM - WORKING SNAPSHOT
=========================================

Board:
  Radxa ROCK Pi S / RK3308
  ARM64

Tested kernel:
  6.18.44-current-rockchip64

Audio hardware:
  PCM5102A DAC
  ALSA Loopback (snd-aloop)

DSP:
  Four-channel digital crossover
  2-channel stereo input
  4-channel DAC output:
    channel 0: woofer left
    channel 1: woofer right
    channel 2: tweeter left
    channel 3: tweeter right

The crossover application uses direct ALSA hardware devices.
It detects the Loopback card index dynamically and reads its
playback hardware parameters to select the input sample rate.

IMPORTANT:
  The modified PCM5102A kernel module is specific to the
  kernel version shown above. Do not install it on a different
  kernel. install.sh checks this before making changes.

INSTALLATION:
  1. Extract this archive on the target Rock Pi S.
  2. Check that the target is running the matching kernel:
       uname -r
  3. Run:
       sudo bash install.sh
  4. Reboot:
       sudo reboot

The installer does not modify the boot device tree or
/boot/armbianEnv.txt. The working board's boot configuration
and device-tree snapshots are included in the boot directory
for reference.

The installer enables the crossover service but does not
start it immediately. Rebooting allows the modified driver
to load cleanly.

After reboot, check:
  uname -r
  cat /proc/asound/cards
  lsmod | grep -E 'pcm5102a|snd_aloop'
  systemctl status crossoverd
  journalctl -u crossoverd -b --no-pager
  cat /proc/asound/card0/pcm0p/sub0/hw_params

The original PCM5102A driver is included in the driver
directory as a backup/reference.
