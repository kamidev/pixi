const std = @import("std");
const pixi = @import("../../pixi.zig");
const core = @import("mach").core;
const imgui = @import("zig-imgui");
const zmath = @import("zmath");

pub fn draw(file: *pixi.storage.Internal.Pixi) void {
    const transforming = file.transform_texture != null;

    {
        const shadow_color = pixi.math.Color.initFloats(0.0, 0.0, 0.0, pixi.state.settings.shadow_opacity).toU32();
        // Draw a shadow fading from bottom to top
        const pos = imgui.getWindowPos();
        const height = imgui.getWindowHeight();
        const width = imgui.getWindowWidth();

        if (imgui.getWindowDrawList()) |draw_list| {
            draw_list.addRectFilledMultiColor(
                .{ .x = pos.x, .y = (pos.y + height) - pixi.state.settings.shadow_length * pixi.content_scale[1] },
                .{ .x = pos.x + width, .y = pos.y + height },
                0x0,
                0x0,
                shadow_color,
                shadow_color,
            );
        }
    }

    const window_width = imgui.getWindowWidth();
    const window_height = imgui.getWindowHeight();
    const file_width = @as(f32, @floatFromInt(file.width));
    const file_height = @as(f32, @floatFromInt(file.height));
    const tile_width = @as(f32, @floatFromInt(file.tile_width));
    const tile_height = @as(f32, @floatFromInt(file.tile_height));

    const canvas_center_offset = file.canvasCenterOffset(.primary);

    // Handle zooming, panning and extents
    {
        var sprite_camera: pixi.gfx.Camera = .{
            .zoom = @min(window_width / file_width, window_height / file_height),
        };
        sprite_camera.setNearestZoomFloor();
        if (!file.camera.zoom_initialized) {
            file.camera.zoom_initialized = true;
            file.camera.zoom = sprite_camera.zoom;
        }
        sprite_camera.setNearestZoomFloor();
        const min_zoom = @min(sprite_camera.zoom, 1.0);

        file.camera.processPanZoom();

        // Lock camera from zooming in or out too far for the flipbook
        file.camera.zoom = std.math.clamp(file.camera.zoom, min_zoom, pixi.state.settings.zoom_steps[pixi.state.settings.zoom_steps.len - 1]);

        // Lock camera from moving too far away from canvas
        file.camera.position[0] = std.math.clamp(file.camera.position[0], -(canvas_center_offset[0] + file_width), canvas_center_offset[0] + file_width);
        file.camera.position[1] = std.math.clamp(file.camera.position[1], -(canvas_center_offset[1] + file_height), canvas_center_offset[1] + file_height);
    }

    // TODO: Only clear and update if we need to?
    if (file.transform_texture == null)
        file.temporary_layer.clear(true);

    if (imgui.isWindowHovered(imgui.HoveredFlags_None)) {
        const mouse_position = pixi.state.mouse.position;

        if (file.camera.pixelCoordinates(.{
            .texture_position = canvas_center_offset,
            .position = mouse_position,
            .width = file.width,
            .height = file.height,
        })) |pixel_coord| {
            const pixel = .{ @as(usize, @intFromFloat(pixel_coord[0])), @as(usize, @intFromFloat(pixel_coord[1])) };

            const tile_column = @divTrunc(pixel[0], @as(usize, @intCast(file.tile_width)));
            const tile_row = @divTrunc(pixel[1], @as(usize, @intCast(file.tile_height)));

            const x = @as(f32, @floatFromInt(tile_column)) * tile_width + canvas_center_offset[0];
            const y = @as(f32, @floatFromInt(tile_row)) * tile_height + canvas_center_offset[1];

            if (pixi.state.sidebar != .pack)
                file.camera.drawTexture(file.background.view_handle, file.tile_width, file.tile_height, .{ x, y }, 0x88FFFFFF);

            file.processStrokeTool(.primary, .{}) catch unreachable;
            file.processFillTool(.primary, .{}) catch unreachable;
            file.processAnimationTool() catch unreachable;
            file.processSampleTool(.primary, .{});

            if (pixi.state.mouse.button(.primary)) |primary| {
                if (primary.pressed()) {
                    const tiles_wide = @divExact(@as(usize, @intCast(file.width)), @as(usize, @intCast(file.tile_width)));
                    const tile_index = tile_column + tile_row * tiles_wide;

                    if (pixi.state.sidebar == .sprites) {
                        file.makeSpriteSelection(tile_index);
                    } else if (pixi.state.tools.current != .animation) {
                        // Ensure we only set the request state on the first set.
                        if (file.flipbook_scroll_request) |*request| {
                            request.elapsed = 0.0;
                            request.from = file.flipbook_scroll;
                            request.to = file.flipbookScrollFromSpriteIndex(tile_index);
                        } else {
                            file.flipbook_scroll_request = .{ .from = file.flipbook_scroll, .to = file.flipbookScrollFromSpriteIndex(tile_index), .state = file.selected_animation_state };
                        }
                    }
                }
            }
        } else {
            if (pixi.state.mouse.button(.primary)) |primary| {
                if (primary.released()) {
                    if (pixi.state.sidebar == .sprites) {
                        file.selected_sprites.clearAndFree();
                    }
                }
            }
        }
    }

    // Draw transform texture on gpu to temporary texture
    draw_transform: {
        if (file.transform_texture) |*transform_texture| {
            if (@abs(transform_texture.width) < 1.0 or @abs(transform_texture.height) < 1.0)
                break :draw_transform;
            if (file.transform_bindgroup) |transform_bindgroup| {
                if (file.compute_bindgroup) |compute_bindgroup| {
                    if (file.compute_buffer) |compute_buffer| {
                        if (file.staging_buffer) |staging_buffer| {
                            const width: f32 = @floatFromInt(file.width);
                            const height: f32 = @floatFromInt(file.height);

                            const buffer_size: usize = @as(usize, @intCast(file.width * file.height * @sizeOf([4]f32)));

                            const origin: [2]f32 = .{ transform_texture.width / 2.0, transform_texture.height / 2.0 };

                            const texture_height: f32 = transform_texture.height;

                            const position = zmath.f32x4(
                                @trunc(transform_texture.position[0] + canvas_center_offset[0]),
                                @trunc(-transform_texture.position[1] - (canvas_center_offset[1] + texture_height)),
                                0.0,
                                0.0,
                            );

                            const uniforms = pixi.gfx.UniformBufferObject{ .mvp = zmath.transpose(
                                zmath.orthographicLh(width, height, -100, 100),
                            ) };

                            pixi.state.batcher.begin(.{
                                .pipeline_handle = pixi.state.pipeline_default,
                                .compute_pipeline_handle = pixi.state.pipeline_compute,
                                .bind_group_handle = transform_bindgroup,
                                .compute_bind_group_handle = compute_bindgroup,
                                .output_texture = &file.temporary_layer.texture,
                                .compute_buffer = compute_buffer,
                                .staging_buffer = staging_buffer,
                                .buffer_size = buffer_size,
                                .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
                            }) catch unreachable;

                            pixi.state.batcher.texture(
                                position,
                                &transform_texture.texture,
                                .{
                                    .width = transform_texture.width,
                                    .height = transform_texture.height,
                                    .rotation = -transform_texture.rotation,
                                    .origin = origin,
                                },
                            ) catch unreachable;

                            pixi.state.batcher.end(uniforms, pixi.state.uniform_buffer_default) catch unreachable;
                        }
                    }
                }
            }
        }
    }

    // Draw all layers in reverse order
    {
        var i: usize = file.layers.items.len;
        while (i > 0) {
            i -= 1;

            if (file.layers.items[i].visible)
                file.camera.drawLayer(file.layers.items[i], canvas_center_offset);
        }

        // Draw the temporary layer
        file.camera.drawLayer(file.temporary_layer, canvas_center_offset);

        // Draw grid
        file.camera.drawGrid(canvas_center_offset, file_width, file_height, @as(usize, @intFromFloat(file_width / tile_width)), @as(usize, @intFromFloat(file_height / tile_height)), pixi.state.theme.text_secondary.toU32());

        drawTransformTextureControls(file, canvas_center_offset);

        if (file.heightmap.visible) {
            file.camera.drawRectFilled(.{ canvas_center_offset[0], canvas_center_offset[1], file_width, file_height }, 0x60FFFFFF);
            if (file.heightmap.layer) |layer| {
                file.camera.drawLayer(layer, canvas_center_offset);
            }
        }
    }

    // Draw height in pixels if currently editing heightmap and zoom is sufficient
    {
        if (file.heightmap.visible) {
            if (file.camera.zoom >= 30.0) {
                if (file.camera.pixelCoordinates(.{
                    .texture_position = canvas_center_offset,
                    .position = pixi.state.mouse.position,
                    .width = file.width,
                    .height = file.height,
                })) |pixel_coord| {
                    const temp_x = @as(usize, @intFromFloat(pixel_coord[0]));
                    const temp_y = @as(usize, @intFromFloat(pixel_coord[1]));
                    const position = .{ pixel_coord[0] + canvas_center_offset[0] + 0.2, pixel_coord[1] + canvas_center_offset[1] + 0.25 };
                    file.camera.drawText("{d}", .{pixi.state.colors.height}, position, 0xFFFFFFFF);

                    const min: [2]u32 = .{
                        @intCast(@max(@as(i32, @intCast(temp_x)) - 5, 0)),
                        @intCast(@max(@as(i32, @intCast(temp_y)) - 5, 0)),
                    };

                    const max: [2]u32 = .{
                        @intCast(@min(temp_x + 5, file.width)),
                        @intCast(@min(temp_y + 5, file.height)),
                    };

                    var x: u32 = min[0];
                    while (x < max[0]) : (x += 1) {
                        var y: u32 = min[1];
                        while (y < max[1]) : (y += 1) {
                            const pixel = .{ @as(usize, @intCast(x)), @as(usize, @intCast(y)) };
                            const pixel_color = file.heightmap.layer.?.getPixel(pixel);
                            if (pixel_color[3] != 0 and (pixel[0] != temp_x or pixel[1] != temp_y)) {
                                const pixel_position = .{ canvas_center_offset[0] + @as(f32, @floatFromInt(x)) + 0.2, canvas_center_offset[1] + @as(f32, @floatFromInt(y)) + 0.25 };
                                file.camera.drawText("{d}", .{pixel_color[0]}, pixel_position, 0xFFFFFFFF);
                            }
                        }
                    }
                }
            }
        }
    }

    // Draw box around selected sprite or origin selection if on sprites tab, as well as animation start and end
    {
        const tiles_wide = @divExact(file.width, file.tile_width);

        if (pixi.state.sidebar == .sprites and !transforming) {
            if (file.selected_sprites.items.len > 0) {
                for (file.selected_sprites.items) |sprite_index| {
                    const column = @mod(@as(u32, @intCast(sprite_index)), tiles_wide);
                    const row = @divTrunc(@as(u32, @intCast(sprite_index)), tiles_wide);
                    const x = @as(f32, @floatFromInt(column)) * tile_width + canvas_center_offset[0];
                    const y = @as(f32, @floatFromInt(row)) * tile_height + canvas_center_offset[1];
                    const rect: [4]f32 = .{ x, y, tile_width, tile_height };

                    file.camera.drawRect(rect, 3.0, pixi.state.theme.text.toU32());

                    // Draw the origin
                    const sprite: pixi.storage.Internal.Sprite = file.sprites.items[sprite_index];
                    file.camera.drawLine(
                        .{ x + sprite.origin_x, y },
                        .{ x + sprite.origin_x, y + tile_height },
                        pixi.state.theme.text_red.toU32(),
                        2.0,
                    );
                    file.camera.drawLine(
                        .{ x, y + sprite.origin_y },
                        .{ x + tile_width, y + sprite.origin_y },
                        pixi.state.theme.text_red.toU32(),
                        2.0,
                    );
                }
            }
        } else if (pixi.state.sidebar != .pack and !transforming) {
            const column = @mod(@as(u32, @intCast(file.selected_sprite_index)), tiles_wide);
            const row = @divTrunc(@as(u32, @intCast(file.selected_sprite_index)), tiles_wide);
            const x = @as(f32, @floatFromInt(column)) * tile_width + canvas_center_offset[0];
            const y = @as(f32, @floatFromInt(row)) * tile_height + canvas_center_offset[1];
            const rect: [4]f32 = .{ x, y, tile_width, tile_height };

            file.camera.drawRect(rect, 3.0, pixi.state.theme.text.toU32());
        }

        if (pixi.state.popups.animation_length > 0 and pixi.state.tools.current == .animation and !transforming) {
            if (pixi.state.mouse.button(.primary)) |primary| {
                if (primary.down() or pixi.state.popups.animation) {
                    const start_column = @mod(@as(u32, @intCast(pixi.state.popups.animation_start)), tiles_wide);
                    const start_row = @divTrunc(@as(u32, @intCast(pixi.state.popups.animation_start)), tiles_wide);
                    const start_x = @as(f32, @floatFromInt(start_column)) * tile_width + canvas_center_offset[0];
                    const start_y = @as(f32, @floatFromInt(start_row)) * tile_height + canvas_center_offset[1];
                    const start_rect: [4]f32 = .{ start_x, start_y, tile_width, tile_height };

                    const end_column = @mod(@as(u32, @intCast(pixi.state.popups.animation_start + pixi.state.popups.animation_length - 1)), tiles_wide);
                    const end_row = @divTrunc(@as(u32, @intCast(pixi.state.popups.animation_start + pixi.state.popups.animation_length - 1)), tiles_wide);
                    const end_x = @as(f32, @floatFromInt(end_column)) * tile_width + canvas_center_offset[0];
                    const end_y = @as(f32, @floatFromInt(end_row)) * tile_height + canvas_center_offset[1];
                    const end_rect: [4]f32 = .{ end_x, end_y, tile_width, tile_height };

                    file.camera.drawAnimationRect(start_rect, end_rect, 6.0, pixi.state.theme.highlight_primary.toU32(), pixi.state.theme.text_red.toU32());
                }
            }
        }

        if (file.animations.items.len > 0) {
            if (pixi.state.tools.current == .animation and !transforming) {
                for (file.animations.items, 0..) |animation, i| {
                    const start_column = @mod(@as(u32, @intCast(animation.start)), tiles_wide);
                    const start_row = @divTrunc(@as(u32, @intCast(animation.start)), tiles_wide);
                    const start_x = @as(f32, @floatFromInt(start_column)) * tile_width + canvas_center_offset[0];
                    const start_y = @as(f32, @floatFromInt(start_row)) * tile_height + canvas_center_offset[1];
                    const start_rect: [4]f32 = .{ start_x, start_y, tile_width, tile_height };

                    const end_column = @mod(@as(u32, @intCast(animation.start + animation.length - 1)), tiles_wide);
                    const end_row = @divTrunc(@as(u32, @intCast(animation.start + animation.length - 1)), tiles_wide);
                    const end_x = @as(f32, @floatFromInt(end_column)) * tile_width + canvas_center_offset[0];
                    const end_y = @as(f32, @floatFromInt(end_row)) * tile_height + canvas_center_offset[1];
                    const end_rect: [4]f32 = .{ end_x, end_y, tile_width, tile_height };

                    const thickness: f32 = if (i == file.selected_animation_index and (if (pixi.state.mouse.button(.primary)) |primary| primary.up() else false and !pixi.state.popups.animation)) 4.0 else 2.0;
                    file.camera.drawAnimationRect(start_rect, end_rect, thickness, pixi.state.theme.highlight_primary.toU32(), pixi.state.theme.text_red.toU32());
                }
            } else if (pixi.state.sidebar != .pack and !transforming) {
                const animation = file.animations.items[file.selected_animation_index];

                const start_column = @mod(@as(u32, @intCast(animation.start)), tiles_wide);
                const start_row = @divTrunc(@as(u32, @intCast(animation.start)), tiles_wide);
                const start_x = @as(f32, @floatFromInt(start_column)) * tile_width + canvas_center_offset[0];
                const start_y = @as(f32, @floatFromInt(start_row)) * tile_height + canvas_center_offset[1];
                const start_rect: [4]f32 = .{ start_x, start_y, tile_width, tile_height };

                const end_column = @mod(@as(u32, @intCast(animation.start + animation.length - 1)), tiles_wide);
                const end_row = @divTrunc(@as(u32, @intCast(animation.start + animation.length - 1)), tiles_wide);
                const end_x = @as(f32, @floatFromInt(end_column)) * tile_width + canvas_center_offset[0];
                const end_y = @as(f32, @floatFromInt(end_row)) * tile_height + canvas_center_offset[1];
                const end_rect: [4]f32 = .{ end_x, end_y, tile_width, tile_height };

                file.camera.drawAnimationRect(start_rect, end_rect, 4.0, pixi.state.theme.highlight_primary.toU32(), pixi.state.theme.text_red.toU32());
            }
        }
    }
}

