const std = @import("std");
const v = @import("root.zig");
test "evaluation corpus finite deterministic bounded duration and DC" {
    const ja = [_][]const u8{ "アイウエオ", "コンニチワ", "オハヨウ", "モーバス", "メッセージ", "セツゾク", "バッテリー", "エラー" };
    const en = [_][]const u8{ "hello", "hello world", "system ready", "message received", "battery low", "network connected", "device disconnected", "warning", "system error" };
    for (0..2) |lang| {
        const texts: []const []const u8 = if (lang == 0) &ja else &en;
        for (texts) |text| {
            var es: [128]v.event.PhonemeEvent = undefined;
            const seq = if (lang == 0) try v.japanese.parse(text, &es) else try v.english.parse(text, &es);
            var a = try v.synth.Synth.init(.{});
            var b = try v.synth.Synth.init(.{});
            try a.enqueue(seq.events());
            try b.enqueue(seq.events());
            var buf: [257]i16 = undefined;
            var other: [257]i16 = undefined;
            var count: usize = 0;
            var sum: i64 = 0;
            var peak: u32 = 0;
            var jump: u32 = 0;
            var last: i32 = 0;
            while (!a.finished()) {
                const n = a.render(&buf);
                try std.testing.expectEqual(n, b.render(other[0..n]));
                try std.testing.expectEqualSlices(i16, buf[0..n], other[0..n]);
                for (buf[0..n]) |x| {
                    peak = @max(peak, @abs(@as(i32, x)));
                    jump = @max(jump, @abs(@as(i32, x) - last));
                    last = x;
                    sum += x;
                }
                count += n;
            }
            try std.testing.expect(count >= 1600 and count < 16000 * 10);
            try std.testing.expect(peak > 100 and peak < 30000);
            try std.testing.expect(jump < 30000);
            try std.testing.expect(@abs(@divTrunc(sum, @as(i64, @intCast(count)))) < 200);
            try std.testing.expect(std.math.isFinite(a.peak));
        }
    }
}
test "all phonemes presets and sample rates stable" {
    for (std.meta.tags(v.phoneme.PhonemeId)) |p| for (v.voice.presets) |preset| for ([_]u32{ 8000, 16000, 22050, 48000 }) |rate| {
        var s = try v.synth.Synth.init(.{ .sample_rate = rate, .voice = preset.voice });
        const es = [_]v.event.PhonemeEvent{.{ .phoneme = p, .duration_ms = 75 }};
        try s.enqueue(&es);
        var buf: [113]i16 = undefined;
        var count: usize = 0;
        while (!s.finished()) {
            const n = s.render(&buf);
            for (buf[0..n]) |x| try std.testing.expect(@abs(@as(i32, x)) < 30000);
            count += n;
        }
        try std.testing.expectEqual(s.frames(es[0]), count);
        try std.testing.expect(std.math.isFinite(s.peak));
    };
}
test "invalid config event and busy queue rejected" {
    try std.testing.expectError(error.InvalidConfig, v.synth.Synth.init(.{ .voice = .{ .speed = 0 } }));
    try std.testing.expectError(error.InvalidConfig, v.synth.Synth.init(.{ .sample_rate = 1 }));
    var s = try v.synth.Synth.init(.{});
    const invalid = [_]v.event.PhonemeEvent{.{ .phoneme = .a, .duration_ms = 0 }};
    try std.testing.expectError(error.InvalidEvent, s.enqueue(&invalid));
    const valid = [_]v.event.PhonemeEvent{.{ .phoneme = .a }};
    try s.enqueue(&valid);
    try std.testing.expectError(error.Busy, s.enqueue(&valid));
}
