#!/bin/bash
# Bring up the full AirDrop stack on the built-in MT7921 and try to talk to an
# Apple device.
#
#   ./airdrop.sh                 # discover only (opendrop find)
#   ./airdrop.sh receive         # advertise this box as an AirDrop target
#   ./airdrop.sh send <file>     # discover, then try to send <file>
#
# Layers, and where each one comes from:
#   1. AWDL link sync         - OWL on a dedicated mon0 vif with PM off
#   2. awdl0 + IPv6 link-local - OWL creates this automatically
#   3. mDNS _airdrop._tcp      - OpenDrop (in .venv-opendrop)
#   4. AirDrop auth + HTTPS    - OpenDrop; EXPECTED TO BE THE BLOCKER, see below
#
# ON THE PHONE, before running:
#   - Settings > General > AirDrop > "Everyone for 10 Minutes".
#     This is the mode that historically needed no Apple-signed validation
#     record. Contacts-only will almost certainly fail.
#   - Open the AirDrop/share sheet and LEAVE IT OPEN so AWDL keeps advertising.
#
# HONEST EXPECTATION: layers 1-3 should work. Layer 4 may well fail - on current
# iOS, AirDrop to a non-contact wants the AirDrop-code handshake, which OpenDrop
# does not implement, and the contacts path needs an Apple-key-signed Validation
# Record that cannot be forged. See FINDINGS.md section 7. Discovery succeeding
# but transfer failing is the expected outcome, not a bug in this script.
#
# NOTE: this takes the Wi-Fi card exclusively - no internet while it runs.
#
# SAFETY: bash trap + setsid-detached watchdog restores networking even on
# kill -9 or hang.
set -u

MODE="${1:-find}"
SENDFILE="${2:-}"

IFACE=wlp2s0
MON=mon0              # plain vif: owns and steers the channel
MONA=mon1             # active vif (ACTIVE=1 only): ACKs, rides mon0's channel
AWDL=awdl0
# Channel. Default 36: an iPhone was observed on 2026-07-30 advertising
# 36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36 - six slots on 36 against two on
# 149, so 149 is its MINORITY channel and sitting there misses most of its
# availability windows. Override with e.g. CHAN=149 ./airdrop.sh
CHAN="${CHAN:-36}"
case "$CHAN" in
  6)   CHAN_MHZ=2437 ;;
  36)  CHAN_MHZ=5180 ;;
  44)  CHAN_MHZ=5220 ;;
  149) CHAN_MHZ=5745 ;;
  *)   echo "REFUSING: CHAN must be 6, 36, 44 or 149 (got $CHAN)"; exit 1 ;;
esac
PEER_WAIT=45          # how long to wait for an AWDL peer before giving up
FIND_TIME=25          # how long to let opendrop scan
WATCHDOG_TIMEOUT=420
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OWL=/home/jed/owl/build/daemon/owl
VENV=/home/jed/owl/.venv-opendrop/bin/opendrop
OUT=/mnt/shared/owl-airdrop-$(date +%Y%m%d-%H%M%S)

# The "6.12.97 is required" rule is RELAXED as of 2026-07-30. That belief came
# from a 6.18-vs-6.12.97 comparison that we now know was confounded by the
# runtime-PM bug (FINDINGS.md §8) - the kernel may never have been the variable.
# Warn, do not refuse, so other kernels can actually be tested.
KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - known-good" ;;
  *) echo "kernel $KREL - NOT the pinned 6.12.97. Continuing anyway;"
     echo "  if RX misbehaves, boot 6.12.97 before concluding anything." ;;
esac
[ -x "$OWL" ]  || { echo "REFUSING: no OWL binary at $OWL"; exit 1; }
[ -x "$VENV" ] || { echo "REFUSING: no opendrop at $VENV"; exit 1; }
if [ "$MODE" = "send" ]; then
  [ -n "$SENDFILE" ] || { echo "REFUSING: send needs a file: ./airdrop.sh send <file>"; exit 1; }
  [ -f "$SENDFILE" ] || { echo "REFUSING: no such file: $SENDFILE"; exit 1; }
fi
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

