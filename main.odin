package main

import "core:path/slashpath"
import "core:fmt"
import "core:strconv"
import "core:slice"
import "core:strings"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:unicode"
import "core:c"
import rl "vendor:raylib"

ANIMATE_SPEED            :: 400
IS_DEBUGGING_COMPLETION  :: false
IS_DEBUGGING_NEW_RECORD  :: false
IS_DEBUGGING_UNDO_BUFFER :: true

// TODO: remove asserts from the main path

View :: enum {
	Collections,
	Samples,
	Typing,
}

font: Font

State :: struct {
	requested_quit : bool,
	size           : Vec2,
	dt             : f32,

	view: View,

	available_collections : [dynamic]Collection,
	collection_idx        : int,

	loaded_collection : ^Collection,
	available_samples : [dynamic]Sample,
	sample_idx : int,

	typing: TypingState,
}

Collection :: struct {
	name     : string,
	fullpath : string,
}

CollectionProgressEntry :: struct {
	sample        : string,
	personal_best : f32, // seconds
}

UndoEntry :: struct {
	idx    : int,
	value  : []byte,
	insert : bool,
}

TypingState :: struct {
	sample: ^Sample,

	// NOTE: make sure that the font is monospace, so that we can display the
	// target letter right above what was actually typed, without any letter spacing issues
	typed       : [dynamic]byte,
	copied      : [dynamic]byte,
	undo_buffer : [dynamic]^UndoEntry, // Potential candidate for an arena allocator.
	undo_idx   : int,
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
	duration : f32,
	prev_duration : f32,
	completed : bool,
	animation_t : f32,
	animation_new_record : f32,
	animation_zig: bool,
}

Sample :: struct {
	name: string,
	text: []byte,
	personal_best: f32,
}

SelectionRange :: struct { start, end: int }

COLOR_BG        :: Color{ 255, 255, 255, 255 }
COLOR_BG2       :: Color{ 200, 200, 200, 255 }
COLOR_FG        :: Color{ 0, 0, 0, 255 }
COLOR_TARGET    :: Color{ 125, 125, 125, 255 }
COLOR_HIGHLIGHT :: Color{ 0, 120, 215, 255 }
COLOR_WRONG     :: Color{ 255, 125, 125, 255 }
COLOR_RED       :: Color{ 255, 0, 0, 255 }

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
	state.collection_idx = math.clamp(state.collection_idx, 0, len(state.available_collections) - 1)
}

load_game_state :: proc() -> ^State {
	state := new(State)

	state.view = .Collections

	// The truetype font as loaded by RayLib looks like ass for some reason. 
	// Manually converting it to a bitmap font does not help.
	// Not solved yet. 
	font = rl.LoadFontEx("./font/IBMPlexMono-Regular.ttf", 64, nil, 250)
	// rl.SetTextureFilter(font.texture, .POINT)

	load_available_collections(state)

	if IS_DEBUGGING_COMPLETION {
		// Airdrop ourselves right to the end
		idx : int = -1
		for collection, i in state.available_collections {
			if collection.name == "puzzles" {
				idx = i
			}
		}
		assert(idx != -1)

		load_collection(state, &state.available_collections[idx])
		start_typing(state)
		n := len(state.typing.sample.text)
		for char, idx in state.typing.sample.text {
			if idx == n -1 {break}
			append(&state.typing.typed, char)
		}
		set_cursor_pos(&state.typing, n, false)
	}

	return state
}

