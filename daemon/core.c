/*
 * OWL: an open Apple Wireless Direct Link (AWDL) implementation
 * Copyright (C) 2018  The Open Wireless Link Project (https://owlink.org)
 * Copyright (C) 2018  Milan Stute
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "core.h"
#include "netutils.h"

#include "log.h"
#include "wire.h"
#include "rx.h"
#include "tx.h"
#include "schedule.h"

#include <signal.h>

#ifdef __APPLE__
# define SIGSTATS SIGINFO
#else
# define SIGSTATS SIGUSR1
#endif

#define ETHER_LENGTH 14
#define ETHER_DST_OFFSET 0
#define ETHER_SRC_OFFSET 6
#define ETHER_ETHERTYPE_OFFSET 12

#define POLL_NEW_UNICAST 0x1
#define POLL_NEW_MULTICAST 0x2

static void dump_frame(const char *dump_file, const struct pcap_pkthdr *hdr, const uint8_t *buf) {
	if (dump_file) {
		/* Make sure file exists because 'pcap_dump_open_append' does NOT create file for you */
		fclose(fopen(dump_file, "a+"));
		pcap_t *p = pcap_open_dead(DLT_IEEE802_11_RADIO, 65535);
		pcap_dumper_t *dumper = pcap_dump_open_append(p, dump_file);
		pcap_dump((u_char *) dumper, hdr, buf);
		pcap_close(p);
		pcap_dump_close(dumper);
	}
}

static void ev_timer_rearm(struct ev_loop *loop, ev_timer *timer, double in) {
	ev_timer_stop(loop, timer);
	ev_timer_set(timer, in, 0.);
	ev_timer_start(loop, timer);
}

void wlan_device_ready(struct ev_loop *loop, ev_io *handle, int revents) {
	struct daemon_state *state = handle->data;
	int cnt = pcap_dispatch(state->io.wlan_handle, 1, &awdl_receive_frame, handle->data);
	if (cnt > 0)
		ev_feed_event(loop, handle, revents);
}

static int poll_host_device(struct daemon_state *state) {
	struct buf *buf = NULL;
	int result = 0;
	while (!state->next && !circular_buf_full(state->tx_queue_multicast)) {
		buf = buf_new_owned(ETHER_MAX_LEN);
		int len = buf_len(buf);
		if (host_recv(&state->io, (uint8_t *) buf_data(buf), &len) < 0) {
			goto wire_error;
		} else {
			bool is_multicast;
			struct ether_addr dst;
			buf_take(buf, buf_len(buf) - len);
			READ_ETHER_ADDR(buf, ETHER_DST_OFFSET, &dst);
			is_multicast = dst.ether_addr_octet[0] & 0x01;
			if (is_multicast) {
				circular_buf_put(state->tx_queue_multicast, buf);
				result |= POLL_NEW_MULTICAST;
			} else { /* unicast */
				state->next = buf;
				result |= POLL_NEW_UNICAST;
			}
		}
	}
	return result;
wire_error:
	if (buf)
		buf_free(buf);
	return result;
}

void host_device_ready(struct ev_loop *loop, ev_io *handle, int revents) {
	(void) loop;
	(void) revents; /* should always be EV_READ */
	struct daemon_state *state = handle->data;

	int poll_result = poll_host_device(state); /* fill TX queues */
	if (poll_result & POLL_NEW_MULTICAST)
		awdl_send_multicast(loop, &state->ev_state.tx_mcast_timer, 0);
	if (poll_result & POLL_NEW_UNICAST)
		awdl_send_unicast(loop, &state->ev_state.tx_timer, 0);
}

void awdl_receive_frame(uint8_t *user, const struct pcap_pkthdr *hdr, const uint8_t *buf) {
#define MAX_NUM_AMPDU 16 /* TODO lookup this constant from the standard */
	struct daemon_state *state = (void *) user;
	int result;
	const struct buf *frame = buf_new_const(buf, hdr->caplen);
	struct buf *data_arr[MAX_NUM_AMPDU];
	struct buf **data = &data_arr[0];
	result = awdl_rx(frame, &data, &state->awdl_state);
	if (result == RX_OK) {
		for (struct buf **data_start = &data_arr[0]; data_start < data; data_start++) {
			host_send(&state->io, buf_data(*data_start), buf_len(*data_start));
			buf_free(*data_start);
		}
	} else if (result < RX_OK) {
		log_warn("unhandled frame (%d)", result);
		dump_frame(state->dump, hdr, buf);
		state->awdl_state.stats.rx_unknown++;
	}
	buf_free(frame);
}

