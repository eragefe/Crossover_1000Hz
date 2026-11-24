#!/bin/sh
set -eu



REPO="https://github.com/eragefe/Crossover_1000Hz.git"
WORK="/tmp/Crossover_1000Hz"
APP="/root/crossover"
KVER="$(uname -r)"
MODULE_DIR="/lib/modules/$KVER"
TCE_DIR="/etc/sysconfig/tcedir"

echo "===== TINY CORE CROSSOVER INSTALLER ====="

# 1. Install Git if necessary
if ! command -v git >/dev/null 2>&1; then
    echo "Installing Git..."
    su tc -c "tce-load -wi git"
fi

# Keep Git available after reboot
if [ -f "$TCE_DIR/onboot.lst" ]; then
    grep -qxF git.tcz "$TCE_DIR/onboot.lst" ||
        echo git.tcz >> "$TCE_DIR/onboot.lst"
fi

# 2. Clone the project
echo "Cloning crossover repository..."
rm -rf "$WORK"
git clone --depth 1 "$REPO" "$WORK"

# 3. Install crossover files without overwriting existing programs/settings
mkdir -p "$APP"

for file in crossover.c crossoverd_auto crossoverd_auto.c; do
    if [ ! -e "$APP/$file" ]; then
        cp "$WORK/crossover/$file" "$APP/$file"
    else
        echo "Preserving existing $APP/$file"
    fi
done

for file in crossover_freq.conf tweeter_gain.conf; do
    if [ ! -e "$APP/$file" ]; then
        if [ -f "$WORK/crossover/$file" ]; then
            cp "$WORK/crossover/$file" "$APP/$file"
        fi
    else
        echo "Preserving existing setting: $file"
    fi
done

chmod +x "$APP/crossoverd_auto"

# 4. Install the modified PCM5102A driver
echo "Installing modified PCM5102A driver..."
mkdir -p "$MODULE_DIR/kernel/sound/soc/codecs"


install -m 644 "$WORK/driver/snd-soc-pcm5102a.ko" \
    "$MODULE_DIR/kernel/sound/soc/codecs/snd-soc-pcm5102a.ko"

# Rebuild module dependency information.
# The currently loaded driver is NOT unloaded or disturbed.
depmod -a "$KVER"

# 5. Install Tiny Core-compatible control menu
cat > "$APP/audio-control.sh" <<'CONTROL'
#!/bin/sh

DIR="/root/crossover"
FREQ_FILE="$DIR/crossover_freq.conf"
GAIN_FILE="$DIR/tweeter_gain.conf"
SERVICE="/usr/local/bin/crossoverd-service"

show_settings() {
    printf "\nCurrent crossover frequency: "
    cat "$FREQ_FILE" 2>/dev/null || echo "not set"
    printf "Current tweeter gain: "
    cat "$GAIN_FILE" 2>/dev/null || echo "not set"
}

change_frequency() {
    printf "Enter crossover frequency (100-18000 Hz, steps of 100): "
    read frequency

    case "$frequency" in
        ''|*[!0-9]*)
            echo "Invalid frequency."
            return
            ;;
    esac

    if ! awk -v f="$frequency" \
        'BEGIN { exit !(f >= 100 && f <= 18000 && f % 100 == 0) }'
    then
        echo "Frequency must be 100-18000 Hz in steps of 100."
        return
    fi

    printf "%s\n" "$frequency" > "$FREQ_FILE"
    echo "Frequency saved."
    "$SERVICE" restart
}

change_gain() {
    printf "Enter tweeter gain (-10.0 to 0.0 dB): "
    read gain

    if ! awk -v g="$gain" \
        'BEGIN {
            if (g !~ /^-?[0-9]+([.][0-9]+)?$/) exit 1
            if (g < -10 || g > 0) exit 1
        }'
    then
        echo "Gain must be between -10.0 and 0.0 dB."
        return
    fi

    awk -v g="$gain" 'BEGIN { printf "%.1f\n", g }' > "$GAIN_FILE"
    echo "Tweeter gain saved."
}

while :
do
    clear
    echo "================================"
    echo "       DIGITAL CROSSOVER"
    echo "================================"
    show_settings
    echo
    echo "1. Change crossover frequency"
    echo "2. Change tweeter gain"
    echo "3. Show settings"
    echo "4. Restart crossover"
    echo "5. Crossover status"
    echo "0. Exit"
    echo
    printf "Select: "
    read choice

    case "$choice" in
        1) change_frequency ;;
        2) change_gain ;;
        3) show_settings ;;
        4) "$SERVICE" restart ;;
        5) "$SERVICE" status ;;
        0) exit 0 ;;
        *) echo "Invalid selection." ;;
    esac

    echo
    printf "Press Enter to continue..."
    read pause
done
CONTROL

chmod +x "$APP/audio-control.sh"

# 6. Preserve the existing service; create it only if missing
mkdir -p /usr/local/bin

cat > /usr/local/bin/crossoverd-service <<'SERVICE'
#!/bin/sh
APP=/root/crossover
PIDFILE=/var/run/crossoverd.pid

start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Crossover is already running."
        return 0
    fi
    modprobe snd-aloop || exit 1
    "$APP/crossoverd_auto" &
    echo $! > "$PIDFILE"
    echo "Crossover started."
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "Crossover stopped."
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "Crossover is running."
        else
            echo "Crossover is stopped."
            exit 1
        fi ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
SERVICE

chmod +x /usr/local/bin/crossoverd-service

touch /opt/bootlocal.sh
# Route all audio renderers through the crossover
sed -i "s|--gstout-audiodevice=hw:0,0|--gstout-audiodevice=hw:Loopback,0,0|g" /opt/bootlocal.sh
sed -i "s|-d hw:0|-d hw:Loopback,0|g" /opt/bootlocal.sh
sed -i "s|-o hw:0|-o hw:Loopback,0|g" /opt/bootlocal.sh

# 7. Configure automatic startup before audio renderers
touch /opt/bootlocal.sh
if ! grep -qF "/usr/local/bin/crossoverd-service start" /opt/bootlocal.sh; then
    sed -i "/^# Turn off blue user LED/i\\# Start four-channel digital crossover\n/usr/local/bin/crossoverd-service start\nsleep 2\n" /opt/bootlocal.sh
fi

# 8. Add required files to Tiny Core persistence list
touch /opt/.filetool.lst

add_persistence() {
    entry="$1"
    grep -qxF "$entry" /opt/.filetool.lst ||
        echo "$entry" >> /opt/.filetool.lst
}

add_persistence "opt"
add_persistence "root/crossover"
add_persistence "usr/local/bin/crossoverd-service"
add_persistence "lib/modules/$KVER/kernel/sound/soc/codecs/snd-soc-pcm5102a.ko"
add_persistence "lib/modules/$KVER/modules.dep"
add_persistence "lib/modules/$KVER/modules.alias"
add_persistence "lib/modules/$KVER/modules.symbols"
add_persistence "lib/modules/$KVER/modules.softdep"

if [ -f "$MODULE_DIR/modules.devname" ]; then
    add_persistence "lib/modules/$KVER/modules.devname"
fi

# 9. Save everything for the next reboot
echo "Saving Tiny Core persistence..."
filetool.sh -b

echo
echo "===== INSTALLATION FINISHED ====="
echo "Crossover files: $APP"
echo "Control menu:    $APP/audio-control.sh"
echo "Driver:          $MODULE_DIR"
echo "Startup:         /opt/bootlocal.sh"
echo
echo "The running driver and crossover service were not unloaded."
echo "No reboot has been performed."
