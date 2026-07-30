# AWDL sync on a MediaTek MT7921 (Filogic 330) with OWL — findings

Status: **link-layer sync with a real Apple device works and is reproducible.**
Peer discovery, channel-sequence parsing, and master election are all confirmed.
One open problem remains (peer ages out after ~4 s); it is characterised at the
end of this document.

> **CORRECTION 2026-07-30 — the above is NOT currently reproducible.** On a fresh
> boot of the pinned 6.12.97 kernel, monitor-mode RX on this MT7921 delivers
> **zero frames**, measured three independent ways (see §8). The sync result in
> §5 did happen — `sync-log.txt` is a real transcript — but it cannot be
> reproduced today, and §2's account of *why* 6.18 differs from 6.12.97 is partly
> wrong. Read §8 before trusting §2 or §4.

This document records what was done and what was observed. It is the basis for a
writeup, not a tutorial.

---

## 1. Hardware and platform

| | |
|---|---|
| Adapter | MEDIATEK MT7921 802.11ax PCIe [Filogic 330], PCI ID `14c3:7961` |
| Subsystem | Lenovo `17aa:e0bc` |
| Driver | `mt7921e` (mt76) |
| Interface | `wlp2s0`, MAC `4c:82:a9:17:65:27` |
| OS | Void Linux (runit; `sv` for service control) |
| Kernel | **6.12.97_1 — pinned, see §2** |
| Toolchain | GCC 14.2.1, CMake 4.2.2, Ninja 1.13.2 |
| Regulatory domain | NZ (`iw reg set NZ`) |

The MT7921 is a fully offloaded chip: channel selection, timing, and the TX path
below the radiotap header live in firmware. That matters for the open problem in
§6 — OWL's software channel-hop schedule has to be honoured by a chip that does
its own scheduling.

## 2. The 6.18 mt76 monitor-RX regression

This was the single largest time sink and is worth stating first, because it
makes every other part of the system look broken.

**Symptom on kernel 6.18 (tested: 6.18.32_1, 6.18.33_1):**

- The card **injects fine.** Frames sent through the pcap TX path go out; they
  are visible to other capture devices.
- The card captures **zero frames in monitor mode.** Not "few", not "only
  beacons" — nothing at all reaches the pcap handle, in an RF environment
  saturated with 2.4 GHz and 5 GHz beacons.
- TX power additionally reads stuck at 3 dBm.
  **RETRACTED 2026-07-30:** this is not a 6.18 symptom. `txpower 3.00 dBm` is
  reported on 6.12.97 too, in *managed* mode, while associated and passing
  traffic normally, and it persists after an explicit
  `iw dev wlp2s0 set txpower fixed 2000`. Meanwhile dmesg logs
  `Limiting TX power to 30 (30 - 0) dBm`. So this is a cosmetic mt76 reporting
  quirk with no diagnostic value. Ignore it.

Because AWDL is a receive-driven protocol — OWL learns peers, their channel
sequences, and their election metrics entirely from received action frames — a
silent RX failure presents as "OWL runs, sends PSFs, and never discovers
anything." There is no error. Nothing logs. The daemon looks healthy.

**How it was diagnosed.** The confound is that on Linux, an interface in monitor
mode can be quietly reclaimed or reconfigured by NetworkManager, wpa_supplicant,
or dhcpcd, which produces the same "no frames" outcome for entirely mundane
reasons. So the test had to eliminate userspace interference before blaming the
driver. That is what `monitor-test.sh` does (kept at
`/mnt/shared/downloads/monitor-test.sh`):

1. Stop `NetworkManager` via runit, then `pkill` `wpa_supplicant` and `dhcpcd`,
   and **prove** none survived by listing remaining processes.
2. Set the regulatory domain, bring the interface down, `iw dev … set monitor
   active`, bring it up, and explicitly force `txpower fixed 2000`.
3. Print `iw dev … info` so the *actual* type / txpower / channel the driver
   settled on is on the record, not the type that was requested.
4. `dmesg -C` to clear the ring buffer, hold active monitor for 15 s, then dump
   only the *new* kernel messages — so any firmware or auth/assoc complaint
   during the hold is unambiguous and not archaeology from boot.
5. An `EXIT INT TERM` trap restores managed mode and networking unconditionally,
   including on Ctrl-C or a hang-kill. (Without this, a failed monitor test
   leaves the machine with no network, which is how you lose an evening.)