load_collection :: proc(state: ^State, collection: ^Collection) {
	files, err := os.read_all_directory_by_path(collection.fullpath, context.allocator)
	assert(err == nil)
	defer delete(files)

	sb := make([dynamic]byte)
	defer delete(sb)

	state.loaded_collection = collection

	clear(&state.available_samples)
	for file in files {
		if file.type != .Regular {continue}

		defer free_all(context.temp_allocator)
		text, err := os.read_entire_file_from_path(file.fullpath, context.temp_allocator)
		assert(err == nil)

		clear(&sb)

		text_str := string(text)
		for line in strings.split_lines_iterator(&text_str) {
			line_trimmed := transmute([]byte)strings.trim_right_space(line)
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

		// Also check for a progress file, and load whatever we put in that
		load_progress(collection, &sample)

		append(&state.available_samples, sample)
	}

	if len(state.available_samples) > 0 {
		state.sample_idx = 0
	}

	return
}

// truncates the undo buffer, and appends a new entry
make_undo_entry :: proc(typing: ^TypingState, idx: int, value: []u8, insert: bool) {
	for i in typing.undo_idx+1..<len(typing.undo_buffer) {
		delete_undo_entry(typing.undo_buffer[i])
	}
	resize(&typing.undo_buffer, typing.undo_idx)

	undo_entry := new_clone(UndoEntry{
		idx=idx,
		value=slice.clone(value),
		insert=insert,
	})
	append(&typing.undo_buffer, undo_entry)
	typing.undo_idx += 1

	if insert {
		debug_log("logging insert %v", string(value))
	} else {
		debug_log("logging delete %v", string(value))
	}

	if IS_DEBUGGING_UNDO_BUFFER {
		debug_log("-------------")
		for entry in typing.undo_buffer {
			debug_log("idx=%v, value= %v, insert=%v", entry.idx, string(entry.value), entry.insert)
		}
	}
}

delete_undo_entry :: proc(entry: ^UndoEntry) {
	if entry != nil {
		delete(entry.value)
	}
}

Color :: rl.Color
Vec2  :: rl.Vector2
Font  :: rl.Font

delete_text :: proc(typing: ^TypingState, range: SelectionRange, is_undo := false) -> bool {
	n := len(typing.typed)
	range := range
	range.start = math.clamp(range.start, 0, n)
	range.end   = math.clamp(range.end, 0, n)

	if range.start == range.end  {return false}

	lo, hi := get_lo_hi(range)

	if !is_undo {
		make_undo_entry(typing, lo, typing.typed[lo:hi], insert=false)
	}

	remove_range(&typing.typed, lo, hi)
	set_cursor_pos(typing, lo, false)

	return true
}

delete_selected :: proc(typing: ^TypingState) -> bool {
	return delete_text(typing, typing.range)
}

insert_text :: proc(typing: ^TypingState, idx: int,  val: []byte, is_undo := false) {
	if !is_undo {
		make_undo_entry(typing, idx, val, insert=true)
	}
	inject_at_elems(&typing.typed, idx, ..val)
	set_cursor_pos(typing, idx + len(val), false)
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
	}
}