RESTORE_CMDS='
  sudo pkill -x owl 2>/dev/null || true
  sudo ip link set '"$MONA"' down 2>/dev/null || true
  sudo iw dev '"$MONA"' del 2>/dev/null || true
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
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return 0
  RESTORED=1
  echo ""
  echo "--- restoring ---"
  [ -n "${POLL_PID:-}" ] && kill "$POLL_PID" 2>/dev/null
  if [ -f "$OUT/radio.log" ]; then
    echo "  channels the radio actually visited:"
    awk '{print $2}' "$OUT/radio.log" | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
  fi
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
# INT/TERM must restore AND exit. With a bare `trap restore EXIT INT TERM`, a
# Ctrl-C during the opendrop pipeline ran restore (tearing the card down) and
# then let the rest of the script run on regardless - which is exactly what
# happened on the first real run.
trap 'restore; exit 130' INT TERM
trap restore EXIT

# ---------- layer 1: AWDL link ----------
echo ""
echo "### layer 1: AWDL link on $MON"
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $MONA del 2>/dev/null
sudo iw dev $MON del 2>/dev/null
# Monitor vif setup. THE PAIR (activelate2.sh/activelate3.sh, 2026-07-31).
#
# A vif created with `flags active` on its own is stuck at 5180 MHz forever, by
# every ordering tried - see FINDINGS §13/§14. But an active vif created
# ALONGSIDE a plain vif that already owns the channel comes up on that channel,
# at full reception, and the two share one channel context: retuning either one
# moves both. Measured, radiotap-verified, twice:
#
#   plain alone           2437 (667 frames)
#   active alongside      2437 (710)   <- no RX penalty
#   retune plain -> 2412  active follows to 2412, and back again
#   retune ACTIVE -> 2412 works too, so OWL can steer its own interface
#
# So `flags active` never cost us reception; being dumped on an empty 5180 did.
# That removes both obstacles at once: ACKs for unicast AWDL data AND the
# channel hopping needed to follow the peer's sequence.
#
#   ACTIVE=1 ./airdrop.sh        # the pair: ACKs + hopping. Use this for transfer.
#   ./airdrop.sh                 # default: plain only, hops, one-way (no ACKs)
#
# NOT YET CONFIRMED: that the firmware really does ACK in this configuration.
# Monitor flags cannot be read back (`iw dev <vif> info` prints nothing about
# them), so the only proof is layer 2.5 below reporting bidirectional IP.
if [ "${ACTIVE:-0}" = "1" ]; then
  echo "  mode: PAIR - plain $MON steers the channel, active $MONA ACKs"
else
  echo "  mode: plain monitor only (hops, but one-way - no ACKs)"
fi
sudo iw phy phy0 interface add $MON type monitor \
  || { echo "FAILED to create $MON"; exit 1; }
sudo ip link set $MON up
sudo sh -c "echo 0 > $MT76/runtime-pm"
sudo sh -c "echo 0 > $MT76/deep-sleep"
sudo iw dev $MON set freq $CHAN_MHZ
OWL_IF=$MON
if [ "${ACTIVE:-0}" = "1" ]; then
  # order matters: the plain vif must exist and be tuned FIRST
  if sudo iw phy phy0 interface add $MONA type monitor flags active 2>/dev/null \
     && sudo ip link set $MONA up 2>/dev/null; then
    OWL_IF=$MONA
    sudo sh -c "echo 0 > $MT76/runtime-pm"
    sudo sh -c "echo 0 > $MT76/deep-sleep"
    echo "  active vif $MONA up alongside $MON - OWL will run on $MONA"
  else
    echo "  WARNING: could not bring up the active vif; falling back to $MON."
    echo "  Without ACKs the path is one-way and a transfer cannot complete."
    sudo iw dev $MONA del 2>/dev/null
  fi
fi
sleep 2
echo "  PM off, $MON on $(iw dev $MON info 2>/dev/null | grep -oP 'channel \K[0-9]+') (requested $CHAN / $CHAN_MHZ MHz)"

# independent radio poller - confirms OWL really hops, without trusting its logs
( while :; do
    printf '%s %s\n' "$(date +%s.%N)" \
      "$(iw dev $MON info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo NA)"
    sleep 0.05
  done ) > "$OUT/radio.log" &
POLL_PID=$!

