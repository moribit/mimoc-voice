const std = @import("std");
const E = @import("event.zig").PhonemeEvent;
const V = @import("voice.zig");
const P = @import("phoneme.zig");
pub const Config = struct { sample_rate: u32 = 16000, voice: V.Voice = .{} };
/// Events are borrowed and must remain immutable until finished. Enqueue only on an idle synth.
pub const Synth = struct {
    config: Config,
    events: []const E = &.{},
    index: usize = 0,
    frame: usize = 0,
    osc: @import("oscillator.zig").Oscillator = .{},
    noise: @import("noise.zig").Noise = .{},
    filters: [3]@import("resonator.zig").Resonator = .{ .{}, .{}, .{} },
    previous: V.Parameters = V.parameters(.schwa),
    last_x: f32 = 0,
    last_y: f32 = 0,
    peak: f32 = 0,
    dc_mean: f32 = 0,
    pub fn init(config: Config) !Synth {
        const v = config.voice;
        if (config.sample_rate < 8000 or config.sample_rate > 96000 or !std.math.isFinite(v.speed) or v.speed < 0.25 or v.speed > 4 or !std.math.isFinite(v.base_pitch_hz) or v.base_pitch_hz < 40 or v.base_pitch_hz > 600 or !std.math.isFinite(v.amplitude) or v.amplitude < 0 or v.amplitude > 1 or !std.math.isFinite(v.breath) or v.breath < 0 or v.breath > 1 or !std.math.isFinite(v.formant_scale) or v.formant_scale < 0.5 or v.formant_scale > 2) return error.InvalidConfig;
        return .{ .config = config };
    }
    pub fn enqueue(self: *Synth, events: []const E) !void {
        if (!self.finished()) return error.Busy;
        for (events) |e| {
            if (e.duration_ms == 0 or !std.math.isFinite(e.pitch_scale) or !std.math.isFinite(e.pitch_end_scale) or e.pitch_scale < 0.1 or e.pitch_scale > 4 or e.pitch_end_scale < 0.1 or e.pitch_end_scale > 4) return error.InvalidEvent;
            if (e.parameters) |q| {
                if (!std.math.isFinite(q.gain) or q.gain < 0 or q.gain > 4 or !std.math.isFinite(q.noise) or q.noise < 0 or q.noise > 1 or !std.math.isFinite(q.attack_ms) or q.attack_ms < 0 or q.attack_ms > 1000 or !std.math.isFinite(q.release_ms) or q.release_ms < 0 or q.release_ms > 1000) return error.InvalidEvent;
                for (q.formants) |f| if (!std.math.isFinite(f.frequency_hz) or !std.math.isFinite(f.bandwidth_hz) or !std.math.isFinite(f.gain) or f.frequency_hz < 0 or f.bandwidth_hz <= 0 or f.gain < 0 or f.gain > 4) return error.InvalidEvent;
            }
        }
        self.events = events;
        self.index = 0;
        self.frame = 0;
    }
    pub fn finished(self: *const Synth) bool {
        return self.index >= self.events.len;
    }
    pub fn frames(self: *const Synth, e: E) usize {
        return @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.config.sample_rate)) * @as(f64, @floatFromInt(e.duration_ms)) / (1000 * @as(f64, self.config.voice.speed)))));
    }
    pub fn render(self: *Synth, out: []i16) usize {
        var count: usize = 0;
        const rate: @TypeOf(@as(f32, 0)) = @floatFromInt(self.config.sample_rate);
        while (count < out.len and !self.finished()) {
            const e = self.events[self.index];
            const total = self.frames(e);
            const q = e.parameters orelse V.parameters(e.phoneme);
            const blend = @min(1, @as(f32, @floatFromInt(self.frame)) / (rate * 0.025));
            for (0..3) |j| {
                var f = q.formants[j];
                f.frequency_hz = (self.previous.formants[j].frequency_hz * (1 - blend) + f.frequency_hz * blend) * self.config.voice.formant_scale;
                f.bandwidth_hz = self.previous.formants[j].bandwidth_hz * (1 - blend) + f.bandwidth_hz * blend;
                f.gain = self.previous.formants[j].gain * (1 - blend) + f.gain * blend;
                self.filters[j].configure(f, rate);
            }
            const progress = @as(f32, @floatFromInt(self.frame)) / @as(f32, @floatFromInt(total));
            const start = if (e.pitch_hz == 0) self.config.voice.base_pitch_hz * e.pitch_scale else @as(f32, @floatFromInt(e.pitch_hz));
            const end = if (e.pitch_end_hz == 0) (if (e.pitch_hz == 0) self.config.voice.base_pitch_hz * e.pitch_end_scale else start * 0.94) else @as(f32, @floatFromInt(e.pitch_end_hz));
            const source = self.osc.next(std.math.clamp(start + (end - start) * progress, 40, 600), rate, self.config.voice.waveform);
            const noise = self.noise.next();
            var x = (if (q.voiced) source else 0) + noise * (q.noise + self.config.voice.breath);
            const plosive = switch (e.phoneme) {
                .k, .g, .p, .b, .t, .d, .ch, .ts => true,
                else => false,
            };
            if (plosive) {
                if (progress < 0.45) x = if (q.voiced) source * 0.05 else 0 else if (progress < 0.58) x += noise * 1.8;
            }
            var y: f32 = 0;
            for (&self.filters) |*f| y += f.process(x);
            if (q.noise > 0) y += noise * q.noise * 0.12;
            const env = @import("envelope.zig").value(self.frame, total, @intFromFloat(q.attack_ms * rate / 1000), @intFromFloat(q.release_ms * rate / 1000));
            y *= env * q.gain * self.config.voice.amplitude * 2;
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
                self.previous = q;
                self.index += 1;
                self.frame = 0;
            }
        }
        return count;
    }
};
test "streaming exact count partial buffers deterministic EOS" {
    const events = [_]E{ .{ .phoneme = .a, .duration_ms = 100 }, .{ .phoneme = .i, .duration_ms = 101 } };
    var a = try Synth.init(.{});
    var b = try Synth.init(.{});
    try a.enqueue(&events);
    try b.enqueue(&events);
    var full: [3216]i16 = undefined;
    try std.testing.expectEqual(full.len, a.render(&full));
    var offset: usize = 0;
    var small: [37]i16 = undefined;
    while (!b.finished()) {
        const n = b.render(&small);
        try std.testing.expectEqualSlices(i16, full[offset..][0..n], small[0..n]);
        offset += n;
    }
    try std.testing.expectEqual(full.len, offset);
    try std.testing.expectEqual(@as(usize, 0), b.render(&small));
    try std.testing.expectEqual(@as(usize, 0), b.render(&.{}));
}
