const std = @import("std");
const math = std.math;
const rand = std.rand;
const PlaydateAllocator = @import("memory.zig").PlaydateAllocator;

const pdapi = @import("playdate_api_definitions.zig");

var state: *State = undefined;
var sound: *Sound = undefined;
var pd: *pdapi.PlaydateAPI = undefined;
var player: *pdapi.SamplePlayer = undefined;

pub inline fn isButtonDown(button: pdapi.PDButtons) bool {
    var down: pdapi.PDButtons = 0;

    pd.system.getButtonState(&down, null, null);

    return down & button != 0;
}

pub inline fn isButtonPressed(button: pdapi.PDButtons) bool {
    var pressed: pdapi.PDButtons = 0;

    pd.system.getButtonState(null, &pressed, null);

    return pressed & button != 0;
}

const Vector2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vector2 {
        return .{ .x = x, .y = y };
    }

    pub fn scale(self: @This(), s: f32) Vector2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn rotate(self: @This(), angle: f32) Vector2 {
        const c = math.cos(angle);
        const s = math.sin(angle);
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
        const len = math.sqrt(self.x * self.x + self.y * self.y);
        return .{ .x = self.x / len, .y = self.y / len };
    }

    pub fn distance(self: @This(), other: Vector2) f32 {
        return math.sqrt((self.x - other.x) * (self.x - other.x) + (self.y - other.y) * (self.y - other.y));
    }
};

const THICKNESS = 1.0;
const SCALE = 9.0;
const SIZE = Vector2.init(pdapi.LCD_COLUMNS, pdapi.LCD_ROWS);

const Ship = struct {
    pos: Vector2,
    vel: Vector2,
    rot: f32,
    deathTime: f32 = 0.0,

    fn isDead(self: @This()) bool {
        return self.deathTime != 0.0;
    }
};

const Asteroid = struct {
    pos: Vector2,
    vel: Vector2,
    size: AsteroidSize,
    seed: u64,
    remove: bool = false,
};

const AlienSize = enum {
    BIG,
    SMALL,

    fn collisionSize(self: @This()) f32 {
        return switch (self) {
            .BIG => SCALE * 0.8,
            .SMALL => SCALE * 0.5,
        };
    }

    fn dirChangeTime(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.85,
            .SMALL => 0.35,
        };
    }

    fn shotTime(self: @This()) f32 {
        return switch (self) {
            .BIG => 1.25,
            .SMALL => 0.75,
        };
    }

    fn speed(self: @This()) f32 {
        return switch (self) {
            .BIG => 3,
            .SMALL => 6,
        };
    }
};

const Alien = struct {
    pos: Vector2,
    dir: Vector2,
    size: AlienSize,
    remove: bool = false,
    lastShot: f32 = 0,
    lastDir: f32 = 0,
};

const ParticleType = enum {
    LINE,
    DOT,
};

const Particle = struct {
    pos: Vector2,
    vel: Vector2,
    ttl: f32,

    values: union(ParticleType) {
        LINE: struct {
            rot: f32,
            length: f32,
        },
        DOT: struct {
            radius: f32,
        },
    },
};

const Projectile = struct {
    pos: Vector2,
    vel: Vector2,
    ttl: f32,
    spawn: f32,
    remove: bool = false,
};

const State = struct {
    now: f32 = 0,
    delta: f32 = 0,
    stageStart: f32 = 0,
    ship: Ship,
    asteroids: std.ArrayList(Asteroid),
    asteroids_queue: std.ArrayList(Asteroid),
    particles: std.ArrayList(Particle),
    projectiles: std.ArrayList(Projectile),
    aliens: std.ArrayList(Alien),
    rand: rand.Random,
    lives: usize = 0,
    lastScore: usize = 0,
    score: usize = 0,
    reset: bool = false,
    lastBloop: usize = 0,
    bloop: usize = 0,
    frame: usize = 0,
};

const Sound = struct {
    bloopLo: *pdapi.SamplePlayer,
    bloopHi: *pdapi.SamplePlayer,
    shoot: *pdapi.SamplePlayer,
    thrust: *pdapi.SamplePlayer,
    asteroid: *pdapi.SamplePlayer,
    explode: *pdapi.SamplePlayer,
};

fn loadSample(file_path: [:0]const u8) !*pdapi.SamplePlayer {
    const sample_player: *pdapi.SamplePlayer = pd.sound.sampleplayer.newPlayer().?;

    if (pd.sound.sample.load(file_path.ptr)) |sample| {
        _ = pd.sound.sampleplayer.setSample(sample_player, sample);
    } else {
        return error.SoundSampleFileNotFound;
    }

    return sample_player;
}

