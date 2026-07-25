#!/bin/bash
# AWDL hop test - captures OWL's belief and the radio's truth against one clock.
set -u
IFACE=wlp2s0
CHAN=149
DUR=60
OUT=/mnt/shared/owl-hoptest-$(date +%Y%m%d-%H%M%S)
OWL=~/owl/build/daemon/owl

# --- preflight: the documented failure mode, checked first ---
KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97. Monitor RX dies silently on 6.18."; exit 1 ;;
esac
[ -x "$OWL" ] || { echo "REFUSING: no binary at $OWL"; exit 1; }
mkdir -p "$OUT" || exit 1

sudo -v || exit 1   # cache creds now so the trap never prompts

restore() {
  echo "--- restoring networking ---"
  [ -n "${POLL_PID:-}" ] && kill "$POLL_PID" 2>/dev/null
  [ -n "${OWL_PID:-}"  ] && sudo kill "$OWL_PID" 2>/dev/null
  sleep 1
  sudo pkill -x owl 2>/dev/null
  sudo ip link set $IFACE down 2>/dev/null
  sudo iw dev $IFACE set type managed 2>/dev/null
  sudo ip link set $IFACE up 2>/dev/null
  sudo sv up NetworkManager 2>/dev/null
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

# --- take the card ---
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant; sudo pkill -x dhcpcd; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down

# --- stream 2: radio truth, 20 Hz, independent of OWL ---
( while :; do
    printf '%s %s\n' "$(date +%s.%N)" \
      "$(iw dev $IFACE info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo NA)"
    sleep 0.05
  done ) > "$OUT/radio.log" &
POLL_PID=$!

# --- stream 1: OWL, timestamped on the same clock ---
sudo stdbuf -oL "$OWL" -i $IFACE -c $CHAN -vv 2>&1 \
  | python3 -u -c 'import sys,time
for l in sys.stdin: sys.stdout.write("%.6f %s" % (time.time(), l))' > "$OUT/owl.log" &
OWL_PID=$(pgrep -x owl | head -1)

echo "running ${DUR}s on channel $CHAN -> $OUT"
sleep $DUR
