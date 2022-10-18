const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zstbi = @import("zstbi");
const zm = @import("zmath");

// TODO: Add build instructions to readme, and note requires xcode for nativefiledialogs to build.
// TODO: Nativefiledialogs requires xcode appkit frameworks.

pub const name: [:0]const u8 = "Pixi";
pub const settings = @import("settings.zig");

pub const editor = @import("editor/editor.zig");

pub const assets = @import("assets.zig");
pub const shaders = @import("shaders.zig");

pub const fs = @import("tools/fs.zig");
pub const math = @import("math/math.zig");
pub const gfx = @import("gfx/gfx.zig");
pub const input = @import("input/input.zig");
pub const storage = @import("storage/storage.zig");

pub const fa = @import("tools/font_awesome.zig");

test {
    _ = math;
    _ = gfx;
    _ = input;
}

pub var state: *PixiState = undefined;

/// Holds the global game state.
pub const PixiState = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    camera: gfx.Camera,
    controls: input.Controls = .{},
    pipeline_default: zgpu.RenderPipelineHandle = .{},
    window: Window,
    sidebar: Sidebar = .files,
    style: editor.Style = .{},
    project_folder: ?[:0]const u8 = null,
    background_logo: gfx.Texture,
    open_files: std.ArrayList(storage.File),
    open_file_index: usize = 0,
    //bind_group_default: zgpu.BindGroupHandle,
    //batcher: gfx.Batcher,
};

pub const Sidebar = enum {
    files,
    tools,
    sprites,
    settings,
};

pub const Window = struct { size: zm.F32x4, scale: zm.F32x4 };

fn init(allocator: std.mem.Allocator, window: zglfw.Window) !*PixiState {
    const gctx = try zgpu.GraphicsContext.create(allocator, window);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    zstbi.init(arena);
    defer zstbi.deinit();

    const background_logo = try gfx.Texture.initFromFile(gctx, assets.Icon1024_png.path, .{});

    //const batcher = try gfx.Batcher.init(allocator, gctx, settings.batcher_max_sprites);

    const window_size = window.getSize();
    const window_scale = window.getContentScale();
    const state_window: Window = .{
        .size = zm.f32x4(@intToFloat(f32, window_size[0]), @intToFloat(f32, window_size[1]), 0, 0),
        .scale = zm.f32x4(window_scale[0], window_scale[1], 0, 0),
    };

    var camera = gfx.Camera.init(settings.design_size, .{ .w = window_size[0], .h = window_size[1] }, zm.f32x4(0, 0, 0, 0));

    // Build the default bind group.
    const bind_group_layout_default = gctx.createBindGroupLayout(&.{
        zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
        zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
    });
    defer gctx.releaseResource(bind_group_layout_default);

    // const bind_group_default = gctx.createBindGroup(bind_group_layout_default, &[_]zgpu.BindGroupEntryInfo{
    //     .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(gfx.Uniforms) },
    //     .{ .binding = 1, .texture_view_handle = diffusemap.view_handle },
    //     .{ .binding = 2, .sampler_handle = diffusemap.sampler_handle },
    // });

    var open_files = std.ArrayList(storage.File).init(allocator);

    state = try allocator.create(PixiState);
    state.* = .{
        .allocator = allocator,
        .gctx = gctx,
        .camera = camera,
        .window = state_window,
        .background_logo = background_logo,
        .open_files = open_files,
        //.batcher = batcher,
        //.bind_group_default = bind_group_default,
    };

    // Create render pipelines.
    {
        // (Async) Create default render pipeline.
        gfx.utils.createPipelineAsync(allocator, bind_group_layout_default, .{}, &state.pipeline_default);
    }

    return state;
}

fn deinit(allocator: std.mem.Allocator) void {
    editor.deinit();
    //state.batcher.deinit();
    zgui.backend.deinit();
    zgui.deinit();
    state.gctx.destroy(allocator);
    allocator.destroy(state);
}

fn update() void {
    zgui.backend.newFrame(state.gctx.swapchain_descriptor.width, state.gctx.swapchain_descriptor.height);

    editor.draw();

    zgui.showDemoWindow(null);
}

fn draw() void {
    const swapchain_texv = state.gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const zgui_commands = commands: {
        const encoder = state.gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer zgui_commands.release();

    // const batcher_commands = state.batcher.finish() catch unreachable;
    // defer batcher_commands.release();

    state.gctx.submit(&.{zgui_commands});

    if (state.gctx.present() == .swap_chain_resized) {
        state.camera.setWindow(state.gctx.window);

        const window_size = state.gctx.window.getSize();
        const window_scale = state.gctx.window.getContentScale();
        state.window = .{
            .size = zm.f32x4(@intToFloat(f32, window_size[0]), @intToFloat(f32, window_size[1]), 0, 0),
            .scale = zm.f32x4(window_scale[0], window_scale[1], 0, 0),
        };
    }
}

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    // Create window
    zglfw.defaultWindowHints();
    zglfw.windowHint(.cocoa_retina_framebuffer, 1);
    zglfw.windowHint(.client_api, 0);
    const window = try zglfw.createWindow(settings.design_width, settings.design_height, name, null, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    // Set callbacks
    window.setCursorPosCallback(input.callbacks.cursor);
    window.setScrollCallback(input.callbacks.scroll);
    window.setKeyCallback(input.callbacks.key);
    window.setMouseButtonCallback(input.callbacks.button);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    state = try init(allocator, window);
    defer deinit(allocator);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor std.math.max(scale[0], scale[1]);
    };

    zgui.init(allocator);
    zgui.io.setIniFilename(assets.root ++ "imgui.ini");
    _ = zgui.io.addFontFromFile(assets.root ++ "fonts/CozetteVector.ttf", settings.zgui_font_size * scale_factor);
    var config = zgui.FontConfig.init();
    config.merge_mode = true;
    const ranges: []const u16 = &.{ 0xf000, 0xf976, 0 };
    _ = zgui.io.addFontFromFileWithConfig(assets.root ++ "fonts/fa-solid-900.ttf", settings.zgui_font_size * scale_factor * 1.1, config, ranges.ptr);
    _ = zgui.io.addFontFromFileWithConfig(assets.root ++ "fonts/fa-regular-400.ttf", settings.zgui_font_size * scale_factor * 1.1, config, ranges.ptr);
    zgui.backend.init(window, state.gctx.device, @enumToInt(zgpu.GraphicsContext.swapchain_format));

    // Base style
    state.style.set();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        update();
        draw();
    }
}
