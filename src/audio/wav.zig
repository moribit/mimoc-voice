const std = @import("std");
const S = @import("../core/synth.zig").Synth;
extern fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern fn fclose(*anyopaque) c_int;
pub fn header(rate: u32, count: u32) ![44]u8 {
    if (count > (std.math.maxInt(u32) - 36) / 2 or rate > std.math.maxInt(u32) / 2) return error.WavTooLarge;
    var h: [44]u8 = undefined;
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + count * 2, .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little);
    std.mem.writeInt(u16, h[20..22], 1, .little);
    std.mem.writeInt(u16, h[22..24], 1, .little);
    std.mem.writeInt(u32, h[24..28], rate, .little);
    std.mem.writeInt(u32, h[28..32], rate * 2, .little);
    std.mem.writeInt(u16, h[32..34], 2, .little);
    std.mem.writeInt(u16, h[34..36], 16, .little);
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], count * 2, .little);
    return h;
}
/// Writes bounded chunks. Caller owns synth and events; filesystem only in audio adapter.
pub fn exportFile(path: [:0]const u8, synth: *S) !void {
    if (synth.index != 0 or synth.frame != 0) return error.AlreadyRendering;
    var count: u64 = 0;
    for (synth.events) |e| count += synth.frames(e);
    if (count > std.math.maxInt(u32)) return error.WavTooLarge;
    const h = try header(synth.config.sample_rate, @intCast(count));
    const f = fopen(path, "wb") orelse return error.OpenFailed;
    var closed = false;
    defer if (!closed) {
        _ = fclose(f);
    };
    if (fwrite(&h, 1, h.len, f) != h.len) return error.WriteFailed;
    var pcm: [512]i16 = undefined;
    var bytes: [1024]u8 = undefined;
    while (!synth.finished()) {
        const n = synth.render(&pcm);
        for (pcm[0..n], 0..) |sample, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], sample, .little);
        if (fwrite(&bytes, 1, n * 2, f) != n * 2) return error.WriteFailed;
    }
    closed = true;
    if (fclose(f) != 0) return error.WriteFailed;
}
test "RIFF PCM header count and overflow" {
    const h = try header(16000, 1600);
    try std.testing.expectEqualStrings("RIFF", h[0..4]);
    try std.testing.expectEqual(@as(u32, 3236), std.mem.readInt(u32, h[4..8], .little));
    try std.testing.expectEqual(@as(u32, 3200), std.mem.readInt(u32, h[40..44], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, h[22..24], .little));
    try std.testing.expectError(error.WavTooLarge, header(16000, std.math.maxInt(u32)));
}
