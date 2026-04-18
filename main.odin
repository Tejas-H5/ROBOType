package main

// Typing practice program. I've tried a bunch of them over the years, none of them 
// handle mistakes very well - I think that the input field should be very similar to a
// regular text field you would interact with in an OS text box, and your goal is to just
// make the curent text match the target text using all the same facilities that an OS 
// textfield would give you.
// 
// This idea, pushed to it's logical limit, would result in a series of examples, 
// with online leaderboards showing how quickly someone was able to complete it. 
// We can finally figure out is Vim is truly a better input mechanism xD

import "core:math"
import "core:math/linalg"
import "core:unicode"
import "core:c"
import rl "vendor:raylib"

COLOR_BG        :: Color{ 255, 255, 255, 255 }
COLOR_FG        :: Color{ 0, 0, 0, 255 }
COLOR_HIGHLIGHT :: Color{ 0, 120, 215, 255 }

main :: proc() {
	rl.InitWindow(0, 0, "RoboType")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	rl.SetExitKey(.KEY_NULL)

	set_logging_type(.Fmt)

	defer rl.CloseWindow()

	state := new_game_state()

	for !rl.WindowShouldClose() && !state.requested_quit {
		state.size.x = f32(rl.GetScreenWidth())
		state.size.y = f32(rl.GetScreenHeight())
		state.dt     = rl.GetFrameTime();

		rl.BeginDrawing(); {
			run_game(state)
		} rl.EndDrawing();
	}
}

State :: struct {
	requested_quit : bool,
	size           : Vec2,
	dt             : f32,

	typed      : [dynamic]byte,
	range      : SelectionRange,
	blink_time : f32,

	// TODO: clipboard, undo, find out the remaining features.
	// Not really necessary for a

	offset_smooth : Vec2,
	start_caret_at, end_caret_at : Vec2,
	is_animated                  : bool,
}

SelectionRange :: struct { start, end: int }

new_game_state :: proc() -> ^State {
	state := new(State)
	
	return state
}

Color :: rl.Color
Vec2  :: rl.Vector2
Font  :: rl.Font

delete_selected :: proc(state: ^State) -> bool {
	if state.range.start == state.range.end  {return false}

	lo, hi := get_lo_hi(state.range)
	remove_range(&state.typed, lo, hi)

	state.range.end   = lo
	state.range.start = state.range.end

	return true
}

get_lo_hi :: proc(range: SelectionRange) -> (int, int) {
	lo := math.min(range.end, range.start)
	hi := math.max(range.end, range.start)
	return lo, hi
}

