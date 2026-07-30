# AWDL / OWL on MT7921 - project notes

## Status: WORKS (with one open problem)
Synced with a real Apple device. Peer discovery, channel-sequence parsing,
and master election all confirmed on an MT7921 Filogic 330. Reproducible.

## CRITICAL: kernel pin
- Kernel 6.18 has a broken mt76 monitor-mode RX path. Card injects (TX) fine
  but captures ZERO frames in monitor mode. TX power also stuck at 3 dBm.
- Kernel 6.12.97 works. Monitor RX confirmed (beacons flood in).
- GRUB pinned to 6.12.97 via saved_entry. DO NOT let it boot 6.18 or monitor
  RX silently dies and everything looks broken again.
- If it ever "randomly breaks after reboot": check `uname -r`. If 6.18, that's why.

## Build
- Repo: seemoo-lab/owl at ~/owl (copied off /mnt/shared - NTFS strips exec bit)
- Builds clean on GCC 14, no source changes. Deps: libev, libnl3, libpcap.
- Build: cmake -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -S . -B build
         cmake --build build --target owl
- Binary: ~/owl/build/daemon/owl

## Run (kills internet on the card while running)
    sudo sv down NetworkManager
    sudo pkill -x wpa_supplicant; sudo pkill -x dhcpcd; sleep 1
    sudo iw reg set NZ
    sudo ip link set wlp2s0 down
    sudo ./owl -i wlp2s0 -c 149 -v      # -c 44 or 149 for 5GHz (Mac lives there)
Restore:
    sudo ip link set wlp2s0 down; sudo iw dev wlp2s0 set type managed
    sudo ip link set wlp2s0 up; sudo sv up NetworkManager

## Discovery notes
- Lone OWL node sits STATIC on its master channel (chanseq_init_static, all
  16 slots = master chan). Default master = ch6 (2.4GHz).
- Local environment is all 5GHz. Must run -c 44 or -c 149 to hear the Mac.
- Mac's advertised sequence seen: 149,149,149,149,149,149,36,36,6,149,149,149,149,149,36,36

## OPEN PROBLEM (next session)
- Peer is discovered and added, then DROPPED after ~4 seconds.
- Cause: OWL stays static on one channel while the Mac hops its full sequence
  (149/36/6). OWL misses the availability windows on 36 and 6, can't maintain
  the link, peer ages out.
- FIX: make OWL adopt and FOLLOW the discovered peer's channel sequence instead
  of sitting static. Lives in awdl_switch_channel() in daemon/core.c (~line 279).
  The switch loop already reads channel.sequence[slot] - needs the sequence to
  become the peer's, and the hop timing tight enough that the offload chip keeps
  up. Whether mt7921 firmware latency allows tight-enough hopping is THE research
  question.

## Transfer reality check (further out)
- iPhone on iOS 26.5 => AirDrop-code handshake for non-contacts. OpenDrop can't
  do it. Contacts auth needs a real Apple ID Validation Record (VLD) from a
  device signed into YOUR Apple ID. Can't forge - it's Apple-key-signed.
- Sync (link layer, done) is separate from transfer (auth, hard/maybe-blocked).
- The SYNC result alone is novel and worth writing up regardless of transfer.

## 2026-07-30: kernel pin was never actually durable, fixed properly
- Machine was running 6.18.33_1 despite this doc saying pinned to 6.12.97.
  First attempt (`grub-editenv ... set saved_entry=...6.12.97...`) did NOT
  survive a reboot - after rebooting, `uname -r` was still 6.18.33_1 and
  `saved_entry` had reverted to `gnulinux-simple-...`.
- Root cause: `/etc/default/grub` had `GRUB_DEFAULT=saved` +
  `GRUB_SAVEDEFAULT=true`. That combo re-saves whatever kernel actually
  booted as the new default every boot. The 6.12.97 entry lives inside the
  "Advanced options" submenu; GRUB apparently didn't resolve the saved
  submenu entry at boot time, fell through to the top-level `simple` entry
  (tracks newest installed kernel = 6.18.x), booted that, then re-saved
  `simple` - silently undoing the pin every single time.
- Real fix: hard-set the default in `/etc/default/grub` instead of relying
  on grubenv:
  `GRUB_DEFAULT="gnulinux-6.12.97_1-advanced-2e859942-2a74-4cf8-81d2-1db8a58693e6"`,
  `GRUB_SAVEDEFAULT=false`, then `sudo grub-mkconfig -o /boot/grub/grub.cfg`.
  Confirmed the regenerated grub.cfg now has a literal
  `set default="gnulinux-6.12.97_1-advanced-..."` fallback, not `saved`.
  Backup of the old config: `/etc/default/grub.bak-20260730`.
- Needs an actual reboot onto 6.12.97 before any further OWL testing - monitor
  RX is silently dead on 6.18, see FINDINGS.md §2. If it ever regresses again,
  suspect a `grub-mkconfig` re-run (e.g. from a kernel package update)
  clobbering `/etc/default/grub` back to `GRUB_DEFAULT=saved` - check that
  file first, not just the running kernel.
- The one existing hoptest run (`/mnt/shared/owl-hoptest-20260725-230110/`)
  has ZERO peer/election events in owl.log - consistent with the channel
  mismatch bug below, not a failure of the follow-sequence fix (9bac866).
  That fix has still never been validated against a real device.

