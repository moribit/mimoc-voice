const std = @import("std");
pub const Choice = enum { x, y, same };
pub const Trial = struct { index: u32, x_is_new: bool, choice: Choice };
/// Random assignment is injected by the application; fixed seeds make tests reproducible.
pub const Blind = struct {
    state: u32 = 1,
    active: bool = false,
    revealed: bool = false,
    x_is_new: bool = false,
    heard_x: bool = false,
    heard_y: bool = false,
    trials: [128]Trial = undefined,
    len: usize = 0,
    new_wins: usize = 0,
    old_wins: usize = 0,
    ties: usize = 0,
    pub fn start(self: *Blind, seed: u32) void {
        self.* = .{ .state = if (seed == 0) 1 else seed, .active = true };
        self.shuffle();
    }
    fn shuffle(self: *Blind) void {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        self.x_is_new = (x & 0x80000000) != 0;
        self.heard_x = false;
        self.heard_y = false;
    }
    pub fn markHeard(self: *Blind, side: Choice) void {
        if (side == .x) self.heard_x = true else if (side == .y) self.heard_y = true;
    }
    pub fn vote(self: *Blind, choice: Choice) !void {
        if (!self.active or self.revealed) return error.NoBlindTrial;
        if (!self.heard_x or !self.heard_y) return error.AuditionBothSides;
        if (self.len == self.trials.len) return error.TrialCapacity;
        self.trials[self.len] = .{ .index = @intCast(self.len + 1), .x_is_new = self.x_is_new, .choice = choice };
        self.len += 1;
        if (choice == .same) self.ties += 1 else if ((choice == .x) == self.x_is_new) self.new_wins += 1 else self.old_wins += 1;
        self.shuffle();
    }
};
test "blind seeded randomization both audition required ties and mapping" {
    var b = Blind{};
    b.start(0x12345678);
    var x: usize = 0;
    for (0..32) |i| {
        try std.testing.expectError(error.AuditionBothSides, b.vote(.x));
        b.markHeard(.x);
        b.markHeard(.y);
        const is_new = b.x_is_new;
        if (is_new) x += 1;
        try b.vote(if (i == 0) .same else if (is_new) .x else .y);
    }
    try std.testing.expect(x > 0 and x < 32);
    try std.testing.expectEqual(@as(usize, 31), b.new_wins);
    try std.testing.expectEqual(@as(usize, 1), b.ties);
    b.revealed = true;
    try std.testing.expectError(error.NoBlindTrial, b.vote(.x));
}
