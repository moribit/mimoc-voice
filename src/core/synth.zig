const std = @import("std");
const A = @import("target.zig");
const T = A.AcousticTarget;
const V = @import("voice.zig");
pub const EnvelopeMode = enum { single, legacy_double };
pub const Config = struct { sample_rate: u32 = 16000, voice: V.Voice = .{}, envelope_mode: EnvelopeMode = .single };
pub fn preEnvelope(value: f32, env: f32, mode: EnvelopeMode) f32 {
    return if (mode == .legacy_double) value * env else value;
}
/// Events are borrowed and must remain immutable until finished. Enqueue only on an idle synth.
pub const Synth = struct {
    config: Config,
    targets: []const T = &.{},
    index: usize = 0,
    frame: usize = 0,
    osc: @import("oscillator.zig").Oscillator = .{},
    noise: @import("noise.zig").Noise = .{},
    filters: [3]@import("resonator.zig").Resonator = .{ .{}, .{}, .{} },
    noise_low: f32 = 0,
    noise_filter: @import("resonator.zig").Resonator = .{},
    last_x: f32 = 0,
    last_y: f32 = 0,
    peak: f32 = 0,
    dc_mean: f32 = 0,
    pub fn init(config: Config) !Synth {
        const v = config.voice;
        if (config.sample_rate < 8000 or config.sample_rate > 96000 or !std.math.isFinite(v.speed) or v.speed < 0.25 or v.speed > 4 or !std.math.isFinite(v.base_pitch_hz) or v.base_pitch_hz < 40 or v.base_pitch_hz > 600 or !std.math.isFinite(v.amplitude) or v.amplitude < 0 or v.amplitude > 1 or !std.math.isFinite(v.breath) or v.breath < 0 or v.breath > 1 or !std.math.isFinite(v.formant_scale) or v.formant_scale < 0.5 or v.formant_scale > 2) return error.InvalidConfig;
        return .{ .config = config };
    }
    pub fn enqueue(self: *Synth, targets: []const T) !void {
        if (!self.finished()) return error.Busy;
        for (targets) |t| A.validate(t) catch return error.InvalidEvent;
        self.targets = targets;
        self.index = 0;
        self.frame = 0;
    }
    pub fn finished(self: *const Synth) bool {
        return self.index >= self.targets.len;
    }
    pub fn frames(self: *const Synth, e: anytype) usize {
        return @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.config.sample_rate)) * @as(f64, @floatFromInt(e.duration_ms)) / (1000 * @as(f64, self.config.voice.speed)))));
    }
    pub fn render(self: *Synth, out: []i16) usize {
        var count: usize = 0;
        const rate: f32 = @floatFromInt(self.config.sample_rate);
        while (count < out.len and !self.finished()) {
            const e = self.targets[self.index];
            const total = self.frames(e);
            const progress = @as(f32, @floatFromInt(self.frame)) / @as(f32, @floatFromInt(@max(total - 1, 1)));
            const ms = progress * @as(f32, @floatFromInt(e.duration_ms));
            const formants = A.formantsAt(e, ms);
            for (0..3) |j| {
                var f = formants[j];
                f.frequency_hz *= self.config.voice.formant_scale;
                self.filters[j].configure(f, rate);
            }
            const start = if (e.pitch_start_hz == 0) self.config.voice.base_pitch_hz * e.pitch_start_scale else @as(f32, @floatFromInt(e.pitch_start_hz));
            const end = if (e.pitch_end_hz == 0) self.config.voice.base_pitch_hz * e.pitch_end_scale else @as(f32, @floatFromInt(e.pitch_end_hz));
            const source = self.osc.next(std.math.clamp(start + (end - start) * progress, 40, 600), rate, self.config.voice.waveform);
            const noise = self.noise.next();
            var shaped = noise;
            switch (e.noise_shape) {
                .legacy, .broadband, .aspiration => {},
                .high_pass => {
                    const alpha = 1 - @exp(-2 * std.math.pi * @min(e.noise_frequency_hz, rate * 0.45) / rate);
                    self.noise_low += alpha * (noise - self.noise_low);
                    shaped = noise - self.noise_low;
                },
                .band_pass => {
                    self.noise_filter.configure(.{ .frequency_hz = e.noise_frequency_hz, .bandwidth_hz = e.noise_bandwidth_hz }, rate);
                    shaped = self.noise_filter.process(noise) * 2;
                },
            }
            var x = source * e.voicing + shaped * e.noise + noise * self.config.voice.breath;
            if (ms < e.closure_ms) x = source * e.voicing * e.closure_voicing else if (ms < e.closure_ms + e.burst_ms) x += shaped * e.burst_gain;
            var y: f32 = 0;
            for (&self.filters) |*f| y += f.process(x);
            y += shaped * e.noise * e.noise_bypass;
            const env = @import("envelope.zig").value(self.frame, total, @intFromFloat(e.attack_ms * rate / (1000 * self.config.voice.speed)), @intFromFloat(e.release_ms * rate / (1000 * self.config.voice.speed)));
            const amplitude = e.amplitude_start + (e.amplitude_end - e.amplitude_start) * progress;
            y *= amplitude * e.gain * self.config.voice.amplitude * 2;
            if (self.config.envelope_mode == .legacy_double) y *= env;
            // DC blocker followed by bounded soft limiting; no integer saturation/clipping.
            const dc = y - self.last_x + 0.995 * self.last_y;
            self.last_x = y;
            self.last_y = dc;
            self.peak = @max(self.peak, @abs(dc));
            const limited = dc / (1 + @abs(dc));
            self.dc_mean += 0.01 * (limited - self.dc_mean);
            out[count] = @intFromFloat((limited - self.dc_mean) * env * 14000);
            count += 1;
            self.frame += 1;
            if (self.frame == total) {
                self.index += 1;
                self.frame = 0;
            }
        }
        return count;
    }
};
test "streaming exact count partial buffers deterministic EOS" {
    const events = [_]@import("event.zig").PhonemeEvent{ .{ .phoneme = .a, .duration_ms = 100 }, .{ .phoneme = .i, .duration_ms = 101 } };
    var storage: [2]T = undefined;
    const targets = try @import("../planner/planner.zig").plan(&events, &storage, .{});
    var a = try Synth.init(.{});
    var b = try Synth.init(.{});
    try a.enqueue(targets);
    try b.enqueue(targets);
    try std.testing.expectEqual(@as(usize, 0), a.render(&.{}));
    try std.testing.expectEqual(@as(usize, 0), a.frame);
    var full: [3220]i16 = @splat(12345);
    const frames_total: usize = 3216;
    try std.testing.expectEqual(frames_total, a.render(&full));
    for (full[frames_total..]) |sample| try std.testing.expectEqual(@as(i16, 12345), sample);
    var offset: usize = 0;
    var small: [37]i16 = undefined;
    while (!b.finished()) {
        const n = b.render(&small);
        try std.testing.expectEqualSlices(i16, full[offset..][0..n], small[0..n]);
        offset += n;
    }
    try std.testing.expectEqual(frames_total, offset);
    try std.testing.expectEqual(@as(usize, 0), b.render(&small));
    try std.testing.expectEqual(@as(usize, 0), b.render(&.{}));
}

