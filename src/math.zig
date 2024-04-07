const std = @import("std");

pub const Vector2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vector2 {
        return .{ .x = x, .y = y };
    }

    pub fn scale(self: @This(), s: f32) Vector2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn rotate(self: @This(), angle: f32) Vector2 {
        const c = std.math.cos(angle);
        const s = std.math.sin(angle);
        return .{
            .x = self.x * c - self.y * s,
            .y = self.x * s + self.y * c,
        };
    }

    pub fn add(self: @This(), other: Vector2) Vector2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn subtract(self: @This(), other: Vector2) Vector2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn normalize(self: @This()) Vector2 {
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        return .{ .x = self.x / len, .y = self.y / len };
    }

    pub fn distance(self: @This(), other: Vector2) f32 {
        return std.math.sqrt((self.x - other.x) * (self.x - other.x) + (self.y - other.y) * (self.y - other.y));
    }
};

// mutable version of Vector2
pub const MutableVector2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) MutableVector2 {
        return .{ .x = x, .y = y };
    }

    pub fn scale(self: *@This(), s: f32) void {
        self.x *= s;
        self.y *= s;
    }

    pub fn rotate(self: *@This(), angle: f32) void {
        const c = std.math.cos(angle);
        const s = std.math.sin(angle);
        const x = self.x;
        self.x = x * c - self.y * s;
        self.y = x * s + self.y * c;
    }

    pub fn add(self: *@This(), other: Vector2) void {
        self.x += other.x;
        self.y += other.y;
    }

    pub fn subtract(self: *@This(), other: Vector2) void {
        self.x -= other.x;
        self.y -= other.y;
    }

    pub fn normalize(self: *@This()) void {
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        self.x /= len;
        self.y /= len;
    }

    pub fn distance(self: *@This(), other: Vector2) f32 {
        return std.math.sqrt((self.x - other.x) * (self.x - other.x) + (self.y - other.y) * (self.y - other.y));
    }
};
