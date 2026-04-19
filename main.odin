package main

import "core:unicode/utf8/utf8string"
import "core:slice"
import "core:strings"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:unicode"
import "core:c"
import rl "vendor:raylib"

View :: enum {
	Collections,
	Samples,
	Typing,
	Completed,
}

State :: struct {
	requested_quit : bool,
	size           : Vec2,
	dt             : f32,

	view: View,

	available_collections : [dynamic]Collection,
	collection_idx        : int,

	available_samples : [dynamic]Sample,
	sample_idx : int,

	typing: TypingState,
}

Collection :: struct {
	name: string,
	fullpath: string,
}

TypingState :: struct {
	sample: ^Sample,

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

	// NOTE: I actually don't care about the number of types I typed the wrong thing - 
	// Really, I just want to minimize the time. If the most optimal typing strategy actually
	// invovles making shittone of mistakes and then editing them later, I don't want to be 
	// penalized for getting one or two letters wrong actually.
	// This is especially the case in the puzzle levels, that will rely heavily on moving the
	// cursor around and copy-pasting stuff. 
	started_time  : f64,
	finished_time : f64,
}

Sample :: struct {
	name: string,
	text: []byte,
}

SelectionRange :: struct { start, end: int }

COLOR_BG        :: Color{ 255, 255, 255, 255 }
COLOR_BG2       :: Color{ 200, 200, 200, 255 }
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

load_available_collections :: proc(state: ^State) {
	files, err := os.read_all_directory_by_path("./collections", context.temp_allocator)
	assert(err == nil)
	defer free_all(context.temp_allocator)

	clear(&state.available_collections)
	for file in files {
		if file.type == .Directory {
			collection := Collection{
				name = strings.clone(file.name),
				fullpath = strings.clone(file.fullpath),
			}
			append(&state.available_collections, collection)
		}
	}
	
	state.collection_idx = 0
}

load_game_state :: proc() -> ^State {
	state := new(State)

	state.view = .Collections

	load_available_collections(state)

	return state
}

load_collection :: proc(state: ^State, collection_path: string) {
	defer free_all(context.temp_allocator)

	files, err := os.read_all_directory_by_path(collection_path, context.temp_allocator)
	assert(err == nil)

	sb := make([dynamic]byte)
	defer delete(sb)

	clear(&state.available_samples)
	for file in files {
		if file.type != .Regular {continue}

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

			remaining_trimmed := strings.trim_right_space(text_str)
			if remaining_trimmed != "" {
				append(&sb, '\n')
			}
		}

		sample := Sample {
			name = strings.clone(file.name),
			text = slice.clone(sb[:]),
		}

		append(&state.available_samples, sample)
	}

	if len(state.available_samples) > 0 {
		state.sample_idx = 0
	}

	return
}

Color :: rl.Color
Vec2  :: rl.Vector2
Font  :: rl.Font

delete_selected :: proc(state: ^TypingState) -> bool {
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
	if state.requested_quit {return;}

	switch state.view {
	case .Collections: run_collection_selector(state)
	case .Samples:     run_sample_selector(state)
	case .Typing:      run_typing(state)
	case .Completed:   run_completed(state)
	}
}

