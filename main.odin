package main

import "core:mem"
import "core:path/filepath"
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

ANIMATE_SPEED            :: 0.5

//// Debug flags

WINDOWED                 :: false
IS_DEBUGGING_UNDO_BUFFER :: false
IS_DEBUGGING_ALLOCATIONS :: false
IS_DEBUGGING_ERRROR      :: 0

// IS_DEBUGGING_FILE        :: "collections/programming/odin/tracking_allocator.odin"
IS_DEBUGGING_FILE        :: ""
IS_DEBUGGING_COMPLETION  :: false
IS_DEBUGGING_NEW_RECORD  :: false // Set to true to disable saving

COLLECTIONS_PATH :: "collections"

NEWLINE_STR :: "\\n"
TAB_STR     :: "->"

DRAW_MODE :: TextDrawMode.Overlayed

TextDrawMode :: enum {
	Overlayed,
}

View :: enum {
	Samples,
	Typing,
}

font: Font

LoadableItemType :: enum {
	Collection,
	Sample,
}

@(rodata)
LOADABLE_ITEM_ORDER := [LoadableItemType]int {
	.Sample     = 0,
	.Collection = 1,
}

LoadableItem :: struct {
	name: string,
	type: LoadableItemType,
	sample: ^Sample,
}

CurrentPath :: struct {
	parent : ^CurrentPath,
	path: string,
	item_idx : int,
}

State :: struct {
	requested_quit : bool,
	size           : Vec2,
	dt             : f32,

	error : string,

	view: View,

	current_path : ^CurrentPath,

	available_items : [dynamic]LoadableItem,
	item_idx        : int,

	available_samples_arena     : mem.Dynamic_Arena,
	available_samples_allocator : mem.Allocator,

	typing: TypingState,
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
	next_sample_idx : int,
	next_sample     : ^Sample,

	// NOTE: make sure that the font is monospace, so that we can display the
	// target letter right above what was actually typed, without any letter spacing issues
	typed       : [dynamic]byte,
	copied      : [dynamic]byte,
	undo_buffer : [dynamic]^UndoEntry, // Potential candidate for an arena allocator.
	undo_idx   : int,
	range      : SelectionRange,
	blink_time : f32,
	mutation_unhandled : bool,

	offset_smooth : Vec2,
	start_caret_at, end_caret_at : Vec2, // NOTE: kinda not used tbh
	current_typed_height : f32,
	is_animated                  : bool,

	// NOTE: I actually don't care about the number of times I typed the wrong thing - 
	// Really, I just want to minimize the time. If the most optimal typing strategy actually
	// invovles making shittone of mistakes and then editing them later, I don't want to be 
	// penalized for getting one or two letters wrong actually.
	// This is especially the case in the puzzle levels, that will rely heavily on moving the
	// cursor around and copy-pasting stuff. 
	// That being said, I think it would be cool to have a [perfect]. Its like an SS in a rhythm game
	started_time  : f64,
	perfect : bool,
	duration : f32,
	prev_duration : f32,
	completed : bool,
	animation_t : f32,
	animation_new_record : f32,
	animation_zigging: bool,
}

Sample :: struct {
	name: string,
	relative_path: string,
	text: []byte,
	personal_best: f32,
	perfect: bool,
}

SelectionRange :: struct { start, end: int }

COLOR_BG        :: Color{ 255, 255, 255, 255 }
COLOR_BG2       :: Color{ 200, 200, 200, 255 }
COLOR_FG        :: Color{ 0, 0, 0, 255 }
COLOR_TARGET    :: Color{ 170, 170, 170, 255 }
COLOR_HIGHLIGHT :: Color{ 0, 120, 215, 255 }
COLOR_WRONG     :: Color{ 255, 0, 0, 255 }
COLOR_RED       :: Color{ 255, 0, 0, 255 }

last_monitor : c.int

