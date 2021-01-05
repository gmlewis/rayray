const std = @import("std");

const c = @import("c.zig");

pub const Shape = struct {
    const Self = @This();

    kind: u32, // One of the SHAPE_* values from rayray.h
    mat: u32, // Index into the materials list
    data: []c.vec4, // Depends on kind!

    pub fn new_sphere(
        alloc: *std.mem.Allocator,
        center: c.vec3,
        radius: f32,
        mat: u32,
    ) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = center.x, .y = center.y, .z = center.z, .w = radius };

        return Self{
            .kind = c.SHAPE_SPHERE,
            .mat = mat,
            .data = data,
        };
    }

    pub fn new_infinite_plane(
        alloc: *std.mem.Allocator,
        normal: c.vec3,
        offset: f32,
        mat: u32,
    ) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = normal.x, .y = normal.y, .z = normal.z, .w = offset };

        return Self{
            .kind = c.SHAPE_INFINITE_PLANE,
            .mat = mat,
            .data = data,
        };
    }
};

pub const Material = struct {
    const Self = @This();

    kind: u32, // One of the MAT_* values from rayray.h
    data: []c.vec4, // More raw data!

    pub fn new_diffuse(alloc: *std.mem.Allocator, r: f32, g: f32, b: f32) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = r, .y = g, .z = b, .w = 0 };

        return Self{
            .kind = c.MAT_DIFFUSE,
            .data = data,
        };
    }

    pub fn new_light(alloc: *std.mem.Allocator, r: f32, g: f32, b: f32) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = r, .y = g, .z = b, .w = 0 };

        return Self{
            .kind = c.MAT_LIGHT,
            .data = data,
        };
    }

    pub fn new_metal(alloc: *std.mem.Allocator, r: f32, g: f32, b: f32, fuzz: f32) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = r, .y = g, .z = b, .w = fuzz };

        return Self{
            .kind = c.MAT_METAL,
            .data = data,
        };
    }

    pub fn new_glass(alloc: *std.mem.Allocator, r: f32, g: f32, b: f32, eta: f32) !Self {
        var data = try alloc.alloc(c.vec4, 1);
        data[0] = .{ .x = r, .y = g, .z = b, .w = eta };

        return Self{
            .kind = c.MAT_GLASS,
            .data = data,
        };
    }

    // If the material is tightly packed, then we pack data[0].xyz into the
    // yzw elements of the material slot.
    pub fn tightly_packed(self: *const Self) bool {
        return switch (self.kind) {
            c.MAT_DIFFUSE, c.MAT_LIGHT => true,
            c.MAT_METAL, c.MAT_GLASS => false,
            else => std.debug.panic("Invalid material type: {}\n", .{self.kind}),
        };
    }
};

