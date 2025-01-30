package main

import "base:runtime"
import "core:fmt"
import "core:dynlib"
import "core:log"
import "core:os/os2"
import "core:path/filepath"
import "core:time"
import sapp "shared:sokol/app"
import shelpers "shared:sokol/helpers"

default_context: runtime.Context

game: Game_API
old_games: [dynamic]Game_API
next_dll_version: int

Game_API :: struct {
	__handle: dynlib.Library,
	version: int,
	mod_time: time.Time,
	init: proc(),
	cleanup: proc(),
	frame: proc(),
	event: proc(e: ^sapp.Event),
	should_quit: proc() -> bool,
	get_mem: proc() -> rawptr,
	get_mem_size: proc() -> int,
	reloaded: proc(mem: rawptr),
}

GAME_DLL_PATH :: "hot_reload/game.dll"

get_game_version_path :: proc(version: int) -> string {
	return fmt.tprintf("hot_reload/game_{0}.dll", version)
}

load_game_dll :: proc() -> (api: Game_API, ok: bool) {
	mod_time, mod_time_err := os2.modification_time_by_path(GAME_DLL_PATH)
	if mod_time_err != nil {
		log.errorf("Could not get moditication time of {0}", GAME_DLL_PATH)
		return
	}

	game_dll_copy_path := get_game_version_path(next_dll_version)
	copy_err := os2.copy_file(game_dll_copy_path, GAME_DLL_PATH)
	if copy_err != nil {
		// file might be locked so don't complain for now
		return
	}

	if _, ok := dynlib.initialize_symbols(&api, game_dll_copy_path, "game_"); !ok {
		log.errorf("Could not load game library {0}: {1}", game_dll_copy_path, dynlib.last_error())
		return
	}

	api.mod_time = mod_time
	api.version = next_dll_version
	next_dll_version += 1
	ok = true
	return
}

unload_game_dll :: proc(api: Game_API) {
	unload_ok := dynlib.unload_library(api.__handle)
	if !unload_ok {
		log.errorf("Could not unload game library: {0}", dynlib.last_error())
		return
	}

	game_dll_path := get_game_version_path(api.version)
	remove_err := os2.remove(game_dll_path)
	if remove_err != nil {
		log.errorf("Could not remove game library file {0}", game_dll_path)
	}
}

main :: proc() {
	context.logger = log.create_console_logger()
	default_context = context

	exe_dir := filepath.dir(os2.args[0], context.temp_allocator)
	os2.set_working_directory(exe_dir)

	game_api, game_api_ok := load_game_dll()
	if !game_api_ok {
		return
	}

	game = game_api
	old_games = make([dynamic]Game_API)

	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		event_cb = event,
		width = 1280,
		height = 720,
		window_title = "Game",
		enable_clipboard = true,
		logger = sapp.Logger(shelpers.logger(&default_context)),
		allocator = sapp.Allocator(shelpers.allocator(&default_context))
	})
}

init :: proc "c" () {
	context = default_context

	game.init()
}

frame :: proc "c" () {
	context = default_context

	reload := false
	mod_time, mod_time_err := os2.modification_time_by_path(GAME_DLL_PATH)
	if mod_time_err == nil && game.mod_time != mod_time {
		reload = true
	}

	if reload {
		log.debug("Reloading modified game library")
		new_game, new_game_ok := load_game_dll()
		if new_game_ok {
			old_game := game
			game = new_game

			if game.get_mem_size() != old_game.get_mem_size() {
				// structure changed, need a full reset
				log.debug("Memory size changed - doing a full reinit")

				old_game.cleanup()

				unload_game_dll(old_game)
				for g in old_games {
					unload_game_dll(g)
				}
				clear(&old_games)

				game.init()
			} else {
				// structure (probably) hasn't changed - do a hot reload
				append(&old_games, old_game)
				game.reloaded(old_game.get_mem())
				log.debug("Game library reloaded")
			}
		}
	}

	if game.should_quit() {
		sapp.quit()
		return
	}

	game.frame()
	free_all(context.temp_allocator)
}

cleanup :: proc "c" () {
	context = default_context

	game.cleanup()
	free_all(context.temp_allocator)
	unload_game_dll(game)
	for g in old_games {
		unload_game_dll(g)
	}
	delete(old_games)
}

event :: proc "c" (e: ^sapp.Event) {
	context = default_context

	game.event(e)
}