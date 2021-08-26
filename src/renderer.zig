const std = @import("std");

const c = @import("c.zig");
const shaderc = @import("shaderc.zig");
const png = @import("png.zig");

const AsyncShaderc = @import("async_shaderc.zig").AsyncShaderc;
const Blit = @import("blit.zig").Blit;
const Preview = @import("preview.zig").Preview;
const Scene = @import("scene.zig").Scene;
const Options = @import("options.zig").Options;
const Optimized = @import("optimized.zig").Optimized;
const Viewport = @import("viewport.zig").Viewport;

const FRAME_TIME_COUNT: u32 = 8;
pub const Renderer = struct {
    const Self = @This();

    initialized: bool = false,

    alloc: *std.mem.Allocator,

    device: c.WGPUDeviceId,
    queue: c.WGPUQueueId,

    scene: Scene,

    // This is a buffer which we use for ray storage.  It's equivalent to
    // a texture, but can be read and written in the same shader.
    image_buf: c.WGPUBufferId,
    image_buf_size: u32,

    compiler: ?AsyncShaderc,
    preview: Preview,
    optimized: ?Optimized,
    blit: Blit,

    uniforms: c.rayUniforms,
    uniform_buf: c.WGPUBufferId,

    start_time_ms: i64,
    last_time_ms: i64,
    frame_times_ms: [FRAME_TIME_COUNT]u32,
    frame_time_index: u32,

    // We render continuously, but reset stats after the optimized renderer
    // is built to get a fair performance metric
    opt_time_ms: i64,
    opt_offset_samples: u32,

    pub fn init(
        alloc: *std.mem.Allocator,
        scene: Scene,
        options: Options,
        device: c.WGPUDeviceId,
    ) !Self {
        ////////////////////////////////////////////////////////////////////////
        // Uniform buffers (shared by both raytracing and blitter)
        const uniform_buf = c.wgpu_device_create_buffer(
            device,
            &(c.WGPUBufferDescriptor){
                .label = "blit uniforms",
                .size = @sizeOf(c.rayUniforms),
                .usage = c.WGPUBufferUsage_UNIFORM | c.WGPUBufferUsage_COPY_DST,
                .mapped_at_creation = false,
            },
        );

        var out = Self{
            .alloc = alloc,

            .device = device,
            .queue = c.wgpu_device_get_default_queue(device),

            .compiler = null,
            .preview = undefined, // Built after update_size()
            .optimized = null,
            .blit = undefined, // Built after update_size()
            .scene = scene,

            // Populated in update_size()
            .image_buf = undefined,
            .image_buf_size = undefined,

            .uniforms = .{
                // Populated in update_size()
                .width_px = undefined,
                .height_px = undefined,

                .offset_x = 0,
                .offset_y = 0,

                .samples = 0,
                .samples_per_frame = 1,

                .spectral = if (options.spectral) 1 else 0,
                ._padding = undefined,

                .camera = scene.camera,
            },
            .uniform_buf = uniform_buf,

            .start_time_ms = 0,
            .last_time_ms = 0,
            .frame_times_ms = [_]u32{0} ** FRAME_TIME_COUNT,
            .frame_time_index = 0,

            .opt_time_ms = 0,
            .opt_offset_samples = 0,
        };

        out.update_size(options.width, options.height);
        out.blit = try Blit.init(
            alloc,
            device,
            uniform_buf,
            out.image_buf,
            out.image_buf_size,
        );
        out.preview = try Preview.init(
            alloc,
            scene,
            device,
            uniform_buf,
            out.image_buf,
            out.image_buf_size,
        );
        out.initialized = true;

        return out;
    }

    pub fn build_opt(self: *Self, scene: Scene) !bool {
        // The compiler is already running, so don't do anything yet
        if (self.compiler != null) {
            return false;
        }

        self.compiler = AsyncShaderc.init(scene, self.device);
        try (self.compiler orelse unreachable).start();

        return true;
    }

    pub fn get_options(self: *const Self) Options {
        return .{
            .total_samples = null,
            .width = self.uniforms.width_px,
            .height = self.uniforms.height_px,
            .spectral = self.uniforms.spectral != 0,
        };
    }

    fn update_uniforms(self: *const Self) void {
        c.wgpu_queue_write_buffer(
            self.queue,
            self.uniform_buf,
            0,
            @ptrCast([*c]const u8, &self.uniforms),
            @sizeOf(c.rayUniforms),
        );
    }

    fn draw_camera_gui(self: *Self) bool {
        var changed = false;
        const width = c.igGetWindowWidth();
        c.igPushItemWidth(width * 0.5);
        changed = c.igDragFloat3("pos", @ptrCast([*c]f32, &self.uniforms.camera.pos), 0.05, -10, 10, "%.1f", 0) or changed;
        changed = c.igDragFloat3("target", @ptrCast([*c]f32, &self.uniforms.camera.target), 0.05, -10, 10, "%.1f", 0) or changed;
        changed = c.igDragFloat3("up", @ptrCast([*c]f32, &self.uniforms.camera.up), 0.1, -1, 1, "%.1f", 0) or changed;
        changed = c.igDragFloat("perspective", &self.uniforms.camera.perspective, 0.01, 0, 1, "%.2f", 0) or changed;
        changed = c.igDragFloat("defocus", &self.uniforms.camera.defocus, 0.0001, 0, 0.1, "%.4f", 0) or changed;
        changed = c.igDragFloat("focal length", &self.uniforms.camera.focal_distance, 0.01, 0, 10, "%.2f", 0) or changed;
        changed = c.igDragFloat("scale", &self.uniforms.camera.scale, 0.05, 0, 10, "%.1f", 0) or changed;
        const w = width - c.igGetCursorPosX();
        c.igIndent(w * 0.25);
        if (c.igButton("Reset", .{ .x = w * 0.5, .y = 0 })) {
            self.uniforms.camera = self.scene.camera;
            changed = true;
        }
        c.igUnindent(w * 0.25);
        return changed;
    }

    pub fn draw_gui(self: *Self, menu_height: f32, menu_width: *f32) !bool {
        var changed = false;

        c.igPushStyleVarFloat(c.ImGuiStyleVar_WindowRounding, 0.0);
        c.igPushStyleVarFloat(c.ImGuiStyleVar_WindowBorderSize, 1.0);
        c.igSetNextWindowPos(.{ .x = 0, .y = menu_height }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        const window_size = c.igGetIO().*.DisplaySize;
        c.igSetNextWindowSizeConstraints(.{
            .x = 0,
            .y = window_size.y - menu_height,
        }, .{
            .x = window_size.x / 2,
            .y = window_size.y - menu_height,
        }, null, null);
        const flags = c.ImGuiWindowFlags_NoTitleBar |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoCollapse;
        if (c.igBegin("rayray", null, flags)) {
            if (c.igCollapsingHeaderBoolPtr("Camera", null, 0)) {
                changed = self.draw_camera_gui() or changed;
            }

            if (c.igCollapsingHeaderBoolPtr("Shapes", null, 0)) {
                changed = (try self.scene.draw_shapes_gui()) or changed;
            }

            if (c.igCollapsingHeaderBoolPtr("Materials", null, 0)) {
                changed = (try self.scene.draw_materials_gui()) or changed;
            }
            menu_width.* = c.igGetWindowWidth();
        }

        c.igEnd();
        c.igPopStyleVar(2);

        if (changed) {
            try self.preview.upload_scene(self.scene);
            self.uniforms.samples = 0;
            self.uniforms.samples_per_frame = 1;
            self.frame_time_index = 0;

            if (self.optimized) |*opt| {
                opt.deinit();
                self.optimized = null;
            }
            // This will tell us to ignore the compiler result, because
            // the shader has changed while it was running.
            if (self.compiler) |*comp| {
                comp.cancelled = true;
            }
        }
        return changed;
    }

    pub fn draw(
        self: *Self,
        viewport: Viewport,
        next_texture: c.WGPUOption_TextureViewId,
        cmd_encoder: c.WGPUCommandEncoderId,
    ) !void {
        // Check whether the compiler for a scene-specific shader has finished
        if (self.compiler) |*comp| {
            if (comp.check()) |comp_shader| {
                defer c.wgpu_shader_module_destroy(comp_shader);
                if (self.optimized) |*opt| {
                    opt.deinit();
                    self.optimized = null;
                }
                if (!comp.cancelled) {
                    self.optimized = try Optimized.init(
                        self.alloc,
                        comp_shader,
                        self.device,
                        self.uniform_buf,
                        self.image_buf,
                        self.image_buf_size,
                    );
                    self.opt_time_ms = std.time.milliTimestamp();
                    self.opt_offset_samples = self.uniforms.samples;
                }
                comp.deinit();
                self.compiler = null;
            }
        }

        const width = @floatToInt(u32, viewport.width);
        const height = @floatToInt(u32, viewport.height);
        if (width != self.uniforms.width_px or height != self.uniforms.height_px) {
            self.update_size(width, height);
        }
        self.uniforms.offset_x = @floatToInt(u32, viewport.x);
        self.uniforms.offset_y = @floatToInt(u32, viewport.y);

        self.update_uniforms();

        // Cast another set of rays, one per pixel
        const first = self.uniforms.samples == 0;
        const n = self.uniforms.width_px * self.uniforms.height_px;
        const nt = (n + c.COMPUTE_SIZE - 1) / c.COMPUTE_SIZE;
        if (self.optimized) |*opt| {
            try opt.render(first, nt, cmd_encoder);
        } else {
            try self.preview.render(first, nt, cmd_encoder);
        }

        self.blit.draw(viewport, next_texture, cmd_encoder);
        const now_ms = std.time.milliTimestamp();

        // Record the start time at the first frame, to skip startup time
        if (self.uniforms.samples == 0) {
            self.start_time_ms = now_ms;
        } else if (now_ms >= self.last_time_ms) {
            const dt = @intCast(u32, now_ms - self.last_time_ms);
            // Work around an issue where frames get submitted too fast,
            // which can causes the autoscaler to overestimate its capabilities
            if (dt > 15) {
                self.frame_times_ms[self.frame_time_index] = dt;
                self.frame_time_index = (self.frame_time_index + 1) % FRAME_TIME_COUNT;
            }
        }
        self.last_time_ms = now_ms;
        self.uniforms.samples += self.uniforms.samples_per_frame;

        // Skew samples per frame based on average frame time
        if (self.frame_time_index == FRAME_TIME_COUNT - 1) {
            var t: u32 = 0;
            for (self.frame_times_ms) |f| {
                t += f;
            }
            t = @divFloor(t, FRAME_TIME_COUNT);
            // When running normally, we expect a 16ms frame time.  We target
            // a frame time of 20 ms, with 2 ms of hysteresis on either side,
            // biased to count up quickly (since we reset to 1 when the scene
            // changes)
            const delta: i32 = switch (t) {
                0...16 => 4,
                17 => 2,
                18...22 => 0,
                else => -1,
            };
            if (delta != 0) {
                const next = @intCast(i32, self.uniforms.samples_per_frame) + delta;
                if (next >= 1) {
                    self.uniforms.samples_per_frame = @intCast(u32, next);
                } else {
                    self.uniforms.samples_per_frame = 1;
                }
                self.frame_time_index = 0;
            }
        }
    }

    fn prefix(v: *f64) u8 {
        if (v.* > 1_000_000_000) {
            v.* /= 1_000_000_000;
            return 'G';
        } else if (v.* > 1_000_000) {
            v.* /= 1_000_000;
            return 'M';
        } else if (v.* > 1_000) {
            v.* /= 1_000;
            return 'K';
        } else {
            return ' ';
        }
    }

    pub fn stats(self: *const Self, alloc: *std.mem.Allocator) ![]u8 {
        var samples = self.uniforms.samples;
        if (self.optimized != null) {
            samples -= self.opt_offset_samples;
        }
        var start_time_ms = if (self.optimized == null) self.start_time_ms else self.opt_time_ms;
        var ray_count = @intToFloat(f64, self.uniforms.width_px) *
            @intToFloat(f64, self.uniforms.height_px) *
            @intToFloat(f64, self.uniforms.samples);

        const dt_sec = @intToFloat(f64, std.time.milliTimestamp() - start_time_ms) / 1000.0;

        var rays_per_sec = ray_count / dt_sec;
        var rays_per_sec_prefix = prefix(&rays_per_sec);

        return try std.fmt.allocPrintZ(
            alloc,
            "{}x | {d:.2} {c}sps | {} spp | {} x {}",
            .{
                self.uniforms.samples_per_frame,
                rays_per_sec,
                rays_per_sec_prefix,
                self.uniforms.samples,
                self.uniforms.width_px,
                self.uniforms.height_px,
            },
        );
    }

    pub fn deinit(self: *Self) void {
        self.blit.deinit();
        self.preview.deinit();
        if (self.optimized) |*opt| {
            opt.deinit();
        }
        self.scene.deinit();
        c.wgpu_buffer_destroy(self.uniform_buf, true);
        c.wgpu_buffer_destroy(self.image_buf, true);
    }

    pub fn update_size(self: *Self, width: u32, height: u32) void {
        if (self.initialized) {
            c.wgpu_buffer_destroy(self.image_buf, true);
        }
        self.image_buf_size = width * height * 4 * @sizeOf(f32);
        self.image_buf = c.wgpu_device_create_buffer(
            self.device,
            &(c.WGPUBufferDescriptor){
                .label = "image buf",
                .size = self.image_buf_size,
                .usage = c.WGPUBufferUsage_STORAGE | c.WGPUBufferUsage_COPY_SRC,
                .mapped_at_creation = false,
            },
        );

        self.uniforms.width_px = width;
        self.uniforms.height_px = height;
        self.uniforms.samples = 0;
        self.uniforms.samples_per_frame = 1;
        self.frame_time_index = 0;

        self.start_time_ms = std.time.milliTimestamp();

        if (self.initialized) {
            self.blit.bind(self.uniform_buf, self.image_buf, self.image_buf_size);
            self.preview.bind(self.image_buf, self.image_buf_size);
            if (self.optimized) |*opt| {
                opt.rebuild_bind_group(self.uniform_buf, self.image_buf, self.image_buf_size);
                self.opt_time_ms = self.start_time_ms;
                self.opt_offset_samples = 0;
            }
        }
    }

    pub fn save_png(self: *const Self) !void {
        const tmp_buf = c.wgpu_device_create_buffer(
            self.device,
            &(c.WGPUBufferDescriptor){
                .label = "tmp png buffer",
                .size = self.image_buf_size,
                .usage = c.WGPUBufferUsage_COPY_DST | c.WGPUBufferUsage_MAP_READ,
                .mapped_at_creation = false,
            },
        );
        defer c.wgpu_buffer_destroy(tmp_buf, true);

        const cmd_encoder = c.wgpu_device_create_command_encoder(
            self.device,
            &(c.WGPUCommandEncoderDescriptor){ .label = "png save encoder" },
        );
        c.wgpu_command_encoder_copy_buffer_to_buffer(
            cmd_encoder,
            self.image_buf,
            0,
            tmp_buf,
            0,
            self.image_buf_size,
        );
        const cmd_buf = c.wgpu_command_encoder_finish(cmd_encoder, null);
        c.wgpu_queue_submit(self.queue, &cmd_buf, 1);

        c.wgpu_buffer_map_read_async(
            tmp_buf,
            0,
            self.image_buf_size,
            read_buffer_map_cb,
            null,
        );
        c.wgpu_device_poll(self.device, true);
        const ptr = c.wgpu_buffer_get_mapped_range(
            tmp_buf,
            0,
            self.image_buf_size,
        );
        const data = @ptrCast([*]const f32, @alignCast(4, ptr));
        try png.save_png(
            self.alloc,
            data,
            @intToFloat(f32, self.uniforms.samples),
            self.uniforms.width_px,
            self.uniforms.height_px,
        );
        c.wgpu_buffer_unmap(tmp_buf);
    }
};

export fn read_buffer_map_cb(status: c.WGPUBufferMapAsyncStatus, userdata: [*c]u8) void {
    _ = status;
    _ = userdata;
}