fn playSound(s: *pdapi.SamplePlayer) void {
    _ = pd.sound.sampleplayer.play(s, 1, 1);
}

fn drawCircle(pos: Vector2, radius: ?c_int) void {
    const x: c_int = @intFromFloat(pos.x);
    const y: c_int = @intFromFloat(pos.y);
    const circumference = if (radius) |r| r * 2 else 2;

    pd.graphics.fillEllipse(x, y, circumference, circumference, 0, 360, @intFromEnum(pdapi.LCDSolidColor.ColorWhite));
}

fn drawLines(org: Vector2, scale: f32, rot: f32, points: []const Vector2, connect: bool) void {
    const Transformer = struct {
        org: Vector2,
        scale: f32,
        rot: f32,

        fn apply(self: @This(), p: Vector2) Vector2 {
            return p.rotate(self.rot).scale(self.scale).add(self.org);
        }
    };

    const t = Transformer{
        .org = org,
        .scale = scale,
        .rot = rot,
    };

    const bound = if (connect) points.len else (points.len - 1);
    for (0..bound) |i| {
        const v0 = t.apply(points[i]);
        const v1 = t.apply(points[(i + 1) % points.len]);

        pd.graphics.drawLine(@intFromFloat(v0.x), @intFromFloat(v0.y), @intFromFloat(v1.x), @intFromFloat(v1.y), math.ceil(THICKNESS), @intFromEnum(pdapi.LCDSolidColor.ColorWhite));
    }
}

fn drawNumber(n: usize, pos: Vector2) !void {
    const NUMBER_LINES = [10][]const [2]f32{
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
        &.{ .{ 0.5, 0 }, .{ 0.5, 1 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0 }, .{ 1, 0 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 } },
        &.{ .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 1 }, .{ 1, 0 } },
        &.{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 } },
        &.{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0.5 }, .{ 0, 0.5 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } },
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0 } },
        &.{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 } },
    };

    var pos2 = pos;

    var val = n;
    var digits: usize = 0;
    while (val >= 0) {
        digits += 1;
        val /= 10;
        if (val == 0) {
            break;
        }
    }

    //pos2.x += @as(f32, @floatFromInt(digits)) * SCALE;
    val = n;
    while (val >= 0) {
        var points = try std.BoundedArray(Vector2, 16).init(0);
        for (NUMBER_LINES[val % 10]) |p| {
            try points.append(Vector2.init(p[0] - 0.5, (1.0 - p[1]) - 0.5));
        }

        drawLines(pos2, SCALE * 0.8, 0, points.slice(), false);
        pos2.x -= SCALE;
        val /= 10;
        if (val == 0) {
            break;
        }
    }
}

// BIG.size -> 10.3
// MEDIUM.size -> 8.3
// SMALL.size -> 2.5
const AsteroidSize = enum {
    BIG,
    MEDIUM,
    SMALL,

    fn score(self: @This()) usize {
        return switch (self) {
            .BIG => 20,
            .MEDIUM => 50,
            .SMALL => 100,
        };
    }

    fn size(self: @This()) f32 {
        return switch (self) {
            .BIG => SCALE * 3.0,
            .MEDIUM => SCALE * 1.4,
            .SMALL => SCALE * 0.8,
        };
    }

    fn collisionScale(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.4,
            .MEDIUM => 0.65,
            .SMALL => 1.0,
        };
    }

    fn velocityScale(self: @This()) f32 {
        return switch (self) {
            .BIG => 0.75,
            .MEDIUM => 1.8,
            .SMALL => 3.0,
        };
    }
};

fn drawAsteroid(pos: Vector2, size: AsteroidSize, seed: u64) !void {
    var prng = rand.Xoshiro256.init(seed);
    var random = prng.random();

    var points = try std.BoundedArray(Vector2, 16).init(0);
    const n = random.intRangeLessThan(i32, 8, 15);

    for (0..@intCast(n)) |i| {
        var radius = 0.3 + (0.2 * random.float(f32));
        if (random.float(f32) < 0.2) {
            radius -= 0.2;
        }

        const angle: f32 = (@as(f32, @floatFromInt(i)) * (math.tau / @as(f32, @floatFromInt(n)))) + (math.pi * 0.125 * random.float(f32));
        try points.append(
            Vector2.init(math.cos(angle), math.sin(angle)).scale(radius),
        );
    }

    drawLines(pos, size.size(), 0.0, points.slice(), true);
}

