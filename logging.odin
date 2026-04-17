package main

import "core:log"
import "core:fmt"

LoggingType :: enum {
	None,
	Logger,
	Fmt,
}

logging_type := LoggingType.Logger

set_logging_type :: proc(type: LoggingType) {
	logging_type = type
}

debug_log :: proc(format: string, args: ..any, location := #caller_location) {
	switch logging_type {
	case .None:
	case .Logger:
		log.infof(format, ..args, location=location)
	case .Fmt:
		fmt.printfln(format, ..args)
	}
}

// Don't remove calls to this
debug_log_intentional :: debug_log
