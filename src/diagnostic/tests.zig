const std = @import("std");
const v = @import("../root.zig");
test "frozen Phase 5 WAV hashes pin double envelope reference" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const Cases = [_]struct { name: []const u8, text: []const u8, language: enum { isolated, en, ja }, sha: []const u8 }{
        .{ .name = "h", .text = "h", .language = .isolated, .sha = "c6b12af4e9c8658e0405bc73f140fd09261461b4e0b4c20c7c51c74048a47fc3" },
        .{ .name = "l", .text = "l", .language = .isolated, .sha = "de18e2fd49b8f6b6a316f804e846bb6c3934ef7bf7dace9fcf8eb2df7962b560" },
        .{ .name = "hello", .text = "hello", .language = .en, .sha = "8adaba67c77b1380344e980cfff50c44dd0c67aada928f26810de62615d67e36" },
        .{ .name = "konnichiwa", .text = "コンニチワ", .language = .ja, .sha = "fd190b81ebdf8998b8a07175a23f1984289d18c3929fd65ff8c00ef7ce699ac7" },
    };
    for (Cases) |case| {
        var events: [64]v.baseline.event.PhonemeEvent = undefined;
        var count: usize = 0;
        if (case.language == .isolated) {
            events[0] = .{ .phoneme = std.meta.stringToEnum(v.baseline_phoneme.PhonemeId, case.text).?, .duration_ms = 500 };
            count = 1;
        } else if (case.language == .en) {
            const seq = try v.baseline.english.parse(case.text, &events);
            count = seq.len;
        } else {
            const seq = try v.baseline.japanese.parse(case.text, &events);
            count = seq.len;
        }
        var synth = try v.baseline.synth.Synth.init(.{});
        try synth.enqueue(events[0..count]);
        var frames: u32 = 0;
        for (events[0..count]) |e| frames += @intCast(synth.frames(e));
        const header = try v.wav.header(16000, frames);
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(&header);
        var pcm: [512]i16 = undefined;
        var bytes: [1024]u8 = undefined;
        while (!synth.finished()) {
            const n = synth.render(&pcm);
            for (pcm[0..n], 0..) |sample, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], sample, .little);
            sha.update(bytes[0 .. n * 2]);
        }
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        var hex: [64]u8 = undefined;
        for (digest, 0..) |b, i| {
            hex[i * 2] = "0123456789abcdef"[b >> 4];
            hex[i * 2 + 1] = "0123456789abcdef"[b & 15];
        }
        try std.testing.expectEqualStrings(case.sha, &hex);
    }
}