int awdl_send_data(const struct buf *buf, const struct io_state *io_state,
                   struct awdl_state *awdl_state, struct ieee80211_state *ieee80211_state) {
	uint8_t awdl_data[65535];
	int awdl_data_len;
	uint16_t ethertype;
	struct ether_addr src, dst;
	uint64_t now;
	uint16_t period, slot, tu;

	READ_BE16(buf, ETHER_ETHERTYPE_OFFSET, &ethertype);
	READ_ETHER_ADDR(buf, ETHER_DST_OFFSET, &dst);
	READ_ETHER_ADDR(buf, ETHER_SRC_OFFSET, &src);

	buf_strip(buf, ETHER_LENGTH);
	awdl_data_len = awdl_init_full_data_frame(awdl_data, &src, &dst,
	                                          buf_data(buf), buf_len(buf),
	                                          awdl_state, ieee80211_state);
	now = clock_time_us();
	period = awdl_sync_current_eaw(now, &awdl_state->sync) / AWDL_CHANSEQ_LENGTH;
	slot = awdl_sync_current_eaw(now, &awdl_state->sync) % AWDL_CHANSEQ_LENGTH;
	tu = awdl_sync_next_aw_tu(now, &awdl_state->sync);
	log_trace("Send data (len %d) to %s (%u.%u.%u)", awdl_data_len,
	          ether_ntoa(&dst), period, slot, tu);
	awdl_state->stats.tx_data++;
	if (wlan_send(io_state, awdl_data, awdl_data_len) < 0)
		return TX_FAIL;
	return TX_OK;

wire_error:
	return TX_FAIL;
}

void awdl_send_action(struct daemon_state *state, enum awdl_action_type type) {
	uint8_t buf[65535];
	int len;

	len = awdl_init_full_action_frame(buf, &state->awdl_state, &state->ieee80211_state, type);
	if (len < 0)
		return;
	log_trace("send %s", awdl_frame_as_str(type));
	wlan_send(&state->io, buf, len);

	state->awdl_state.stats.tx_action++;
}

void awdl_send_psf(struct ev_loop *loop, ev_timer *handle, int revents) {
	(void) loop;
	(void) revents;
	awdl_send_action(handle->data, AWDL_ACTION_PSF);
}

void awdl_send_mif(struct ev_loop *loop, ev_timer *timer, int revents) {
	(void) revents;
	struct daemon_state *state = timer->data;
	struct awdl_state *awdl_state = &state->awdl_state;
	uint64_t now, next_aw, eaw_len;

	now = clock_time_us();
	next_aw = awdl_sync_next_aw_us(now, &awdl_state->sync);
	eaw_len = awdl_state->sync.presence_mode * awdl_state->sync.aw_period;

	/* Schedule MIF in middle of sequence (if non-zero) */
	if (awdl_chan_num(awdl_state->channel.current, awdl_state->channel.enc) > 0)
		awdl_send_action(state, AWDL_ACTION_MIF);

	/* schedule next in the middle of EAW */
	ev_timer_rearm(loop, timer, usec_to_sec(next_aw + ieee80211_tu_to_usec(eaw_len / 2)));
}

void awdl_send_unicast(struct ev_loop *loop, ev_timer *timer, int revents) {
	(void) revents;
	struct daemon_state *state = timer->data;
	struct awdl_state *awdl_state = &state->awdl_state;
	uint64_t now = clock_time_us();
	double in = 0;

	if (state->next) { /* we have something to send */
		struct awdl_peer *peer;
		struct ether_addr dst;
		read_ether_addr(state->next, ETHER_DST_OFFSET, &dst);
		if (compare_ether_addr(&dst, &awdl_state->self_address) == 0) {
			/* send back to self */
			host_send(&state->io, buf_data(state->next), buf_len(state->next));
			buf_free(state->next);
			state->next = NULL;
		} else if (awdl_peer_get(awdl_state->peers.peers, &dst, &peer) < 0) {
			log_debug("Drop frame to non-peer %s", ether_ntoa(&dst));
			buf_free(state->next);
			state->next = NULL;
		} else {
			in = awdl_can_send_unicast_in(awdl_state, peer, now, AWDL_UNICAST_GUARD_TU);
			if (in == 0) { /* send now */
				awdl_send_data(state->next, &state->io, &state->awdl_state, &state->ieee80211_state);
				buf_free(state->next);
				state->next = NULL;
				state->awdl_state.stats.tx_data_unicast++;
			} else { /* try later */
				if (in < 0) /* we are at the end of slot but within guard */
					in = -in + usec_to_sec(ieee80211_tu_to_usec(AWDL_UNICAST_GUARD_TU));
			}
		}
	}

	/* rearm if more unicast frames available */
	if (state->next) {
		log_trace("awdl_send_unicast: retry in %lu TU", ieee80211_usec_to_tu(sec_to_usec(in)));
		ev_timer_rearm(loop, timer, in);
	} else {
		/* poll for more frames to keep queue full */
		ev_feed_event(loop, &state->ev_state.read_host, 0);
	}
}

