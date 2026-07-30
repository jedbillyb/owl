#!/bin/bash
# Can an active monitor vif be made to sit on a channel other than 5180 MHz?
#
# Every active-monitor attempt so far (activetest.sh, activetest2.sh, awdltest.sh,
# airdrop.sh) created the vif with `flags active` AT CREATION and then tried to
# tune it - and it stayed pinned at 5180 forever. FINDINGS 10-12 concluded from
# that "active monitor cannot retune at all". But the ORDER was never varied.
#
# If the firmware only refuses a retune *while* active mode is on, then tuning
# first and enabling active afterwards should leave the radio where we put it.
# That single ordering is the difference between "AirDrop is a dead end on this
# chip" and "AirDrop is reachable": OWL needs active mode for unicast ACKs
# (daemon/netutils.c:225) AND needs to follow the phone's channel sequence.
# Right now we can have either, not both.
#
# Four orderings, all on the same target frequency, all verified by the radiotap
# frequency of the frames actually captured - `iw` lies about the channel on this
# chip (METHODOLOGY RULE, FINDINGS 12).
#
#   A plain, up, set freq                       baseline: known to tune
#   B flags active at create, up, set freq      known bad: pins at 5180
#   C plain, up, set freq, THEN set monitor active   <- the untested ordering
#   D flags active at create, set freq DOWN, then up <- tune before the link is up
#
# Target is the busiest 2.4 GHz channel found by a scan, for two reasons: there
# is guaranteed traffic there so the radiotap frequency is always observable,
# and it can never be confused with 5180 (the stuck value).
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE=wlp2s0
MON=mon0
DWELL=15
WATCHDOG_TIMEOUT=420
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
STUCK_MHZ=5180
OUT=/mnt/shared/owl-activelate-$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
echo "kernel: $(uname -r)"

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
  echo "restored. logs in $OUT"
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

# --- pick the busiest 2.4 GHz channel while the card is still managed ---------
echo "scanning for the busiest 2.4 GHz channel..."
sudo ip link set $IFACE up 2>/dev/null
MHZ=$(sudo iw dev $IFACE scan 2>/dev/null | grep -oP '(?<=^\tfreq: )2\d{3}' \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
MHZ=${MHZ:-2437}
echo "target frequency: $MHZ MHz"

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

# NOTE: there is no way to read a monitor vif's flags back - `iw dev X info`
# prints type/wiphy/addr and nothing else, even for a vif created with
# `flags active`. So ACT below is not a readback: it records whether the kernel
# ACCEPTED the request to enter active mode (exit status of the command that
# asked for it). That is the only observable, and it is sufficient here.
#
# $1 = label, $2 = ordering (a|b|c|d)  -> sets ALL_N, DOM, STUCK_N, IW_SAYS, ACT
probe() {
  local LABEL="$1" KIND="$2" PCAP="$OUT/$1.pcap" RC
  ACT=n/a
  sudo ip link set $MON down 2>/dev/null
  sudo iw dev $MON del 2>/dev/null
  sudo ip link set $IFACE down
  sleep 1

  case "$KIND" in
    a|c) sudo iw phy phy0 interface add $MON type monitor 2>"$OUT/$1.err"; RC=$? ;;
    b|d) sudo iw phy phy0 interface add $MON type monitor flags active 2>"$OUT/$1.err"; RC=$?
         [ "$RC" = "0" ] && ACT=yes ;;
  esac
  [ "$RC" != "0" ] && { echo "  CREATE FAILED: $(cat "$OUT/$1.err")"; ALL_N=0; DOM=none; STUCK_N=0; IW_SAYS=none; ACT=no; return; }

  if [ "$KIND" = "d" ]; then
    # tune while the link is still down, then bring it up and never touch freq again
    sudo iw dev $MON set freq $MHZ 2>"$OUT/$1.freq.err"
    sudo ip link set $MON up
  else
    sudo ip link set $MON up
  fi

  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"

  [ "$KIND" != "d" ] && sudo iw dev $MON set freq $MHZ 2>"$OUT/$1.freq.err"

  if [ "$KIND" = "c" ]; then
    # THE test: already tuned and up, now switch this vif into active mode.
    # Try in place first; if the kernel insists the link be down, cycle it but
    # do NOT re-tune afterwards - keeping the channel across the switch is
    # exactly what is being measured.
    if sudo iw dev $MON set monitor active 2>"$OUT/$1.active.err"; then
      ACT=yes
    else
      echo "  (in-place switch refused: $(cat "$OUT/$1.active.err") - retrying with link down)"
      sudo ip link set $MON down
      if sudo iw dev $MON set monitor active 2>>"$OUT/$1.active.err"; then
        ACT=yes
      else
        ACT=no; echo "  ACTIVE SWITCH FAILED"
      fi
      sudo ip link set $MON up
    fi
  fi

  sleep 2
  IW_SAYS=$(sudo iw dev $MON info 2>/dev/null | grep -oP '(?<=channel )\d+ \(\K\d+' | head -1)

  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 4)) tcpdump -i $MON -w "$PCAP" >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null

  ALL_N=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  STUCK_N=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -c "$STUCK_MHZ MHz")
  printf '  iw_says=%-6s active_accepted=%-4s actual_freq=%-6s frames=%-6s at_5180=%s\n' \
         "${IW_SAYS:-none}" "$ACT" "${DOM:-none}" "${ALL_N:-0}" "${STUCK_N:-0}"
}