run_typing :: proc(state: ^State) {
	typing := &state.typing

	if typing.sample == nil {return}

	// Input
	{
		// TODO: Moving up and down lines! (hard feature)
		// TODO: Tab
		// TODO: VIM bindings support

		is_range_selecting := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		is_moving_by_word  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		remove_last_word := is_moving_by_word && rlIsKeyPressedOrRepeated(.W)

		prev_end := typing.range.end
		prev_len := len(typing.typed)

		if rlIsKeyPressedOrRepeated(.LEFT) {
			if is_moving_by_word {
				new_pos := move_cursor_prev_boundary(typing.range.end, typing.typed[:])
				set_cursor_pos(typing, new_pos, is_range_selecting)
			} else {
				new_pos := typing.range.end - 1
				set_cursor_pos(typing, new_pos, is_range_selecting)
			}
		}

		if rlIsKeyPressedOrRepeated(.RIGHT) {
			if is_moving_by_word {
				new_pos := move_cursor_next_boundary(typing.range.end, typing.typed[:])
				set_cursor_pos(typing, new_pos, is_range_selecting)
			} else {
				new_pos := typing.range.end + 1
				set_cursor_pos(typing, new_pos, is_range_selecting)
			}
		}

		if rlIsKeyPressedOrRepeated(.HOME) {
			pos := typing.range.end
			for pos > 0 && char_at(typing.typed[:], pos - 1) != '\n' {
				pos -= 1
			}

			set_cursor_pos(typing, pos, is_range_selecting)
		}
		if rlIsKeyPressedOrRepeated(.END) { 
			pos := typing.range.end
			n := len(typing.typed)
			for pos < n && char_at(typing.typed[:], pos) != '\n' {
				pos += 1
			}

			set_cursor_pos(typing, pos, is_range_selecting)
		}

		if rlIsKeyPressedOrRepeated(.BACKSPACE) || remove_last_word {
			if !delete_selected(typing) {
				if is_moving_by_word {
					lo := move_cursor_prev_boundary(typing.range.end, typing.typed[:])
					if lo != typing.range.end {
						remove_range(&typing.typed, lo, typing.range.end)
						set_cursor_pos(typing, lo, false)
					}
				} else {
					if typing.range.end > 0 {
						ordered_remove(&typing.typed, typing.range.end - 1)
						set_cursor_pos(typing, typing.range.end - 1, false)
					}
				}
			}
		}

		if rlIsKeyPressedOrRepeated(.DELETE) {
			if !delete_selected(typing) {
				if is_moving_by_word {
					hi := move_cursor_next_boundary(typing.range.end, typing.typed[:])
					if hi != typing.range.end {
						remove_range(&typing.typed, typing.range.end, hi)
						set_cursor_pos(typing, typing.range.end, false)
					}
				} else {
					ordered_remove(&typing.typed, typing.range.end)
				}
			}
		}

		// The keyboard shortcut to remove the last word involves 'W', and we dont want to type a W.
		if !remove_last_word {
			for {
				c := rl.GetCharPressed()
				if c == 0 {break}

				type_char(typing, c)
			}
		}

		if rlIsKeyPressedOrRepeated(.ENTER) {
			type_char(typing, '\n')
		}

		mutated := prev_len != len(typing.typed)
		selection_changed := typing.range.end != prev_end

		if mutated || selection_changed {
			// NOTE: this only applies to horizontal movement 
			// I've recently decided to not have horizontal movement, but yet to fully commit. I'll remove this later
			// state.is_animated = !mutated
			typing.is_animated = true
			typing.blink_time  = 0
		}

		if mutated {
			if len(typing.typed) == len(typing.sample.text) {
				all_correct := true
				for idx in 0..<len(typing.typed) {
					if typing.typed[idx] != typing.sample.text[idx] {
						all_correct = false
						break;
					}
				}

				if all_correct {
					state.view = .Completed
					typing.finished_time = rl.GetTime()
				}
			}
		}
	}

	rl.ClearBackground(COLOR_BG)

	window_size := state.size
	dt          := state.dt

	center       := window_size / 2
	font_size    := window_size.y * 0.05
	spacing      := font_size / 10
	vertical_spacing := font_size / 5
	row_offset   := Vec2{0, font_size + spacing}
	cursor_start := Vec2{ spacing, spacing }
	character_width := f32(rl.MeasureText("w", c.int(font_size)))


	// This is the size we need for the cursor to mathematically fit between the letters without
	// touching the letters and also distribute the spacing nicely
	cursor_width   := spacing / 2
	cursor_padding := (spacing - cursor_width) / 2

	typing.blink_time += dt

	chars_to_draw := math.max(len(typing.typed), len(typing.sample.text))

	start_caret_at, end_caret_at : Vec2
	for phase in UI_PHASES { 
		cursor := cursor_start
		if phase == .Draw {
			// TODO: camera offset
			cursor -= typing.offset_smooth
		}

		set_start, set_end : bool
		for idx in 0..<chars_to_draw {
			char, has_char          := char_ok(typing.typed[:], idx)
			target_char, has_target := char_ok(typing.sample.text, idx)

			target_is_newline := target_char == '\n'
			is_newline        := char == '\n'

			if idx == typing.range.start {
				start_caret_at, set_start = cursor + row_offset, true
			}
			if idx == typing.range.end {
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
				lo, hi         := get_lo_hi(typing.range)
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

			if typing.is_animated {
				t := 50 * dt
				typing.offset_smooth = linalg.lerp(typing.offset_smooth, offset, t)
			} else {
				typing.offset_smooth = offset
			}
		}
	}
	typing.start_caret_at = start_caret_at
	typing.end_caret_at = end_caret_at

	BLINK_TIME :: 1.0
	if typing.blink_time > BLINK_TIME {
		typing.blink_time -= BLINK_TIME
	}

	if typing.blink_time < BLINK_TIME / 2 {
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

		cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, "%v", typing.sample.name)

		cursor.x += font_size // NOTE: font_size is a vertical unit, so it's strange to use it horizontally. it'll do for now
	}

	switch {
	case rlIsKeyPressedOrRepeated(.ESCAPE): state.view = .Samples
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

	if unicode.is_letter(r) {return .Letter}
	if unicode.is_alpha(r) {return .Letter}

	switch r {
	case '`', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '-', '=', '[', ']', '\\', '{',
		'}', '|', ';', '\'', ':', '"', ',', '.', '/', '<', '>', '?': 
		return .Punctuation
	}

	debug_log("other: %v", r)

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

// Useful when you need to loop over a bunch of rows just to figure out how tall a thing is, so you can center it vertically.
// Do let me know if there is a better way to center UI :)
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

type_char :: proc(state: ^TypingState, c: rune) {
	delete_selected(state)

	inject_at(&state.typed, state.range.end, byte(c))
	set_cursor_pos(state, state.range.end + 1, false)
}

set_cursor_pos :: proc(state: ^TypingState, pos: int, is_range_selecting: bool) {
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

run_collection_selector :: proc(state: ^State) {
	if len(state.available_collections) == 0 { return }

	center    := state.size / 2
	font_size := state.size.y * 0.1
	vertical_spacing  := font_size / 5

	cursor_start := Vec2{ center.x, 10 }

	switch{
	case rlIsKeyPressedOrRepeated(.DOWN): state.collection_idx += 1
	case rlIsKeyPressedOrRepeated(.UP):   state.collection_idx -= 1
	case rlIsKeyPressedOrRepeated(.ENTER): 
		load_collection(state, state.available_collections[state.collection_idx].fullpath)
		state.view = .Samples
	case rlIsKeyPressedOrRepeated(.ESCAPE):
		state.requested_quit = true
	}
	state.collection_idx = math.clamp(state.collection_idx, 0, len(state.available_collections) - 1)

	rl.ClearBackground(COLOR_BG)

	cursor : Vec2
	cursor_selected : Vec2
	for phase in UI_PHASES {
		if phase == .Draw {
			cursor = { cursor_start.x, center.y - cursor_selected.y / 2 - font_size / 2 }
		}

		for &collection, idx in state.available_collections {
			selected := idx == state.collection_idx
			size := draw_centered_label(state, phase, cursor, font_size, collection.name, selected=selected)
			if phase == .Measure && selected {
				cursor_selected = cursor
			}

			cursor += { 0, size.y }
		}
	}

	// Top bar
	top_corner := Vec2{0, 0}
	draw_centered_label(state, .Draw, {state.size.x / 2, 0}, font_size, "Choose a collection")
}

run_sample_selector :: proc(state: ^State) {
	if len(state.available_samples) == 0 { return }

	center    := state.size / 2
	font_size := state.size.y * 0.1
	vertical_spacing  := font_size / 5

	cursor_start := Vec2{ center.x, 10 }

	switch{
	case rlIsKeyPressedOrRepeated(.DOWN): state.sample_idx += 1
	case rlIsKeyPressedOrRepeated(.UP):   state.sample_idx -= 1
	case rlIsKeyPressedOrRepeated(.ENTER): 
		state.view = .Typing
		typing := &state.typing
		typing.sample = &state.available_samples[state.sample_idx]
		typing.started_time = rl.GetTime()
		clear(&typing.typed)
	case rlIsKeyPressedOrRepeated(.ESCAPE):
		state.view = .Collections
	}
	state.sample_idx = math.clamp(state.sample_idx, 0, len(state.available_samples) - 1)

	rl.ClearBackground(COLOR_BG)

	cursor : Vec2
	cursor_selected : Vec2
	for phase in UI_PHASES {
		if phase == .Draw {
			cursor = { cursor_start.x, center.y - cursor_selected.y / 2 - font_size / 2 }
		}

		for &sample, idx in state.available_samples {
			selected := idx == state.sample_idx
			size := draw_centered_label(state, phase, cursor, font_size, sample.name, selected=selected)
			if phase == .Measure && selected {
				cursor_selected = cursor
			}

			cursor += { 0, size.y }
		}
	}

	// Top bar
	top_corner := Vec2{0, 0}
	draw_centered_label(state, .Draw, {state.size.x / 2, 0}, font_size, "Choose a sample")
}

draw_centered_label :: proc(
	state: ^State,
	phase: UiPhase,
	cursor: Vec2,
	font_size: f32,
	name: string,
	selected := false,
	width: f32 = -1
) -> Vec2 {
	width := width
	if width < 0 {
		width = draw_text(.Measure, cursor, font_size, COLOR_FG, "%v", name)
	}

	if selected {
		if phase == .Draw {
			rl.DrawRectangleV(cursor + { -width / 2, 0 }, {width, font_size}, COLOR_BG2)
		}
	}

	if phase == .Draw {
		draw_text(.Draw, cursor + {-width / 2, 0 }, font_size, COLOR_FG, "%v", name)
	}

	return {width, font_size}
}

run_completed :: proc(state: ^State) {
	typing := &state.typing

	duration := typing.finished_time - typing.started_time

	window_size := state.size
	center      := window_size / 2

	font_size    := window_size.y * 0.05
	spacing      := font_size / 10
	vertical_spacing := font_size / 5
	
	rl.ClearBackground(COLOR_BG)

	cursor := Vec2{0, 0}
	draw_text(.Draw, cursor, font_size, COLOR_FG, "Completed in %.3f seconds!", duration)

	switch{
	case rlIsKeyPressedOrRepeated(.ESCAPE):
		state.view = .Collections
	}
}