pub const Scene = struct {
    const Self = @This();

    alloc: *std.mem.Allocator,
    shapes: std.ArrayList(Shape),
    materials: std.ArrayList(Material),
    camera: c.rayCamera,

    fn new(alloc: *std.mem.Allocator, camera: c.rayCamera) Self {
        return Scene{
            .alloc = alloc,
            .shapes = std.ArrayList(Shape).init(alloc),
            .materials = std.ArrayList(Material).init(alloc),
            .camera = camera,
        };
    }

    fn default_camera() c.rayCamera {
        return .{
            .pos = .{ .x = 8, .y = 1.5, .z = 2 },
            .target = .{ .x = 0, .y = 0, .z = 0 },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .scale = 1,
            .defocus = 0.03,
            .perspective = 0.4,
            .focal_distance = 4.0,
        };
    }

    fn new_material(self: *Self, m: Material) !u32 {
        try self.materials.append(m);
        return @intCast(u32, self.materials.items.len - 1);
    }

    pub fn new_simple_scene(alloc: *std.mem.Allocator) !Self {
        var scene = new(alloc, default_camera());
        const white = try scene.new_material(try Material.new_diffuse(alloc, 1, 1, 1));
        const red = try scene.new_material(try Material.new_diffuse(alloc, 1, 0.2, 0.2));
        const light = try scene.new_material(try Material.new_light(alloc, 1, 1, 1));

        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0, .y = 0, .z = 0 },
            0.1,
            light,
        ));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0.5, .y = 0.3, .z = 0 },
            0.5,
            white,
        ));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = -0.5, .y = 0.3, .z = 0 },
            0.3,
            red,
        ));

        return scene;
    }

    pub fn new_cornell_box(alloc: *std.mem.Allocator) !Self {
        var scene = new(alloc, default_camera());
        const white = try scene.new_material(try Material.new_diffuse(alloc, 1, 1, 1));
        const red = try scene.new_material(try Material.new_diffuse(alloc, 1, 0.1, 0.1));
        const blue = try scene.new_material(try Material.new_diffuse(alloc, 0.1, 0.1, 1));
        const green = try scene.new_material(try Material.new_diffuse(alloc, 0.1, 1, 0.1));
        const metal = try scene.new_material(try Material.new_metal(alloc, 1, 1, 0.5, 0.1));
        const glass = try scene.new_material(try Material.new_glass(alloc, 1, 1, 1, 1.5));
        const light = try scene.new_material(try Material.new_light(alloc, 4, 4, 4));

        // Light
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0, .y = 6.05, .z = 0 },
            5.02,
            light,
        ));
        // Back wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 0, .z = 1 },
            -1,
            white,
        ));
        // Left wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 1, .y = 0, .z = 0 },
            -1,
            red,
        ));
        // Right wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = -1, .y = 0, .z = 0 },
            -1,
            green,
        ));
        // Top wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = -1, .z = 0 },
            -1.05,
            white,
        ));
        // Bottom wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 1, .z = 0 },
            -1,
            white,
        ));
        // Front wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 0, .z = -1 },
            -1,
            white,
        ));
        // Blue sphere
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = -0.3, .y = -0.6, .z = -0.2 },
            0.4,
            blue,
        ));
        // Metal sphere
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0.5, .y = -0.7, .z = 0.3 },
            0.3,
            metal,
        ));
        // Glass sphere
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0.1, .y = -0.8, .z = 0.5 },
            0.2,
            glass,
        ));

        return scene;
    }

    pub fn new_rtiow(alloc: *std.mem.Allocator) !Self {
        // Initialize the RNG
        var buf: [8]u8 = undefined;
        try std.os.getrandom(buf[0..]);
        const seed = std.mem.readIntLittle(u64, buf[0..8]);

        var r = std.rand.DefaultPrng.init(seed);

        var scene = new(alloc, .{
            .pos = .{ .x = 8, .y = 1.5, .z = 2 },
            .target = .{ .x = 0, .y = 0, .z = 0 },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .scale = 1,
            .defocus = 0.03,
            .perspective = 0.4,
            .focal_distance = 4.0,
        });

        const ground_material = try scene.new_material(
            try Material.new_diffuse(alloc, 0.5, 0.5, 0.5),
        );
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0, .y = -1000, .z = 0 },
            1000,
            ground_material,
        ));
        var a: i32 = -11;
        while (a < 11) : (a += 1) {
            var b: i32 = -11;
            while (b < 11) : (b += 1) {
                const x = @intToFloat(f32, a) + 0.7 * r.random.float(f32);
                const y: f32 = 0.18;
                const z = @intToFloat(f32, b) + 0.7 * r.random.float(f32);

                const da = std.math.sqrt(std.math.pow(f32, x - 4, 2) +
                    std.math.pow(f32, z, 2));
                const db = std.math.sqrt(std.math.pow(f32, x, 2) +
                    std.math.pow(f32, z, 2));
                const dc = std.math.sqrt(std.math.pow(f32, x + 4, 2) +
                    std.math.pow(f32, z, 2));

                if (da > 1.1 and db > 1.1 and dc > 1.1) {
                    const choose_mat = r.random.float(f32);
                    var mat: u32 = undefined;
                    if (choose_mat < 0.8) {
                        const red = r.random.float(f32);
                        const green = r.random.float(f32);
                        const blue = r.random.float(f32);
                        mat = try scene.new_material(
                            try Material.new_diffuse(alloc, red, green, blue),
                        );
                    } else if (choose_mat < 0.95) {
                        const red = r.random.float(f32) / 2 + 1;
                        const green = r.random.float(f32) / 2 + 1;
                        const blue = r.random.float(f32) / 2 + 1;
                        const fuzz = r.random.float(f32) / 2;
                        mat = try scene.new_material(
                            try Material.new_metal(alloc, red, green, blue, fuzz),
                        );
                    } else {
                        mat = try scene.new_material(
                            try Material.new_glass(alloc, 1, 1, 1, 1.5),
                        );
                    }
                    try scene.shapes.append(try Shape.new_sphere(alloc, .{ .x = x, .y = y, .z = z }, 0.2, mat));
                }
            }
        }

        const glass = try scene.new_material(try Material.new_glass(alloc, 1, 1, 1, 1.5));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0, .y = 1, .z = 0 },
            1,
            glass,
        ));

        const diffuse = try scene.new_material(try Material.new_diffuse(alloc, 0.4, 0.2, 0.1));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = -4, .y = 1, .z = 0 },
            1,
            diffuse,
        ));

        const metal = try scene.new_material(try Material.new_metal(alloc, 0.7, 0.6, 0.5, 0.0));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 4, .y = 1, .z = 0 },
            1,
            metal,
        ));

        const light = try scene.new_material(try Material.new_light(alloc, 0.8, 0.95, 1));
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0, .y = 0, .z = 0 },
            2000,
            light,
        ));

        return scene;
    }

    pub fn new_horizon(alloc: *std.mem.Allocator) !Self {
        var scene = new(alloc);
        const blue = try scene.new_material(try Material.new_diffuse(alloc, 0.5, 0.5, 1));
        const red = try scene.new_material(try Material.new_diffuse(alloc, 1, 0.5, 0.5));
        const glass = try scene.new_material(try Material.new_glass(alloc, 1, 1, 1, 1.5));
        const light = try scene.new_material(try Material.new_light(alloc, 1, 1, 1));

        // Back wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 0, .z = 1 },
            -100,
            light,
        ));
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 0, .z = -1 },
            -100,
            light,
        ));
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = -1, .z = 0 },
            -100,
            light,
        ));
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 1, .y = 0, .z = 0 },
            -100,
            light,
        ));
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = -1, .y = 0, .z = 0 },
            -100,
            light,
        ));
        // Bottom wall
        try scene.shapes.append(try Shape.new_infinite_plane(
            alloc,
            .{ .x = 0, .y = 1, .z = 0 },
            -1,
            blue,
        ));
        // Red sphere
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 1.25, .y = -0.5, .z = -1 },
            0.5,
            red,
        ));
        // Glass sphere
        try scene.shapes.append(try Shape.new_sphere(
            alloc,
            .{ .x = 0.0, .y = -0.5, .z = -1 },
            0.5,
            glass,
        ));

        return scene;
    }

    pub fn deinit(self: *Self) void {
        for (self.shapes.items) |s| {
            self.alloc.free(s.data);
        }
        self.shapes.deinit();
        for (self.materials.items) |m| {
            self.alloc.free(m.data);
        }
        self.materials.deinit();
    }

    pub fn encode(self: *Self) ![]c.vec4 {
        var num_data: usize = 0;
        for (self.shapes.items) |s| {
            num_data += s.data.len;
        }
        for (self.materials.items) |m| {
            if (!m.tightly_packed()) {
                num_data += m.data.len;
            }
        }

        // Index of primary encoding (one vec4 per item)
        var i: usize = 0;

        // Index of data segment (variable length)
        var j: usize = self.shapes.items.len + self.materials.items.len + 1;

        // Output array, with enough space for everything
        var out = try self.alloc.alloc(c.vec4, j + num_data);

        // Store the list length as the first element
        out[i].x = @intToFloat(f32, self.shapes.items.len);
        i += 1;

        // Encode all of the shapes and their respective data
        for (self.shapes.items) |s| {
            out[i] = .{
                .x = @intToFloat(f32, s.kind), // kind
                .y = @intToFloat(f32, j), // data offset
                .z = @intToFloat(f32, s.mat + self.shapes.items.len + 1), // mat
                .w = 0,
            };
            std.mem.copy(c.vec4, out[j..], s.data);

            i += 1;
            j += s.data.len;
        }

        // Put the materials after the shapes
        for (self.materials.items) |m| {
            if (m.tightly_packed()) {
                out[i] = .{
                    .x = @intToFloat(f32, m.kind),
                    .y = m.data[0].x,
                    .z = m.data[0].y,
                    .w = m.data[0].z,
                };
            } else {
                out[i] = .{
                    .x = @intToFloat(f32, m.kind),
                    .y = @intToFloat(f32, j),
                    .z = 0,
                    .w = 0,
                };
                std.mem.copy(c.vec4, out[j..], m.data);
                j += m.data.len;
            }
            i += 1;
        }
        return out;
    }
};
