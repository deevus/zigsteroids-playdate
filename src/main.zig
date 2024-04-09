const std = @import("std");
const rand = std.rand;
const PlaydateAllocator = @import("memory.zig").PlaydateAllocator;
const Playdate = @import("playdate-sdk").Playdate;
const PlaydateSamplePlayer = @import("playdate-sdk").sound.PlaydateSamplePlayer;

const math = @import("playdate-sdk").math;
const Vector2 = math.Vector2;
const Vector2i = math.Vector2i;

const pdapi = @import("playdate_api_definitions.zig");

var state: *State = undefined;
var sound: *Sound = undefined;
var pd: *pdapi.PlaydateAPI = undefined;
var player: *pdapi.SamplePlayer = undefined;
var sdk: Playdate = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

const THICKNESS = 1;
const SCALE = 12.0;
const SIZE = Vector2.init(pdapi.LCD_COLUMNS, pdapi.LCD_ROWS);

const MAX_ASTEROIDS = 256;
const MAX_PARTICLES = 256;
const MAX_PROJECTILES = 256;
const MAX_ALIENS = 16;

const BUFFER_SIZE = 1024 * 1024 * 2;

var buffer: [BUFFER_SIZE]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;

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

    fn addAsteroid(self: *@This(), asteroid: Asteroid) !void {
        const total_asteroids = self.asteroids.items.len + self.asteroids_queue.items.len;
        if (total_asteroids < MAX_ASTEROIDS) {
            try self.asteroids_queue.append(asteroid);
        }
    }

    fn addParticle(self: *@This(), particle: Particle) !void {
        if (self.particles.items.len < MAX_PARTICLES) {
            try self.particles.append(particle);
        }
    }

    fn addProjectile(self: *@This(), projectile: Projectile) !void {
        if (self.projectiles.items.len < MAX_PROJECTILES) {
            try self.projectiles.append(projectile);
        }
    }

    fn addAlien(self: *@This(), alien: Alien) !void {
        if (self.aliens.items.len < MAX_ALIENS) {
            try self.aliens.append(alien);
        }
    }
};

const Sound = struct {
    bloopLo: PlaydateSamplePlayer,
    bloopHi: PlaydateSamplePlayer,
    shoot: PlaydateSamplePlayer,
    thrust: PlaydateSamplePlayer,
    asteroid: PlaydateSamplePlayer,
    explode: PlaydateSamplePlayer,
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

fn playSound(s: PlaydateSamplePlayer) void {
    s.play();
}

fn drawCircle(pos: Vector2, radius: ?c_int) void {
    sdk.graphics.drawCircle(.{
        .position = pos.toVector2i(),
        .radius = radius,
        .color = .ColorBlack,
    });
}

fn drawLines(org: Vector2, scale: f32, rot: f32, points: []const Vector2, connect: bool) void {
    sdk.graphics.drawLines(.{
        .origin = org,
        .scale = scale,
        .rotation = rot,
        .points = points,
        .connect = connect,
        .thickness = THICKNESS,
        .color = .ColorWhite,
    });
}

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

fn drawNumber(n: usize, pos: Vector2) !void {
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

        const angle: f32 = (@as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(n)))) + (std.math.pi * 0.125 * random.float(f32));
        try points.append(
            Vector2.init(std.math.cos(angle), std.math.sin(angle)).scale(radius),
        );
    }

    drawLines(pos, size.size(), 0.0, points.slice(), true);
}

fn splatLines(pos: Vector2, count: usize) !void {
    if (state.particles.items.len < MAX_PARTICLES) {
        for (0..count) |_| {
            const angle = std.math.tau * state.rand.float(f32);
            try state.addParticle(.{
                .pos = Vector2.init(state.rand.float(f32) * 3, state.rand.float(f32) * 3).add(pos),
                .vel = Vector2.init(std.math.cos(angle), std.math.sin(angle)).scale(2.0 * state.rand.float(f32)),
                .ttl = 3.0 + state.rand.float(f32),
                .values = .{
                    .LINE = .{
                        .rot = std.math.tau * state.rand.float(f32),
                        .length = SCALE * (0.6 + (0.4 * state.rand.float(f32))),
                    },
                },
            });
        }
    }
}

