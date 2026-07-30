#!/bin/bash
# Decisive A/B: does `iw set channel` kill monitor RX on mt7921?
#
# Hypothesis. monitor-test.sh (2026-07-25) reported beacons flooding in on
# 6.12.97 and it NEVER sets a channel. hoptest.sh and OWL both DO set one, and
# both see zero RX. If RX works before a set-channel and dies after it, that is
# the whole bug - and it also explains the 07-25 observation of frames tagged
# 5180 MHz (the AP's channel, which the radio never actually left) while iw
# happily reported 149.
#
# Phase A: monitor mode, no channel set at all. Capture.
# Phase B: same session, now set a channel. Capture again.
# Same session, same interface, nothing else differs.
#
# SAFETY: bash trap + detached watchdog that restores even on kill -9 or hang.
set -u

IFACE=wlp2s0
DWELL=10
WATCHDOG_TIMEOUT=150
OUT=/mnt/shared/owl-rxtest-$(date +%Y%m%d-%H%M%S)

KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97."; exit 1 ;;
esac
command -v tcpdump >/dev/null || { echo "REFUSING: no tcpdump"; exit 1; }
mkdir -p "$OUT" || exit 1
sudo -v || exit 1

RESTORE_CMDS='
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

restore() {
  echo "--- restoring networking ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

# capture $1=label, writes pcap, prints frame count and radiotap freqs
capture() {
  local LABEL="$1" PCAP="$OUT/$1.pcap"
  local INFO CLAIMED CLAIMED_MHZ TXP COUNT FREQS
  INFO=$(iw dev $IFACE info 2>/dev/null)
  CLAIMED=$(echo "$INFO" | grep -oP 'channel \K[0-9]+')
  CLAIMED_MHZ=$(echo "$INFO" | grep -oP 'channel [0-9]+ \(\K[0-9]+')
  TXP=$(echo "$INFO" | grep -oP 'txpower \K[0-9.]+')
  echo "  iw claims: channel ${CLAIMED:-NA} (${CLAIMED_MHZ:-NA} MHz), txpower ${TXP:-NA} dBm"

  sudo timeout $((DWELL + 3)) tcpdump -i $IFACE -w "$PCAP" -c 500 >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null

  COUNT=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  FREQS=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null \
            | grep -oP '\b\d{4} MHz' | sort | uniq -c | sort -rn \
            | awk '{printf "%s(%sx) ", $2, $1}')
  echo "  captured: ${COUNT:-0} frames"
  echo "  radiotap freqs seen: ${FREQS:-none}"
  printf '%-28s iw_claims=%-4s iw_mhz=%-6s frames=%-5s freqs_seen=%s\n' \
    "$LABEL" "${CLAIMED:-NA}" "${CLAIMED_MHZ:-NA}" "${COUNT:-0}" "${FREQS:-none}" >> "$OUT/summary.txt"
}

: > "$OUT/summary.txt"

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
echo "grabbers remaining (want none): $(ps -eo comm | grep -E 'wpa_supplicant|NetworkManager|dhcpcd|iwd' | tr '\n' ' ')"
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up

echo ""
echo "=== PHASE A: monitor mode, NO channel set (replicates monitor-test.sh) ==="
capture "A_no_channel_set"

echo ""
echo "=== PHASE B: same session, now explicitly set channel 36 ==="
sudo iw dev $IFACE set channel 36 2>&1 | sed 's/^/  set: /'
capture "B_after_set_ch36"

echo ""
echo "=== PHASE C: re-enter monitor mode fresh, no channel set ==="
sudo ip link set $IFACE down
sudo iw dev $IFACE set type managed
sudo ip link set $IFACE up
sleep 2
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up
capture "C_fresh_no_channel_set"

echo ""
echo "=========== SUMMARY ==========="
cat "$OUT/summary.txt"
echo "==============================="
echo ""
echo "Interpretation:"
echo "  A>0 and B=0            -> set-channel kills RX. That is the bug."
echo "  A=0 and C=0            -> monitor RX is dead regardless; set-channel is innocent."
echo "  A>0, B=0, C>0          -> confirms it, and confirms re-init recovers."
