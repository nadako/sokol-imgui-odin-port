package simgui

import "core:c"
import "core:mem"
import imgui "shared:imgui"
import sapp "shared:sokol/app"
import sg "shared:sokol/gfx"

Context :: struct {
	cur_dpi_scale: f32,
	vbuf: sg.Buffer,
	ibuf: sg.Buffer,
	font_img: sg.Image,
	font_smp: sg.Sampler,
	def_img: sg.Image,
	def_smp: sg.Sampler,
	def_shd: sg.Shader,
	def_pip: sg.Pipeline,
    // separate shader and pipeline for unfilterable user images
    shd_unfilterable: sg.Shader,
    pip_unfilterable: sg.Pipeline,
	vertices: []imgui.DrawVert,
	indices: []imgui.DrawIdx,
	is_osx: bool,
	// store imgui context so we can restore it for hot-reload
	imgui_context: ^imgui.Context,
}
ctx: ^Context

setup :: proc() -> ^Context {
	MAX_VERTICES :: 65536 // TODO: this could/should be configurable with the desc

	ctx = new(Context)
	ctx.cur_dpi_scale = 1.0
	ctx.is_osx = is_osx()

    // allocate an intermediate vertex- and index-buffer
    ctx.vertices = make([]imgui.DrawVert, MAX_VERTICES)
    ctx.indices = make([]imgui.DrawIdx, MAX_VERTICES * 3)

    // initialize Dear ImGui
	ctx.imgui_context = imgui.CreateContext()
	io := imgui.GetIO()
	imgui.FontAtlas_AddFontDefault(io.Fonts)
	io.ConfigMacOSXBehaviors = is_osx()
	io.BackendFlags += {.RendererHasVtxOffset, .HasMouseCursors}

	pio := imgui.GetPlatformIO()
	pio.Platform_SetClipboardTextFn = set_clipboard
	pio.Platform_GetClipboardTextFn = get_clipboard

	sg.push_debug_group("sokol-imgui")

	shd_desc := simgui_shader_desc(sg.query_backend())
	ctx.def_shd = sg.make_shader(shd_desc)

	pip_desc := sg.Pipeline_Desc{
		label = "sokol-imgui-pipeline",
		shader = ctx.def_shd,
		layout = {
			attrs = {
				ATTR_simgui_position = {
					offset = i32(offset_of(imgui.DrawVert, pos)),
					format = .FLOAT2
				},
				ATTR_simgui_texcoord0 ={
					offset = i32(offset_of(imgui.DrawVert, uv)),
					format = .FLOAT2
				},
				ATTR_simgui_color0 = {
					offset = i32(offset_of(imgui.DrawVert, col)),
					format = .UBYTE4N
				},
			},
			buffers = {
				0 = { stride = size_of(imgui.DrawVert) }
			},
		},
		index_type = .UINT16,
		colors = {
			0 = {
				write_mask = .RGB,
				blend = {
					enabled = true,
					src_factor_rgb = .SRC_ALPHA,
					dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
				}
			}
		},
	}
	ctx.def_pip = sg.make_pipeline(pip_desc)

    // create a unfilterable/nonfiltering variants of the shader and pipeline
    shd_desc.images[IMG_tex].sample_type = .UNFILTERABLE_FLOAT
    shd_desc.samplers[SMP_smp].sampler_type = .NONFILTERING
    shd_desc.label = "sokol-imgui-shader-unfilterable"
    ctx.shd_unfilterable = sg.make_shader(shd_desc)
    pip_desc.shader = ctx.shd_unfilterable
    pip_desc.label = "sokol-imgui-pipeline-unfilterable"
    ctx.pip_unfilterable = sg.make_pipeline(pip_desc)

	ctx.vbuf = sg.make_buffer({
		usage = .STREAM,
		size = len(ctx.vertices) * size_of(imgui.DrawVert),
		label = "sokol-imgui-vertices",
	})

	ctx.ibuf = sg.make_buffer({
		type = .INDEXBUFFER,
		usage = .STREAM,
		size = len(ctx.indices) * size_of(imgui.DrawIdx),
		label = "sokol-imgui-indices",
	})

	// a default user-image sampler
	ctx.def_smp = sg.make_sampler({
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
		label = "sokol-imgui-default-sampler",
	})

    // a default user image
	def_pixels: [64]u32 = 0xFF
    ctx.def_img = sg.make_image({
		width = 8,
		height = 8,
		pixel_format = .RGBA8,
		data = {
			subimage = {
				0 = {
					0 = {
						ptr = &def_pixels,
						size = size_of(def_pixels)
					}
				}
			}
		},
		label = "sokol-imgui-default-image",
	})

	create_fonts_texture(io)

	sg.pop_debug_group()

	return ctx
}

