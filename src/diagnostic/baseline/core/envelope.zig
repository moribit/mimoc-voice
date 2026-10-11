const std = @import("std");
pub fn value(frame: usize, total: usize, attack: usize, release: usize) f32 {
    if (total == 0) return 0;
    const a = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(@max(attack, 1)));
    const r = @as(f32, @floatFromInt(total - 1 - frame)) / @as(f32, @floatFromInt(@max(release, 1)));
    return @max(0, @min(1, @min(a, r)));
}
test "envelope endpoints" {
    try std.testing.expectEqual(@as(f32, 0), value(0, 100, 10, 10));
    try std.testing.expectEqual(@as(f32, 0), value(99, 100, 10, 10));
    try std.testing.expectEqual(@as(f32, 1), value(50, 100, 10, 10));
}