void awdl_send_multicast(struct ev_loop *loop, ev_timer *timer, int revents) {
	(void) revents;
	struct daemon_state *state = timer->data;
	struct awdl_state *awdl_state = &state->awdl_state;
	uint64_t now = clock_time_us();
	double in = 0;

	if (!circular_buf_empty(state->tx_queue_multicast)) { /* we have something to send */
		in = awdl_can_send_in(awdl_state, now, AWDL_MULTICAST_GUARD_TU);
		if (awdl_is_multicast_eaw(awdl_state, now) && (in == 0)) { /* we can send now */
			void *next;
			circular_buf_get(state->tx_queue_multicast, &next, 0);
			awdl_send_data((struct buf *) next, &state->io, &state->awdl_state, &state->ieee80211_state);
			buf_free(next);
			state->awdl_state.stats.tx_data_multicast++;
		} else { /* try later */
			if (in == 0) /* try again next EAW */
				in = usec_to_sec(ieee80211_tu_to_usec(64));
			else if (in < 0) /* we are at the end of slot but within guard */
				in = -in + usec_to_sec(ieee80211_tu_to_usec(AWDL_MULTICAST_GUARD_TU));
		}
	}

	/* rearm if more multicast frames available */
	if (!circular_buf_empty(state->tx_queue_multicast)) {
		log_trace("awdl_send_multicast: retry in %lu TU", ieee80211_usec_to_tu(sec_to_usec(in)));
		ev_timer_rearm(loop, timer, in);
	} else {
		/* poll for more frames to keep queue full */
		ev_feed_event(loop, &state->ev_state.read_host, 0);
	}
}

void awdl_switch_channel(struct ev_loop *loop, ev_timer *timer, int revents) {
	(void) revents;
	uint64_t now, next_aw;
	int slot;
	struct awdl_chan chan_new;
	int chan_num_new, chan_num_old;
	struct daemon_state *state = timer->data;
	struct awdl_state *awdl_state = &state->awdl_state;

	chan_num_old = awdl_chan_num(awdl_state->channel.current, awdl_state->channel.enc);

	now = clock_time_us();
	slot = awdl_sync_current_eaw(now, &awdl_state->sync) % AWDL_CHANSEQ_LENGTH;
	chan_new = awdl_state->channel.sequence[slot];
	chan_num_new = awdl_chan_num(awdl_state->channel.sequence[slot], awdl_state->channel.enc);

	if (chan_num_new && (chan_num_new != chan_num_old)) {
		int err = 0;
		log_debug("switch channel to %d (slot %d)", chan_num_new, slot);
		if (!state->io.wlan_is_file) {
			/* NOTE: upstream called is_channel_available() here and then
			 * discarded the result. That call issues a full split wiphy dump
			 * over netlink and blocks the event loop -- harmless with a static
			 * 16-slot sequence (this branch never re-enters), but once we
			 * actually follow a peer's sequence it runs on every transition,
			 * against a 16 TU (16384 us) availability window. It is dropped
			 * here; a failed set_channel() is caught below anyway, which is
			 * the outcome the check was nominally guarding against. */
			uint64_t t0 = clock_time_us();
			err = set_channel(state->io.wlan_ifindex, chan_num_new);
			log_debug("set_channel(%d) took %llu us", chan_num_new,
			          (unsigned long long) (clock_time_us() - t0));
		}
		if (err < 0) {
			/* Do NOT advance channel.current: the radio did not move, and
			 * lying about it desyncs our idea of the channel from the card. */
			log_warn("could not switch to channel %d (slot %d), radio still on %d",
			         chan_num_new, slot, chan_num_old);
		} else {
			awdl_state->channel.current = chan_new;
		}
	}

	next_aw = awdl_sync_next_aw_us(now, &awdl_state->sync);

	ev_timer_rearm(loop, timer, usec_to_sec(next_aw));
}

static void awdl_neighbor_add(struct awdl_peer *p, void *_io_state) {
	struct io_state *io_state = _io_state;
	neighbor_add_rfc4291(io_state->host_ifindex, &p->addr);
}

static void awdl_neighbor_remove(struct awdl_peer *p, void *_io_state) {
	struct io_state *io_state = _io_state;
	neighbor_remove_rfc4291(io_state->host_ifindex, &p->addr);
}