run_typing :: proc(state: ^State) {
	typing := &state.typing

	if typing.sample == nil           {return}
	if state.loaded_collection == nil {return}

	// Input
	if !typing.completed {
		// TODO: Moving up and down lines! (hard feature)
		// TODO: Tab
		// TODO: VIM bindings support

		shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		ctrl_down  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)

		is_range_selecting := shift_down
		is_moving_by_word  := ctrl_down
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

		// Up and down arrows. The code is just a more complicated version of HOME/END
		if rlIsKeyPressedOrRepeated(.UP) {
			// Move the cursor up

			required_offset := 0
			pos := typing.range.end
			for pos > 0 && char_at(typing.typed[:], pos - 1) != '\n' {
				pos -= 1
				required_offset += 1
			}
			if pos > 0 { pos -= 1 }
			for pos > 0 && char_at(typing.typed[:], pos - 1) != '\n' {
				pos -= 1
			}
			n := len(typing.typed)
			for pos < n && char_at(typing.typed[:], pos) != '\n' && required_offset > 0 {
				pos += 1
				required_offset -= 1
			}

			set_cursor_pos(typing, pos, is_range_selecting)
		}
		if rlIsKeyPressedOrRepeated(.DOWN) {
			// Move the cursor down

			start_pos := typing.range.end

			required_offset := 0
			pos := start_pos
			for pos > 0 && char_at(typing.typed[:], pos - 1) != '\n' {
				pos -= 1
				required_offset += 1
			}

			pos = start_pos
			n := len(typing.typed)
			for pos < n && char_at(typing.typed[:], pos) != '\n' {
				pos += 1
			}
			if pos < n {pos += 1}
			for pos < n && char_at(typing.typed[:], pos) != '\n' && required_offset > 0 {
				pos += 1
				required_offset -= 1
			}

			set_cursor_pos(typing, pos, is_range_selecting)
		}
		if ctrl_down && rlIsKeyPressedOrRepeated(.C) {
			clear(&typing.copied)
			lo, hi := get_lo_hi(typing.range)
			for idx in lo..<hi {
				append(&typing.copied, typing.typed[idx])
			}
		}
		if ctrl_down && rlIsKeyPressedOrRepeated(.V) {
			delete_selected(typing)
			start := typing.range.end
			insert_text(typing, start, typing.copied[:])
		}
		if ctrl_down && !shift_down && rlIsKeyPressedOrRepeated(.Z) {
			if typing.undo_idx > 0 {
				typing.undo_idx -= 1

				undo_entry := typing.undo_buffer[typing.undo_idx]
				assert(undo_entry != nil)
				if undo_entry.insert {
					debug_log("deleting fr fr")
					delete_text(typing, {undo_entry.idx, undo_entry.idx + len(undo_entry.value)}, is_undo = true)
				} else {
					debug_log("inserting. wtf")
					insert_text(typing, undo_entry.idx, undo_entry.value, is_undo = true)
				}
			}
		}
		if (ctrl_down && rlIsKeyPressedOrRepeated(.R)) || (ctrl_down && shift_down && rlIsKeyPressedOrRepeated(.Z)) {
			n := len(typing.undo_buffer)
			if typing.undo_idx < n {
				undo_entry := typing.undo_buffer[typing.undo_idx]
				assert(undo_entry != nil)
				if undo_entry.insert {
					debug_log("inserting fr fr")
					insert_text(typing, undo_entry.idx, undo_entry.value, is_undo = true)
				} else {
					debug_log("deleting wt")
					delete_text(typing, {undo_entry.idx, undo_entry.idx + len(undo_entry.value)}, is_undo = true)
				}

				typing.undo_idx += 1
			}
		}
		if ctrl_down && rlIsKeyPressedOrRepeated(.A) {
			set_cursor_pos(typing, 0, false)
			set_cursor_pos(typing, len(typing.sample.text), true)
		}

		if rlIsKeyPressedOrRepeated(.BACKSPACE) || remove_last_word {
			if !delete_selected(typing) {
				if is_moving_by_word {
					lo := move_cursor_prev_boundary(typing.range.end, typing.typed[:])
					if lo != typing.range.end {
						delete_text(typing, {lo, typing.range.end})
					}
				} else {
					if typing.range.end > 0 {
						delete_text(typing, {typing.range.end - 1, typing.range.end})
					}
				}
			}
		}

		if rlIsKeyPressedOrRepeated(.DELETE) {
			if !delete_selected(typing) {
				if is_moving_by_word {
					hi := move_cursor_next_boundary(typing.range.end, typing.typed[:])
					if hi != typing.range.end {
						delete_text(typing, {typing.range.end, hi})
					}
				} else {
					delete_text(typing, {typing.range.end, typing.range.end + 1})
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

		curr_len := len(typing.typed)
		mutated  := prev_len != curr_len
		selection_changed := typing.range.end != prev_end

		if mutated || selection_changed {
			// NOTE: this only applies to horizontal movement 
			// I've recently decided to not have horizontal movement, but yet to fully commit. I'll remove this later
			// state.is_animated = !mutated
			typing.is_animated = true
			typing.blink_time  = 0
		}

		if mutated {
			if curr_len == 0 {
				// Prevent typing everything but the final letter, then clearing all, resetting the timer, then pasting getting a sub-1 second time.
				clear(&typing.copied)
				// Same as above, but redoing a clear-all action instead of pasting
				clear_undo_buffer(typing)
			}

			if prev_len == 0 && curr_len > 0 {
				typing.started_time = rl.GetTime()
			}

			if len(typing.typed) == len(typing.sample.text) {
				all_correct := true
				for idx in 0..<len(typing.typed) {
					if typing.typed[idx] != typing.sample.text[idx] {
						all_correct = false
						break;
					}
				}

				if all_correct && !typing.completed {
					typing.completed   = true
					typing.animation_t = 0

					typing.prev_duration = typing.sample.personal_best
					typing.duration      = f32(rl.GetTime() - typing.started_time)
					if typing.prev_duration == 0 || typing.duration < typing.prev_duration {
						typing.sample.personal_best = typing.duration
						// save progress
						save_progress(state.loaded_collection, typing.sample)
						free_all(context.temp_allocator)
					}
				}
			}
		}
	} else if typing.completed {
		if rlIsKeyPressedOrRepeated(.ENTER) {
			n := len(state.available_samples)
			if state.sample_idx < n - 1 {
				state.sample_idx += 1
				start_typing(state)
			} else {
				state.view = .Collections
			}
		}
		if rlIsKeyPressedOrRepeated(.R) {
			start_typing(state)
		}
	}

	rl.ClearBackground(COLOR_BG)

	window_size := state.size
	dt          := state.dt

	center       := window_size / 2
	font_size    := window_size.y * 0.05
	spacing      := f32(0) // font_size / 10
	vertical_spacing := font_size / 5
	row_offset   := Vec2{0, font_size + spacing}
	cursor_start := Vec2{ spacing, spacing }
	character_width := f32(rl.MeasureTextEx(font, "w", font_size, 0).x)

	typing.blink_time += dt

	chars_to_draw := math.max(len(typing.typed), len(typing.sample.text))

	start_caret_at, end_caret_at : Vec2
	cursor := cursor_start
	document_height : f32
	for phase in UI_PHASES { 
		cursor = cursor_start
		if phase == .Draw {
			// TODO: camera offset
			cursor -= typing.offset_smooth
		}

		set_start, set_end : bool
		idx : int
		for idx < chars_to_draw {
			cursor_start := cursor
			result := draw_text_row(
				.Measure,
				typing, 
				idx, chars_to_draw,
				cursor_start,
				font_size, vertical_spacing, spacing, row_offset,
				window_size,
				draw_target_row = true
			)
			result = draw_text_row(
				phase,
				typing, 
				idx, chars_to_draw,
				cursor_start,
				font_size, vertical_spacing, spacing, row_offset,
				window_size,
				draw_target_row = !result.all_right
			)

			idx    = result.idx
			cursor = result.cursor

			if result.set_start {
				set_start = result.set_start
				start_caret_at = result.start_caret_at
			}
			if result.set_end {
				set_end = result.set_end
				end_caret_at = result.end_caret_at
			}
		}

		if !set_start { start_caret_at = cursor + row_offset }
		if !set_end   { end_caret_at = cursor + row_offset }

		if phase == .Measure {
			document_height = cursor.y

			if !typing.completed {
				// Make sure that the 'camera' starts at this character.
				start := -start_caret_at + 6 * (character_width + spacing)
				end   := -end_caret_at   + 6 * (character_width + spacing)

				offset : Vec2
				point_where_we_should_start_scrolling := center.y
				if end_caret_at.y > point_where_we_should_start_scrolling {
					offset.y = end_caret_at.y - point_where_we_should_start_scrolling
				}

				if typing.is_animated {
					t := 50 * dt
					typing.offset_smooth = linalg.lerp(typing.offset_smooth, offset, t)
				} else {
					typing.offset_smooth = offset
				}

			} else {
				typing.offset_smooth = {0, typing.animation_t}
			}
		}
	}
	typing.start_caret_at = start_caret_at
	typing.end_caret_at = end_caret_at

	if typing.completed {
		// Admire the view

		target_a := -window_size.y * 0.1
		target_b := math.max(0, document_height - window_size.y + window_size.y * 0.1)

		if typing.animation_zig {
			typing.animation_t += dt * ANIMATE_SPEED
			if typing.animation_t > target_b {
				typing.animation_t = target_b
				typing.animation_zig = !typing.animation_zig
			}
		} else {
			typing.animation_t -= dt * ANIMATE_SPEED
			if typing.animation_t < target_a {
				typing.animation_t = target_a
				typing.animation_zig = !typing.animation_zig
			}
		}
	}

	BLINK_TIME :: 1.0
	if typing.blink_time > BLINK_TIME {
		typing.blink_time -= BLINK_TIME
	}

	if typing.blink_time < BLINK_TIME / 2 {
		// This is the size we need for the cursor to mathematically fit between the letters without
		// touching the letters and also distribute the spacing nicely
		cursor_width   := font_size / 10

		rl.DrawRectangleV({ end_caret_at.x, end_caret_at.y }, { cursor_width, font_size }, COLOR_FG)
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

		duration : f32
		if typing.completed {
			duration = typing.duration
		} else if len(typing.typed) > 0 {
			duration = f32(rl.GetTime() - typing.started_time)
		}

		cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, " | time: %.3f", duration)
	}

	if typing.completed {
		font_size := window_size.y * 0.05
		
		cursor := Vec2{0, 0}
		height := 2 * font_size
		if typing.prev_duration != 0 {
			height += font_size
		}
		rl.DrawRectangleV(cursor, {window_size.x, height}, COLOR_BG)
		cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, "%v Completed in %.3f seconds!", typing.sample.name, typing.duration)

		if typing.duration < typing.prev_duration {
			col := rl.ColorFromHSV(typing.animation_new_record, 1, 1)
			typing.animation_new_record += dt * 1000
			cursor.x += draw_text(.Draw, cursor, font_size, col, "New record!!!")
		}

		cursor.x = 0
		cursor.y += font_size

		if typing.prev_duration != 0 {
			cursor.x += draw_text(.Draw, cursor, font_size, COLOR_FG, "Your old time was %.3f seconds.", typing.prev_duration)
			cursor.x += 50


			cursor.x = 0
			cursor.y += font_size
		}

		n := len(state.available_samples)
		if state.sample_idx < n - 1 {
			next_sample := state.available_samples[state.sample_idx + 1]
			draw_text(.Draw, cursor, font_size, COLOR_FG, "[Enter] -> next sample - %v, [R] -> Restart", next_sample.name)
		} else {
			draw_text(.Draw, cursor, font_size, COLOR_FG, "[Enter] -> collections, [R] -> Restart")
		}
	}

	switch {
	case rl.IsKeyPressed(.ESCAPE): 
		if typing.range.start != typing.range.end {
			set_cursor_pos(typing, typing.range.end, false)
		} else {
			state.view = .Samples
		}
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

// Pretend to draw something. Measure how big it was, and use that info to draw it in the right place, or to draw it differently.
// It can be used for any kind of measuring though. E.g I also use it to check if we encoutnered any incorrect letters, and if not, 
// render the text row _without_ the target row.
UiPhase :: enum {
	Measure,
	Draw,
}

// Useful when you need to loop over a bunch of rows just to figure out how tall a thing is, so you can center it vertically.
// Do let me know if there is a better way to center UI :)
UI_PHASES :: []UiPhase { .Measure, .Draw }

draw_text :: proc(phase: UiPhase, cursor: Vec2, font_size: f32, color: Color, fmt: cstring, args: ..any) -> f32 {
	text  := rl.TextFormat(fmt, ..args)
	width := rl.MeasureTextEx(font, text, font_size, 0).x
	if phase == .Draw {
		rl.DrawTextEx(font, text, cursor, font_size, 0, color)
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

type_char :: proc(typing: ^TypingState, c: rune) {
	delete_selected(typing)
	insert_text(typing, typing.range.end, []byte{ byte(c) })
}

set_cursor_pos :: proc(typing: ^TypingState, pos: int, is_range_selecting: bool) {
	pos := math.clamp(pos, 0, len(typing.typed))
	typing.range.end = pos
	if !is_range_selecting {
		typing.range.start = pos
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
		load_collection(state, &state.available_collections[state.collection_idx])
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
			cursor = { cursor_start.x, center.y - cursor_selected.y - font_size / 2 }
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
	draw_centered_label(state, .Draw, {state.size.x / 2, 0}, font_size, "Choose a collection", selected=true, selected_bg=COLOR_BG)
}

start_typing :: proc(state: ^State) {
	state.view = .Typing
	typing := &state.typing
	typing.sample = &state.available_samples[state.sample_idx]
	typing.started_time = rl.GetTime()
	typing.completed = false
	clear(&typing.typed)
	clear(&typing.copied)
	clear_undo_buffer(typing)
	set_cursor_pos(typing, 0, false)
}

clear_undo_buffer :: proc(typing: ^TypingState) {
	// Initially I wanted to persist the copy buffer between sessions. But then what's stopping you from copying everything but 1,
	// and pasting that back in on the next session? So yea, we gotta clear this too
	for entry in typing.undo_buffer {
		delete_undo_entry(entry)
	}
	clear(&typing.undo_buffer)
	typing.undo_idx = 0
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
		start_typing(state)
	case rlIsKeyPressedOrRepeated(.ESCAPE):
		state.view = .Collections
	}
	state.sample_idx = math.clamp(state.sample_idx, 0, len(state.available_samples) - 1)

	rl.ClearBackground(COLOR_BG)

	cursor : Vec2
	cursor_selected : Vec2
	for phase in UI_PHASES {
		if phase == .Draw {
			cursor = {
				cursor_start.x,
				cursor_start.y + center.y - cursor_selected.y - font_size / 2
			}
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
	draw_centered_label(state, .Draw, {state.size.x / 2, 0}, font_size, "Choose a sample", selected=true, selected_bg=COLOR_BG)
}

draw_centered_label :: proc(
	state: ^State,
	phase: UiPhase,
	cursor: Vec2,
	font_size: f32,
	name: string,
	selected := false,
	selected_bg := COLOR_BG2,
	width: f32 = -1
) -> Vec2 {
	width := width
	if width < 0 {
		width = draw_text(.Measure, cursor, font_size, COLOR_FG, "%v", name)
	}

	if selected {
		if phase == .Draw {
			rl.DrawRectangleV(cursor + { -width / 2, 0 }, {width, font_size}, selected_bg)
		}
	}

	if phase == .Draw {
		draw_text(.Draw, cursor + {-width / 2, 0 }, font_size, COLOR_FG, "%v", name)
	}

	return {width, font_size}
}

run_completed :: proc(state: ^State) {
}

DrawLineResult :: struct {
	start_caret_at, end_caret_at : Vec2,
	set_start, set_end: bool,

	cursor : Vec2,
	idx    : int,

	all_right  : bool,
}

draw_text_row :: proc(
	phase: UiPhase,
	typing: ^TypingState,
	start,
	to_draw: int,
	cursor: Vec2,
	font_size: f32,
	vertical_spacing: f32,
	spacing: f32,
	row_offset: Vec2,
	window_size: Vec2,
	draw_target_row: bool,
) -> (result: DrawLineResult) {
	cursor_start := cursor

	cursor := cursor

	result.all_right = true

	for idx in start..<to_draw {
		result.idx = idx + 1

		char, has_char          := char_ok(typing.typed[:], idx)
		target_char, has_target := char_ok(typing.sample.text, idx)

		target_is_newline := target_char == '\n'
		is_newline        := char == '\n'

		is_wrong := has_char && has_target && target_char != char
		if is_wrong || !has_char {
			result.all_right = false
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
			// NOTE: Update the other place as well
			// Wrap the text - the current line has overflowed
			cursor.x = cursor_start.x
			cursor.y += row_offset.y
			if draw_target_row {
				cursor.y += row_offset.y
			}
		}

		{
			cursor := cursor

			// Target text
			if draw_target_row {
				if phase == .Draw {
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

				cursor += row_offset
			}

			if idx == typing.range.start {
				result.start_caret_at, result.set_start = cursor, true
			}
			if idx == typing.range.end {
				result.end_caret_at, result.set_end = cursor, true
			}

			// Typed text
			{
				if phase == .Draw {
					lo, hi         := get_lo_hi(typing.range)
					is_highlighted := lo <= idx && idx < hi

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
		}

		cursor.x += width + spacing
		if target_is_newline {
			// NOTE: Update the other place as well
			// Wrap the text - newline
			cursor.x = cursor_start.x
			cursor.y += row_offset.y
			if draw_target_row {
				cursor.y += row_offset.y
			}
			break;
		}
	}

	result.cursor = cursor

	return
}

pull_float :: proc(str: ^string) -> (val: f32, ok: bool) {
	val_str := strings.split_iterator(str, ",") or_return

	val_str = strings.trim_space(val_str)
	val, ok  = strconv.parse_f32(val_str)

	return
}

load_progress :: proc(collection: ^Collection, sample: ^Sample) {
	progress_path := slashpath.join({".", "progress", collection.name, sample.name}, context.temp_allocator)

	progress_text_bytes, err := os.read_entire_file_from_path(progress_path, context.temp_allocator)
	if err != .FILE_NOT_FOUND && err != .Not_Exist && err != nil {
		debug_log("load error %v", err)
		return
	}

	progress_text := string(progress_text_bytes)
	personal_best, ok := pull_float(&progress_text)
	if ok {
		sample.personal_best = personal_best
		debug_log("loaded pb %v", personal_best)
	}
}

save_progress :: proc(collection: ^Collection, sample: ^Sample) {
	debug_log("saving new pb: %v, %v", sample.name, sample.personal_best)

	if IS_DEBUGGING_NEW_RECORD {return}

	progress_path := slashpath.join({".", "progress", collection.name, sample.name}, context.temp_allocator)
	progress_dir  := slashpath.dir(progress_path, context.temp_allocator)

	{
		err := os.make_directory_all(progress_dir)
		if err != nil {return}
	}

	{
		err := os.write_entire_file_from_string(
			progress_path,
			fmt.aprintf("%v", sample.personal_best, allocator=context.temp_allocator),
		)
		if err != nil {return}
	}
}
