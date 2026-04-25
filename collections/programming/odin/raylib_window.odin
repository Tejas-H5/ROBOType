package raylib_window

import rl "vendor:raylib"
import "core:c"

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI})

	rl.InitWindow(0, 0, "RoboType")
	defer rl.CloseWindow()

	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))

	for !rl.WindowShouldClose() {
		window_size := [2]c.int{rl.GetScreenWidth(), rl.GetScreenHeight()}
		center      := window_size / 2
			
		rl.ClearBackground({255, 255, 255, 255 })
		rl.DrawText("Raycasting Library", center.x, center.y, 100, rl.Color{0, 0, 0, 255})

		free_all(context.temp_allocator)
	}
}