## 2026-07-25: radio channel does not match requested channel
- `iw dev wlp2s0 set channel 149` -> `iw info` reports 149, but every frame
  captured arrives tagged 5180 MHz (= channel 36). Plain iw, not OWL's netlink
  path, so this is below OWL entirely.
- Explains 60s OWL run with 1618 outbound lines and ZERO received frames:
  pcap filter is AWDL BSSID only, Mac advertises on 149, radio was on 36.
- Monitor RX itself is fine (22 pkts, 0 dropped) on 6.12.97.
- txpower read 3.00 dBm on 6.12.97 - FINDINGS §2 lists this as a 6.18 symptom.
  Run did not force `txpower fixed 2000`. §2 claim needs qualifying or dropping.
- UNRESOLVED: is the radio actually on 36, or is mt76 mislabelling the radiotap
  frequency field? Sweep 36/44/149 and see whether reported freq tracks. That
  test is written up in the chat log, run it first thing.

## 2026-07-30: kernel pin fix attempt #2 - GRUB doesn't recurse into submenus for default=<id>
- Attempt #1 (hardcode GRUB_DEFAULT to the entry ID, disable GRUB_SAVEDEFAULT)
  still didn't work - had to manually enter "Advanced options" and pick
  6.12.97 by hand after reboot.
- Real root cause: the 6.12.97 entry lives inside the "Advanced options"
  submenu, and GRUB's `default="<id>"` resolution only searches the
  TOP-LEVEL menu list, not recursively into submenus. So the hardcoded ID
  from attempt #1 never matched anything at boot and GRUB silently fell
  back to the first top-level entry (`simple`, tracks newest kernel).
- Fix: `GRUB_DISABLE_SUBMENU=true` in /etc/default/grub, then
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`. This flattens every kernel
  into its own top-level `menuentry` (no more "Advanced options" submenu),
  so the same `gnulinux-6.12.97_1-advanced-...` ID is now directly
  reachable by GRUB's default matching. Verified in the regenerated
  grub.cfg: `set default="gnulinux-6.12.97_1-advanced-..."` and that same
  ID now appears as a top-level `menuentry`, not nested under a submenu.
- Not yet confirmed by an actual unattended reboot - do that next and check
  `uname -r` without touching the keyboard at boot.

## 2026-07-30: monitor RX is dead on the MT7921 - the real blocker
Tried to reproduce the sync against an iPhone (AirDrop sheet open = AWDL
advertising). 1587 log lines, all TX, zero RX. Chased it down; full writeup in
FINDINGS.md §8. Short version:

- Radio DOES tune correctly. chansweep.sh: iw_mhz tracks the requested channel
  exactly on 36/44/149/6. The 07-25 "radio is on 36 while claiming 149" theory
  is dead - that was never the bug.
- `iw set channel` is NOT the culprit. rxtest.sh A/B: zero frames with a channel
  set, without one, and after re-entering monitor mode fresh.
- Frames never leave the chip. rxcounters.sh: netdev rx_packets delta = 0 over
  10s parked on ch2 where the AP was actively serving. Not a pcap/BPF issue.
- Positive control FAILED: zero frames on the AP's own channel, and on 2.4GHz.
  So it is not "nothing was on 149".
- Probable cause: `iw phy phy0 info` lists monitor under supported modes but
  monitor appears in NO valid interface combination. Monitor mode is nominal,
  not functional: set monitor succeeds, netdev enters promiscuous mode, no
  firmware error is logged, nothing is ever delivered.
- Ruled out: kernel (pin verified 6.12.97_1), firmware (pkg from 2026-05-21,
  predates the working result), suspend wedge (fresh boot), regulatory (zero on
  2.4GHz too), userspace grabbers (all confirmed dead).
- FINDINGS §2's "txpower stuck at 3 dBm" is RETRACTED - it reads 3.00 dBm in
  managed mode too while passing traffic fine. Cosmetic mt76 quirk, ignore it.

So sync-log.txt is real but is NOT reproducible today and we do not yet know why
it once worked. 9bac866 still cannot be validated - that needs received frames.

### Next, in order of promise
1. Plug in the AR9271 USB adapter and run OWL on that. ath9k_htc monitor +
   injection actually works. Costs the "can a fully-offloaded chip hop fast
   enough" angle but unblocks validating 9bac866 today. (Not plugged in during
   these tests - lsusb showed only the Foxconn BT device.)
2. Try 6.12.90_1 or 6.12.11_1 (both still installed). Worth considering the
   kernel that worked on 07-25 was one of these and got written down as 6.12.97
   from memory late in a long session. One reboot each to test.
3. Dig at mt7921 monitor support: does a separately-added vif
   (`iw phy phy0 interface add mon0 type monitor`) behave differently from an
   in-place type change? Check mt76 upstream for monitor fixes.

### Test harness safety
chansweep.sh / rxtest.sh / rxcounters.sh all use a bash trap PLUS a
setsid-detached watchdog that restores networking even if the script is kill -9'd
or hangs (a trap cannot survive SIGKILL). Watchdog was verified to fire after a
hard kill before being relied on. Do not add a test here without that pattern -
an earlier ad-hoc monitor-mode command with no trap did drop wifi.
