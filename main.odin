package main

import "core:slice"
import "core:strings"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:unicode"
import "core:c"
import rl "vendor:raylib"


// Typing practice program. I've tried a bunch of them over the years, none of them 
// handle mistakes very well - I think that the input field should be very similar to a
// regular text field you would interact with in an OS text box, and your goal is to just
// make the curent text match the target text using all the same facilities that an OS 
// textfield would give you.
// 
// This idea, pushed to it's logical limit, would result in a series of examples, 
// with online leaderboards showing how quickly someone was able to complete it. 
// We can finally figure out is Vim is truly a better input mechanism xD


State :: struct {
	requested_quit : bool,
	size           : Vec2,
	dt             : f32,

	// NOTE: make sure that the font is monospace, so that we can display the
	// target letter right above what was actually typed, without any letter spacing issues
	typed      : [dynamic]byte,
	range      : SelectionRange,
	blink_time : f32,

	// TODO: clipboard, undo, find out the remaining features.
	// Not really necessary for a

	offset_smooth : Vec2,
	start_caret_at, end_caret_at : Vec2,
	is_animated                  : bool,

	available_samples : [dynamic]Sample,
	current_sample    : ^Sample,

	error : string,
}

Sample :: struct {
	name: string,
	text: []byte,
}

SelectionRange :: struct { start, end: int }


COLOR_BG        :: Color{ 255, 255, 255, 255 }
COLOR_FG        :: Color{ 0, 0, 0, 255 }
COLOR_TARGET    :: Color{ 125, 125, 125, 255 }
COLOR_HIGHLIGHT :: Color{ 0, 120, 215, 255 }
COLOR_WRONG     :: Color{ 255, 125, 125, 255 }
COLOR_RED        :: Color{ 255, 0, 0, 255 }

last_monitor : c.int

main :: proc() {
	rl.InitWindow(0, 0, "RoboType")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	rl.SetExitKey(.KEY_NULL)

	last_monitor = -1

	set_logging_type(.Fmt)

	defer rl.CloseWindow()

	state := load_game_state()

	for !rl.WindowShouldClose() && !state.requested_quit {
		monitor := rl.GetCurrentMonitor()
		if last_monitor != monitor {
			last_monitor = monitor
			rl.SetTargetFPS(rl.GetMonitorRefreshRate(monitor))
		}

		state.size.x = f32(rl.GetScreenWidth())
		state.size.y = f32(rl.GetScreenHeight())
		state.dt     = rl.GetFrameTime();

		rl.BeginDrawing(); {
			run_game(state)
		} rl.EndDrawing();
	}
}