/*
 * How recently a peer must have sent us a data frame to count as "active" for
 * the purpose of channel-sequence adoption. Generous on purpose: a transfer
 * that stalls for a slot or two must not cause us to flap back to the elected
 * master's sequence and lose the overlap that was carrying the transfer.
 */
#define AWDL_DATA_PEER_TIMEOUT_US (5 * 1000000ULL)

/*
 * Pick the peer whose channel sequence we should follow.
 *
 * Upstream always followed the election winner (the sync master). That is
 * correct for staying in sync, but it is the wrong sequence to be on when the
 * device we are actually exchanging data with is someone else -- which is the
 * common case, because any room with several Apple devices in it elects a
 * master that has nothing to do with our transfer. Measured on a real AirDrop
 * receive: the elected master was a bystander for the first 70 seconds, and the
 * transfer only got going once the election happened to swing to the phone.
 *
 * So: prefer the peer that has most recently sent us *data*, and fall back to
 * the elected master when no transfer is in flight. Sync accuracy is unaffected
 * -- awdl_sync_* still tracks the elected master; this only decides which
 * availability windows we try to be present for.
 */
static struct awdl_peer *awdl_chanseq_source(struct awdl_state *awdl, uint64_t now, int *from_data) {
	struct awdl_peer *peer, *best = NULL, *master;
	awdl_peers_it_t it;

	*from_data = 0;

	it = awdl_peers_it_new(awdl->peers.peers);
	while (awdl_peers_it_next(it, &peer) == PEERS_OK) {
		if (!peer->has_sequence || !peer->last_data_rx)
			continue;
		if (now - peer->last_data_rx > AWDL_DATA_PEER_TIMEOUT_US)
			continue;
		if (!best || peer->last_data_rx > best->last_data_rx)
			best = peer;
	}
	awdl_peers_it_free(it);

	if (best) {
		*from_data = 1;
		return best;
	}

	/* No active transfer: fall back to the elected sync master. */
	if (awdl_peer_get(awdl->peers.peers, &awdl->election.sync_addr, &master) < 0)
		return NULL;
	return master->has_sequence ? master : NULL;
}

/*
 * Adopt a peer's channel sequence so that we are on-channel during its
 * availability windows. Reverts to our own static sequence when we are our own
 * sync master and nobody is sending us data.
 *
 * The peer's sequence is stored as raw TLV bytes, so its encoding must be
 * adopted along with it -- decoding those bytes with a different encoding
 * yields plausible-looking but wrong channel numbers.
 */
static void awdl_adopt_chanseq(struct daemon_state *state) {
	struct awdl_state *awdl = &state->awdl_state;
	struct awdl_peer *src;
	uint64_t now = clock_time_us();
	int from_data;

	src = awdl_chanseq_source(awdl, now, &from_data);

	/* Only revert to the static sequence when there is also no data peer --
	 * being our own sync master says nothing about whether a transfer is in
	 * flight, and dropping the peer's sequence mid-transfer is exactly the
	 * stall we are trying to avoid. */
	if (!src) {
		if (awdl_election_is_sync_master(&awdl->election, &awdl->self_address) &&
		    awdl->channel.sequence_from_peer) {
			log_info("no sync master or data peer, reverting to static channel sequence");
			awdl_chanseq_init_static(awdl->channel.sequence, &awdl->channel.master);
			awdl->channel.enc = AWDL_CHAN_ENC_OPCLASS;
			awdl->channel.sequence_from_peer = 0;
		}
		return;
	}

	if (awdl->channel.enc != src->sequence_enc ||
	    memcmp(awdl->channel.sequence, src->sequence, sizeof(src->sequence))) {
		awdl->channel.enc = src->sequence_enc;
		memcpy(awdl->channel.sequence, src->sequence, sizeof(src->sequence));
		awdl->channel.sequence_from_peer = 1;
		log_info("following channel sequence of %s %s (%s), enc %d",
		         from_data ? "data peer" : "sync master",
		         ether_ntoa(&src->addr), src->name, src->sequence_enc);
	}
}

void awdl_clean_peers(struct ev_loop *loop, ev_timer *timer, int revents) {
	(void) loop;
	(void) revents; /* should always be EV_TIMER */
	uint64_t cutoff_time;
	struct daemon_state *state;

	state = (struct daemon_state *) timer->data;
	cutoff_time = clock_time_us() - state->awdl_state.peers.timeout;

	awdl_peers_remove(state->awdl_state.peers.peers, cutoff_time,
	                  state->awdl_state.peer_remove_cb, state->awdl_state.peer_remove_cb_data);

	/* TODO for now run election immediately after clean up; might consider seperate timer for this */
	awdl_election_run(&state->awdl_state.election, &state->awdl_state.peers);

	awdl_adopt_chanseq(state);

	ev_timer_again(loop, timer);
}