fn splatDots(pos: Vector2, count: usize) !void {
    if (state.particles.items.len < MAX_PARTICLES) {
        for (0..count) |_| {
            const angle = std.math.tau * state.rand.float(f32);
            try state.addParticle(.{
                .pos = Vector2.init(state.rand.float(f32) * 3, state.rand.float(f32) * 3).add(pos),
                .vel = Vector2.init(std.math.cos(angle), std.math.sin(angle)).scale(2.0 + 4.0 * state.rand.float(f32)),
                .ttl = 0.5 + (0.4 * state.rand.float(f32)),
                .values = .{
                    .DOT = .{
                        .radius = SCALE * 0.025,
                    },
                },
            });
        }
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

        const seed = state.rand.int(u64);
        const vel = dir.scale(a.size.velocityScale() * 2.2 * state.rand.float(f32)).add(if (impact) |i| i.scale(0.7) else Vector2.init(0, 0));

        const asteroid: Asteroid = .{
            .pos = a.pos,
            .vel = vel,
            .size = size,
            .seed = seed,
        };

        try state.addAsteroid(asteroid);
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

        if (sdk.system.isButtonDown(pdapi.BUTTON_LEFT)) {
            state.ship.rot -= state.delta * std.math.tau * ROT_SPEED;
        }

        if (sdk.system.isButtonDown(pdapi.BUTTON_RIGHT)) {
            state.ship.rot += state.delta * std.math.tau * ROT_SPEED;
        }

        const dirAngle = state.ship.rot + (std.math.pi * 0.5);
        var shipDir = Vector2.init(std.math.cos(dirAngle), std.math.sin(dirAngle));

        if (sdk.system.isButtonDown(pdapi.BUTTON_UP)) {
            math.scale(&shipDir, state.delta * SHIP_SPEED);
            math.add(&shipDir, state.ship.vel);

            state.ship.vel = shipDir;

            if (state.frame % 2 == 0) {
                playSound(sound.thrust);
            }
        }

        const DRAG = 0.015;
        math.scale(&state.ship.vel, 1.0 - DRAG);
        math.add(&state.ship.pos, state.ship.vel);
        state.ship.pos.x = @mod(state.ship.pos.x, SIZE.x);
        state.ship.pos.y = @mod(state.ship.pos.y, SIZE.y);

        if (sdk.system.isButtonPressed(pdapi.BUTTON_A)) {
            try state.addProjectile(.{
                .pos = state.ship.pos.add(shipDir.scale(SCALE * 0.55)),
                .vel = shipDir.scale(10.0),
                .ttl = 2.0,
                .spawn = state.now,
            });
            playSound(sound.shoot);

            math.add(&state.ship.vel, shipDir.scale(-0.5));
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
    try state.asteroids.ensureUnusedCapacity(state.asteroids_queue.items.len);
    for (state.asteroids_queue.items) |a| {
        try state.asteroids.append(a);
    }
    try state.asteroids_queue.resize(0);

    {
        var i: usize = 0;
        while (i < state.asteroids.items.len) {
            var a = state.asteroids.items[i];

            math.add(&a.pos, a.vel);
            a.pos.x = @mod(a.pos.x, SIZE.x);
            a.pos.y = @mod(a.pos.y, SIZE.y);

            state.asteroids.items[i] = a;

            const ship_velocity_unit = state.ship.vel.normalize();

            // check for ship v. asteroid collision
            if (!state.ship.isDead() and a.pos.distance(state.ship.pos) < a.size.size() * a.size.collisionScale()) {
                state.ship.deathTime = state.now;
                try hitAsteroid(&a, ship_velocity_unit);
            }

            // check for alien v. asteroid collision
            for (state.aliens.items) |*l| {
                if (!l.remove and a.pos.distance(l.pos) < a.size.size() * a.size.collisionScale()) {
                    l.remove = true;
                    try hitAsteroid(&a, ship_velocity_unit);
                }
            }

            // check for projectile v. asteroid collision
            for (state.projectiles.items) |*p| {
                if (!p.remove and a.pos.distance(p.pos) < a.size.size() * a.size.collisionScale()) {
                    p.remove = true;
                    try hitAsteroid(&a, p.vel.normalize());
                }
            }

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

            math.add(&p.pos, p.vel);
            p.pos.x = @mod(p.pos.x, SIZE.x);
            p.pos.y = @mod(p.pos.y, SIZE.y);

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
            math.add(&p.pos, p.vel);
            p.pos.x = @mod(p.pos.x, SIZE.x);
            p.pos.y = @mod(p.pos.y, SIZE.y);

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
            var a = state.aliens.items[i];

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
                    const angle = std.math.tau * state.rand.float(f32);
                    a.dir = Vector2.init(std.math.cos(angle), std.math.sin(angle));
                }

                math.add(&a.pos, a.dir.scale(a.size.speed()));
                a.pos.x = @mod(a.pos.x, SIZE.x);
                a.pos.y = @mod(a.pos.y, SIZE.y);

                if ((state.now - a.lastShot) > a.size.shotTime()) {
                    a.lastShot = state.now;

                    var dir = state.ship.pos.clone();
                    math.subtract(&dir, a.pos);
                    math.normalize(&dir);

                    var projectile_pos = a.pos.clone();
                    math.add(&projectile_pos, dir.scale(SCALE * 0.55));

                    try state.addProjectile(.{
                        .pos = projectile_pos,
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
        if (state.bloop % 2 == 1) {
            playSound(sound.bloopHi);
        } else {
            sound.bloopLo.play();
        }
    }
    state.lastBloop = state.bloop;

    if (state.asteroids.items.len == 0 and state.aliens.items.len == 0) {
        try resetAsteroids();
    }

    if ((state.lastScore / 5000) != (state.score / 5000)) {
        try state.addAlien(.{
            .pos = Vector2.init(
                if (state.rand.boolean()) 0 else SIZE.x - SCALE,
                state.rand.float(f32) * SIZE.y,
            ),
            .dir = Vector2.init(0, 0),
            .size = .BIG,
        });
    }

    if ((state.lastScore / 8000) != (state.score / 8000)) {
        try state.addAlien(.{
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
    sdk.graphics.clear(.{ .color = .ColorBlack });

    // draw remaining lives
    for (0..state.lives) |i| {
        drawLines(
            Vector2.init(SCALE + (@as(f32, @floatFromInt(i)) * SCALE), SCALE),
            SCALE,
            -std.math.pi,
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

        if (sdk.system.isButtonDown(pdapi.BUTTON_UP) and @mod(@as(i32, @intFromFloat(state.now * 20)), 2) == 0) {
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

    const n = @min(30 + state.score / 1500, MAX_ASTEROIDS);

    for (0..n) |_| {
        const angle = std.math.tau * state.rand.float(f32);
        const size = state.rand.enumValue(AsteroidSize);

        const pos = Vector2.init(
            state.rand.float(f32) * SIZE.x,
            state.rand.float(f32) * SIZE.y,
        );

        const vel = Vector2.init(std.math.cos(angle), std.math.sin(angle)).scale(size.velocityScale() * 3.0 * state.rand.float(f32));

        try state.addAsteroid(.{
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
            sdk = Playdate.init(@ptrCast(playdate));
            fba = std.heap.FixedBufferAllocator.init(&buffer);
            arena = std.heap.ArenaAllocator.init(fba.allocator());
            allocator = arena.allocator();

            var prng = rand.Xoshiro256.init(playdate.system.getCurrentTimeMilliseconds());
            const global_state: *GlobalState = allocator.create(GlobalState) catch unreachable;

            pd = playdate;

            global_state.* = .{
                .playdate = playdate,
                .game_state = .{
                    .ship = .{
                        .pos = SIZE.scale(0.5),
                        .vel = Vector2.init(0, 0),
                        .rot = 0.0,
                    },
                    .asteroids = std.ArrayList(Asteroid).init(allocator),
                    .asteroids_queue = std.ArrayList(Asteroid).init(allocator),
                    .particles = std.ArrayList(Particle).init(allocator),
                    .projectiles = std.ArrayList(Projectile).init(allocator),
                    .aliens = std.ArrayList(Alien).init(allocator),
                    .rand = prng.random(),
                },
                .sound_player = playdate.sound.sampleplayer.newPlayer().?,
                .sound = .{
                    .bloopLo = sdk.sound.loadSample("bloop_lo.wav"),
                    .bloopHi = sdk.sound.loadSample("bloop_hi.wav"),
                    .shoot = sdk.sound.loadSample("shoot.wav"),
                    .thrust = sdk.sound.loadSample("thrust.wav"),
                    .asteroid = sdk.sound.loadSample("asteroid.wav"),
                    .explode = sdk.sound.loadSample("explode.wav"),
                },
            };

            sound = &global_state.sound;
            state = &global_state.game_state;
            player = global_state.sound_player;

            resetGame() catch @panic("Failed to reset game");

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

    update() catch @panic("Update failed");

    render() catch @panic("Render failed");

    sdk.system.drawFps(.{ .x = 0, .y = 0 });

    return 1;
}

/// Crashes the game with a message and error return trace in the following format:
///
/// ```txt
/// panic: your message here
/// 9001cdef 900189ab 90014567 90010123 9000cdef
/// 900089ab 90004567 90000123
/// ```
///
/// To override the default panic handler with this function, add the following lines of code to
/// your root source file:
///
/// ```zig
/// const playdate = @import("playdate");
///
/// pub const panic = playdate.panic;
/// ```
///
pub fn panic(msg: []const u8, error_ret_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const self = sdk.system;

    @setCold(true);

    const num_addrs = (if (error_ret_trace) |trace| trace.index else 0) + 1;
    const chars_per_addr = 1 + @bitSizeOf(usize) / 4;
    const buf_len = msg.len + num_addrs * chars_per_addr;
    if (self.api.realloc(null, buf_len + 1)) |ptr| {
        defer _ = self.api.realloc(ptr, 0);

        const buf: [*]u8 = @ptrCast(ptr);
        var buf_i: usize = 0;

        @memcpy(buf, msg);
        buf_i += msg.len;
        var addr_i: usize = 0;
        if (error_ret_trace) |trace| {
            while (addr_i < trace.index) : (addr_i += 1) {
                buf[buf_i] = if (addr_i % 5 == 0) '\n' else ' ';
                buf_i += 1;
                const addr = trace.instruction_addresses[addr_i];
                var shift: std.math.Log2Int(usize) = @bitSizeOf(usize) - 4;
                while (true) : (shift -= 4) {
                    var nybble = addr >> shift & 0xf;
                    nybble += if (nybble < 0xa) '0' else 'a' - 0xa;
                    buf[buf_i] = @truncate(nybble);
                    buf_i += 1;
                    if (shift == 0) break;
                }
            }
        }
        {
            buf[buf_i] = if (addr_i % 5 == 0) '\n' else ' ';
            buf_i += 1;
            const addr = ret_addr orelse @returnAddress();
            var shift: std.math.Log2Int(usize) = @bitSizeOf(usize) - 4;
            while (true) : (shift -= 4) {
                var nybble = addr >> shift & 0xf;
                nybble += if (nybble < 0xa) '0' else 'a' - 0xa;
                buf[buf_i] = @truncate(nybble);
                buf_i += 1;
                if (shift == 0) break;
            }
        }
        buf[buf_i] = 0;

        self.api.@"error"("panic: %s", buf);
    } else {
        self.api.@"error"("panic");
    }

    while (true) {
        @breakpoint();
    }
}