load_game_state :: proc() -> (state: ^State) {
	state = new(State)

	defer free_all(context.temp_allocator)

	files, err := os.read_all_directory_by_path("./text", context.temp_allocator)
	if err != nil {
		delete(state.error)
		state.error = fmt.aprintf("Couldn't open the text folder: %v", err)
		return
	}

	sb := make([dynamic]byte)
	defer delete(sb)

	for file in files {
		text, err := os.read_entire_file_from_path(file.fullpath, context.temp_allocator)
		assert(err == nil)

		clear(&sb)

		text_str := string(text)
		for line in strings.split_lines_iterator(&text_str) {
			line_trimmed := transmute([]byte)strings.trim_space(line)
			if len(line_trimmed) == 0 {continue}

			for b in line_trimmed {
				type := get_letter_type(b)
				if type == .Other {continue}

				append(&sb, b)
			}

			append(&sb, '\n')
		}

		sample := Sample {
			name = strings.clone(file.name),
			text = slice.clone(sb[:]),
		}

		append(&state.available_samples, sample)
	}

	debug_log("%v sample loaded", len(state.available_samples), type=.Logger)

	if len(state.available_samples) > 0 {
		state.current_sample = &state.available_samples[0];
		debug_log("current sample: %v", state.current_sample.name, type=.Logger)
	}

	return
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

		// TODO: Moving up and down lines! (hard feature)
		// TODO: Tab
		// TODO: VIM bindings support

		is_range_selecting := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		is_moving_by_word  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		remove_last_word := is_moving_by_word && rlIsKeyPressedOrRepeated(.W)

		prev_end := state.range.end
		prev_len := len(state.typed)

		if rlIsKeyPressedOrRepeated(.LEFT) {
			if is_moving_by_word {
				new_pos := move_cursor_prev_boundary(state.range.end, state.typed[:])
				set_cursor_pos(state, new_pos, is_range_selecting)
			} else {
				new_pos := state.range.end - 1
				set_cursor_pos(state, new_pos, is_range_selecting)
			}
		}

		if rlIsKeyPressedOrRepeated(.RIGHT) {
			if is_moving_by_word {
				new_pos := move_cursor_next_boundary(state.range.end, state.typed[:])
				set_cursor_pos(state, new_pos, is_range_selecting)
			} else {
				new_pos := state.range.end + 1
				set_cursor_pos(state, new_pos, is_range_selecting)
			}
		}

		if rlIsKeyPressedOrRepeated(.HOME) {
			pos := state.range.end
			for pos > 0 && char_at(state.typed[:], pos - 1) != '\n' {
				pos -= 1
			}

			set_cursor_pos(state, pos, is_range_selecting)
		}
		if rlIsKeyPressedOrRepeated(.END) { 
			pos := state.range.end
			n := len(state.typed)
			for pos < n && char_at(state.typed[:], pos) != '\n' {
				pos += 1
			}

			set_cursor_pos(state, pos, is_range_selecting)
		}

		if rlIsKeyPressedOrRepeated(.BACKSPACE) || remove_last_word {
			if !delete_selected(state) {
				if is_moving_by_word {
					lo := move_cursor_prev_boundary(state.range.end, state.typed[:])
					if lo != state.range.end {
						remove_range(&state.typed, lo, state.range.end)
						set_cursor_pos(state, lo, false)
					}
				} else {
					if state.range.end > 0 {
						ordered_remove(&state.typed, state.range.end - 1)
						set_cursor_pos(state, state.range.end - 1, false)
					}
				}
			}
		}

		if rlIsKeyPressedOrRepeated(.DELETE) {
			if !delete_selected(state) {
				if is_moving_by_word {
					hi := move_cursor_next_boundary(state.range.end, state.typed[:])
					if hi != state.range.end {
						remove_range(&state.typed, state.range.end, hi)
						set_cursor_pos(state, state.range.end, false)
					}
				} else {
					ordered_remove(&state.typed, state.range.end)
				}
			}
		}

		// The keyboard shortcut to remove the last word involves 'W', and we dont want to type a W.
		if !remove_last_word {
			for {
				c := rl.GetCharPressed()
				if c == 0 {break}

				type_char(state, c)
			}
		}

		if rlIsKeyPressedOrRepeated(.ENTER) {
			type_char(state, '\n')
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
	}

	rl.ClearBackground(COLOR_BG)

	window_size := state.size
	dt          := state.dt

	center       := window_size / 2
	font_size    := window_size.y * 0.05
	spacing      := font_size / 10
	row_offset   := Vec2{0, font_size + spacing}
	vertical_spacing := font_size / 5
	cursor_start := Vec2{ spacing, spacing }
	character_width := f32(rl.MeasureText("w", c.int(font_size)))


	// This is the size we need for the cursor to mathematically fit between the letters without
	// touching the letters and also distribute the spacing nicely
	cursor_width   := spacing / 2
	cursor_padding := (spacing - cursor_width) / 2

	state.blink_time += dt

	chars_to_draw := math.max(len(state.typed), len(state.current_sample.text))

	start_caret_at, end_caret_at : Vec2
	for phase in UI_PHASES { 
		cursor := cursor_start
		if phase == .Draw {
			// TODO: camera offset
			cursor -= state.offset_smooth
		}

		set_start, set_end : bool
		for idx in 0..<chars_to_draw {
			char, has_char          := char_ok(state.typed[:], idx)
			target_char, has_target := char_ok(state.current_sample.text, idx)

			target_is_newline := target_char == '\n'
			is_newline        := char == '\n'

			if idx == state.range.start {
				start_caret_at, set_start = cursor + row_offset, true
			}
			if idx == state.range.end {
				end_caret_at, set_end = cursor + row_offset, true
			}

			NEWLINE_STR :: "\\n"

			width : f32
			if target_is_newline || is_newline {
				width = draw_text(.Measure, {}, font_size, COLOR_FG, "%v", NEWLINE_STR)
			} else {
				target_width := draw_text(.Measure, cursor, font_size, COLOR_BG, "%c", target_char)
				char_width   := !has_char ? target_width : draw_text(.Measure, cursor, font_size, COLOR_BG, "%c", char)
				width        = math.max(char_width, target_width)
			}

			if cursor.x + width > window_size.x {
				// Wrap the text. Need to do it here, when we know the size of the char.
				cursor.x = cursor_start.x
				cursor.y += 2 * (font_size + vertical_spacing)
			}

			if phase == .Draw {
				is_wrong := has_char && has_target && target_char != char
				lo, hi         := get_lo_hi(state.range)
				is_highlighted := lo <= idx && idx < hi

				// Target text
				{
					text_col := COLOR_TARGET
					if is_wrong {
						text_col = COLOR_BG
					}

					if is_wrong {
						draw_letter_highlight(cursor, width, spacing, vertical_spacing, font_size, COLOR_WRONG)
					}

					if target_is_newline {
						if is_wrong {
							draw_text(.Draw, cursor, font_size, text_col, NEWLINE_STR)
						}
					} else {
						draw_text(.Draw, cursor, font_size, text_col, "%c", target_char)
					}
				}

				// Typed text
				{
					cursor := cursor + row_offset

					text_col := COLOR_FG
					if is_highlighted {
						text_col = COLOR_BG
					}

					if is_highlighted {
						draw_letter_highlight(cursor, width, spacing, vertical_spacing, font_size, COLOR_HIGHLIGHT)
					}

					if is_newline {
						if is_wrong {
							draw_text(.Draw, cursor, font_size, text_col, NEWLINE_STR)
						}
					} else {
						draw_text(.Draw, cursor, font_size, text_col, "%c", char)
					}
				}

			}

			cursor.x += width + spacing
			if target_is_newline {
				// Start a new line (needs to be done _after_ rendering the newline
				cursor.x = cursor_start.x
				cursor.y += 2 * (font_size + vertical_spacing)
			}
		}

		if !set_start { start_caret_at = cursor + row_offset }
		if !set_end   { end_caret_at = cursor + row_offset }

		if phase == .Measure {
			// Make sure that the 'camera' starts at this character.
			start := -start_caret_at + 6 * (character_width + spacing)
			end   := -end_caret_at   + 6 * (character_width + spacing)

			offset : Vec2
			point_where_we_should_start_scrolling := 2 * (2 * font_size)
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

	// Status line
	{
		font_size         := font_size / 1.5
		vertical_spacing  := font_size / 5
		spacing           := font_size / 10
		statusline_height := font_size + vertical_spacing
		top_corner        := Vec2{spacing, window_size.y} - {0, statusline_height}
		cursor            := top_corner + {0, vertical_spacing / 2}

		rl.DrawRectangleV(top_corner, {window_size.x, statusline_height}, COLOR_BG)

		if state.current_sample != nil {
			cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, "%v", state.current_sample.name)
		} else {
			cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, "%v", "None")
		}

		cursor.x += font_size // NOTE: font_size is a vertical unit, so it's strange to use it horizontally. it'll do for now
	}
}



