const P = @import("phoneme.zig").PhonemeId;
pub const Formant = struct { frequency_hz: f32, bandwidth_hz: f32 = 100, gain: f32 = 1 };
pub const Waveform = enum { sawtooth, pulse, glottal };
pub const Voice = struct { base_pitch_hz: f32 = 125, speed: f32 = 1, amplitude: f32 = 0.7, breath: f32 = 0.035, formant_scale: f32 = 1, waveform: Waveform = .glottal };
pub const Parameters = struct { formants: [3]Formant, formants_end: ?[3]Formant = null, voiced: bool = true, noise: f32 = 0, gain: f32 = 1, attack_ms: f32 = 8, release_ms: f32 = 12 };
fn f(a: f32, b: f32, c: f32) [3]Formant {
    return .{ .{ .frequency_hz = a, .bandwidth_hz = 80, .gain = 1 }, .{ .frequency_hz = b, .bandwidth_hz = 110, .gain = 0.65 }, .{ .frequency_hz = c, .bandwidth_hz = 160, .gain = 0.35 } };
}
pub fn parameters(p: P) Parameters {
    var q = Parameters{ .formants = switch (p) {
        .a => f(800, 1200, 2600),
        .aa => f(730, 1090, 2440),
        .ah => f(640, 1190, 2390),
        .ao => f(570, 840, 2410),
        .iy => f(270, 2290, 3010),
        .uw => f(300, 870, 2240),
        .ey => f(530, 1840, 2480),
        .ay => f(730, 1090, 2440),
        .ow => f(450, 900, 2450),
        .aw => f(730, 1090, 2440),
        .oy => f(570, 840, 2410),
        .i => f(280, 2300, 3000),
        .u => f(350, 1000, 2400),
        .uh => f(440, 1020, 2240),
        .e => f(500, 1900, 2600),
        .eh => f(530, 1840, 2480),
        .o => f(500, 850, 2500),
        .ae => f(660, 1720, 2410),
        .ih => f(390, 1990, 2550),
        .schwa => f(500, 1500, 2500),
        .er, .r => f(450, 1300, 1700),
        .m => f(250, 1000, 2100),
        .n, .N, .ng => f(280, 1500, 2300),
        .w => f(300, 700, 2200),
        .y, .j => f(280, 2200, 2900),
        .l => f(400, 1200, 2500),
        .k, .g => f(450, 1800, 3000),
        .p, .b => f(350, 800, 2200),
        .t, .d, .ts => f(450, 2400, 3500),
        .f, .v => f(900, 2200, 4000),
        .th, .dh => f(1200, 2600, 4200),
        .h => f(500, 1500, 2500),
        .s, .z => f(3500, 5500, 6500),
        .sh, .ch => f(1800, 3000, 4500),
        else => f(500, 1500, 2500),
    } };
    q.voiced = @import("phoneme.zig").voiced(p);
    q.noise = switch (p) {
        .s, .sh, .f, .h, .th, .ch, .ts => 0.8,
        .z, .v, .dh => 0.35,
        else => 0,
    };
    if (p == .silence) q.gain = 0;
    switch (p) {
        .m, .n, .N, .ng => {
            q.formants[0].bandwidth_hz = 60;
            q.formants[1].gain = 0.2;
            q.formants[2].gain = 0.1;
            q.gain = 0.8;
        },
        else => {},
    }
    return q;
}
pub const presets = [_]struct { name: []const u8, voice: Voice }{ .{ .name = "Default", .voice = .{} }, .{ .name = "Robot", .voice = .{ .base_pitch_hz = 110, .waveform = .pulse, .breath = 0 } }, .{ .name = "Deep", .voice = .{ .base_pitch_hz = 85, .formant_scale = 0.8 } }, .{ .name = "Bright", .voice = .{ .base_pitch_hz = 180, .formant_scale = 1.18 } }, .{ .name = "Retro", .voice = .{ .base_pitch_hz = 145, .waveform = .sawtooth, .breath = 0.06 } } };

pub fn endFormants(p: P) [3]Formant {
    return switch (p) {
        .ey, .ay, .oy => parameters(.ih).formants,
        .ow => f(350, 1100, 2450),
        .aw => parameters(.uh).formants,
        else => parameters(p).formants,
    };
}