set_context :: proc(new_context: ^Context) {
	ctx = new_context
	imgui.SetCurrentContext(ctx.imgui_context)
}

create_fonts_texture :: proc(io: ^imgui.IO) {
	ctx.font_smp = sg.make_sampler({
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
		label = "sokol-imgui-font-sampler",
	})

	pixels: ^c.uchar
    width, height: c.int
	imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, nil)

	ctx.font_img = sg.make_image({
		width = width,
		height = height,
		pixel_format = .RGBA8,
		data = {
			subimage = {
				0 = {
					0 = { ptr = pixels, size = uint(width * height) * size_of(u32)}
				}
			}
		},
		label = "sokol-imgui-font-image",
	})
	io.Fonts.TexID = imtextureid_with_sampler(ctx.font_img, ctx.font_smp)
}

destroy_fonts_texture :: proc() {
    // NOTE: it's valid to call the destroy funcs with sg.INVALID_ID
    sg.destroy_sampler(ctx.font_smp)
    sg.destroy_image(ctx.font_img)
    ctx.font_smp.id = sg.INVALID_ID
    ctx.font_img.id = sg.INVALID_ID
}

shutdown :: proc() {
	imgui.DestroyContext()
	sg.destroy_pipeline(ctx.pip_unfilterable)
	sg.destroy_shader(ctx.shd_unfilterable)
    sg.destroy_pipeline(ctx.def_pip)
    sg.destroy_shader(ctx.def_shd)
    sg.destroy_sampler(ctx.font_smp)
    sg.destroy_image(ctx.font_img)
    sg.destroy_sampler(ctx.def_smp)
    sg.destroy_image(ctx.def_img)
    sg.destroy_buffer(ctx.ibuf)
    sg.destroy_buffer(ctx.vbuf)
    sg.pop_debug_group()
    sg.push_debug_group("sokol-imgui")
    delete(ctx.vertices)
    delete(ctx.indices)
}

imtextureid_with_sampler :: proc(img: sg.Image, smp: sg.Sampler) -> imgui.TextureID {
    return transmute(imgui.TextureID)((u64(smp.id)<<32) | u64(img.id))
}

imtextureid :: proc(img: sg.Image) -> imgui.TextureID {
    return imtextureid_with_sampler(img, ctx.def_smp);
}

image_from_imtextureid :: proc(imtex_id: imgui.TextureID) -> sg.Image {
	imtex_id := transmute(u64)imtex_id
    return sg.Image { u32(imtex_id) }
}

sampler_from_imtextureid :: proc(imtex_id: imgui.TextureID) -> sg.Sampler {
	imtex_id := transmute(u64)imtex_id
    return sg.Sampler { u32(imtex_id >> 32) }
}

set_clipboard :: proc "c" (ctx: ^imgui.Context, text: cstring) {
	sapp.set_clipboard_string(text)
}

get_clipboard :: proc "c" (ctx: ^imgui.Context) -> cstring {
	return sapp.get_clipboard_string()
}

Frame_Desc :: struct {
	width: i32,
	height: i32,
	delta_time: f64,
	dpi_scale: f32,
}

