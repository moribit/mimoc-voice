const std = @import("std");
const E = @import("../core/event.zig").PhonemeEvent;
const P = @import("../core/phoneme.zig");
const V = @import("../core/voice.zig");
const A = @import("../core/target.zig");
pub const AcousticTarget = A.AcousticTarget;
pub const Language = enum { neutral, ja, en };
pub const Options = struct { language: Language = .neutral, context_timing: bool = true, context_transitions: bool = true, shaped_noise: bool = true, dynamic_vowels: bool = true, english_vowels: bool = true, stress_prosody: bool = true };
pub const Timing = struct { schwa: u16 = 70, short_vowel: u16 = 100, stressed_vowel: u16 = 135, diphthong: u16 = 170, fricative: u16 = 70, approximant: u16 = 85, plosive: u16 = 50, nasal: u16 = 80, affricate: u16 = 80 };
pub fn duration(e: E, prev: ?E, next: ?E, options: Options, timing: Timing) u16 {
    if (e.timing == .explicit or options.language != .en) return e.duration_ms;
    if (!options.context_timing) return if (P.vowel(e.phoneme)) 110 else 60;
    var ms: u16 = switch (P.class(e.phoneme)) {
        .silence => 65,
        .vowel => if (e.phoneme == .schwa and e.stress == 0) timing.schwa else if (P.diphthong(e.phoneme)) timing.diphthong else if (e.stress > 0) timing.stressed_vowel else timing.short_vowel,
        .fricative => timing.fricative,
        .approximant => timing.approximant,
        .plosive => timing.plosive,
        .nasal => timing.nasal,
        .affricate => timing.affricate,
    };
    if (P.diphthong(e.phoneme) and e.stress > 0) ms += 15;
    if (next == null or next.?.phoneme == .silence) {
        if (P.vowel(e.phoneme) or P.class(e.phoneme) == .approximant) ms += 10;
    }
    if (P.class(e.phoneme) == .plosive and prev != null and P.class(prev.?.phoneme) == .fricative) ms -= 10;
    if (P.vowel(e.phoneme) and next != null and P.class(next.?.phoneme) == .plosive and !P.voiced(next.?.phoneme)) ms = @intFromFloat(@as(f32, @floatFromInt(ms)) * 0.9);
    return ms;
}
fn transition(from: P.PhonemeId, to: P.PhonemeId) f32 {
    const f = P.class(from);
    const t = P.class(to);
    if (f == .silence or t == .silence) return 0;
    if (f == .approximant or t == .approximant) return 60;
    if (f == .vowel and t == .vowel) return 65;
    if (f == .plosive or f == .affricate) return 20;
    if (f == .fricative) return 30;
    return 25;
}
/// Converts into caller-owned memory. No filesystem, audio, UI, allocator or mutable globals.
pub fn plan(events: []const E, out: []AcousticTarget, options: Options) ![]AcousticTarget {
    return planWithTiming(events, out, options, .{});
}
pub fn planWithTiming(events: []const E, out: []AcousticTarget, options: Options, timing: Timing) ![]AcousticTarget {
    if (out.len < events.len) return error.NoSpace;
    for (events, 0..) |e, i| {
        const alias: P.PhonemeId = if (!options.english_vowels and options.language == .en) switch (e.phoneme) {
            .iy => .i,
            .uw, .uh => .u,
            .eh => .e,
            .aa, .ah => .a,
            .ao => .o,
            else => e.phoneme,
        } else e.phoneme;
        const q = e.parameters orelse V.parameters(alias);
        const prev = if (i > 0) events[i - 1] else null;
        const next = if (i + 1 < events.len) events[i + 1] else null;
        const ms = duration(e, prev, next, options, timing);
        const stressed = options.stress_prosody and options.language == .en and e.stress > 0;
        const weak = options.language == .en and e.phoneme == .schwa and e.stress == 0;
        out[i] = .{ .phoneme = e.phoneme, .duration_ms = ms, .pitch_start_scale = e.pitch_scale * (if (stressed) @as(f32, 1.12) else 1), .pitch_end_scale = e.pitch_end_scale * (if (stressed) @as(f32, 1.06) else 1), .pitch_start_hz = e.pitch_hz, .pitch_end_hz = e.pitch_end_hz, .amplitude_start = if (weak) 0.65 else if (stressed) 1.12 else 1, .amplitude_end = if (weak) 0.65 else if (stressed) 1.05 else 1, .formants_start = q.formants, .formants_body = q.formants, .formants_end = if (P.diphthong(e.phoneme) and options.dynamic_vowels) V.endFormants(e.phoneme) else q.formants, .glide = P.diphthong(e.phoneme) and options.dynamic_vowels, .voicing = if (q.voiced) 1 else 0, .noise = q.noise, .gain = q.gain, .attack_ms = q.attack_ms, .release_ms = q.release_ms, .stress = e.stress };
        if (options.context_transitions) {
            out[i].transition_in_ms = if (prev) |p| transition(p.phoneme, e.phoneme) else 0;
        } else out[i].transition_in_ms = 25;
        if (P.class(e.phoneme) == .plosive or P.class(e.phoneme) == .affricate) {
            out[i].closure_ms = @as(f32, @floatFromInt(ms)) * 0.45;
            out[i].burst_ms = @as(f32, @floatFromInt(ms)) * 0.13;
        }
        if (options.shaped_noise) {
            out[i].noise_shape = switch (e.phoneme) {
                .s, .z => .high_pass,
                .sh, .ch, .j => .band_pass,
                .f, .v, .th, .dh => .high_pass,
                .h => .aspiration,
                else => .broadband,
            };
            out[i].noise_frequency_hz = switch (e.phoneme) {
                .s, .z => 3500,
                .sh, .ch, .j => 2200,
                .f, .v => 1000,
                .th, .dh => 1600,
                else => 1200,
            };
            out[i].noise_bandwidth_hz = if (e.phoneme == .sh or e.phoneme == .ch) 1400 else 2200;
            out[i].noise_bypass = if (e.phoneme == .h) 0 else 0.12;
        }
    }
    if (options.context_transitions) {
        for (events, 0..) |e, i| {
            if (e.phoneme == .h and i + 1 < events.len and P.vowel(events[i + 1].phoneme)) {
                out[i].formants_body = out[i + 1].formants_body;
                out[i].formants_start = out[i].formants_body;
                out[i].formants_end = out[i].formants_body;
            }
            if (P.class(e.phoneme) == .approximant) {
                if (i > 0 and P.vowel(events[i - 1].phoneme)) {
                    out[i - 1].formants_end = A.mix(out[i - 1].formants_end, out[i].formants_body, 0.35);
                    out[i - 1].transition_out_ms = 45;
                }
                if (i + 1 < events.len and P.vowel(events[i + 1].phoneme)) {
                    out[i].formants_end = A.mix(out[i].formants_body, out[i + 1].formants_body, 0.65);
                    out[i].transition_out_ms = 55;
                }
            }
        }
    }
    for (events, 0..) |e, i| {
        if (i > 0 and events[i - 1].phoneme != .silence and e.phoneme != .silence) out[i].formants_start = out[i - 1].formants_end;
        try A.validate(out[i]);
    }
    return out[0..events.len];
}
test "hello targets stress timing diphthong and context" {
    const en = @import("../lang/english.zig");
    var events: [16]E = undefined;
    const seq = try en.parse("hello", &events);
    var storage: [16]AcousticTarget = undefined;
    const targets = try plan(seq.events(), &storage, .{ .language = .en });
    const ps = [_]P.PhonemeId{ .h, .schwa, .l, .ow };
    for (targets, ps) |t, p| try std.testing.expectEqual(p, t.phoneme);
    try std.testing.expect(targets[0].duration_ms >= 60 and targets[0].duration_ms <= 80);
    try std.testing.expect(targets[1].duration_ms >= 60 and targets[1].duration_ms <= 90);
    try std.testing.expect(targets[2].duration_ms >= 70 and targets[2].duration_ms <= 100);
    try std.testing.expect(targets[3].duration_ms >= 150 and targets[3].duration_ms <= 220);
    try std.testing.expect(targets[3].amplitude_start > targets[1].amplitude_start);
    try std.testing.expect(targets[3].pitch_start_scale > targets[1].pitch_start_scale);
    try std.testing.expect(targets[3].formants_body[0].frequency_hz != targets[3].formants_end[0].frequency_hz);
    try std.testing.expectEqual(@as(f32, 60), targets[3].transition_in_ms);
}
test "approximant target depends on neighbors all l r w y" {
    for ([_]P.PhonemeId{ .l, .r, .w, .y }) |p| {
        const a = [_]E{ .{ .phoneme = .eh }, .{ .phoneme = p }, .{ .phoneme = .iy } };
        const b = [_]E{ .{ .phoneme = .aa }, .{ .phoneme = p }, .{ .phoneme = .uw } };
        var x: [3]AcousticTarget = undefined;
        var y: [3]AcousticTarget = undefined;
        _ = try plan(&a, &x, .{});
        _ = try plan(&b, &y, .{});
        try std.testing.expect(x[1].formants_start[1].frequency_hz != y[1].formants_start[1].frequency_hz);
        try std.testing.expect(x[1].formants_end[1].frequency_hz != y[1].formants_end[1].frequency_hz);
    }
}
test "caller capacity invalid and explicit timing" {
    var out: [1]AcousticTarget = undefined;
    const e = [_]E{.{ .phoneme = .ow, .duration_ms = 321 }};
    const t = try plan(&e, &out, .{ .language = .en });
    try std.testing.expectEqual(@as(u16, 321), t[0].duration_ms);
    try std.testing.expectError(error.NoSpace, plan(&e, out[0..0], .{}));
}
