#!/bin/bash
# Does `flags active` on the monitor vif kill RX on mt7921?
#
# Suspicion: the run immediately before adding `flags active` saw 48 AWDL frames
# on ch6; the first run WITH it saw 0 frames on all four channels. That is the
# only thing that changed, so test it directly instead of blaming the phone.
#
# Parked on channel 3 (2422 MHz) where the local AP actually is, so traffic is
# guaranteed to exist and "0 frames" cannot be explained by a quiet channel.
# Counts ALL frames, not just AWDL - this is a question about the RX path.
#
#   A: mon0 created plain           (expect frames)
#   B: mon0 created flags active    (if 0, active monitor breaks RX)
#   C: mon0 plain again             (proves it is causal, not drift)
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE=wlp2s0
MON=mon0
MHZ=2422
DWELL=8
WATCHDOG_TIMEOUT=200
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OUT=/mnt/shared/owl-activetest-$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

RESTORE_CMDS='
  sudo ip link set '"$MON"' down 2>/dev/null || true
  sudo iw dev '"$MON"' del 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return 0
  RESTORED=1
  echo ""; echo "--- restoring ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored."
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

# $1 = label, $2 = "plain" | "active"
probe() {
  local LABEL="$1" KIND="$2" PCAP="$OUT/$1.pcap" RC N
  sudo ip link set $MON down 2>/dev/null
  sudo iw dev $MON del 2>/dev/null
  sudo ip link set $IFACE down
  if [ "$KIND" = "active" ]; then
    sudo iw phy phy0 interface add $MON type monitor flags active 2>"$OUT/$1.err"; RC=$?
  else
    sudo iw phy phy0 interface add $MON type monitor 2>"$OUT/$1.err"; RC=$?
  fi
  if [ "$RC" != "0" ]; then
    echo "  create FAILED (rc=$RC): $(cat "$OUT/$1.err")"
    printf '%-22s CREATE FAILED\n' "$LABEL" >> "$OUT/summary.txt"
    return
  fi
  sudo ip link set $MON up
  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"
  sudo iw dev $MON set freq $MHZ 2>/dev/null
  sleep 2
  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 3)) tcpdump -i $MON -w "$PCAP" -c 2000 >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null
  N=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  echo "  frames: ${N:-0}"
  printf '%-22s frames=%s\n' "$LABEL" "${N:-0}" >> "$OUT/summary.txt"
}

: > "$OUT/summary.txt"
echo "=== A: mon0 plain (no flags) ==="   ; probe "A_plain"       plain
echo "=== B: mon0 flags active ==="       ; probe "B_flags_active" active
echo "=== C: mon0 plain again ==="        ; probe "C_plain_again"  plain

echo ""
echo "=========== SUMMARY (channel 3 / 2422 MHz, AP is here) ==========="
cat "$OUT/summary.txt"
echo "=================================================================="
echo ""
echo "  A>0, B=0, C>0 -> 'flags active' kills RX on mt7921. Cannot have both"
echo "                   ACKs and reception; the one-way path is unavoidable"
echo "                   on this chip and AirDrop is not reachable this way."
echo "  A>0, B>0      -> active monitor is fine; the earlier zero-frame run was"
echo "                   the phone being silent, not my change."