fn splatLines(pos: Vector2, count: usize) !void {
    for (0..count) |_| {
        const angle = math.tau * state.rand.float(f32);
        try state.particles.append(.{
            .pos = Vector2.init(state.rand.float(f32) * 3, state.rand.float(f32) * 3).add(pos),
            .vel = Vector2.init(math.cos(angle), math.sin(angle)).scale(2.0 * state.rand.float(f32)),
            .ttl = 3.0 + state.rand.float(f32),
            .values = .{
                .LINE = .{
                    .rot = math.tau * state.rand.float(f32),
                    .length = SCALE * (0.6 + (0.4 * state.rand.float(f32))),
                },
            },
        });
    }
}

fn splatDots(pos: Vector2, count: usize) !void {
    for (0..count) |_| {
        const angle = math.tau * state.rand.float(f32);
        try state.particles.append(.{
            .pos = Vector2.init(state.rand.float(f32) * 3, state.rand.float(f32) * 3).add(pos),
            .vel = Vector2.init(math.cos(angle), math.sin(angle)).scale(2.0 + 4.0 * state.rand.float(f32)),
            .ttl = 0.5 + (0.4 * state.rand.float(f32)),
            .values = .{
                .DOT = .{
                    .radius = SCALE * 0.025,
                },
            },
        });
    }
}

fn hitAsteroid(a: *Asteroid, impact: ?Vector2) !void {
    playSound(sound.asteroid);

    state.score += a.size.score();
    a.remove = true;

    try splatDots(a.pos, 10);

    if (a.size == .SMALL) {
        return;
    }

    for (0..2) |_| {
        const dir = a.vel.normalize();
        const size: AsteroidSize = switch (a.size) {
            .BIG => .MEDIUM,
            .MEDIUM => .SMALL,
            else => unreachable,
        };

        try state.asteroids_queue.append(.{
            .pos = a.pos,
            .vel = dir.scale(a.size.velocityScale() * 2.2 * state.rand.float(f32)).add(if (impact) |i| i.scale(0.7) else Vector2.init(0, 0)),
            .size = size,
            .seed = state.rand.int(u64),
        });
    }
}