LetterType :: enum {
	Other,
	Whitespace,
	Newline,
	Letter,
	Punctuation,
}

get_letter_type :: proc(b: byte) -> LetterType {
	r := rune(b)

	if r == '\n' {return .Newline}
	if r == ' '  {return .Whitespace }

	if unicode.is_punct(r)  {return .Punctuation}
	if unicode.is_letter(r) {return .Letter}

	return .Other
}


move_cursor_prev_boundary :: proc(pos: int, text: []byte) -> int {
	if pos == 0 {return 0}

	pos := pos
	n   := len(text)

	initial_type := LetterType.Whitespace

	for pos > 0 && (initial_type == .Whitespace || initial_type == .Newline) {
		initial_type = get_letter_type(char_at(text, pos - 1))
		for pos > 0 && get_letter_type(char_at(text, pos - 1)) == initial_type {
			pos -= 1
		}
	}

	return pos
}

move_cursor_next_boundary :: proc(pos: int, text: []byte) -> int {
	n := len(text)
	initial_type := get_letter_type(char_at(text, pos))

	pos := pos
	for pos < n && get_letter_type(char_at(text, pos)) == initial_type {
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

char_at :: proc(text: []byte, idx: int) -> byte {
	char, _ := char_ok(text, idx)
	return char
}

char_ok :: proc(text: []byte, idx: int) -> (byte, bool) {
	if idx < 0 || idx >= len(text) { return ' ', false }
	return text[idx], true
}

type_char :: proc(state: ^State, c: rune) {
	delete_selected(state)

	inject_at(&state.typed, state.range.end, byte(c))
	set_cursor_pos(state, state.range.end + 1, false)
}

set_cursor_pos :: proc(state: ^State, pos: int, is_range_selecting: bool) {
	pos := math.clamp(pos, 0, len(state.typed))
	state.range.end = pos
	if !is_range_selecting {
		state.range.start = pos
	}
}

draw_letter_highlight :: proc(cursor: Vec2, width, spacing, vertical_spacing, font_size: f32, color: Color) {
	rl.DrawRectangleV(
		cursor - {spacing / 2, vertical_spacing / 2},
		{width + spacing, font_size + vertical_spacing},
		color,
	)
}

