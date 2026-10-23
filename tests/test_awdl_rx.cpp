/*
 * OWL: an open Apple Wireless Direct Link (AWDL) implementation
 * Copyright (C) 2018  The Open Wireless Link Project (https://owlink.org)
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

extern "C" {
#include "rx.h"
#include "state.h"
#include "peers.h"
#include "wire.h"
}

#include <vector>

#include "gtest/gtest.h"

#define OUT_SLOTS 16

/* A-MSDU subframe header (14) + LLC/SNAP (8) + AWDL data header (8) = 30, padded to 32 */
static std::vector<uint8_t> amsdu(int subframes, const struct ether_addr *src) {
	static const uint8_t payload[] = {
		0xaa, 0xaa, 0x03, 0x00, 0x17, 0xf2, 0x08, 0x00, /* LLC/SNAP, AWDL OUI, PID 0x0800 */
		0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x86, 0xdd, /* AWDL data header, IPv6 */
	};
	std::vector<uint8_t> f;
	for (int i = 0; i < subframes; i++) {
		f.insert(f.end(), 6, 0xff);                                     /* dst */
		f.insert(f.end(), src->ether_addr_octet, src->ether_addr_octet + 6);
		f.push_back(0);
		f.push_back(sizeof(payload));                                   /* length (BE) */
		f.insert(f.end(), payload, payload + sizeof(payload));
		if (i < subframes - 1)
			f.insert(f.end(), 2, 0);                                    /* pad 30 -> 32 */
	}
	return f;
}

class AmsduRx : public ::testing::Test {
  protected:
	struct awdl_state state;
	struct ether_addr paddr = {{0x3a, 0xdd, 0x74, 0x15, 0x95, 0x5c}};
	/* one extra slot past the end, so an overrun is visible instead of corrupting the stack */
	struct buf *slots[OUT_SLOTS + 1];
	struct buf *const canary = (struct buf *) 0x1;

	void SetUp() override {
		struct ether_addr self = {{0x4c, 0x82, 0xa9, 0x17, 0x65, 0x27}};
		struct awdl_chan c149 = CHAN_OPCLASS_149;
		awdl_init_state(&state, "void-btw", &self, c149, 0);
		awdl_peer_add(state.peers.peers, &paddr, 0, NULL, NULL);
		slots[OUT_SLOTS] = canary;
	}

	int rx(int subframes, struct buf ***cursor) {
		std::vector<uint8_t> f = amsdu(subframes, &paddr);
		const struct buf *frame = buf_new_const(f.data(), f.size());
		*cursor = &slots[0];
		int err = awdl_rx_data_amsdu(frame, cursor, &slots[OUT_SLOTS], &paddr, &paddr, &state);
		buf_free(frame);
		for (struct buf **p = &slots[0]; p < *cursor; p++)
			buf_free(*p);
		return err;
	}
};

TEST_F(AmsduRx, fills_output_array_exactly) {
	struct buf **cursor;
	EXPECT_EQ(rx(OUT_SLOTS, &cursor), RX_OK);
	EXPECT_EQ(cursor, &slots[OUT_SLOTS]);
	EXPECT_EQ(slots[OUT_SLOTS], canary);
}

TEST_F(AmsduRx, rejects_more_subframes_than_slots) {
	struct buf **cursor;
	EXPECT_EQ(rx(OUT_SLOTS + 1, &cursor), RX_TOO_MANY_FRAMES);
	EXPECT_EQ(cursor, &slots[OUT_SLOTS]);
	EXPECT_EQ(slots[OUT_SLOTS], canary);
}

TEST_F(AmsduRx, rejects_flood_of_subframes) {
	struct buf **cursor;
	EXPECT_EQ(rx(200, &cursor), RX_TOO_MANY_FRAMES);
	EXPECT_EQ(cursor, &slots[OUT_SLOTS]);
	EXPECT_EQ(slots[OUT_SLOTS], canary);
}