run_game :: proc(state: ^State) {
	// Input
	{
		if state.requested_quit {return;}
		if rl.IsKeyPressed(.ESCAPE) {
			state.requested_quit = true
			return;
		}

		// TODO: VIM bindings support

		is_range_selecting := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		is_moving_by_word  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		remove_last_word := is_moving_by_word && rl.IsKeyPressed(.W)

		prev_end := state.range.end
		prev_len := len(state.typed)

		if rlIsKeyPressedOrRepeated(.LEFT) {
			if is_moving_by_word {
				state.range.end = move_cursor_prev_boundary(state.range.end, state.typed[:])
			} else {
				state.range.end -= 1
				if state.range.end < 0 { state.range.end = 0 }
			}
		}

		if rlIsKeyPressedOrRepeated(.RIGHT) {
			if is_moving_by_word {
				state.range.end = move_cursor_next_boundary(state.range.end, state.typed[:])
			} else {
				state.range.end += 1
				n := len(state.typed)
				if state.range.end > n { state.range.end = n }
			}
		}

		if rlIsKeyPressedOrRepeated(.HOME) { state.range.end = 0 }
		if rlIsKeyPressedOrRepeated(.END) { state.range.end = len(state.typed) }

		if rlIsKeyPressedOrRepeated(.BACKSPACE) || remove_last_word {
			if !delete_selected(state) {
				if is_moving_by_word {
					lo := move_cursor_prev_boundary(state.range.end, state.typed[:])
					if lo != state.range.end {
						remove_range(&state.typed, lo, state.range.end)
						state.range.end = lo
						state.range.start = state.range.end
					}
				} else {
					ordered_remove(&state.typed, state.range.end - 1)
					state.range.end -= 1
					state.range.start = state.range.end
				}
			}
		}

		if rlIsKeyPressedOrRepeated(.DELETE) {
			if !delete_selected(state) {
				if is_moving_by_word {
					hi := move_cursor_next_boundary(state.range.end, state.typed[:])
					if hi != state.range.end {
						remove_range(&state.typed, state.range.end, hi)
						state.range.start = state.range.end
					}
				} else {
					ordered_remove(&state.typed, state.range.end)
				}
			}
		}

		if !remove_last_word {
			for {
				c := rl.GetCharPressed()
				if c == 0 {break}

				delete_selected(state)

				inject_at(&state.typed, state.range.end, byte(c))
				state.range.end   += 1
				state.range.start = state.range.end
			}
		}

		mutated := prev_len != len(state.typed)
		selection_changed := state.range.end != prev_end

		if mutated || selection_changed {
			// NOTE: this only applies to horizontal movement 
			// I've recently decided to not have horizontal movement, but yet to fully commit. I'll remove this later
			// state.is_animated = !mutated
			state.is_animated = true
			state.blink_time  = 0
		}

		if selection_changed {
			if !is_range_selecting {
				state.range.start = state.range.end
			}
		}
	}

	rl.ClearBackground(COLOR_BG)

	window_size := state.size
	dt          := state.dt

	center       := window_size / 2
	font_size    := window_size.y * 0.07
	spacing      := font_size / 10
	vertical_spacing := font_size / 5
	cursor_start := Vec2{ spacing, spacing }
	character_width := f32(rl.MeasureText("w", c.int(font_size)))


	// This is the size we need for the cursor to mathematically fit between the letters without
	// touching the letters and also distribute the spacing nicely
	cursor_width   := spacing / 2
	cursor_padding := (spacing - cursor_width) / 2

	state.blink_time += dt

	start_caret_at, end_caret_at : Vec2
	for phase in UI_PHASES { 
		cursor := cursor_start
		if phase == .Draw {
			// TODO: camera offset
			cursor -= state.offset_smooth
		}

		set_start, set_end : bool
		for char, idx in state.typed {
			if idx == state.range.start {
				start_caret_at, set_start = cursor, true
			}
			if idx == state.range.end {
				end_caret_at, set_end = cursor, true
			}

			width := draw_text(.Measure, cursor, font_size, COLOR_BG, "%c", char)
			if cursor.x + width > window_size.x {
				// Wrap the text
				cursor.x = 0
				cursor.y += font_size + vertical_spacing
			}
			if phase == .Draw {
				lo, hi := get_lo_hi(state.range)
				is_highlighted := lo <= idx && idx < hi

				if is_highlighted {
					rl.DrawRectangleV(cursor - {spacing / 2, vertical_spacing / 2}, {width + spacing, font_size + vertical_spacing}, COLOR_HIGHLIGHT)
					draw_text(.Draw, cursor, font_size, COLOR_BG, "%c", char)
				} else {
					draw_text(.Draw, cursor, font_size, COLOR_FG, "%c", char)
				}
			}
			cursor.x += width + spacing
		}

		if !set_start { start_caret_at = cursor }
		if !set_end   { end_caret_at = cursor }

		if phase == .Measure {
			// Make sure that the 'camera' starts at this character.
			start := -start_caret_at + 6 * (character_width + spacing)
			end   := -end_caret_at   + 6 * (character_width + spacing)

			offset : Vec2
			point_where_we_should_start_scrolling := window_size.y - 3 * font_size
			if end_caret_at.y > point_where_we_should_start_scrolling {
				offset.y = end_caret_at.y - point_where_we_should_start_scrolling
			}

			if state.is_animated {
				t := 50 * dt
				state.offset_smooth = linalg.lerp(state.offset_smooth, offset, t)
			} else {
				state.offset_smooth = offset
			}
		}
	}
	state.start_caret_at = start_caret_at
	state.end_caret_at = end_caret_at

	BLINK_TIME :: 1.0
	if state.blink_time > BLINK_TIME {
		state.blink_time -= BLINK_TIME
	}

	if state.blink_time < BLINK_TIME / 2 {
		rl.DrawRectangleV({ end_caret_at.x + cursor_padding - spacing, end_caret_at.y }, { cursor_width, font_size }, COLOR_FG)
	}
}



LetterType :: enum {
	Whitespace,
	Letter,
	Punctuation,
}

get_letter_type :: proc(text: []byte, pos: int) -> LetterType {
	if pos >= len(text) {return .Whitespace}

	r := rune(text[pos])
	if unicode.is_punct(r) {return .Punctuation}
	if unicode.is_letter(r) {return .Letter}

	return .Whitespace
}

move_cursor_prev_boundary :: proc(pos: int, text: []byte) -> int {
	if pos == 0 {return 0}

	pos := pos
	n   := len(text)

	initial_type := get_letter_type(text, pos - 1)

	for pos > 0 && get_letter_type(text, pos - 1) == initial_type {
		pos -= 1
	}

	return pos
}

move_cursor_next_boundary :: proc(pos: int, text: []byte) -> int {
	n := len(text)
	initial_type := get_letter_type(text, pos)

	pos := pos
	for pos < n && get_letter_type(text, pos) == initial_type {
		pos += 1
	}

	return pos
}

UiPhase :: enum {
	Measure,
	Draw,
}

UI_PHASES :: []UiPhase { .Measure, .Draw }

draw_text :: proc(phase: UiPhase, cursor: Vec2, font_size: f32, color: Color, fmt: cstring, args: ..any) -> f32 {
	text  := rl.TextFormat(fmt, ..args)
	width := rl.MeasureText(text, c.int(font_size))
	if phase == .Draw {
		rl.DrawText(text, c.int(cursor.x), c.int(cursor.y), c.int(font_size), color)
	}
	return f32(width)
}

rlIsKeyPressedOrRepeated :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key);
}