void awdl_print_stats(struct ev_loop *loop, ev_signal *handle, int revents) {
	(void) loop;
	(void) revents; /* should always be EV_TIMER */
	struct awdl_stats *stats = &((struct daemon_state *) handle->data)->awdl_state.stats;

	log_info("STATISTICS");
	log_info(" TX action %llu, data %llu, unicast %llu, multicast %llu",
	         stats->tx_action, stats->tx_data, stats->tx_data_unicast, stats->tx_data_multicast);
	log_info(" RX action %llu, data %llu, unknown %llu",
	         stats->rx_action, stats->rx_data, stats->rx_unknown);
}

int awdl_init(struct daemon_state *state, const char *wlan, const char *host, struct awdl_chan chan, const char *dump) {
	int err;
	char hostname[HOST_NAME_LENGTH_MAX + 1];

	err = netutils_init();
	if (err < 0)
		return err;

	err = io_state_init(&state->io, wlan, host, &AWDL_BSSID);
	if (err < 0)
		return err;

	err = get_hostname(hostname, sizeof(hostname));
	if (err < 0)
		return err;

	awdl_init_state(&state->awdl_state, hostname, &state->io.if_ether_addr, chan, clock_time_us());
	state->awdl_state.peer_cb = awdl_neighbor_add;
	state->awdl_state.peer_cb_data = (void *) &state->io;
	state->awdl_state.peer_remove_cb = awdl_neighbor_remove;
	state->awdl_state.peer_remove_cb_data = (void *) &state->io;
	ieee80211_init_state(&state->ieee80211_state);

	state->next = NULL;
	state->tx_queue_multicast = circular_buf_init(16);
	state->dump = dump;

	return 0;
}

void awdl_free(struct daemon_state *state) {
	circular_buf_free(state->tx_queue_multicast);
	io_state_free(&state->io);
	netutils_cleanup();
}

void awdl_schedule(struct ev_loop *loop, struct daemon_state *state) {

	state->ev_state.loop = loop;

	/* Timer for channel switching */
	state->ev_state.chan_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.chan_timer, awdl_switch_channel, 0, 0);
	ev_timer_start(loop, &state->ev_state.chan_timer);

	/* Timer for peer table cleanup */
	state->ev_state.peer_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.peer_timer, awdl_clean_peers, 0, usec_to_sec(state->awdl_state.peers.clean_interval));
	ev_timer_again(loop, &state->ev_state.peer_timer);

	/* Trigger frame reception from WLAN device */
	state->ev_state.read_wlan.data = (void *) state;
	ev_io_init(&state->ev_state.read_wlan, wlan_device_ready, state->io.wlan_fd, EV_READ);
	ev_io_start(loop, &state->ev_state.read_wlan);

	/* Trigger frame reception from host device */
	state->ev_state.read_host.data = (void *) state;
	ev_io_init(&state->ev_state.read_host, host_device_ready, state->io.host_fd, EV_READ);
	ev_io_start(loop, &state->ev_state.read_host);

	/* Timer for PSFs */
	state->ev_state.psf_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.psf_timer, awdl_send_psf,
	              usec_to_sec(ieee80211_tu_to_usec(state->awdl_state.psf_interval)),
	              usec_to_sec(ieee80211_tu_to_usec(state->awdl_state.psf_interval)));
	ev_timer_start(loop, &state->ev_state.psf_timer);

	/* Timer for MIFs */
	state->ev_state.mif_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.mif_timer, awdl_send_mif, 0, 0);
	ev_timer_start(loop, &state->ev_state.mif_timer);

	/* Timer for unicast packets */
	state->ev_state.tx_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.tx_timer, awdl_send_unicast, 0, 0);
	ev_timer_start(loop, &state->ev_state.tx_timer);

	/* Timer for multicast packets */
	state->ev_state.tx_mcast_timer.data = (void *) state;
	ev_timer_init(&state->ev_state.tx_mcast_timer, awdl_send_multicast, 0, 0);
	ev_timer_start(loop, &state->ev_state.tx_mcast_timer);

	/* Register signal to print statistics */
	state->ev_state.stats.data = (void *) state;
	ev_signal_init(&state->ev_state.stats, awdl_print_stats, SIGSTATS);
	ev_signal_start(loop, &state->ev_state.stats);
}
