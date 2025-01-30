package game

import "base:runtime"
import "core:log"
import sapp "shared:sokol/app"
import shelpers "shared:sokol/helpers"
import sg "shared:sokol/gfx"
import imgui "shared:imgui"
import simgui "simgui"

default_context: runtime.Context

Globals :: struct {
	should_quit: bool,
	pass_action: sg.Pass_Action,
	imgui_context: ^simgui.Context,
}

g: ^Globals

@(export)
game_init :: proc() {
	default_context = context

	g = new(Globals)

	sg.setup({
		environment = shelpers.glue_environment(),
		logger = sg.Logger(shelpers.logger(&default_context)),
		allocator = sg.Allocator(shelpers.allocator(&default_context)),
	})
	g.imgui_context = simgui.setup()

	game_reloaded(g)
}

@(export)
game_cleanup :: proc() {
	simgui.shutdown()
	sg.shutdown()
	free(g)
}

@(export)
game_reloaded :: proc(mem: rawptr) {
	g = transmute(^Globals)mem

	simgui.set_context(g.imgui_context)

	g.pass_action.colors[0] = { load_action = .CLEAR, clear_value = {0,0,0,1} }
}

@(export)
game_should_quit :: proc() -> bool {
	return g.should_quit
}

@(export)
game_get_mem :: proc() -> rawptr {
	return g
}

@(export)
game_get_mem_size :: proc() -> int {
	return size_of(Globals)
}

@(export)
game_frame :: proc() {
    simgui.new_frame({
		width = sapp.width(),
		height = sapp.height(),
		delta_time = sapp.frame_duration(),
		dpi_scale = sapp.dpi_scale(),
	})

	sg.begin_pass({ action = g.pass_action, swapchain = shelpers.glue_swapchain() })
	simgui.render()
	sg.end_pass()
	sg.commit()

}

@(export)
game_event :: proc(e: ^sapp.Event) {
	if simgui.handle_event(e) {
		return
	}

	if e.type == .KEY_DOWN && e.key_code == .ESCAPE {
		g.should_quit = true
	}
}