#!/bin/bash

DIR="/root/crossover"
FREQ_FILE="$DIR/crossover_freq.conf"
GAIN_FILE="$DIR/tweeter_gain.conf"

show_settings() {
    echo
    echo "  Current crossover: $(cat "$FREQ_FILE" 2>/dev/null || echo 1000) Hz"
    echo "  Tweeter gain:      $(cat "$GAIN_FILE" 2>/dev/null || echo 0.0) dB"
    echo
}

change_frequency() {
    echo
    echo "===== CROSSOVER FREQUENCY ====="
    echo
    echo "  Enter a frequency from 100 to 18000 Hz."
    echo "  Valid increments: 100 Hz"
    echo

    read -r -p "Crossover frequency (Hz): " frequency

    if ! [[ "$frequency" =~ ^[0-9]+$ ]]; then
        echo "Invalid frequency."
        return
    fi

    frequency=$((10#$frequency))

    if (( frequency < 100 || frequency > 18000 || frequency % 100 != 0 )); then
        echo "Frequency must be 100-18000 Hz in 100 Hz increments."
        return
    fi

    echo "$frequency" > "$FREQ_FILE"

    echo
    echo "Setting crossover to $frequency Hz..."
    echo "Restarting audio crossover..."

    if systemctl restart crossoverd; then
        echo "Crossover restarted successfully."
    else
        echo "ERROR: Could not restart crossover."
    fi
}

change_gain() {
    echo
    echo "===== TWEETER GAIN ====="
    echo
    echo "  Enter a value between -10.0 and 0.0 dB."
    echo "  Examples: -10, -6.5, -3, 0"
    echo

    read -r -p "New tweeter gain (dB): " gain

    if ! [[ "$gain" =~ ^-?([0-9]+)(\.[0-9]+)?$ ]]; then
        echo "Invalid number."
        return
    fi

    if ! awk -v g="$gain" 'BEGIN { exit !(g >= -10 && g <= 0) }'; then
        echo "Gain must be between -10.0 and 0.0 dB."
        return
    fi

    printf "%.1f\n" "$gain" > "$GAIN_FILE"
    echo "Tweeter gain updated to $(cat "$GAIN_FILE") dB."
}

while true; do
    clear

    echo "================================"
    echo "       ROCK PI S AUDIO"
    echo "       CROSSOVER CONTROL"
    echo "================================"

    show_settings

    echo "  1. Change crossover frequency"
    echo "  2. Adjust tweeter gain"
    echo "  3. Show current settings"
    echo "  4. Restart audio crossover"
    echo "  5. Exit"
    echo

    read -r -p "Select option: " option

    case "$option" in
        1) change_frequency ;;
        2) change_gain ;;
        3) show_settings ;;
        4)
            echo
            echo "Restarting audio crossover..."
            systemctl restart crossoverd
            systemctl is-active crossoverd
            ;;
        5) clear; exit 0 ;;
        *) echo "Invalid option." ;;
    esac

    echo
    read -r -p "Press Enter to continue..."
done