# ---------- layer 0: find which channel the phone is actually on ----------
# The phone's channel sequence drifts between runs (36-dominant and
# 149-dominant were both observed on 2026-07-30), and OWL sits statically on
# its master channel until it discovers a peer - so guessing wrong means never
# hearing it. Sweep first, on raw AWDL frames, before committing OWL.
# This also distinguishes "phone is silent" from "phone is elsewhere", which
# guessing cannot.
echo ""
# The sweep now runs in BOTH modes: the active vif rides mon0's channel, so
# steering mon0 steers the pair. Nothing has to be forced to ch36 any more.
echo "### layer 0: locating the phone (AWDL BSSID 00:25:00:ff:94:73)"
AWDL_BSSID="00:25:00:ff:94:73"
BEST_CHAN=""; BEST_N=0; SAW_ANY=0
for c in 36 149 44 6; do
  case "$c" in 6) mhz=2437 ;; 36) mhz=5180 ;; 44) mhz=5220 ;; 149) mhz=5745 ;; esac
  sudo iw dev $MON set freq $mhz 2>/dev/null
  sleep 1
  sudo rm -f "$OUT/scan-$c.pcap"
  sudo timeout 7 tcpdump -i $MON -w "$OUT/scan-$c.pcap" -c 300 \
       "wlan addr3 $AWDL_BSSID" >/dev/null 2>&1 &
  sleep 5
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  n=$(sudo tcpdump -r "$OUT/scan-$c.pcap" 2>/dev/null | wc -l)
  n=${n:-0}
  printf '  ch %-4s AWDL frames: %s\n' "$c" "$n"
  [ "$n" -gt 0 ] && SAW_ANY=1
  if [ "$n" -gt "$BEST_N" ]; then BEST_N=$n; BEST_CHAN=$c; fi
done

if [ "$SAW_ANY" = "0" ]; then
  echo ""
  echo "  No AWDL frames on ANY channel. The phone is not advertising."
  echo "  This is not a Linux-side problem - nothing to sync with."
  echo "  On the phone, immediately before re-running:"
  echo "    1. unlock it and keep the screen ON"
  echo "    2. Settings > General > AirDrop > 'Everyone for 10 Minutes'"
  echo "       (this EXPIRES - re-arm it each time)"
  echo "    3. open the share sheet and leave it open"
  exit 1
fi

echo "  --> strongest on channel $BEST_CHAN ($BEST_N frames); using it"
CHAN=$BEST_CHAN
case "$CHAN" in 6) CHAN_MHZ=2437 ;; 36) CHAN_MHZ=5180 ;; 44) CHAN_MHZ=5220 ;; 149) CHAN_MHZ=5745 ;; esac
sudo iw dev $MON set freq $CHAN_MHZ 2>/dev/null
sleep 1

# -N because the vif is already a monitor and up; OWL's own set-monitor-mode
# would fail with EBUSY. We did that setup ourselves above. In ACTIVE mode
# OWL_IF is the active vif, so OWL's frames go out on the vif that ACKs.
sudo stdbuf -oL "$OWL" -i $OWL_IF -c $CHAN -N -vv > "$OUT/owl.log" 2>&1 &
sleep 4

if ! grep -q "Host device" "$OUT/owl.log"; then
  echo "  OWL failed to start:"
  grep -iE "error|unable" "$OUT/owl.log" | head -5 | sed 's/^/    /'
  exit 1
fi
echo "  OWL up. $(grep -m1 'Host device' "$OUT/owl.log" | sed 's/.*INFO *: *//')"

# ---------- layer 2: awdl0 ----------
echo ""
echo "### layer 2: $AWDL interface"
for i in $(seq 10); do ip link show $AWDL >/dev/null 2>&1 && break; sleep 1; done
if ! ip link show $AWDL >/dev/null 2>&1; then
  echo "  $AWDL never appeared - cannot continue"; exit 1
fi
sudo ip link set $AWDL up 2>/dev/null
ip -6 addr show $AWDL | grep -E "inet6|state" | sed 's/^/  /'

# ---------- wait for an AWDL peer ----------
echo ""
echo "### waiting up to ${PEER_WAIT}s for an AWDL peer ..."
echo "    (AirDrop sheet must be OPEN on the phone, set to Everyone for 10 Minutes)"
FOUND=0
for i in $(seq $PEER_WAIT); do
  if grep -q "add peer" "$OUT/owl.log"; then FOUND=1; break; fi
  sleep 1
done
if [ "$FOUND" = "0" ]; then
  echo "  no AWDL peer found in ${PEER_WAIT}s."
  echo "  DESPITE $BEST_N AWDL frames present on ch $CHAN during the scan."
  echo "  So the phone IS transmitting but OWL is not adding it as a peer -"
  echo "  that points at OWL parsing/election, not the radio."
  echo "  (The sweep now runs in both modes, so this is never ambiguous.)"
  echo "  Logs: $OUT/"
  exit 1
