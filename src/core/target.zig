const std = @import("std");
const P = @import("phoneme.zig").PhonemeId;
const F = @import("voice.zig").Formant;
pub const NoiseShape = enum { legacy, broadband, high_pass, band_pass, aspiration };
pub const AcousticTarget = struct {
    phoneme: P,
    duration_ms: u16,
    pitch_start_scale: f32 = 1,
    pitch_end_scale: f32 = 0.94,
    pitch_start_hz: u16 = 0,
    pitch_end_hz: u16 = 0,
    amplitude_start: f32 = 1,
    amplitude_end: f32 = 1,
    formants_start: [3]F,
    formants_body: [3]F,
    formants_end: [3]F,
    voicing: f32 = 1,
    noise: f32 = 0,
    gain: f32 = 1,
    attack_ms: f32 = 8,
    release_ms: f32 = 12,
    transition_in_ms: f32 = 25,
    transition_out_ms: f32 = 0,
    glide: bool = false,
    stress: u8 = 0,
    noise_shape: NoiseShape = .legacy,
    noise_frequency_hz: f32 = 3000,
    noise_bandwidth_hz: f32 = 1500,
    noise_bypass: f32 = 0.12,
    closure_ms: f32 = 0,
    burst_ms: f32 = 0,
    burst_gain: f32 = 1.8,
    closure_voicing: f32 = 0.05,
};
pub fn mix(a: [3]F, b: [3]F, t: f32) [3]F {
    var out: [3]F = undefined;
    for (0..3) |i| out[i] = .{ .frequency_hz = a[i].frequency_hz + (b[i].frequency_hz - a[i].frequency_hz) * t, .bandwidth_hz = a[i].bandwidth_hz + (b[i].bandwidth_hz - a[i].bandwidth_hz) * t, .gain = a[i].gain + (b[i].gain - a[i].gain) * t };
    return out;
}
/// All time values are in target-time milliseconds; voice speed scales the whole trajectory.
pub fn formantsAt(target: AcousticTarget, ms: f32) [3]F {
    const in = @min(target.transition_in_ms, @as(f32, @floatFromInt(target.duration_ms)) * 0.45);
    const out = @min(target.transition_out_ms, @as(f32, @floatFromInt(target.duration_ms)) * 0.45);
    if (in > 0 and ms < in) return mix(target.formants_start, target.formants_body, std.math.clamp(ms / in, 0, 1));
    const end: @TypeOf(@as(f32, 0)) = @floatFromInt(target.duration_ms);
    if (target.glide) return mix(target.formants_body, target.formants_end, std.math.clamp((ms - in) / @max(1, end - in), 0, 1));
    if (out > 0 and ms > end - out) return mix(target.formants_body, target.formants_end, std.math.clamp((ms - (end - out)) / out, 0, 1));
    return target.formants_body;
}
pub fn validate(t: AcousticTarget) !void {
    if (t.duration_ms == 0 or t.stress > 2) return error.InvalidTarget;
    const nonnegative = [_]f32{ t.amplitude_start, t.amplitude_end, t.voicing, t.noise, t.gain, t.attack_ms, t.release_ms, t.transition_in_ms, t.transition_out_ms, t.closure_ms, t.burst_ms, t.burst_gain, t.closure_voicing, t.noise_frequency_hz, t.noise_bandwidth_hz, t.noise_bypass };
    for (nonnegative) |x| if (!std.math.isFinite(x) or x < 0) return error.InvalidTarget;
    if (t.amplitude_start > 4 or t.amplitude_end > 4 or t.voicing > 1 or t.noise > 1 or t.gain > 4 or t.attack_ms > 1000 or t.release_ms > 1000 or t.transition_in_ms > 5000 or t.transition_out_ms > 5000 or t.closure_ms + t.burst_ms > @as(f32, @floatFromInt(t.duration_ms)) or t.burst_gain > 4 or t.closure_voicing > 1 or t.noise_frequency_hz > 96000 or t.noise_bandwidth_hz == 0 or t.noise_bandwidth_hz > 96000 or t.noise_bypass > 1) return error.InvalidTarget;
    for ([_]f32{ t.pitch_start_scale, t.pitch_end_scale }) |x| if (!std.math.isFinite(x) or x < 0.1 or x > 4) return error.InvalidTarget;
    for ([_][3]F{ t.formants_start, t.formants_body, t.formants_end }) |fs| for (fs) |f| if (!std.math.isFinite(f.frequency_hz) or f.frequency_hz < 0 or f.frequency_hz > 96000 or !std.math.isFinite(f.bandwidth_hz) or f.bandwidth_hz <= 0 or f.bandwidth_hz > 96000 or !std.math.isFinite(f.gain) or f.gain < 0 or f.gain > 4) return error.InvalidTarget;
}
test "diphthong and transition interpolation endpoints" {
    const v = @import("voice.zig");
    const a = v.parameters(.ow).formants;
    const b = v.endFormants(.ow);
    var t = AcousticTarget{ .phoneme = .ow, .duration_ms = 180, .formants_start = a, .formants_body = a, .formants_end = b, .glide = true, .transition_in_ms = 0 };
    try std.testing.expectEqual(a[0].frequency_hz, formantsAt(t, 0)[0].frequency_hz);
    try std.testing.expectEqual(b[0].frequency_hz, formantsAt(t, 180)[0].frequency_hz);
    try std.testing.expectEqual(@as(f32, 400), formantsAt(t, 90)[0].frequency_hz);
    t.glide = false;
    t.formants_start = b;
    t.transition_in_ms = 60;
    try std.testing.expectEqual(@as(f32, 400), formantsAt(t, 30)[0].frequency_hz);
}