new_frame :: proc(desc: Frame_Desc) {
	ctx.cur_dpi_scale = desc.dpi_scale

	io := imgui.GetIO()

	if !io.Fonts.TexReady {
		destroy_fonts_texture()
		create_fonts_texture(io)
	}

	io.DisplaySize.x = f32(desc.width) / desc.dpi_scale
	io.DisplaySize.y = f32(desc.height) / desc.dpi_scale
	io.DeltaTime = f32(desc.delta_time)

	if io.WantTextInput && !sapp.keyboard_shown() {
		sapp.show_keyboard(true)
	}
	if !io.WantTextInput && sapp.keyboard_shown() {
		sapp.show_keyboard(false)
	}

	imgui_cursor := imgui.GetMouseCursor()
	cursor := sapp.get_mouse_cursor()
	#partial switch imgui_cursor {
		case .Arrow:        cursor = .ARROW
		case .TextInput:    cursor = .IBEAM
		case .ResizeAll:    cursor = .RESIZE_ALL
		case .ResizeNS:     cursor = .RESIZE_NS
		case .ResizeEW:     cursor = .RESIZE_EW
		case .ResizeNESW:   cursor = .RESIZE_NESW
		case .ResizeNWSE:   cursor = .RESIZE_NWSE
		case .Hand:         cursor = .POINTING_HAND
		case .NotAllowed:   cursor = .NOT_ALLOWED
	}
	sapp.set_mouse_cursor(cursor)

	imgui.NewFrame()
}

bind_image_sampler :: proc(bindings: ^sg.Bindings, imtex_id: imgui.TextureID) -> sg.Pipeline {
    bindings.images[IMG_tex] = image_from_imtextureid(imtex_id)
    bindings.samplers[SMP_smp] = sampler_from_imtextureid(imtex_id)
    if sg.query_pixelformat(sg.query_image_pixelformat(bindings.images[IMG_tex])).filter {
        return ctx.def_pip
    } else {
		return ctx.pip_unfilterable
    }
}