fi
echo "  peer found:"
grep -E "add peer|changed channel sequence" "$OUT/owl.log" | tail -3 | sed 's/.*[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //' | sed 's/^/    /'
echo "  IPv6 neighbours on $AWDL:"
ip -6 neigh show dev $AWDL | sed 's/^/    /' || echo "    (none yet)"

# ---------- layer 2.5: is there actually an IP data path? ----------
# The neighbour table entry above only proves AWDL link-layer sync. It says
# nothing about whether IPv6 packets actually traverse the link. If mDNS finds
# nothing, the first thing to establish is whether ANY packet gets through.
echo ""
echo "### layer 2.5: IP reachability over $AWDL"
PEER6=$(ip -6 neigh show dev $AWDL | awk '/^fe80:/{print $1; exit}')
if [ -z "${PEER6:-}" ]; then
  echo "  no link-local peer address in the neighbour table - cannot test"
else
  echo "  peer: $PEER6"
  # capture while we ping, so we see whether replies come back at all
  sudo timeout 14 tcpdump -i $AWDL -w "$OUT/awdl0.pcap" >/dev/null 2>&1 &
  sleep 1
  echo "  ping6 (5 attempts, 8s):"
  timeout 12 ping6 -c 5 -W 2 -I $AWDL "$PEER6" 2>&1 | tail -4 | sed "s/^/    /"
  sleep 2
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  TOT=$(sudo tcpdump -r "$OUT/awdl0.pcap" 2>/dev/null | wc -l)
  FROMPEER=$(sudo tcpdump -r "$OUT/awdl0.pcap" 2>/dev/null | grep -c "$(echo $PEER6 | cut -d: -f1-4)" || true)
  MDNS=$(sudo tcpdump -r "$OUT/awdl0.pcap" 2>/dev/null | grep -ci "mdns\|5353" || true)
  echo "  packets on $AWDL: total=$TOT from_peer=$FROMPEER mdns=$MDNS"
  if [ "${TOT:-0}" = "0" ]; then
    echo "  ==> NOTHING traverses awdl0. AWDL syncs but carries no data."
    echo "      That is a data-path problem, not an AirDrop auth problem."
  elif [ "${FROMPEER:-0}" = "0" ]; then
    echo "  ==> we transmit but the phone never answers. One-way path."
  else
    echo "  ==> bidirectional IP works. Any failure past here is service/auth level."
  fi
fi

# ---------- layers 3 + 4: OpenDrop ----------
echo ""
echo "### layer 3: AirDrop service discovery over $AWDL"
timeout $FIND_TIME "$VENV" -i $AWDL find 2>&1 | tee "$OUT/find.log" | sed 's/^/  /'

if ! grep -qE "^\s*[0-9]+\)|Found" "$OUT/find.log" 2>/dev/null; then
  echo ""
  echo "  No AirDrop service discovered."
  echo "  AWDL sync works (peer was found), so this is layer 3/4: the phone is"
  echo "  not advertising _airdrop._tcp to us, or is refusing us. Check that"
  echo "  AirDrop is set to 'Everyone for 10 Minutes' and the sheet is open."
fi

if [ "$MODE" = "receive" ]; then
  echo ""
  echo "### layer 4: advertising as an AirDrop receiver (Ctrl-C to stop)"
  echo "    Now look for this machine in the AirDrop sheet on the phone and send to it."
  "$VENV" -i $AWDL receive 2>&1 | tee "$OUT/receive.log"
elif [ "$MODE" = "send" ]; then
  echo ""
  echo "### layer 4: attempting to send $SENDFILE to receiver index 0"
  echo "    This is the step that is expected to fail on modern iOS - see the"
  echo "    header of this script and FINDINGS.md section 7."
  "$VENV" -i $AWDL send -r 0 -f "$SENDFILE" 2>&1 | tee "$OUT/send.log"
else
  echo ""
  echo "### discovery-only mode. Re-run with:"
  echo "      ./airdrop.sh receive          - advertise, then send FROM the phone"
  echo "      ./airdrop.sh send <file>      - try to send TO the phone"
  echo ""
  echo "    'receive' is the better bet: sending from the phone to Linux is the"
  echo "    direction that has historically been less gated by auth."
fi