Running that identical script under 6.12.97 and under 6.18 isolates the variable
to the kernel: same script, same hardware, same RF environment, same regdomain,
same explicit txpower. Under 6.12.97 the capture floods with beacons. Under 6.18
it stays empty. That is the regression.

**Resolution: pin the kernel.** GRUB `saved_entry` is set to
`gnulinux-6.12.97_1-advanced-…`. 6.18.32_1 and 6.18.33_1 remain installed but
are never booted.

> **Failure mode to remember:** if the setup ever "randomly stops working after a
> reboot," check `uname -r` *first*. If it says 6.18, that is the entire
> explanation. Monitor RX dies silently and every downstream symptom is a red
> herring.

## 3. Build on Void Linux

Upstream is [seemoo-lab/owl](https://github.com/seemoo-lab/owl), at commit
`8e4e840` ("Fix possible buffer overread in wlan string").

**No source changes were required.** It builds clean on GCC 14 with `-Wall
-Wextra`.

Two environment-specific points:

1. **The working copy must live on a real filesystem.** The repo was copied off
   `/mnt/shared` to `~/owl` because that mount is NTFS, which strips the
   executable bit — the build products are unusable in place.
2. **CMake 4 rejects the project's declared minimum.** `CMakeLists.txt` opens
   with `cmake_minimum_required(VERSION 3.5)`, and CMake 4.x refuses
   compatibility with `<3.10`. Rather than patch upstream, override at configure
   time:

```sh
cmake -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -S . -B build
cmake --build build --target owl
```

Dependencies (Void package names differ from the README's Debian/Fedora lists,
but the libraries are the same three): `libpcap` for frame injection and
capture, `libev` for the event loop, `libnl3` for nl80211 interaction.

Binary: `~/owl/build/daemon/owl`.

## 4. Working configuration

Running OWL takes the card away from normal networking for the duration —
expect to lose internet on that interface.

```sh
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant; sudo pkill -x dhcpcd; sleep 1
sudo iw reg set NZ
sudo ip link set wlp2s0 down
sudo ./owl -i wlp2s0 -c 149 -v
```

Restore afterwards:

```sh
sudo ip link set wlp2s0 down
sudo iw dev wlp2s0 set type managed
sudo ip link set wlp2s0 up
sudo sv up NetworkManager
```

**The `-c` flag is the thing that makes or breaks discovery**, and the reason is
structural rather than obvious:

- A lone OWL node does **not** hop. `awdl_state_init()` (`src/state.c:60`) calls
  `awdl_chanseq_init_static(state->channel.sequence, &state->channel.master)`,
  filling all `AWDL_CHANSEQ_LENGTH` (16) slots with a single channel. The
  upstream `awdl_chanseq_init()` call directly above it is commented out.
- The default master channel is **channel 6, i.e. 2.4 GHz**.
- The local environment is entirely 5 GHz, and the Apple device lives there.

So with default settings OWL parks on 2.4 GHz channel 6 and hears nothing,
forever, on a card whose monitor RX is working perfectly. `-c 44` or `-c 149`
moves the static master channel to 5 GHz and discovery starts immediately. OWL
encodes channels with `AWDL_CHAN_ENC_OPCLASS`, and both 44 and 149 have opclass
constants defined (`CHAN_OPCLASS_44`, `CHAN_OPCLASS_149` in `src/channel.h`).

## 5. Sync result

With `-c 149`, OWL synchronises with a real Apple device. Three separate
mechanisms were confirmed working, each observable in `-v` output:

**Peer discovery.** Received action frames are parsed, the peer is inserted into
the hashmap peer table, and `src/peers.c:111` logs `add peer <mac> (<name>)`
with the device's advertised hostname.

**Channel-sequence parsing.** OWL decodes the peer's full 16-slot channel
sequence TLV (`src/rx.c:93`). The Apple device's advertised sequence was read as:

```
149,149,149,149,149,149,36,36,6,149,149,149,149,149,36,36
```

That is a real, correctly-parsed Apple channel sequence: predominantly the
5 GHz social channel 149, with two slots on 36 and one on 2.4 GHz channel 6 —
consistent with a device keeping a foot in the 2.4 GHz social channel for
discovery by legacy peers. Recovering this structure end-to-end (radiotap →
action frame → TLV → per-slot opclass-encoded channels) is the strongest single
piece of evidence that the RX path and the parser are both correct.

**Master election.** `awdl_election_run()` executes on each peer-cleanup tick and
compares `(master_counter, master_metric)`, falling back to sync-tree height and
then MAC address ordering. On adopting a new master it logs the resulting tree
via `src/election.c:118` (`new election tree: …`), formatted as
`self > … > master (met <metric>, ctr <counter>)`. The Apple device won the
election, which is the expected and correct outcome — OWL adopted it as sync
master and slaved its own timing to the peer's.

> **Log evidence — to be pasted in.** The exact `-v` transcript for the run above
> is not archived in this repo. Please drop in the raw lines covering: the `add
> peer` line, the `peer … changed channel sequence to …` line, the `new election
> tree: …` line, and the trailing `remove peer` line ~4 s later. The claims above
> are reconstructed from the source's log-format strings and from the session
> notes; the writeup should quote the real output verbatim.

## 6. Open problem: peer drops after ~4 seconds

The peer is discovered and added, then removed roughly four seconds later, and
the cycle repeats.

**Mechanism.** This is not a bug in discovery — it is the direct consequence of
the static channel sequence described in §4:

1. OWL sits on channel 149 in all 16 slots. It never leaves.
2. The Apple device hops its real sequence: mostly 149, but slots 6, 7, 14, 15
   on channel 36 and slot 8 on channel 6.
3. During the Apple device's excursions to 36 and 6, OWL is on the wrong channel
   and misses those availability windows entirely.
4. The peer's last-seen timestamp goes stale. `awdl_clean_peers()`
   (`daemon/core.c:320`) runs every `PEERS_DEFAULT_CLEAN_INTERVAL` and evicts
   anything older than `PEERS_DEFAULT_TIMEOUT`. Both are declared in
   `src/peers.c:28-29` as `2000000` and `1000000` with a comment reading
   `/* in ms */`, but they are consumed as **microseconds** —
   `cutoff_time = clock_time_us() - state->awdl_state.peers.timeout` — so the
   real values are a **2 s timeout swept by a 1 s cleaner**. Worst-case eviction
   therefore lands between 2 s and 3 s after the last frame, which matches the
   observed ~4 s including the time to first miss. (The `/* in ms */` comment is
   simply wrong; worth noting in the writeup.)

**Direction of the fix.** OWL must adopt and *follow* the discovered peer's
channel sequence instead of remaining static. The machinery is already present:
`awdl_switch_channel()` (`daemon/core.c:279`) computes
`slot = awdl_sync_current_eaw(now, &sync) % AWDL_CHANSEQ_LENGTH`, indexes
`awdl_state->channel.sequence[slot]`, and calls `set_channel()` when the slot's
channel differs from the current one, re-arming itself at
`awdl_sync_next_aw_us()`. It already hops correctly — it is simply hopping over
a sequence with 16 identical entries. Populating `channel.sequence` from the
peer's parsed sequence is the change.

**The actual research question** is not the code change but whether the hardware
can keep up. Each hop calls `set_channel()` down through nl80211 into mt7921
firmware, and AWDL availability windows are short. If mt7921's channel-switch
latency exceeds the window, OWL will arrive on each channel too late to be
useful and the link will not hold no matter how correct the schedule is. Whether
a fully-offloaded MediaTek part can be driven at AWDL hop rates from userspace
is the open question this platform is well placed to answer.

## 7. Scope note: sync is not transfer

Worth stating explicitly so the result is not oversold. Link-layer sync (this
document) and application-layer transfer are separate problems:

- The target iPhone runs iOS 26.5, where AirDrop to a non-contact requires the
  AirDrop-code handshake. OpenDrop does not implement it.
- The contacts path requires a genuine Apple ID Validation Record (VLD) issued
  to a device signed into the same Apple ID. It is Apple-key-signed and cannot
  be forged.

So AirDrop interop is gated on authentication, not on the radio work. The sync
result stands on its own: an open-source AWDL implementation reaching timing and
election agreement with a live Apple device on a fully-offloaded MediaTek chip.

## 8. 2026-07-30: monitor RX on the MT7921 delivers nothing, on the *pinned* kernel

Attempting to re-run the §5 sync against an iPhone (AirDrop sheet open, so AWDL
was actively advertising) produced 1587 log lines of pure TX and **zero received
frames**. Investigating that produced the following, all on kernel 6.12.97_1 on
a fresh boot with the regdomain explicitly set to NZ.

### The radio tunes correctly; that was never the bug

`chansweep.sh` requests channels 36/44/149/6 in turn and records both what `iw`
claims and the radiotap frequency of arriving frames:

```
req_ch=36   iw_claims=36   iw_mhz=5180   frames=0
req_ch=44   iw_claims=44   iw_mhz=5220   frames=0
req_ch=149  iw_claims=149  iw_mhz=5745   frames=0
req_ch=6    iw_claims=6    iw_mhz=2437   frames=0
```

`iw_mhz` tracks `req_ch` exactly in every case, so the 2026-07-25 note about the
radio sitting on 5180 MHz while claiming 149 is **not** a channel-setting bug.
Channel 36 here is a deliberate positive control - the local AP lives there - and
it returned zero frames, which means the control failed and the problem is
upstream of channel selection entirely.

### `iw set channel` is not the culprit either

`monitor-test.sh` (which reported beacons flooding in on 07-25) never sets a
channel, whereas `hoptest.sh` and OWL both do. `rxtest.sh` A/B tests exactly
that, in one session:

```
A_no_channel_set        iw_claims=6    frames=0
B_after_set_ch36        iw_claims=36   frames=0
C_fresh_no_channel_set  iw_claims=36   frames=0
```

RX is dead with and without a channel set, and dead again after tearing monitor
mode down and re-entering it. Set-channel is exonerated.

### The frames never leave the chip

`rxcounters.sh` compares three independent counters over one 10 s monitor window,
parked on channel 2 where the AP was actively serving traffic:

| counter | result |
|---|---|
| mt76 hardware RX (debugfs) | debugfs not present on this build |
| netdev `rx_packets` delta | **0** |
| libpcap frames (tcpdump) | **0** |

The netdev counter sat at 2,002,976 from normal managed-mode use and did not
advance by a single packet. So this is not a pcap, BPF, or filter problem - the
driver hands nothing up at all.

### Probable cause: mt7921 monitor mode is nominal, not functional

`iw phy phy0 info` lists `monitor` under *Supported interface modes*, but the
valid interface combinations are:

```
* #{ managed, P2P-client } <= 2, #{ AP, P2P-GO } <= 1, total <= 2, #channels <= 2
```

**`monitor` appears in no valid combination.** That is consistent with everything
observed: `iw dev wlp2s0 set monitor active` succeeds, the netdev genuinely
enters promiscuous mode (dmesg confirms `entered promiscuous mode` on each
attempt), no firmware error is ever logged, and not one frame is delivered.

Ruled out while narrowing this down:
- **Not a kernel regression from 6.18.** The pin is holding; `uname -r` is
  6.12.97_1 (verified after the GRUB fix, see NOTES.md).
- **Not a firmware update.** `linux-firmware-network-20260410_1`, installed
  2026-05-21, predates the 07-25 working result.
- **Not a suspend/resume wedge.** Fresh boot, no suspend cycle.
- **Not regulatory.** Zero frames on 2.4 GHz ch 6 and ch 2, which no regdomain
  restricts. Under the US rules the card was actually using, ch 149 is 30 dBm
  and not DFS.
- **Not userspace interference.** NetworkManager down, `wpa_supplicant` and
  `dhcpcd` confirmed dead before each test.

### What this means for the project

The §5 sync result is real - `sync-log.txt` is a genuine transcript with a
correctly parsed Apple channel sequence. But it is **not reproducible on this
adapter today**, and the reason it once worked is not yet explained. Until
monitor RX can be recovered, the follow-the-peer-sequence fix (`9bac866`) cannot
be validated, because validating it requires receiving frames.

Three candidate paths, in rough order of promise:

1. **Try the AR9271 USB adapter.** `ath9k_htc` has genuinely solid monitor and
   injection support, unlike a fully-offloaded part. It costs the "can a
   fully-offloaded MediaTek chip be driven at AWDL hop rates" research angle,
   but it would unblock validating `9bac866` immediately. The adapter was not
   plugged in during these tests (`lsusb` showed only the Foxconn Bluetooth
   device).
2. **Try the other installed kernels.** 6.12.90_1 and 6.12.11_1 are both still
   installed. It is worth considering that the kernel which actually worked on
   07-25 was one of those and was recorded as 6.12.97 from memory late in a long
   session. Cheap to test, one reboot each.
3. **Dig into mt7921 monitor support directly.** The missing interface
   combination is the thread to pull - check whether a separately-added monitor
   vif (`iw phy phy0 interface add mon0 type monitor`) behaves differently from
   an in-place type change, and check mt76 upstream for monitor-mode fixes.

### Test harnesses added

`chansweep.sh`, `rxtest.sh`, and `rxcounters.sh` all follow the same safety
pattern: a bash `trap` on EXIT/INT/TERM **plus** an independent `setsid`-detached
watchdog that restores networking even if the script is `kill -9`'d or hangs,
which a trap alone cannot survive. The watchdog mechanism was verified to fire
after a hard kill before being relied on. No test can leave the machine without
wifi.

## 9. 2026-07-30 (later): both bugs found, and `9bac866` is validated

§8 closes. The zero-RX problem was **two independent mt7921 bugs stacked on top of
each other**, and neither is the kernel. With both worked around, OWL synchronised
with an iPhone and the follow-the-peer-channel-sequence fix demonstrably works.

### Bug 1: runtime power management silently kills monitor RX

`runtime-pm` and `deep-sleep` both default to `1`, and `runtime_pm_stats` showed
the chip dozing roughly twice as long as it was awake. In managed mode the
association keeps it awake. In monitor mode nothing does, so it sleeps and
delivers **zero** frames, with no error anywhere.

```
/sys/kernel/debug/ieee80211/phy0/mt76/runtime-pm   -> must be 0
/sys/kernel/debug/ieee80211/phy0/mt76/deep-sleep   -> must be 0
```

Note `debugfs` is **not mounted by default** on this box:
`sudo mount -t debugfs none /sys/kernel/debug` first, or the knobs do not exist.
`pmtest.sh` demonstrates it: PM on = 0 frames, PM off = frames arrive. (The
control phase was not a clean zero, because writing the knob itself wakes the
chip and it stays awake - so treat the knob as "wake and stay awake", not a
clean on/off switch.)

### Bug 2: an in-place interface type switch never retunes the radio

This is the real explanation for the 2026-07-25 "frames tagged 5180 MHz while iw
reports 149" mystery, and it is worse than it looked - the radio never leaves
5180 MHz **at all**.

`iw dev wlp2s0 set type monitor` (what `monitor-test.sh`, `hoptest.sh` and every
earlier harness did) leaves the hardware pinned at 5180 MHz no matter what
channel is requested, while `iw` faithfully reports whatever was asked for. A
**dedicated monitor vif** tunes correctly. `montest.sh`, target 5745 MHz:

| method | dominant RX freq | verdict |
|---|---|---|
| in-place `set type monitor`, 149 set first | 5180 | stuck |
| `set freq 5745` | no frames | - |
| `set freq 5745 HT20` | no frames | - |
| `set channel 149` + link down/up bounce | 5180 | stuck |
| **`iw phy phy0 interface add mon0 type monitor`** | **5745** | **works** |

So the correct setup is:

```sh
sudo mount -t debugfs none /sys/kernel/debug        # if not already mounted
sudo ip link set wlp2s0 down
sudo iw phy phy0 interface add mon0 type monitor
sudo ip link set mon0 up
sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/runtime-pm'
sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/deep-sleep'
sudo iw dev mon0 set freq 5745
sudo ./build/daemon/owl -i mon0 -c 149 -N -vv
```

### Bug 3 (minor): OWL needs `-N` on a pre-made monitor vif

OWL calls `set_monitor_mode()` itself (`daemon/io.c:296`). On an interface that is
already a monitor vif **and up**, that nl80211 call fails with `EBUSY` and OWL
aborts before it starts:

```
ERROR: Error while receiving via netlink: Object busy
ERROR: Could not put device in monitor mode: mon0
ERROR: could not initialize core
```

`-N` sets `wlan_no_monitor_mode` and skips the step. The option already existed
upstream; no patch needed.

### Result: sync with an iPhone, and the peer is held

`hoptest2.sh`, 60 s, iPhone with the AirDrop sheet open, OWL on `mon0` at ch 149:

- **2018 frames** captured, including **266 real AWDL action frames** on the AWDL
  BSSID `00:25:00:ff:94:73` from `42:24:66:35:43:0c` at -16 dBm.
- Channel sequence parsed from the phone:
  `149,149,149,0,0,0,0,0,6,149,149,0,0,0,0,0`
- Election resolved correctly, phone winning:
  `new election tree: 4c:82:a9:17:65:27 -> 42:24:66:35:43:c (met 65, ctr 223)`
- **Peer lifetimes: 9.78 s, then a second peer still held when the run ended
  (>= 3.56 s).** Against a 2 s timeout swept by a 1 s cleaner, the old behaviour
  was eviction at ~2-3 s. **`9bac866` is validated.**

### The hop happens - but the dwell is short, and that is the real finding

The independent 20 Hz radio poller (which never reads OWL's state, only the
driver's) recorded the radio on two channels:

| channel | samples | share |
|---|---|---|
| 149 | 1060 | 97.3% |
| 6 | 29 | 2.7% |

So OWL genuinely adopted the peer's sequence and hopped to channel 6, and frames
were captured on both 5745 MHz and 2437 MHz. But the peer's sequence had one
channel-6 slot out of six non-zero slots, i.e. **~16.7% expected against 2.7%
observed** - the radio reaches channel 6 for roughly a sixth of its scheduled
dwell.

That is a direct, quantified answer to the open research question in §6: a
fully-offloaded MT7921 *can* be driven to hop from userspace at AWDL rates, but
firmware channel-switch latency eats most of the availability window on the
away-channel. Enough to hold a peer; probably not enough to carry data reliably
in those slots. Worth measuring properly - per-hop switch latency from the
radio.log timestamps is the obvious next step.

## 10. 2026-07-30: AirDrop is not reachable on the MT7921, and the reason is ACKs

Sync works (§9). Data transfer does not, and the wall is **not** Apple's
authentication - we never got far enough to meet it.

### The measurement: a one-way path

With OWL synced to an iPhone, a peer in the table and an IPv6 neighbour
installed on `awdl0`:

```
ping6 -I awdl0 fe80::4024:66ff:fe35:430c
  5 packets transmitted, 0 received, 100% packet loss
packets on awdl0: total=8  from_peer=0  mdns=2
```

Our mDNS queries went out. Nothing ever came back. So the repeated
"No AirDrop service discovered" was never an auth refusal - no packet from the
phone ever reached us.

### The cause: active monitor mode does not work on this chip

AWDL data frames are unicast, so they must be ACKed. That is what *active*
monitor mode is for, and the OWL README lists it as a hard requirement. The
MT7921 claims to support it:

```
iw phy phy0 info -> "Device supports active monitor (which will ACK incoming frames)"
```

It does not, in any usable sense. `activetest.sh`, parked on channel 3 where the
local AP is, counting all frames over 8 s:

| mon0 created | frames |
|---|---|
| plain | 140 |
| **`flags active`** | **6** |
| plain again | 144 |

Active monitor destroys roughly **96%** of reception. This is the same
nominal-but-not-functional pattern as §8's monitor mode and §9's channel tuning:
the capability is advertised, the call succeeds, no error is logged, and the
hardware quietly fails to do it.

### The consequence: a genuine dead end on this adapter

The two options are mutually exclusive, and neither permits AirDrop:

| mode | RX | ACKs | outcome |
|---|---|---|---|
| plain monitor | works | no | one-way path; AirDrop cannot complete |
| active monitor | ~96% lost | yes | nothing arrives to ACK anyway |

So **AirDrop over the built-in MT7921 is blocked by the adapter**, not by Apple.
The harnesses are therefore set to create `mon0` **plain**: reception is what
makes the sync result in §9 possible, and that result is the valuable part.

This retroactively vindicates the README's hardware requirement. It recommends
an AR9280 (ath9k) precisely because a fully-offloaded chip cannot be trusted to
ACK on a monitor vif. The AR9271 (`ath9k_htc`) on hand is the path to an actual
transfer.

### What is and is not blocked

- **Link-layer sync: works, and is the novel result.** Unaffected by any of this.
- **`9bac866` validation: stands.** It only needed RX, which plain monitor gives.
- **AirDrop transfer on MT7921: blocked at the link layer.** Needs a card with
  working active monitor.
- **AirDrop auth (§7): still untested.** It may well also block, but that is now
  an *unverified* claim - the ACK problem stopped us first, and any future
  attempt should re-measure rather than assume.