render :: proc() {
	imgui.Render()

	draw_data := imgui.GetDrawData()
	io := imgui.GetIO()

	if draw_data == nil || draw_data.CmdLists.Size == 0 do return

	command_lists := mem.slice_ptr(draw_data.CmdLists.Data, int(draw_data.CmdLists.Size))

    /* copy vertices and indices into an intermediate buffer so that
       they can be updated with a single sg_update_buffer() call each
       (sg_append_buffer() has performance problems on some GL platforms),
       also keep track of valid number of command lists in case of a
       buffer overflow
    */
    all_vtx_size := 0
    all_idx_size := 0
    cmd_list_count := 0
	for cl in command_lists {
        vtx_size := int(cl.VtxBuffer.Size)
        idx_size := int(cl.IdxBuffer.Size)

        // check for buffer overflow
        if (all_vtx_size + vtx_size) > len(ctx.vertices) ||
		   (all_idx_size + idx_size) > len(ctx.indices) {
            break
        }

        // copy vertices and indices into common buffers
        if vtx_size > 0 do copy(ctx.vertices[all_vtx_size:all_vtx_size+vtx_size], mem.slice_ptr(cl.VtxBuffer.Data, vtx_size))
        if idx_size > 0 do copy(ctx.indices[all_idx_size:all_idx_size+idx_size], mem.slice_ptr(cl.IdxBuffer.Data, idx_size))

        all_vtx_size += vtx_size
        all_idx_size += idx_size

		cmd_list_count += 1
	}

	if cmd_list_count == 0 do return

	sg.push_debug_group("sokol-imgui")

	if all_vtx_size > 0 do sg.update_buffer(ctx.vbuf, {ptr = raw_data(ctx.vertices), size = uint(all_vtx_size * size_of(imgui.DrawVert))})
    if all_idx_size > 0 do sg.update_buffer(ctx.ibuf, {ptr = raw_data(ctx.indices), size = uint(all_idx_size * size_of(imgui.DrawIdx))})

	dpi_scale := ctx.cur_dpi_scale
	fb_width := int(io.DisplaySize.x * dpi_scale)
    fb_height := int(io.DisplaySize.y * dpi_scale)
    sg.apply_viewport(0, 0, fb_width, fb_height, true)
    sg.apply_scissor_rect(0, 0, fb_width, fb_height, true)

    sg.apply_pipeline(ctx.def_pip)

	vs_params := Vs_Params {
		disp_size = { io.DisplaySize.x, io.DisplaySize.y }
	}
	sg.apply_uniforms(UB_vs_params, range_def(&vs_params))

	bind := sg.Bindings {
		vertex_buffers = {0 = ctx.vbuf},
		index_buffer = ctx.ibuf
	}

	tex_id := io.Fonts.TexID
	bind_image_sampler(&bind, tex_id)

	vb_offset: i32 = 0
    ib_offset: i32 = 0
	for cl in command_lists {
		bind.vertex_buffer_offsets[0] = vb_offset
		bind.index_buffer_offset = ib_offset
		sg.apply_bindings(bind)

		commands := mem.slice_ptr(cl.CmdBuffer.Data, int(cl.CmdBuffer.Size))
		vtx_offset: u32 = 0
		for &pcmd in commands {
			if pcmd.UserCallback != nil {
                // User callback, registered via ImDrawList::AddCallback()
                // (ImDrawCallback_ResetRenderState is a special callback value used by the user to request the renderer to reset render state.)
				if pcmd.UserCallback != ImDrawCallback_ResetRenderState {
					pcmd.UserCallback(cl, &pcmd)
                    // need to re-apply all state after calling a user callback
					sg.reset_state_cache()
                    sg.apply_viewport(0, 0, fb_width, fb_height, true)
                    sg.apply_pipeline(ctx.def_pip)
                    sg.apply_uniforms(UB_vs_params, range_def(&vs_params))
                    sg.apply_bindings(bind)
				}
			} else {
				if tex_id != pcmd.TextureId || vtx_offset != pcmd.VtxOffset {
					tex_id = pcmd.TextureId
					vtx_offset = pcmd.VtxOffset

					pip := bind_image_sampler(&bind, tex_id)
					sg.apply_pipeline(pip)
					sg.apply_uniforms(UB_vs_params, range_def(&vs_params))
					bind.vertex_buffer_offsets[0] = vb_offset + i32(pcmd.VtxOffset * size_of(imgui.DrawVert))
					sg.apply_bindings(bind)
				}
                scissor_x := int(pcmd.ClipRect.x * dpi_scale)
                scissor_y := int(pcmd.ClipRect.y * dpi_scale)
                scissor_w := int((pcmd.ClipRect.z - pcmd.ClipRect.x) * dpi_scale)
                scissor_h := int((pcmd.ClipRect.w - pcmd.ClipRect.y) * dpi_scale)
                sg.apply_scissor_rect(scissor_x, scissor_y, scissor_w, scissor_h, true)
				sg.draw(pcmd.IdxOffset, pcmd.ElemCount, 1)
			}
		}

		vtx_size := cl.VtxBuffer.Size * size_of(imgui.DrawVert)
		idx_size := cl.IdxBuffer.Size * size_of(imgui.DrawIdx)
		vb_offset += vtx_size
		ib_offset += idx_size
	}

	sg.apply_viewport(0, 0, fb_width, fb_height, true)
    sg.apply_scissor_rect(0, 0, fb_width, fb_height, true)
	sg.pop_debug_group()
}

range_def :: proc(v: ^$T) -> sg.Range {
	return {ptr = v, size = size_of(T)}
}

ImDrawCallback_ResetRenderState := transmute(imgui.DrawCallback)(~uintptr(7))

