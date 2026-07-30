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
MON=mon0
AWDL=awdl0
CHAN=149
CHAN_MHZ=5745
PEER_WAIT=45          # how long to wait for an AWDL peer before giving up
FIND_TIME=25          # how long to let opendrop scan
WATCHDOG_TIMEOUT=420
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OWL=/home/jed/owl/build/daemon/owl
VENV=/home/jed/owl/.venv-opendrop/bin/opendrop
OUT=/mnt/shared/owl-airdrop-$(date +%Y%m%d-%H%M%S)

KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97."; exit 1 ;;
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

restore() {
  echo ""
  echo "--- restoring ---"
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

# ---------- layer 1: AWDL link ----------
echo ""
echo "### layer 1: AWDL link on $MON"
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $MON del 2>/dev/null
sudo iw phy phy0 interface add $MON type monitor || { echo "FAILED to create $MON"; exit 1; }
sudo ip link set $MON up
sudo sh -c "echo 0 > $MT76/runtime-pm"
sudo sh -c "echo 0 > $MT76/deep-sleep"
sudo iw dev $MON set freq $CHAN_MHZ
sleep 2
echo "  PM off, $MON on $(iw dev $MON info 2>/dev/null | grep -oP 'channel \K[0-9]+')"

# -N because mon0 is already a monitor vif and up; OWL's own set-monitor-mode
# would fail with EBUSY. We did that setup ourselves above.
sudo stdbuf -oL "$OWL" -i $MON -c $CHAN -N -vv > "$OUT/owl.log" 2>&1 &
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
  echo "  Reopen the AirDrop sheet on the phone and try again."
  exit 1
fi
echo "  peer found:"
grep -E "add peer|changed channel sequence" "$OUT/owl.log" | tail -3 | sed 's/.*[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //' | sed 's/^/    /'
echo "  IPv6 neighbours on $AWDL:"
ip -6 neigh show dev $AWDL | sed 's/^/    /' || echo "    (none yet)"

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
