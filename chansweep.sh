#!/bin/bash
# Channel sweep: does the radio actually tune where we ask it to?
#
# Answers the 2026-07-25 open question in NOTES.md - `iw set channel 149` reports
# 149 but captured frames arrived tagged 5180 MHz (ch 36). For each channel we
# record BOTH what iw claims and what radiotap says arriving frames were on.
#
# Channel 36 is included deliberately as a POSITIVE CONTROL: the local AP lives
# there, so if monitor RX is healthy we must see traffic on 36. Silence on 36
# means the RX path is broken; silence only on 149 just means nothing is on 149.
#
# SAFETY: networking is restored by (a) a bash trap on EXIT/INT/TERM and (b) an
# independent detached watchdog that fires even if this script is kill -9'd or
# hangs. Losing wifi should not be possible.
set -u

IFACE=wlp2s0
CHANS="36 44 149 6"
DWELL=8                 # seconds of capture per channel
WATCHDOG_TIMEOUT=180    # hard ceiling; watchdog restores regardless after this
OUT=/mnt/shared/owl-chansweep-$(date +%Y%m%d-%H%M%S)

# --- preflight ---
KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97. Monitor RX dies silently on 6.18."; exit 1 ;;
esac
command -v tcpdump >/dev/null || { echo "REFUSING: no tcpdump"; exit 1; }
mkdir -p "$OUT" || exit 1
sudo -v || exit 1   # cache creds now so no restore path ever prompts

# The restore sequence, as a single string both the trap and the detached
# watchdog run. Every step is || true: a partial failure must not abort the rest.
RESTORE_CMDS='
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'

# --- (b) detached watchdog: survives kill -9 of this script ---
# setsid detaches it from our process group so it is not taken down with us.
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

# --- (a) trap: the normal, immediate restore path ---
restore() {
  echo "--- restoring networking ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  # only now disarm the watchdog, so it stays armed if we die before this point
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

# --- take the card ---
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sleep 1
echo "regdomain now: $(iw reg get 2>/dev/null | grep -m1 '^country')"
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

for CH in $CHANS; do
  echo ""
  echo "=== requesting channel $CH ==="
  sudo iw dev $IFACE set channel $CH 2>&1 | sed 's/^/  set: /'
  # force txpower up - the 3 dBm reading is not regulatory and must be ruled out
  sudo iw dev $IFACE set txpower fixed 2000 2>/dev/null

  # what does the driver claim?
  INFO=$(iw dev $IFACE info 2>/dev/null)
  CLAIMED=$(echo "$INFO" | grep -oP 'channel \K[0-9]+')
  CLAIMED_MHZ=$(echo "$INFO" | grep -oP 'channel [0-9]+ \(\K[0-9]+')
  TXP=$(echo "$INFO" | grep -oP 'txpower \K[0-9.]+')
  echo "  iw claims: channel ${CLAIMED:-NA} (${CLAIMED_MHZ:-NA} MHz), txpower ${TXP:-NA} dBm"

  # what actually arrives?
  PCAP="$OUT/ch${CH}.pcap"
  sudo timeout $((DWELL + 3)) tcpdump -i $IFACE -w "$PCAP" -c 400 >/dev/null 2>&1 &
  TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null

  COUNT=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  # radiotap frequency of the frames we actually received
  FREQS=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null \
            | grep -oP '\b\d{4} MHz' | sort | uniq -c | sort -rn \
            | awk '{printf "%s(%sx) ", $2, $1}')
  echo "  captured: ${COUNT:-0} frames"
  echo "  radiotap freqs seen: ${FREQS:-none}"

  printf 'req_ch=%-4s iw_claims=%-4s iw_mhz=%-6s txpower=%-6s frames=%-5s freqs_seen=%s\n' \
    "$CH" "${CLAIMED:-NA}" "${CLAIMED_MHZ:-NA}" "${TXP:-NA}" "${COUNT:-0}" "${FREQS:-none}" \
    >> "$SUMMARY"
done

echo ""
echo "=========== SUMMARY ==========="
cat "$SUMMARY"
echo "==============================="
echo ""
echo "Read it like this:"
echo "  ch36 frames=0        -> monitor RX itself is broken (positive control failed)"
echo "  iw_mhz tracks req_ch -> channel setting works; 07-25 finding was mislabelling or stale frames"
echo "  freqs_seen != iw_mhz -> radio is tuned elsewhere than claimed: the real bug"