handle_event :: proc(ev: ^sapp.Event) -> bool {
	dpi_scale := ctx.cur_dpi_scale
	io := imgui.GetIO()

	branch: {
	#partial switch ev.type {
		case .FOCUSED:
			imgui.IO_AddFocusEvent(io, true)
		case .UNFOCUSED:
			imgui.IO_AddFocusEvent(io, false)
		case .MOUSE_DOWN:
			add_mouse_pos_event(io, ev.mouse_x / dpi_scale, ev.mouse_y / dpi_scale)
			add_mouse_button_event(io, i32(ev.mouse_button), true)
			update_modifiers(io, ev.modifiers)
		case .MOUSE_UP:
			add_mouse_pos_event(io, ev.mouse_x / dpi_scale, ev.mouse_y / dpi_scale)
			add_mouse_button_event(io, i32(ev.mouse_button), false)
			update_modifiers(io, ev.modifiers)
		case .MOUSE_MOVE:
			add_mouse_pos_event(io, ev.mouse_x / dpi_scale, ev.mouse_y / dpi_scale)
		case .MOUSE_ENTER:
		case .MOUSE_LEAVE:
			// TODO
		case .MOUSE_SCROLL:
			add_mouse_wheel_event(io, ev.scroll_x, ev.scroll_y)
		case .TOUCHES_BEGAN:
            add_touch_pos_event(io, ev.touches[0].pos_x / dpi_scale, ev.touches[0].pos_y / dpi_scale)
            add_touch_button_event(io, 0, true)
		case .TOUCHES_MOVED:
            add_touch_pos_event(io, ev.touches[0].pos_x / dpi_scale, ev.touches[0].pos_y / dpi_scale)
		case .TOUCHES_ENDED:
            add_touch_pos_event(io, ev.touches[0].pos_x / dpi_scale, ev.touches[0].pos_y / dpi_scale)
            add_touch_button_event(io, 0, false)
		case .TOUCHES_CANCELLED:
            add_touch_button_event(io, 0, false)
		case .KEY_DOWN:
			update_modifiers(io, ev.modifiers)
            // intercept Ctrl-V, this is handled via EVENTTYPE_CLIPBOARD_PASTED
			if is_ctrl(ev.modifiers) && (ev.key_code == .V) {
				break branch
			}
            // on web platform, don't forward Ctrl-X, Ctrl-V to the browser
            if is_ctrl(ev.modifiers) && (ev.key_code == .X) {
                sapp.consume_event()
            }
            if is_ctrl(ev.modifiers) && (ev.key_code == .C) {
                sapp.consume_event()
            }
            // it's ok to add ImGuiKey_None key events
            add_sapp_key_event(io, ev.key_code, true);
		case .KEY_UP:
			update_modifiers(io, ev.modifiers)
            // intercept Ctrl-V, this is handled via EVENTTYPE_CLIPBOARD_PASTED
            if is_ctrl(ev.modifiers) && (ev.key_code == .V) {
                break branch
            }
            // on web platform, don't forward Ctrl-X, Ctrl-V to the browser
            if is_ctrl(ev.modifiers) && (ev.key_code == .X) {
                sapp.consume_event()
            }
            if is_ctrl(ev.modifiers) && (ev.key_code == .C) {
                sapp.consume_event()
            }
            // it's ok to add ImGuiKey_None key events
            add_sapp_key_event(io, ev.key_code, false)
		case .CHAR:
            /* on some platforms, special keys may be reported as
               characters, which may confuse some ImGui widgets,
               drop those, also don't forward characters if some
               modifiers have been pressed
            */
			update_modifiers(io, ev.modifiers)
            if (ev.char_code >= 32) &&
               (ev.char_code != 127) &&
               (0 == (ev.modifiers & (sapp.MODIFIER_ALT|sapp.MODIFIER_CTRL|sapp.MODIFIER_SUPER)))
            {
                add_input_character(io, ev.char_code);
            }
		case .CLIPBOARD_PASTED:
            // simulate a Ctrl-V key down/up
			add_imgui_key_event(io, copypaste_modifier(), true)
			add_imgui_key_event(io, .V, true)
			add_imgui_key_event(io, .V, false)
			add_imgui_key_event(io, copypaste_modifier(), false)
	}
	}

	return io.WantCaptureKeyboard || io.WantCaptureMouse
}

