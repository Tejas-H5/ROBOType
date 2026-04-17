package main

import "core:testing"

@(test)
test_move_cursor :: proc(t: ^testing.T) {
	to_bytes :: proc(str: string) -> []u8 {
		return transmute([]u8)(str)
	}

	run_case :: proc(t: ^testing.T, text: string, pos, expect_next, expect_prev: int, loc := #caller_location) {
		testing.expect_value(t, move_cursor_next_boundary(pos, to_bytes(text)), expect_next, loc=loc)
		testing.expect_value(t, move_cursor_prev_boundary(pos, to_bytes(text)), expect_prev, loc=loc)
	}

	// NOTE: Different platforms, and different UIs/Terminals/IDEs/Programs on the same platform will 
	// move the cursor around differently. This is just the simplest

	run_case(t, "a", 0, expect_next = 1, expect_prev = 0)
	run_case(t, "ab", 0, expect_next = 2, expect_prev = 0)

	run_case(t, "a b", 0, expect_next = 1, expect_prev = 0)
	run_case(t, "a b", 1, expect_next = 2, expect_prev = 0)
	run_case(t, "a b", 2, expect_next = 3, expect_prev = 1)
	run_case(t, "a b", 3, expect_next = 3, expect_prev = 2)

	run_case(t, "a bc", 0, expect_next = 1, expect_prev = 0)
	run_case(t, "a bc", 1, expect_next = 2, expect_prev = 0)
	run_case(t, "a bc", 2, expect_next = 4, expect_prev = 1)
	run_case(t, "a bc", 3, expect_next = 4, expect_prev = 2)
	run_case(t, "a bc", 4, expect_next = 4, expect_prev = 2)

	run_case(t, "ab c", 0, expect_next = 2, expect_prev = 0)
	run_case(t, "ab c", 1, expect_next = 2, expect_prev = 0)
	run_case(t, "ab c", 2, expect_next = 3, expect_prev = 0)
	run_case(t, "ab c", 3, expect_next = 4, expect_prev = 2)
	run_case(t, "ab c", 4, expect_next = 4, expect_prev = 3)
}