echo ""
echo "=== A: plain monitor, tuned after up (baseline) ==="
probe "A_plain"            a; A_DOM=$DOM; A_ALL=$ALL_N; A_ACT=$ACT
echo ""
echo "=== B: created with flags active, tuned after up (known bad) ==="
probe "B_active_at_create" b; B_DOM=$DOM; B_ALL=$ALL_N; B_ACT=$ACT
echo ""
echo "=== C: plain + tuned, THEN switched to active  <-- the new ordering ==="
probe "C_active_late"      c; C_DOM=$DOM; C_ALL=$ALL_N; C_ACT=$ACT
echo ""
echo "=== D: created with flags active, tuned while link DOWN ==="
probe "D_active_downtune"  d; D_DOM=$DOM; D_ALL=$ALL_N; D_ACT=$ACT

echo ""
echo "=========== RESULT (target $MHZ MHz) ==========="
printf '  A plain            : freq=%-6s frames=%-6s active_accepted=%s\n' "${A_DOM:-none}" "$A_ALL" "$A_ACT"
printf '  B active-at-create : freq=%-6s frames=%-6s active_accepted=%s\n' "${B_DOM:-none}" "$B_ALL" "$B_ACT"
printf '  C active-late      : freq=%-6s frames=%-6s active_accepted=%s\n' "${C_DOM:-none}" "$C_ALL" "$C_ACT"
printf '  D active-downtune  : freq=%-6s frames=%-6s active_accepted=%s\n' "${D_DOM:-none}" "$D_ALL" "$D_ACT"
echo ""
if [ "${A_DOM:-x}" != "$MHZ" ]; then
  echo "  VOID: even plain monitor did not land on $MHZ (got ${A_DOM:-nothing})."
  echo "  Something is wrong with the run itself; the other phases mean nothing."
else
  for P in C D; do
    eval "D_F=\$${P}_DOM; D_A=\$${P}_ACT; D_N=\$${P}_ALL"
    if [ "$D_A" != "yes" ]; then
      echo "  $P: the kernel refused the request to enter active mode - ordering unusable."
    elif [ "${D_F:-x}" = "$MHZ" ]; then
      echo "  *** $P: ACTIVE MONITOR ON $MHZ MHz ($D_N frames) ***"
      echo "  Active mode and an arbitrary channel are NOT mutually exclusive."
      echo "  This is the ordering airdrop.sh must use; AirDrop is back on the table."
    elif [ "${D_F:-x}" = "$STUCK_MHZ" ]; then
      echo "  $P: still pinned at $STUCK_MHZ - ordering makes no difference."
    else
      echo "  $P: no usable frames (${D_N}); inconclusive, not a pass."
    fi
  done
fi
echo "==============================================="