add_mouse_pos_event :: proc(io: ^imgui.IO, x, y: f32) {
	imgui.IO_AddMouseSourceEvent(io, .Mouse)
	imgui.IO_AddMousePosEvent(io, x, y)
}

add_mouse_button_event :: proc(io: ^imgui.IO, mouse_button: i32, down: bool) {
	imgui.IO_AddMouseSourceEvent(io, .Mouse)
	imgui.IO_AddMouseButtonEvent(io, mouse_button, down)
}

update_modifiers :: proc(io: ^imgui.IO, mods: u32) {
    imgui.IO_AddKeyEvent(io, .ImGuiMod_Ctrl, (mods & sapp.MODIFIER_CTRL) != 0)
    imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, (mods & sapp.MODIFIER_SHIFT) != 0)
    imgui.IO_AddKeyEvent(io, .ImGuiMod_Alt, (mods & sapp.MODIFIER_ALT) != 0)
    imgui.IO_AddKeyEvent(io, .ImGuiMod_Super, (mods & sapp.MODIFIER_SUPER) != 0)
}

add_mouse_wheel_event :: proc(io: ^imgui.IO, wheel_x, wheel_y: f32) {
	imgui.IO_AddMouseSourceEvent(io, .Mouse)
	imgui.IO_AddMouseWheelEvent(io, wheel_x, wheel_y)
}

add_touch_pos_event :: proc(io: ^imgui.IO, x, y: f32) {
	imgui.IO_AddMouseSourceEvent(io, .TouchScreen)
	imgui.IO_AddMousePosEvent(io, x, y)
}

add_touch_button_event :: proc(io: ^imgui.IO, mouse_button: i32, down: bool) {
	imgui.IO_AddMouseSourceEvent(io, .TouchScreen)
	imgui.IO_AddMouseButtonEvent(io, mouse_button, down)
}

add_input_character :: proc(io: ^imgui.IO, c: u32) {
	imgui.IO_AddInputCharacter(io, c);
}

add_sapp_key_event :: proc(io: ^imgui.IO, sapp_key: sapp.Keycode, down: bool) {
    imgui_key := map_keycode(sapp_key)
	imgui.IO_AddKeyEvent(io, imgui_key, down)
}

add_imgui_key_event :: proc(io: ^imgui.IO, imgui_key: imgui.Key, down: bool) {
	imgui.IO_AddKeyEvent(io, imgui_key, down)
}

