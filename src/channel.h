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

#ifndef AWDL_CHANNEL_H_
#define AWDL_CHANNEL_H_

#include <stdint.h>

#define AWDL_CHANSEQ_LENGTH 16

enum awdl_chan_encoding {
	AWDL_CHAN_ENC_SIMPLE = 0,
	AWDL_CHAN_ENC_LEGACY = 1,
	AWDL_CHAN_ENC_OPCLASS = 3,
};

struct awdl_chan {
	union {
		uint8_t val[2];
		struct {
			uint8_t chan_num;
		} simple;
		struct {
			uint8_t flags;
			uint8_t chan_num;
		} legacy;
		struct {
			uint8_t chan_num;
			uint8_t opclass;
		} opclass;
	};
};

#define CHAN_NULL (struct awdl_chan) { { { 0, 0x00 } } }
#define CHAN_OPCLASS_6 (struct awdl_chan) { { { 6, 0x51 } } }
/* 36 is a social channel Apple devices actually favour - an iPhone was observed
 * advertising 36 in 6 of 16 slots against only 2 on 149. Same 5 GHz opclass as
 * 44 and 149. */
#define CHAN_OPCLASS_36 (struct awdl_chan) { { { 36, 0x80 } } }
#define CHAN_OPCLASS_44 (struct awdl_chan) { { { 44, 0x80 } } }
#define CHAN_OPCLASS_149 (struct awdl_chan) { { { 149, 0x80 } } }

uint8_t awdl_chan_num(struct awdl_chan chan, enum awdl_chan_encoding);

int awdl_chan_encoding_size(enum awdl_chan_encoding);

struct awdl_channel_state {
	enum awdl_chan_encoding enc;
	struct awdl_chan sequence[AWDL_CHANSEQ_LENGTH];
	struct awdl_chan master;
	struct awdl_chan current;
	/* 0: 'sequence' is our own static sequence built from 'master'.
	 * 1: 'sequence' was inherited from the elected sync master peer. */
	uint8_t sequence_from_peer;
};

void awdl_chanseq_init(struct awdl_chan *seq);

void awdl_chanseq_init_idle(struct awdl_chan *seq);

void awdl_chanseq_init_static(struct awdl_chan *seq, const struct awdl_chan *chan);

#endif /* AWDL_CHANNEL_H_ */