pub const TransformControls = struct {
    corners: [4][2]f32,
};

pub fn drawTransformTextureControls(file: *pixi.storage.Internal.Pixi, canvas_center_offset: [2]f32) void {
    // Draw transformation texture controls
    if (file.transform_texture) |*transform_texture| {
        if (pixi.state.mouse.button(.primary)) |bt| {
            if (bt.released()) {
                transform_texture.active_control = .none;
            }
        }

        const width: f32 = transform_texture.width;
        const height: f32 = transform_texture.height;
        const position: [2]f32 = .{ canvas_center_offset[0] + transform_texture.position[0], canvas_center_offset[1] + transform_texture.position[1] };

        const center: [2]f32 = .{ position[0] + width / 2.0, position[1] + height / 2.0 };

        const transform_rect: [4]f32 = .{ position[0], position[1], width, height };

        var hovered_control: pixi.storage.Internal.Pixi.TransformControl = .none;

        const text_color = pixi.state.theme.text.toU32();

        var pan_color: u32 = text_color;

        if (file.camera.isHovered(transform_rect)) {
            hovered_control = .pan;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .pan;
                }
            }
        }

        const grip_size: f32 = 10.0 / file.camera.zoom;
        const half_grip_size = grip_size / 2.0;

        const offset = zmath.loadArr2(transform_texture.position) + zmath.loadArr2(canvas_center_offset) + zmath.f32x4(width / 2.0, height / 2.0, 0, 0);
        const radians = std.math.degreesToRadians(transform_texture.rotation);
        const rotation_matrix = zmath.rotationZ(radians);

        const rotation_control_height = 12.0;

        var rotate_control_position = zmath.f32x4(position[0] + width / 2.0, position[1] - rotation_control_height, 0.0, 0.0);
        rotate_control_position -= offset;
        rotate_control_position = zmath.mul(rotate_control_position, rotation_matrix);
        rotate_control_position += offset;

        if (file.camera.isHovered(.{ rotate_control_position[0] - half_grip_size * file.camera.zoom, rotate_control_position[1] - half_grip_size * file.camera.zoom, half_grip_size * file.camera.zoom * 2, half_grip_size * file.camera.zoom * 2 })) {
            if (pixi.state.mouse.button(.primary)) |bt| {
                hovered_control = .rotate;
                if (bt.pressed()) {
                    transform_texture.active_control = .rotate;
                }
            }
        }

        var rotate_color = text_color;

        if (file.camera.isHovered(.{ rotate_control_position[0] - half_grip_size * file.camera.zoom, rotate_control_position[1] - half_grip_size * file.camera.zoom, half_grip_size * file.camera.zoom * 2, half_grip_size * file.camera.zoom * 2 }) or transform_texture.active_control == .rotate) {
            rotate_color = pixi.state.theme.highlight_primary.toU32();
            file.camera.drawCircle(center, ((height / 2.0) + rotation_control_height) * file.camera.zoom, 1.0, text_color);
        }

        var top_position = zmath.f32x4(position[0] + width / 2.0, position[1], 1.0, 0.0);
        top_position -= offset;
        top_position = zmath.mul(top_position, rotation_matrix);
        top_position += offset;

        const top_rect: [4]f32 = .{ top_position[0] - half_grip_size, top_position[1] - half_grip_size, grip_size, grip_size };
        const top_color: u32 = if (file.camera.isHovered(top_rect) or transform_texture.active_control == .n_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(top_rect)) {
            hovered_control = .n_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .n_scale;
                }
            }
        }

        var right_position = zmath.f32x4(position[0] + width, position[1] + height / 2.0, 1.0, 0.0);
        right_position -= offset;
        right_position = zmath.mul(right_position, rotation_matrix);
        right_position += offset;

        const right_rect: [4]f32 = .{ right_position[0] - half_grip_size, right_position[1] - half_grip_size, grip_size, grip_size };
        const right_color: u32 = if (file.camera.isHovered(right_rect) or transform_texture.active_control == .e_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(right_rect)) {
            hovered_control = .e_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .e_scale;
                }
            }
        }

        var bottom_position = zmath.f32x4(position[0] + width / 2.0, position[1] + height, 1.0, 0.0);
        bottom_position -= offset;
        bottom_position = zmath.mul(bottom_position, rotation_matrix);
        bottom_position += offset;

        const bottom_rect: [4]f32 = .{ bottom_position[0] - half_grip_size, bottom_position[1] - half_grip_size, grip_size, grip_size };
        const bottom_color: u32 = if (file.camera.isHovered(bottom_rect) or transform_texture.active_control == .s_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(bottom_rect)) {
            hovered_control = .s_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .s_scale;
                }
            }
        }

        var left_position = zmath.f32x4(position[0], position[1] + height / 2.0, 1.0, 0.0);
        left_position -= offset;
        left_position = zmath.mul(left_position, rotation_matrix);
        left_position += offset;

        const left_rect: [4]f32 = .{ left_position[0] - half_grip_size, left_position[1] - half_grip_size, grip_size, grip_size };
        const left_color: u32 = if (file.camera.isHovered(left_rect) or transform_texture.active_control == .w_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(left_rect)) {
            hovered_control = .w_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .w_scale;
                }
            }
        }

        var tl_position = zmath.f32x4(position[0], position[1], 1.0, 0.0);
        tl_position -= offset;
        tl_position = zmath.mul(tl_position, rotation_matrix);
        tl_position += offset;

        const tl_rect: [4]f32 = .{ tl_position[0] - half_grip_size, tl_position[1] - half_grip_size, grip_size, grip_size };
        const tl_color: u32 = if (file.camera.isHovered(tl_rect) or transform_texture.active_control == .nw_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(tl_rect)) {
            hovered_control = .nw_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .nw_scale;
                }
            }
        }

        var tr_position = zmath.f32x4(position[0] + width, position[1], 1.0, 0.0);
        tr_position -= offset;
        tr_position = zmath.mul(tr_position, rotation_matrix);
        tr_position += offset;

        const tr_rect: [4]f32 = .{ tr_position[0] - half_grip_size, tr_position[1] - half_grip_size, grip_size, grip_size };
        const tr_color: u32 = if (file.camera.isHovered(tr_rect) or transform_texture.active_control == .ne_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(tr_rect)) {
            hovered_control = .ne_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .ne_scale;
                }
            }
        }

        var br_position = zmath.f32x4(position[0] + width, position[1] + height, 1.0, 0.0);
        br_position -= offset;
        br_position = zmath.mul(br_position, rotation_matrix);
        br_position += offset;

        const br_rect: [4]f32 = .{ br_position[0] - half_grip_size, br_position[1] - half_grip_size, grip_size, grip_size };
        const br_color: u32 = if (file.camera.isHovered(br_rect) or transform_texture.active_control == .se_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(br_rect)) {
            hovered_control = .se_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .se_scale;
                }
            }
        }

        var bl_position = zmath.f32x4(position[0], position[1] + height, 1.0, 0.0);
        bl_position -= offset;
        bl_position = zmath.mul(bl_position, rotation_matrix);
        bl_position += offset;

        const bl_rect: [4]f32 = .{ bl_position[0] - half_grip_size, bl_position[1] - half_grip_size, grip_size, grip_size };
        const bl_color: u32 = if (file.camera.isHovered(bl_rect) or transform_texture.active_control == .sw_scale) pixi.state.theme.highlight_primary.toU32() else text_color;

        if (file.camera.isHovered(bl_rect)) {
            hovered_control = .sw_scale;
            if (pixi.state.mouse.button(.primary)) |bt| {
                if (bt.pressed()) {
                    transform_texture.active_control = .sw_scale;
                }
            }
        }

        file.camera.drawLine(.{ tl_position[0], tl_position[1] }, .{ tr_position[0], tr_position[1] }, text_color, 3.0);
        file.camera.drawLine(.{ tr_position[0], tr_position[1] }, .{ br_position[0], br_position[1] }, text_color, 3.0);
        file.camera.drawLine(.{ br_position[0], br_position[1] }, .{ bl_position[0], bl_position[1] }, text_color, 3.0);
        file.camera.drawLine(.{ bl_position[0], bl_position[1] }, .{ tl_position[0], tl_position[1] }, text_color, 3.0);

        file.camera.drawRectFilled(top_rect, top_color);
        file.camera.drawRectFilled(right_rect, right_color);
        file.camera.drawRectFilled(bottom_rect, bottom_color);
        file.camera.drawRectFilled(left_rect, left_color);

        file.camera.drawRectFilled(tl_rect, tl_color);
        file.camera.drawRectFilled(tr_rect, tr_color);
        file.camera.drawRectFilled(br_rect, br_color);
        file.camera.drawRectFilled(bl_rect, bl_color);

        file.camera.drawCircleFilled(.{ rotate_control_position[0], rotate_control_position[1] }, half_grip_size * file.camera.zoom, rotate_color);

        if (transform_texture.active_control == .pan or hovered_control == .pan) {
            pan_color = pixi.state.theme.highlight_primary.toU32();
        }
        file.camera.drawCircleFilled(center, (grip_size / 2.0) * file.camera.zoom, pan_color);

        const cursor: imgui.MouseCursor = if (transform_texture.active_control != .none) switch (transform_texture.active_control) {
            .pan => imgui.MouseCursor_ResizeAll,
            .ne_scale, .sw_scale => imgui.MouseCursor_ResizeNESW,
            .se_scale, .nw_scale => imgui.MouseCursor_ResizeNWSE,
            else => imgui.MouseCursor_Arrow,
        } else switch (hovered_control) {
            .pan => imgui.MouseCursor_Hand,
            .ne_scale, .sw_scale => imgui.MouseCursor_ResizeNESW,
            .se_scale, .nw_scale => imgui.MouseCursor_ResizeNWSE,
            else => imgui.MouseCursor_Arrow,
        };

        imgui.setMouseCursor(cursor);

        if (imgui.isWindowHovered(imgui.HoveredFlags_ChildWindows)) {
            const mouse_position = pixi.state.mouse.position;
            const prev_mouse_position = pixi.state.mouse.previous_position;
            const current_pixel_coords = file.camera.pixelCoordinatesRaw(.{
                .texture_position = canvas_center_offset,
                .position = mouse_position,
                .width = file.width,
                .height = file.height,
            });

            const previous_pixel_coords = file.camera.pixelCoordinatesRaw(.{
                .texture_position = canvas_center_offset,
                .position = prev_mouse_position,
                .width = file.width,
                .height = file.height,
            });

            const delta: [2]f32 = .{
                current_pixel_coords[0] - previous_pixel_coords[0],
                current_pixel_coords[1] - previous_pixel_coords[1],
            };

            switch (transform_texture.active_control) {
                .pan => {
                    transform_texture.position[0] += delta[0];
                    transform_texture.position[1] += delta[1];
                },
                .n_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.height -= delta[1];
                        transform_texture.position[1] += delta[1];
                    }
                },
                .e_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width += delta[0];
                    }
                },
                .s_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.height += delta[1];
                    }
                },
                .w_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width -= delta[0];
                        transform_texture.position[0] += delta[0];
                    }
                },
                .ne_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width += delta[0];
                        transform_texture.height -= delta[1];
                        transform_texture.position[1] += delta[1];
                    }
                },
                .se_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width += delta[0];
                        transform_texture.height += delta[1];
                    }
                },
                .sw_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width -= delta[0];
                        transform_texture.height += delta[1];
                        transform_texture.position[0] += delta[0];
                    }
                },
                .nw_scale => {
                    if (transform_texture.rotation == 0.0) { // TODO: Fix when rotation != 0.0
                        transform_texture.width -= delta[0];
                        transform_texture.height -= delta[1];
                        transform_texture.position[0] += delta[0];
                        transform_texture.position[1] += delta[1];
                    }
                },
                .rotate => {
                    if (imgui.isMouseDoubleClicked(imgui.MouseButton_Left)) {
                        transform_texture.rotation = 0.0;
                        transform_texture.active_control = .none;
                    } else {
                        const c: [2]f32 = .{ transform_texture.position[0] + transform_texture.width / 2.0, transform_texture.position[1] + transform_texture.height / 2.0 };
                        const mouse: [2]f32 = .{ current_pixel_coords[0], current_pixel_coords[1] };

                        const diff = zmath.loadArr2(mouse) - zmath.loadArr2(c);
                        const angle = std.math.atan2(diff[1], diff[0]);

                        transform_texture.rotation = @trunc(std.math.radiansToDegrees(angle) + 90.0);
                    }
                },
                else => {},
            }
        }
    }
}