fn update() !void {
    if (state.reset) {
        state.reset = false;
        try resetGame();
    }

    if (!state.ship.isDead()) {
        // rotations / second
        const ROT_SPEED = 2;
        const SHIP_SPEED = 24;

        if (isButtonDown(pdapi.BUTTON_LEFT)) {
            state.ship.rot -= state.delta * math.tau * ROT_SPEED;
        }

        if (isButtonDown(pdapi.BUTTON_RIGHT)) {
            state.ship.rot += state.delta * math.tau * ROT_SPEED;
        }

        const dirAngle = state.ship.rot + (math.pi * 0.5);
        const shipDir = Vector2.init(math.cos(dirAngle), math.sin(dirAngle));

        if (isButtonDown(pdapi.BUTTON_UP)) {
            state.ship.vel = shipDir.scale(state.delta * SHIP_SPEED).add(state.ship.vel);

            if (state.frame % 2 == 0) {
                playSound(sound.thrust);
            }
        }

        const DRAG = 0.015;
        state.ship.vel = state.ship.vel.scale(1.0 - DRAG);
        state.ship.pos = state.ship.pos.add(state.ship.vel);
        state.ship.pos = Vector2.init(
            @mod(state.ship.pos.x, SIZE.x),
            @mod(state.ship.pos.y, SIZE.y),
        );

        if (isButtonPressed(pdapi.BUTTON_A)) {
            try state.projectiles.append(.{
                .pos = state.ship.pos.add(shipDir.scale(SCALE * 0.55)),
                .vel = shipDir.scale(10.0),
                .ttl = 2.0,
                .spawn = state.now,
            });
            playSound(sound.shoot);

            state.ship.vel = state.ship.vel.add(shipDir.scale(-0.5));
        }

        // check for projectile v. ship collision
        for (state.projectiles.items) |*p| {
            if (!p.remove and (state.now - p.spawn) > 0.15 and state.ship.pos.distance(p.pos) < (SCALE * 0.7)) {
                p.remove = true;
                state.ship.deathTime = state.now;
            }
        }
    }

    // add asteroids from queue
    for (state.asteroids_queue.items) |a| {
        try state.asteroids.append(a);
    }
    try state.asteroids_queue.resize(0);

    {
        var i: usize = 0;
        while (i < state.asteroids.items.len) {
            var a = &state.asteroids.items[i];
            a.pos = a.pos.add(a.vel);
            a.pos = Vector2.init(
                @mod(a.pos.x, SIZE.x),
                @mod(a.pos.y, SIZE.y),
            );

            // check for ship v. asteroid collision
            // if (!state.ship.isDead() and a.pos.distance(state.ship.pos) < a.size.size() * a.size.collisionScale()) {
            //     state.ship.deathTime = state.now;
            //     try hitAsteroid(state, a, state.ship.vel.normalize());
            // }

            // // check for alien v. asteroid collision
            // for (state.aliens.items) |*l| {
            //     if (!l.remove and a.pos.distance(l.pos) < a.size.size() * a.size.collisionScale()) {
            //         l.remove = true;
            //         try hitAsteroid(state, a, state.ship.vel.normalize());
            //     }
            // }

            // // check for projectile v. asteroid collision
            // for (state.projectiles.items) |*p| {
            //     if (!p.remove and a.pos.distance(p.pos) < a.size.size() * a.size.collisionScale()) {
            //         p.remove = true;
            //         try hitAsteroid(state, a, p.vel.normalize());
            //     }
            // }

            if (a.remove) {
                _ = state.asteroids.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    {
        var i: usize = 0;
        while (i < state.particles.items.len) {
            var p = &state.particles.items[i];
            p.pos = p.pos.add(p.vel);
            p.pos = Vector2.init(
                @mod(p.pos.x, SIZE.x),
                @mod(p.pos.y, SIZE.y),
            );

            if (p.ttl > state.delta) {
                p.ttl -= state.delta;
                i += 1;
            } else {
                _ = state.particles.swapRemove(i);
            }
        }
    }

    {
        var i: usize = 0;
        while (i < state.projectiles.items.len) {
            var p = &state.projectiles.items[i];
            p.pos = p.pos.add(p.vel);
            p.pos = Vector2.init(
                @mod(p.pos.x, SIZE.x),
                @mod(p.pos.y, SIZE.y),
            );

            if (!p.remove and p.ttl > state.delta) {
                p.ttl -= state.delta;
                i += 1;
            } else {
                _ = state.projectiles.swapRemove(i);
            }
        }
    }

    {
        var i: usize = 0;
        while (i < state.aliens.items.len) {
            var a = &state.aliens.items[i];

            // check for projectile v. alien collision
            for (state.projectiles.items) |*p| {
                if (!p.remove and (state.now - p.spawn) > 0.15 and a.pos.distance(p.pos) < a.size.collisionSize()) {
                    p.remove = true;
                    a.remove = true;
                }
            }

            // check alien v. ship
            if (!a.remove and a.pos.distance(state.ship.pos) < a.size.collisionSize()) {
                a.remove = true;
                state.ship.deathTime = state.now;
            }

            if (!a.remove) {
                if ((state.now - a.lastDir) > a.size.dirChangeTime()) {
                    a.lastDir = state.now;
                    const angle = math.tau * state.rand.float(f32);
                    a.dir = Vector2.init(math.cos(angle), math.sin(angle));
                }

                a.pos = a.pos.add(a.dir.scale(a.size.speed()));
                a.pos = Vector2.init(
                    @mod(a.pos.x, SIZE.x),
                    @mod(a.pos.y, SIZE.y),
                );

                if ((state.now - a.lastShot) > a.size.shotTime()) {
                    a.lastShot = state.now;
                    const dir = state.ship.pos.subtract(a.pos).normalize();
                    try state.projectiles.append(.{
                        .pos = a.pos.add(dir.scale(SCALE * 0.55)),
                        .vel = dir.scale(6.0),
                        .ttl = 2.0,
                        .spawn = state.now,
                    });
                    playSound(sound.shoot);
                }
            }

            if (a.remove) {
                playSound(sound.asteroid);
                try splatDots(a.pos, 15);
                try splatLines(a.pos, 4);
                _ = state.aliens.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    if (state.ship.deathTime == state.now) {
        playSound(sound.explode);
        try splatDots(state.ship.pos, 20);
        try splatLines(state.ship.pos, 5);
    }

    if (state.ship.isDead() and (state.now - state.ship.deathTime) > 3.0) {
        try resetStage();
    }

    const bloopIntensity = @min(@as(usize, @intFromFloat(state.now - state.stageStart)) / 15, 3);

    var bloopMod: usize = 60;
    for (0..bloopIntensity) |_| {
        bloopMod /= 2;
    }

    if (state.frame % bloopMod == 0) {
        state.bloop += 1;
    }

    if (!state.ship.isDead() and state.bloop != state.lastBloop) {
        playSound(if (state.bloop % 2 == 1) sound.bloopHi else sound.bloopLo);
    }
    state.lastBloop = state.bloop;

    if (state.asteroids.items.len == 0 and state.aliens.items.len == 0) {
        try resetAsteroids();
    }

    if ((state.lastScore / 5000) != (state.score / 5000)) {
        try state.aliens.append(.{
            .pos = Vector2.init(
                if (state.rand.boolean()) 0 else SIZE.x - SCALE,
                state.rand.float(f32) * SIZE.y,
            ),
            .dir = Vector2.init(0, 0),
            .size = .BIG,
        });
    }

    if ((state.lastScore / 8000) != (state.score / 8000)) {
        try state.aliens.append(.{
            .pos = Vector2.init(
                if (state.rand.boolean()) 0 else SIZE.x - SCALE,
                state.rand.float(f32) * SIZE.y,
            ),
            .dir = Vector2.init(0, 0),
            .size = .SMALL,
        });
    }

    state.lastScore = state.score;
}

fn drawAlien(pos: Vector2, size: AlienSize) void {
    const scale: f32 = switch (size) {
        .BIG => 1.0,
        .SMALL => 0.5,
    };

    drawLines(pos, SCALE * scale, 0, &.{
        Vector2.init(-0.5, 0.0),
        Vector2.init(-0.3, 0.3),
        Vector2.init(0.3, 0.3),
        Vector2.init(0.5, 0.0),
        Vector2.init(0.3, -0.3),
        Vector2.init(-0.3, -0.3),
        Vector2.init(-0.5, 0.0),
        Vector2.init(0.5, 0.0),
    }, false);

    drawLines(pos, SCALE * scale, 0, &.{
        Vector2.init(-0.2, -0.3),
        Vector2.init(-0.1, -0.5),
        Vector2.init(0.1, -0.5),
        Vector2.init(0.2, -0.3),
    }, false);
}

const SHIP_LINES = [_]Vector2{
    Vector2.init(-0.4, -0.5),
    Vector2.init(0.0, 0.5),
    Vector2.init(0.4, -0.5),
    Vector2.init(0.3, -0.4),
    Vector2.init(-0.3, -0.4),
};

fn render() !void {
    const g = pd.graphics;

    g.clear(@intFromEnum(pdapi.LCDSolidColor.ColorBlack));

    // draw remaining lives
    for (0..state.lives) |i| {
        drawLines(
            Vector2.init(SCALE + (@as(f32, @floatFromInt(i)) * SCALE), SCALE),
            SCALE,
            -math.pi,
            &SHIP_LINES,
            true,
        );
    }

    // draw score
    try drawNumber(state.score, Vector2.init(SIZE.x - SCALE, SCALE));

    if (!state.ship.isDead()) {
        drawLines(
            state.ship.pos,
            SCALE,
            state.ship.rot,
            &SHIP_LINES,
            true,
        );

        if (isButtonDown(pdapi.BUTTON_UP) and @mod(@as(i32, @intFromFloat(state.now * 20)), 2) == 0) {
            drawLines(
                state.ship.pos,
                SCALE,
                state.ship.rot,
                &.{
                    Vector2.init(-0.3, -0.4),
                    Vector2.init(0.0, -1.0),
                    Vector2.init(0.3, -0.4),
                },
                true,
            );
        }
    }

    for (state.asteroids.items) |a| {
        try drawAsteroid(a.pos, a.size, a.seed);
    }

    for (state.aliens.items) |a| {
        drawAlien(a.pos, a.size);
    }

    for (state.particles.items) |p| {
        switch (p.values) {
            .LINE => |line| {
                drawLines(
                    p.pos,
                    line.length,
                    line.rot,
                    &.{
                        Vector2.init(-0.5, 0),
                        Vector2.init(0.5, 0),
                    },
                    true,
                );
            },
            .DOT => |dot| {
                drawCircle(p.pos, @intFromFloat(dot.radius));
            },
        }
    }

    for (state.projectiles.items) |p| {
        drawCircle(p.pos, 1);
    }
}

fn resetAsteroids() !void {
    try state.asteroids.resize(0);

    for (0..(30 + state.score / 1500)) |_| {
        const angle = math.tau * state.rand.float(f32);
        const size = state.rand.enumValue(AsteroidSize);

        const pos = Vector2.init(
            state.rand.float(f32) * SIZE.x,
            state.rand.float(f32) * SIZE.y,
        );

        const vel = Vector2.init(math.cos(angle), math.sin(angle)).scale(size.velocityScale() * 3.0 * state.rand.float(f32));

        try state.asteroids_queue.append(.{
            .pos = pos,
            .vel = vel,
            .size = size,
            .seed = state.rand.int(u64),
        });
    }

    state.stageStart = state.now;
}

fn resetGame() !void {
    state.lives = 3;
    state.score = 0;

    try resetStage();
    try resetAsteroids();
}

// reset after losing a life
fn resetStage() !void {
    if (state.ship.isDead()) {
        if (state.lives == 0) {
            state.reset = true;
        } else {
            state.lives -= 1;
        }
    }

    state.ship.deathTime = 0.0;
    state.ship = .{
        .pos = SIZE.scale(0.5),
        .vel = Vector2.init(0, 0),
        .rot = 0.0,
    };
}

// pub fn main(state: State, prng: rand.Xoshiro256) !void {
//     sound = .{
//         .bloopLo = rl.loadSound("bloop_lo.wav"),
//         .bloopHi = rl.loadSound("bloop_hi.wav"),
//         .shoot = rl.loadSound("shoot.wav"),
//         .thrust = rl.loadSound("thrust.wav"),
//         .asteroid = rl.loadSound("asteroid.wav"),
//         .explode = rl.loadSound("explode.wav"),
//     };

//     try resetGame();

//     while (!rl.windowShouldClose()) {
//         state.delta = rl.getFrameTime();
//         state.now += state.delta;

//         try update();

//         rl.beginDrawing();
//         defer rl.endDrawing();

//         rl.clearBackground(rl.Color.black);

//         try render();
//         state.frame += 1;
//     }
// }

const GlobalState = struct {
    playdate: *pdapi.PlaydateAPI,
    game_state: State,
    sound: Sound,
    sound_player: *pdapi.SamplePlayer,
};

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    //TODO: replace with your own code!

    _ = arg;
    switch (event) {
        .EventInit => {
            var playdate_allocator = PlaydateAllocator.init(playdate);
            const allocator = playdate_allocator.allocator();

            var prng = rand.Xoshiro256.init(playdate.system.getCurrentTimeMilliseconds());
            const global_state: *GlobalState = allocator.create(GlobalState) catch unreachable;

            const initSize = 512;

            pd = playdate;

            global_state.* = .{
                .playdate = playdate,
                .game_state = .{
                    .ship = .{
                        .pos = SIZE.scale(0.5),
                        .vel = Vector2.init(0, 0),
                        .rot = 0.0,
                    },
                    .asteroids = std.ArrayList(Asteroid).initCapacity(allocator, initSize) catch unreachable,
                    .asteroids_queue = std.ArrayList(Asteroid).initCapacity(allocator, initSize) catch unreachable,
                    .particles = std.ArrayList(Particle).initCapacity(allocator, initSize) catch unreachable,
                    .projectiles = std.ArrayList(Projectile).initCapacity(allocator, initSize) catch unreachable,
                    .aliens = std.ArrayList(Alien).initCapacity(allocator, initSize) catch unreachable,
                    .rand = prng.random(),
                },
                .sound_player = playdate.sound.sampleplayer.newPlayer().?,
                .sound = .{
                    .bloopLo = loadSample("bloop_lo.wav") catch unreachable,
                    .bloopHi = loadSample("bloop_hi.wav") catch unreachable,
                    .shoot = loadSample("shoot.wav") catch unreachable,
                    .thrust = loadSample("thrust.wav") catch unreachable,
                    .asteroid = loadSample("asteroid.wav") catch unreachable,
                    .explode = loadSample("explode.wav") catch unreachable,
                },
            };

            sound = &global_state.sound;
            state = &global_state.game_state;
            player = global_state.sound_player;

            resetGame() catch unreachable;

            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(_: ?*anyopaque) callconv(.C) c_int {
    state.frame += 1;

    const previous_now = state.now;
    state.now = pd.system.getElapsedTime();
    state.delta = pd.system.getElapsedTime() - previous_now;

    update() catch unreachable;

    render() catch unreachable;

    return 1;
}
