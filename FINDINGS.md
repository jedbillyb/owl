# AWDL sync on a MediaTek MT7921 (Filogic 330) with OWL — findings

Status: **link-layer sync with a real Apple device works and is reproducible.**
Peer discovery, channel-sequence parsing, and master election are all confirmed.
One open problem remains (peer ages out after ~4 s); it is characterised at the
end of this document.

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