load_game_state :: proc() -> ^State {
	state := new(State)
	arena := &state.available_samples_arena
	mem.dynamic_arena_init(arena)
	state.available_samples_allocator = mem.dynamic_arena_allocator(arena)
	state.current_path = new_clone(CurrentPath{path = COLLECTIONS_PATH})

	// The truetype font as loaded by RayLib looks like ass for some reason. 
	// Manually converting it to a bitmap font does not help.
	// Not solved yet. 
	font = rl.LoadFontEx("./font/IBMPlexMono-Regular.ttf", 128, nil, 250)
	// rl.SetTextureFilter(font.texture, .POINT)

	state.view = .Samples
	load_directory_or_file(state, COLLECTIONS_PATH)

	if IS_DEBUGGING_FILE != "" {
		load_directory_or_file(state, IS_DEBUGGING_FILE)

		if IS_DEBUGGING_COMPLETION {
			n := len(state.typing.sample.text)
			for char, idx in state.typing.sample.text {
				if idx == n -1 {break}
				insert_text(&state.typing, len(state.typing.typed), []byte{ char })
			}
			set_cursor_pos(&state.typing, n, false)
		}
	}

	return state
}

load_directory_or_file :: proc(state: ^State, relative_path: string) -> bool {
	debug_log("loading path %v ...", relative_path)

	stat, stat_err := os.stat(relative_path, context.allocator)
	defer os.file_info_delete(stat, context.allocator)
	if stat_err != nil || IS_DEBUGGING_ERRROR == 1 {
		state.error = fmt.aprintf("Couldn't read path info %v: %v", relative_path, stat_err)
		return false
	}

	arena := state.available_samples_allocator
	free_all(arena)
	clear(&state.available_items)

	#partial switch stat.type {
	case .Regular:
		sample := load_sample(state, relative_path, arena)
		item   := LoadableItem{name=strings.clone(stat.name, arena), type=.Sample, sample=sample}
		append(&state.available_items, item)

		state.item_idx = 1
		start_typing(state, sample)
	case .Directory:
		state.view = .Samples
		state.typing.sample = nil

		files, err := os.read_all_directory_by_path(relative_path, context.allocator)
		defer os.file_info_slice_delete(files, context.allocator)
		if err != nil || IS_DEBUGGING_ERRROR == 2 {
			state.error = fmt.aprintf("Couldn't read path %v: %v", relative_path, stat_err)
			return false
		}

		for fi in files {
			relative_path, err := filepath.join([]string{relative_path, fi.name}, context.allocator)
			assert(err == nil)
			defer delete(relative_path)

			file, file_err := os.open(fi.fullpath)
			defer os.close(file)
			if file_err != nil {continue}

			#partial switch fi.type {
			case .Regular:
				sample := load_sample(state, relative_path, arena)
				item   := LoadableItem{name=strings.clone(fi.name, arena), type=.Sample, sample=sample}
				append(&state.available_items, item)
			case .Directory:
				// Only include the directory as a collection if it's got at least 1 item
				dirs, err := os.read_directory(file, 1, context.allocator)
				defer os.file_info_slice_delete(dirs, context.allocator)
				if err != nil || len(dirs) == 0 {
					continue
				}

				str, err22 := strings.clone(fi.name, allocator=arena)
				item := LoadableItem{name=str, type=.Collection}
				append(&state.available_items, item)
			}
		}

		state.item_idx = math.clamp(state.item_idx, 0, len(state.available_items) - 1)
	}

	if len(state.available_items) > 0 {

		slice.sort_by(state.available_items[:], proc(a, b: LoadableItem) -> bool {
			if a.type != b.type {
				return LOADABLE_ITEM_ORDER[a.type] < LOADABLE_ITEM_ORDER[b.type]
			}

			return strings.compare(a.name, b.name) < 0
		})
	}
	return true
}


load_sample :: proc(state: ^State, relative_path: string, allocator : mem.Allocator) -> ^Sample {
	debug_log("loading sample %v ...", relative_path)

	text, err := os.read_entire_file_from_path(relative_path, context.allocator)
	defer delete(text)
	fmt.assertf(err == nil, "err wasnt nil: %v", err)

	sb := make([dynamic]byte)
	defer delete(sb)

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

	sample := new_clone(Sample {
		relative_path = strings.clone(relative_path, allocator),
		name = strings.clone(filepath.base(relative_path), allocator),
		text = slice.clone(sb[:], allocator),
	}, allocator)

	// Also check for a progress file, and load whatever we put in that
	load_progress(sample)

	debug_log("loaded %v", relative_path)

	return sample
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

	if IS_DEBUGGING_UNDO_BUFFER {
		if insert {
			debug_log("logging insert %v", string(value))
		} else {
			debug_log("logging delete %v", string(value))
		}

		debug_log("-------------")
		for entry in typing.undo_buffer {
			debug_log("idx=%v, value= %v, insert=%v", entry.idx, string(entry.value), entry.insert)
		}
	}
}