test "single envelope applied only at output legacy double fixed" {
    try std.testing.expectEqual(@as(f32, 0.25), preEnvelope(1, 0.5, .legacy_double) * 0.5);
    try std.testing.expectEqual(@as(f32, 0.5), preEnvelope(1, 0.5, .single) * 0.5);
}

test "render single envelope endpoints deterministic diphthong and partial chunks" {
    const events = [_]@import("event.zig").PhonemeEvent{.{ .phoneme = .ow, .duration_ms = 200 }};
    var targets: [1]T = undefined;
    _ = try @import("../planner/planner.zig").plan(&events, &targets, .{});
    targets[0].transition_in_ms = 0;
    targets[0].attack_ms = 80;
    var a = try Synth.init(.{});
    var b = try Synth.init(.{ .envelope_mode = .single });
    var old = try Synth.init(.{ .envelope_mode = .legacy_double });
    try a.enqueue(&targets);
    try b.enqueue(&targets);
    try old.enqueue(&targets);
    var x: [3200]i16 = undefined;
    var y: [3200]i16 = undefined;
    var z: [3200]i16 = undefined;
    try std.testing.expectEqual(x.len, a.render(&x));
    try std.testing.expectEqual(x.len, old.render(&z));
    var offset: usize = 0;
    while (!b.finished()) {
        const n = b.render(y[offset..@min(y.len, offset + 71)]);
        offset += n;
    }
    try std.testing.expectEqualSlices(i16, &x, &y);
    try std.testing.expectEqual(@as(i16, 0), x[0]);
    try std.testing.expectEqual(@as(i16, 0), x[x.len - 1]);
    var single_energy: f64 = 0;
    var double_energy: f64 = 0;
    for (x[0..640], z[0..640]) |xx, zz| {
        single_energy += @as(f64, @floatFromInt(xx)) * @as(f64, @floatFromInt(xx));
        double_energy += @as(f64, @floatFromInt(zz)) * @as(f64, @floatFromInt(zz));
    }
    try std.testing.expect(single_energy > double_energy);
    var stationary = targets;
    stationary[0].formants_end = stationary[0].formants_body;
    var c = try Synth.init(.{});
    try c.enqueue(&stationary);
    _ = c.render(&y);
    try std.testing.expect(!std.mem.eql(i16, &x, &y));
}