map_keycode :: proc(key: sapp.Keycode) -> imgui.Key {
    #partial switch key {
        case .SPACE:        return .Space;
        case .APOSTROPHE:   return .Apostrophe;
        case .COMMA:        return .Comma;
        case .MINUS:        return .Minus;
        case .PERIOD:       return .Apostrophe;
        case .SLASH:        return .Slash;
        case ._0:            return ._0;
        case ._1:            return ._1;
        case ._2:            return ._2;
        case ._3:            return ._3;
        case ._4:            return ._4;
        case ._5:            return ._5;
        case ._6:            return ._6;
        case ._7:            return ._7;
        case ._8:            return ._8;
        case ._9:            return ._9;
        case .SEMICOLON:    return .Semicolon;
        case .EQUAL:        return .Equal;
        case .A:            return .A;
        case .B:            return .B;
        case .C:            return .C;
        case .D:            return .D;
        case .E:            return .E;
        case .F:            return .F;
        case .G:            return .G;
        case .H:            return .H;
        case .I:            return .I;
        case .J:            return .J;
        case .K:            return .K;
        case .L:            return .L;
        case .M:            return .M;
        case .N:            return .N;
        case .O:            return .O;
        case .P:            return .P;
        case .Q:            return .Q;
        case .R:            return .R;
        case .S:            return .S;
        case .T:            return .T;
        case .U:            return .U;
        case .V:            return .V;
        case .W:            return .W;
        case .X:            return .X;
        case .Y:            return .Y;
        case .Z:            return .Z;
        case .LEFT_BRACKET: return .LeftBracket;
        case .BACKSLASH:    return .Backslash;
        case .RIGHT_BRACKET:return .RightBracket;
        case .GRAVE_ACCENT: return .GraveAccent;
        case .ESCAPE:       return .Escape;
        case .ENTER:        return .Enter;
        case .TAB:          return .Tab;
        case .BACKSPACE:    return .Backspace;
        case .INSERT:       return .Insert;
        case .DELETE:       return .Delete;
        case .RIGHT:        return .RightArrow;
        case .LEFT:         return .LeftArrow;
        case .DOWN:         return .DownArrow;
        case .UP:           return .UpArrow;
        case .PAGE_UP:      return .PageUp;
        case .PAGE_DOWN:    return .PageDown;
        case .HOME:         return .Home;
        case .END:          return .End;
        case .CAPS_LOCK:    return .CapsLock;
        case .SCROLL_LOCK:  return .ScrollLock;
        case .NUM_LOCK:     return .NumLock;
        case .PRINT_SCREEN: return .PrintScreen;
        case .PAUSE:        return .Pause;
        case .F1:           return .F1;
        case .F2:           return .F2;
        case .F3:           return .F3;
        case .F4:           return .F4;
        case .F5:           return .F5;
        case .F6:           return .F6;
        case .F7:           return .F7;
        case .F8:           return .F8;
        case .F9:           return .F9;
        case .F10:          return .F10;
        case .F11:          return .F11;
        case .F12:          return .F12;
        case .KP_0:         return .Keypad0;
        case .KP_1:         return .Keypad1;
        case .KP_2:         return .Keypad2;
        case .KP_3:         return .Keypad3;
        case .KP_4:         return .Keypad4;
        case .KP_5:         return .Keypad5;
        case .KP_6:         return .Keypad6;
        case .KP_7:         return .Keypad7;
        case .KP_8:         return .Keypad8;
        case .KP_9:         return .Keypad9;
        case .KP_DECIMAL:   return .KeypadDecimal;
        case .KP_DIVIDE:    return .KeypadDivide;
        case .KP_MULTIPLY:  return .KeypadMultiply;
        case .KP_SUBTRACT:  return .KeypadSubtract;
        case .KP_ADD:       return .KeypadAdd;
        case .KP_ENTER:     return .KeypadEnter;
        case .KP_EQUAL:     return .KeypadEqual;
        case .LEFT_SHIFT:   return .LeftShift;
        case .LEFT_CONTROL: return .LeftCtrl;
        case .LEFT_ALT:     return .LeftAlt;
        case .LEFT_SUPER:   return .LeftSuper;
        case .RIGHT_SHIFT:  return .RightShift;
        case .RIGHT_CONTROL:return .RightCtrl;
        case .RIGHT_ALT:    return .RightAlt;
        case .RIGHT_SUPER:  return .RightSuper;
        case .MENU:         return .Menu;
        case:               return .None;
    }
}

is_osx :: proc() -> bool {
	// TODO: web osx
	when ODIN_OS == .Darwin {
		return true
	} else {
		return false
	}
}

is_ctrl :: proc(modifiers: u32) -> bool {
    if ctx.is_osx {
        return 0 != (modifiers & sapp.MODIFIER_SUPER);
    } else {
        return 0 != (modifiers & sapp.MODIFIER_CTRL);
    }
}
copypaste_modifier :: proc() -> imgui.Key{
    return ctx.is_osx ? .ImGuiMod_Super : .ImGuiMod_Ctrl
}