delete_undo_entry :: proc(entry: ^UndoEntry) {
	delete(entry.value)
	free(entry)
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

	typing.mutation_unhandled = true

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
	typing.mutation_unhandled = true
}

get_lo_hi :: proc(range: SelectionRange) -> (int, int) {
	lo := math.min(range.end, range.start)
	hi := math.max(range.end, range.start)
	return lo, hi
}

run_game :: proc(state: ^State) {
	if state.requested_quit {return;}

	rl.ClearBackground(COLOR_BG)

	if state.error != "" {
		window_size := state.size
		tc	:= create_text_config(0.05, window_size)

		cursor := Vec2{window_size.x / 2, window_size.y * 0.1}

		line_length := 50
		for idx := 0; idx < len(state.error); idx += line_length {
			end := math.min(idx + line_length, len(state.error))
			draw_text(.Draw, cursor, tc.font_size, COLOR_FG, "%v", state.error[idx:end], alignment=0.5)
			cursor += tc.row_offset
		}

		if rlIsKeyPressedOrRepeated(.ESCAPE) {
			state.requested_quit = true
		}

		return
	}

	switch state.view {
	case .Samples:     run_sample_selector(state)
	case .Typing:      run_typing(state)
	}
}

run_typing :: proc(state: ^State) {
	typing := &state.typing

	window_size := state.size
	center      := window_size / 2
	dt          := state.dt
	tc := create_text_config(0.06, window_size)

	if typing.sample == nil {
		draw_text(.Draw, center, tc.font_size, COLOR_FG, "Sample was not set!")
		return
	}

	// Input
	if !typing.completed {
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
					delete_text(typing, {undo_entry.idx, undo_entry.idx + len(undo_entry.value)}, is_undo = true)
				} else {
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
					insert_text(typing, undo_entry.idx, undo_entry.value, is_undo = true)
				} else {
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

		if rlIsKeyPressedOrRepeated(.TAB) {
			type_char(typing, '\t')
		}

		curr_len := len(typing.typed)
		selection_changed := typing.range.end != prev_end

		defer typing.mutation_unhandled = false

		if typing.mutation_unhandled || selection_changed {
			// NOTE: this only applies to horizontal movement 
			// I've recently decided to not have horizontal movement, but yet to fully commit. I'll remove this later
			// state.is_animated = !mutated
			typing.is_animated = true
			typing.blink_time  = 0
		}

		if typing.mutation_unhandled {
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

					target_a, target_b := get_completion_animation_targets(typing, window_size)
					typing.animation_t = target_b

					typing.prev_duration = typing.sample.personal_best
					typing.duration      = f32(rl.GetTime() - typing.started_time)
					if typing.prev_duration == 0 || typing.duration < typing.prev_duration {
						typing.sample.personal_best = typing.duration
						typing.sample.perfect       = typing.perfect
						// save progress
						save_progress(state, typing.sample)
						free_all(context.temp_allocator)
					}
				}
			}
		}
	} else if typing.completed {
		if rlIsKeyPressedOrRepeated(.ENTER) {
			n := len(state.available_items)

			if state.item_idx < n - 1 {
				// NOTE: black magic incantation. see start_typing internals
				next_sample := state.typing.next_sample
				state.item_idx = state.typing.next_sample_idx
				start_typing(state, next_sample)
			} else {
				state.view = .Samples
			}
		}
		if rlIsKeyPressedOrRepeated(.R) {
			start_typing(state, typing.sample)
		}
	}

	cursor_start := Vec2{ tc.spacing, tc.spacing }
	character_width := f32(rl.MeasureTextEx(font, "w", tc.font_size, 0).x)

	typing.blink_time += dt

	start_caret_at, end_caret_at : Vec2
	cursor := cursor_start

	counter += 1

	for phase in UI_PHASES { 
		cursor = cursor_start
		if phase == .Draw {
			cursor -= typing.offset_smooth
		}

		result: DrawTextResult
		switch DRAW_MODE {
		case .Overlayed:
			result = draw_text_overlayed(tc, phase, typing, cursor, window_size)
		}

		start_caret_at = result.start_caret_at
		end_caret_at = result.end_caret_at
		typing.start_caret_at = result.start_caret_at
		typing.end_caret_at = result.end_caret_at
		cursor = result.cursor

		if phase == .Measure {
			if !typing.completed {
				// Make sure that the 'camera' starts at this character.
				start := -start_caret_at + 6 * (character_width + tc.spacing)
				end   := -end_caret_at   + 6 * (character_width + tc.spacing)

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

	typing.current_typed_height = cursor.y

	if typing.completed {
		// Admire the view

		target_a, target_b := get_completion_animation_targets(typing, window_size)

		if typing.animation_zigging {
			typing.animation_t += dt * window_size.y * ANIMATE_SPEED
			if typing.animation_t > target_b {
				typing.animation_t = target_b
				typing.animation_zigging = !typing.animation_zigging
			}
		} else {
			typing.animation_t -= dt * window_size.y * ANIMATE_SPEED
			if typing.animation_t < target_a {
				typing.animation_t = target_a
				typing.animation_zigging = !typing.animation_zigging
			}
		}
	}

	BLINK_TIME :: 1.0
	if typing.blink_time > BLINK_TIME {
		typing.blink_time -= BLINK_TIME
	}

	if typing.blink_time < BLINK_TIME / 2 || typing.completed {
		// This is the size we need for the cursor to mathematically fit between the letters without
		// touching the letters and also distribute the spacing nicely
		cursor_width   := tc.font_size / 10

		rl.DrawRectangleV({ end_caret_at.x, end_caret_at.y }, { cursor_width, tc.font_size }, COLOR_FG)
	}

	// Status line
	{
		tc := create_text_config(tc.vh / 1.5, window_size)
		height := tc.font_size
		cursor := Vec2{tc.spacing, window_size.y - height}
		rl.DrawRectangleV(cursor, {window_size.x - 2 * tc.spacing, height}, COLOR_BG)

		cursor.x += draw_text(.Draw, cursor, tc.font_size, COLOR_FG, "%v", typing.sample.name)

		duration : f32
		if typing.completed {
			duration = typing.duration
		} else if len(typing.typed) > 0 {
			duration = f32(rl.GetTime() - typing.started_time)
		}

		cursor.x += draw_text(.Draw, cursor, tc.font_size, COLOR_FG, " | time: %.3f", duration)
		if typing.sample.personal_best != 0 {
			cursor.x += draw_text(.Draw, cursor, tc.font_size, COLOR_FG, " | personal best: %.3f", typing.sample.personal_best)
		} else {
			cursor.x += draw_text(.Draw, cursor, tc.font_size, COLOR_FG, " | no record set")
		}
		if typing.perfect {
			cursor.x += draw_text(.Draw, cursor, tc.font_size, COLOR_FG, " | [perfect]")
		}
	}

	if typing.completed {
		font_size := window_size.y * 0.05
		typing.animation_new_record += dt * 0.5 * window_size.y

		cursor_start := Vec2{0, 0}
		cursor       := cursor_start

		for phase in UI_PHASES {
			height :=  cursor.y - cursor_start.y
			cursor = cursor_start

			if phase == .Draw {
				rl.DrawRectangleV(cursor, {window_size.x, height}, COLOR_BG)
			}

			cursor.x += draw_text(phase, cursor, font_size, COLOR_FG, "%v", typing.sample.name)

			cursor = {0, cursor.y + font_size}
			cursor.x += draw_text(phase, cursor, font_size, COLOR_FG, "Completed in %.3f seconds!", typing.duration)
			if typing.duration < typing.prev_duration {
				col := rl.ColorFromHSV(typing.animation_new_record, 1, 1)
				cursor.x += draw_text(phase, cursor, font_size, col, " New record!!!")
			}

			if typing.perfect {
				cursor = {0, cursor.y + font_size}
				col := rl.ColorFromHSV(typing.animation_new_record, 1, 1)
				cursor.x += draw_text(phase, cursor, font_size, col, "You made no mistakes. ")
			}


			if typing.prev_duration != 0 {
				cursor = {0, cursor.y + font_size}
				cursor.x += draw_text(phase, cursor, font_size, COLOR_FG, "Your old time was %.3f seconds.", typing.prev_duration)
				cursor.x += 50
			}

			cursor = {0, cursor.y + font_size}
			n := len(state.available_items)
			if state.item_idx < n - 1 {
				next_sample := state.available_items[state.item_idx + 1]
				draw_text(phase, cursor, font_size, COLOR_FG, "[Enter] -> next sample - %v, [R] -> Restart", next_sample.name)
			} else {
				draw_text(phase, cursor, font_size, COLOR_FG, "[Enter] -> collections, [R] -> Restart")
			}

			cursor = {0, cursor.y + font_size}
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

get_completion_animation_targets :: proc(typing: ^TypingState, window_size: Vec2) -> (f32, f32) {
	// When completed, typing.current_typed_height should be the full height of the text we typed
	target_a := -window_size.y * 0.4
	target_b := math.max(0, typing.current_typed_height + window_size.y * 0.4)
	return target_a, target_b
}

LetterType :: enum {
	Other,
	Whitespace,
	Newline,
	Indentation,
	Letter,
	Punctuation,
}

// Restrict to a limited subset of valid characters.
get_letter_type :: proc(b: byte) -> LetterType {
	r := rune(b)

	if r == '\t' {return .Indentation}
	if r == '\n' {return .Newline}
	if r == ' '  {return .Whitespace }

	if unicode.is_letter(r) {return .Letter}
	if unicode.is_number(r) {return .Letter}

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
// render the text row _without_ the target row. At least I used to do that, but the code has changed since then
UiPhase :: enum {
	Measure,
	Draw,
}

// Useful when you need to loop over a bunch of rows just to figure out how tall a thing is, so you can center it vertically.
// Do let me know if there is a better way to center UI :)
UI_PHASES :: []UiPhase { .Measure, .Draw }

draw_text :: proc(phase: UiPhase, cursor: Vec2, font_size: f32, color: Color, fmt: cstring, args: ..any, alignment : f32 = 0) -> f32 {
	text  := rl.TextFormat(fmt, ..args)
	width := rl.MeasureTextEx(font, text, font_size, 0).x
	if phase == .Draw {
		rl.DrawTextEx(font, text, cursor + {-width * alignment, 0}, font_size, 0, color)
	}
	return f32(width) * (1 - 2 * alignment)
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

start_typing :: proc(state: ^State, sample: ^Sample) {
	state.view = .Typing

	typing := &state.typing
	typing.sample = sample
	assert(typing.sample != nil)

	typing.started_time = rl.GetTime()
	typing.completed = false
	typing.perfect = true
	clear(&typing.typed)
	clear(&typing.copied)
	clear_undo_buffer(typing)
	set_cursor_pos(typing, 0, false)

	typing.next_sample_idx = 0
	typing.next_sample     = nil
	n := len(state.available_items)
	if state.item_idx + 1 < n && state.available_items[state.item_idx].sample == sample {
		for idx in state.item_idx+1..<n {
			item := state.available_items[idx]
			if item.type == .Sample {
				assert(item.sample != nil)
				typing.next_sample_idx = idx
				typing.next_sample     = item.sample
				break
			}
		}
	}

	debug_log("started typing")
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
	window_size := state.size
	center      := window_size / 2
	tc := create_text_config(0.05, window_size)
	cursor_start := Vec2{ center.x, 10 }

	switch{
	case rlIsKeyPressedOrRepeated(.DOWN): 
		num_items := len(state.available_items)
		state.item_idx += 1
		state.item_idx = math.clamp(state.item_idx, 0, len(state.available_items) - 1)
	case rlIsKeyPressedOrRepeated(.UP):   
		state.item_idx -= 1
		state.item_idx = math.clamp(state.item_idx, 0, len(state.available_items) - 1)
	case rlIsKeyPressedOrRepeated(.PAGE_DOWN): 
		num_items := len(state.available_items)
		state.item_idx += 10
		state.item_idx = math.clamp(state.item_idx, 0, len(state.available_items) - 1)
	case rlIsKeyPressedOrRepeated(.PAGE_UP):   
		state.item_idx -= 10
		state.item_idx = math.clamp(state.item_idx, 0, len(state.available_items) - 1)
	case rlIsKeyPressedOrRepeated(.ENTER): 
		current_item := state.available_items[state.item_idx]
		switch current_item.type {
		case .Sample:
			start_typing(state, current_item.sample)
		case .Collection:
			new_path, err := filepath.join([]string{state.current_path.path, current_item.name}, context.allocator)
			assert(err == nil)

			state.current_path.item_idx = state.item_idx
			state.current_path = new_clone(CurrentPath{parent = state.current_path, path   = new_path})
			state.item_idx = 0
			load_directory_or_file(state, state.current_path.path)
		}
	case rlIsKeyPressedOrRepeated(.ESCAPE):
		if state.current_path.parent != nil {
			prev_path := state.current_path
			state.current_path = prev_path.parent
			state.item_idx = state.current_path.item_idx
			delete(prev_path.path)
			free(prev_path)
			load_directory_or_file(state, state.current_path.path)
		} else {
			state.requested_quit = true
		}
	}


	if len(state.available_items) == 0 {
		draw_text(.Draw, center, tc.font_size, COLOR_FG, "No items available")
		return
	}

	cursor           : Vec2
	cursor_selected  : Vec2
	remaining_offset : f32
	col1_offset      : f32
	for phase in UI_PHASES {
		if phase == .Draw {
			cursor = {
				cursor_start.x,
				cursor_start.y + center.y - cursor_selected.y - tc.font_size / 2
			}
		}

		// Top bar
		if state.current_path.parent == nil {
			{
				tc := create_text_config(0.1, window_size)
				draw_centered_label(state, phase, {state.size.x / 2, cursor.y}, tc.font_size, "ROBOType", selected=true, selected_bg=COLOR_BG)
				cursor += tc.row_offset
			}

			draw_centered_label(state, phase, {state.size.x / 2, cursor.y}, tc.font_size, "Choose a sample", selected=true, selected_bg=COLOR_BG)
			cursor += tc.row_offset

			cursor.y += window_size.y * 0.1
		}


		// current folder
		draw_text(phase, {center.x, cursor.y}, tc.font_size, COLOR_FG, ".%v%v", filepath.SEPARATOR, state.current_path.path, alignment=0.5)
		cursor += tc.row_offset

		for &item, idx in state.available_items {
			selected := idx == state.item_idx

			max_width := col1_offset - cursor_start.x + remaining_offset

			cursor_start := cursor_start
			if phase == .Draw {
				cursor_start.x -= max_width / 2
			}

			cursor.x = cursor_start.x

			if phase == .Draw && selected {
				rl.DrawRectangleV(cursor, {max_width, tc.font_size}, COLOR_BG2)
			}

			cursor.x += draw_text(phase, cursor, tc.font_size, COLOR_FG, "%v", item.name)

			cursor.x += 80

			this_col1_offset := cursor.x - cursor_start.x
			if phase == .Measure {
				col1_offset = math.max(col1_offset, this_col1_offset)
			} else {
				cursor.x = cursor_start.x + col1_offset
			}

			if item.sample != nil {
				sample := item.sample
				if sample.personal_best != 0 {
					cursor.x += draw_text(phase, cursor, tc.font_size, COLOR_FG, "%.3f", sample.personal_best)

					if sample.perfect {
						cursor.x += 80
						cursor.x += draw_text(phase, cursor, tc.font_size, COLOR_FG, "[perfect]")
					}
				} else {
					cursor.x += draw_text(.Measure, cursor, tc.font_size, COLOR_FG, "no record set")
				}
			} else {
				cursor.x += draw_text(phase, cursor, tc.font_size, COLOR_FG, "collection")
			}

			if phase == .Measure {
				remaining_offset = math.max(remaining_offset, cursor.x - this_col1_offset)
			}

			if phase == .Measure && selected {
				cursor_selected = cursor
			}

			cursor += tc.row_offset
		}
	}
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

DrawLineResult :: struct {
	start_caret_at, end_caret_at : Vec2,
	set_start, set_end: bool,

	cursor : Vec2,
	idx    : int,

	all_right  : bool,
}

pull_float :: proc(str: ^string) -> (val: f32, ok: bool) {
	val_str := strings.split_iterator(str, ",") or_return

	val_str = strings.trim_space(val_str)
	val, ok  = strconv.parse_f32(val_str)

	return
}

get_first_segment :: proc(path: string) -> string {
	path := path
	for {
		a1, _ := filepath.split(path)
		if a1 == "" {break}

		path = a1
	}

	return path
}

get_progress_path :: proc(sample: ^Sample, allocator : mem.Allocator) -> string {
	progress_relative_path := sample.relative_path[len(COLLECTIONS_PATH):]
	progress_path, fp_err  := filepath.join({".", "progress", progress_relative_path}, allocator)
	assert(fp_err == nil)

	debug_log("progress path: %v, rel pat %v", progress_path, progress_relative_path)

	return progress_path
}

// It's important that relative_sample_path is relative to the current working dir
load_progress :: proc(sample: ^Sample) {
	progress_path := get_progress_path(sample, context.allocator)
	defer delete(progress_path)

	progress_text_bytes, err := os.read_entire_file_from_path(progress_path, context.allocator)
	defer delete(progress_text_bytes)
	if err != .FILE_NOT_FOUND && err != .Not_Exist && err != nil {
		debug_log("load error %v path %v", err)
		// Not a big deal.
		return
	}

	progress_text := string(progress_text_bytes)
	personal_best, ok := pull_float(&progress_text)
	if ok {
		sample.personal_best = personal_best

		perfect, ok := pull_float(&progress_text)
		if ok {
			sample.perfect = perfect == 1
		}

		debug_log("loaded pb=%v, perfect=%v", personal_best, perfect)
	}
}

save_progress :: proc(state: ^State, sample: ^Sample) {
	debug_log("saving new pb: %v, %v, %v", sample.name, sample.personal_best, sample.perfect)

	if IS_DEBUGGING_NEW_RECORD {return}

	progress_path := get_progress_path(sample, context.allocator)
	defer delete(progress_path)

	{
		progress_dir  := filepath.dir(progress_path, context.allocator)
		defer delete(progress_dir)

		make_directory_err := os.make_directory_all(progress_dir)
		if make_directory_err != nil {return}
	}

	file_text := fmt.aprintf("%v,%v", sample.personal_best, sample.perfect ? 1 : 0, allocator=context.allocator)
	defer delete(file_text)

	err := os.write_entire_file_from_string(progress_path, file_text)
	if err != nil {return}
}

DrawTextResult :: struct {
	cursor         : Vec2,
	start_caret_at : Vec2,
	end_caret_at   : Vec2,
}

TextConfig :: struct {
	vh: f32,
	font_size, spacing, vertical_spacing : f32,
	row_offset: Vec2,
}

create_text_config :: proc(font_size_vh: f32, window_size: Vec2) -> (result: TextConfig) {
	result.vh = font_size_vh;
	result.font_size          = math.round(window_size.y * font_size_vh)
	result.spacing            = f32(0) // font_size / 10
	result.vertical_spacing   = result.font_size / 5
	result.row_offset         = Vec2{0, result.font_size + result.vertical_spacing}
	return
}

counter := 0

draw_text_overlayed :: proc(tc: TextConfig, phase: UiPhase, typing: ^TypingState, cursor: Vec2, window_size: Vec2) -> (result: DrawTextResult) {
	cursor := cursor

	final_typed_cursor : Vec2
	final_typed_cursor_idx := -1

	n_typed  := len(typing.typed)
	n_target := len(typing.sample.text)

	// the same indices can be seen multiple times.
	// we want to keep the earliest set
	set_start, set_end := false, false
	cursor_start := cursor

	typed_idx, target_idx := 0, 0
	block_typed, block_target := false, false

	had_typed := false
	for typed_idx <= n_typed || target_idx <= n_target {
		typed_char, has_typed   := char_ok(typing.typed[:],    typed_idx)
		target_char, has_target := char_ok(typing.sample.text, target_idx)
		defer had_typed = has_typed

		target_is_newline_or_end := target_char == '\n' || !has_target
		typed_is_newline_or_end  := typed_char == '\n' || !has_typed

		lo, hi         := get_lo_hi(typing.range)
		is_highlighted := lo <= typed_idx && typed_idx < hi

		just_blocked_typed := false

		finished_drawing_line := false
		if target_is_newline_or_end && typed_is_newline_or_end {
			if !block_target && !block_typed {
				finished_drawing_line = true
			} else if block_target || block_typed {
				finished_drawing_line = true
				block_target = false
				block_typed = false
			}
		} else if target_is_newline_or_end {
			block_target = true
		} else if typed_is_newline_or_end {
			if !block_typed {
				just_blocked_typed = true
				block_typed = true
			}
		}

		defer if !block_typed  { typed_idx  += 1 }
		defer if !block_target { target_idx += 1 }

		width := math.max(
			measure_letter(typed_char, tc, has_typed && !block_typed),
			measure_letter(target_char, tc, has_target && !block_target)
		)
		if cursor.x + width > window_size.x {
			// NOTE: Update the other place as well
			// Wrap the text - the current line has overflowed
			cursor.x = cursor_start.x
			cursor.y += tc.row_offset.y
		}

		if has_typed || had_typed {
			if typed_idx == typing.range.start && !set_start {
				result.start_caret_at, set_start = cursor, true
			}
			if typed_idx == typing.range.end && !set_end {
				result.end_caret_at, set_end = cursor, true
			}

			if final_typed_cursor_idx < typed_idx {
				final_typed_cursor, final_typed_cursor_idx = cursor, typed_idx
			}
		}

		has_typed_unblocked := has_typed
		if block_typed  {has_typed  = false}
		if block_target {has_target = false}

		is_wrong := false
		if has_typed && has_target {
			is_wrong = target_char != typed_char
		} else if has_typed && block_target {
			is_wrong = true
		} else if has_typed_unblocked && just_blocked_typed {
			is_wrong = true
		}

		// NOTE: Mutating while rendering is typically wrong.
		// Should be fine here tho
		if is_wrong {
			typing.perfect = false
		}

		if phase == .Draw {
			char := target_char
			col  := COLOR_TARGET
			bg_col := Color{}

			if is_highlighted && (has_typed || had_typed) {
				col = COLOR_BG
				char = typed_char
				bg_col = COLOR_HIGHLIGHT
			} else if is_wrong {
				if counter % 30 < 15 {
					col = COLOR_WRONG
					char = typed_char
				} else {
					col = COLOR_TARGET
					char = target_char
				}
			} else if has_typed {
				col = COLOR_FG
				char = typed_char
			} 

			draw_single_character_with_highlight(cursor, char, tc, width, col, bg_col, draw_newline = is_wrong)
		}

		cursor.x += width + tc.spacing
		if finished_drawing_line  {
			// NOTE: Update the other place as well
			// Wrap the text - newline
			cursor.x = cursor_start.x
			cursor.y += tc.row_offset.y
		}
	}

	result.cursor = cursor

	return 
}


draw_single_character_with_highlight :: proc(
	cursor: Vec2, 
	char: u8,
	tc: TextConfig,
	width: f32,
	col, bg_col: Color,
	draw_newline: bool,
) {
	if bg_col != {} {
		draw_letter_highlight(cursor, width, tc.spacing, tc.vertical_spacing, tc.font_size, bg_col)
	}

	if char == '\n' {
		if draw_newline {
			draw_text(.Draw, cursor + {0, tc.font_size / 4}, tc.font_size / 2, col, NEWLINE_STR)
		}
	} else if char == '\t' {
		draw_text(.Draw, cursor + {width/2, tc.font_size / 4}, tc.font_size / 2, col, TAB_STR, alignment = 0.5)
	} else {
		draw_text(.Draw, cursor, tc.font_size, col, "%c", char)
	}
}

measure_letter :: proc(char: byte, tc: TextConfig, has: bool) -> f32 {
	if !has {return 0}

	width : f32
	if char == '\n' {
		width = draw_text(.Measure, {}, tc.font_size / 2, {}, "%v", {})
	} else if char == '\t' {
		// 4 width is my preferred when actually coding, but I think it wastes too much space visually
		width = draw_text(.Measure, {}, tc.font_size, {}, " ") * 4
	} else {
		width = draw_text(.Measure, {}, tc.font_size, {}, "%c", char)
	}
	return width
}

main :: proc() {
	when IS_DEBUGGING_ALLOCATIONS {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			} else {
				fmt.eprintf("=== all allocations freed! no error ===\n")
			}
			mem.tracking_allocator_destroy(&track)
		}
	}
	
	// Can't use .WINDOW_HIGHDPI because the height returned by GetScreenHeight and GetRenderHeight are both underreportoed
	rl.SetConfigFlags({.VSYNC_HINT})
	rl.InitWindow(800, 600, "RoboType")
	if WINDOWED {
		rl.SetWindowState({.WINDOW_RESIZABLE})
	} else {
		rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	}
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

	when IS_DEBUGGING_ALLOCATIONS {
		// I'de like the tracking allocator to ignore anything in the persistent stores.

		path := state.current_path
		for path != nil {
			next_path := path.parent
			free(path)
			path = next_path
		}

		free_all(state.available_samples_allocator)
		free(state)
		mem.dynamic_arena_destroy(&state.available_samples_arena)
		delete(state.available_items)

		#reverse for item in state.typing.undo_buffer {
			delete_undo_entry(item)
		}
		delete(state.typing.undo_buffer)
		delete(state.typing.typed)
		delete(state.typing.copied)
	}
}
