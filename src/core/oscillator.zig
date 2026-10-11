const std = @import("std");
pub const Oscillator = struct {
    phase: f32 = 0,
    pub fn next(self: *Oscillator, pitch: f32, rate: f32, wave: @import("voice.zig").Waveform) f32 {
        self.phase += pitch / rate;
        self.phase -= @floor(self.phase);
        const p = self.phase;
        return switch (wave) {
            .sawtooth => 2 * p - 1,
            .pulse => if (p < 0.35) 0.65 else -0.35,
            .glottal => if (p < 0.6) 0.5 * (1 - @cos(2 * std.math.pi * p / 0.6)) - 0.3 else -0.3,
        };
    }
};
test "waveforms bounded periodic" {
    for ([_]@import("voice.zig").Waveform{ .sawtooth, .pulse, .glottal }) |w| {
        var o = Oscillator{};
        for (0..16000) |_| {
            const x = o.next(125, 16000, w);
            try std.testing.expect(std.math.isFinite(x) and @abs(x) <= 1);
        }
    }
}
