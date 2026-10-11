const std = @import("std");
const v = @import("../root.zig");
pub const Record = struct { session_index: u32, phrase: []const u8, language: v.planner.Language, voice_preset: []const u8, voice: v.voice.Voice, envelope: v.synth.EnvelopeMode, parameter_snapshot: []const v.target.AcousticTarget, intelligibility: u8, heard_as: []const u8, problem: []const u8, hypothesis: []const u8, decision: enum { pending, keep, revert } = .pending };
pub const Comparison = struct { phrase: []const u8, language: v.planner.Language, hypothesis: []const u8, scope: []const u8, selected: usize, voice_a: v.voice.Voice, voice_b: v.voice.Voice, envelope_a: v.synth.EnvelopeMode, envelope_b: v.synth.EnvelopeMode, targets_a: []const v.target.AcousticTarget, targets_b: []const v.target.AcousticTarget, trials: []const v.studio_blind.Trial };
pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    comparisons: std.ArrayList(Comparison) = .empty,
    pub fn init(a: std.mem.Allocator) Store {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Store) void {
        for (self.records.items) |r| {
            self.allocator.free(r.phrase);
            self.allocator.free(r.voice_preset);
            self.allocator.free(r.parameter_snapshot);
            self.allocator.free(r.heard_as);
            self.allocator.free(r.problem);
            self.allocator.free(r.hypothesis);
        }
        self.records.deinit(self.allocator);
        for (self.comparisons.items) |c| {
            self.allocator.free(c.phrase);
            self.allocator.free(c.hypothesis);
            self.allocator.free(c.scope);
            self.allocator.free(c.targets_a);
            self.allocator.free(c.targets_b);
            self.allocator.free(c.trials);
        }
        self.comparisons.deinit(self.allocator);
    }
    pub fn append(self: *Store, input: Record) !void {
        if (input.intelligibility < 1 or input.intelligibility > 5) return error.InvalidScore;
        if (input.parameter_snapshot.len > 512 or input.phrase.len > 1024 or input.problem.len > 512 or input.heard_as.len > 256 or input.hypothesis.len > 256 or self.records.items.len >= 256) return error.EvaluationCapacity;
        _ = try v.synth.Synth.init(.{ .voice = input.voice, .envelope_mode = input.envelope });
        for (input.parameter_snapshot) |t| try v.target.validate(t);
        const a = self.allocator;
        var r = input;
        r.phrase = try a.dupe(u8, input.phrase);
        errdefer a.free(r.phrase);
        r.voice_preset = try a.dupe(u8, input.voice_preset);
        errdefer a.free(r.voice_preset);
        r.parameter_snapshot = try a.dupe(v.target.AcousticTarget, input.parameter_snapshot);
        errdefer a.free(r.parameter_snapshot);
        r.heard_as = try a.dupe(u8, input.heard_as);
        errdefer a.free(r.heard_as);
        r.problem = try a.dupe(u8, input.problem);
        errdefer a.free(r.problem);
        r.hypothesis = try a.dupe(u8, input.hypothesis);
        errdefer a.free(r.hypothesis);
        try self.records.append(a, r);
    }
    pub fn appendComparison(self: *Store, input: Comparison) !void {
        if (self.comparisons.items.len >= 128 or input.targets_a.len > 512 or input.targets_b.len > 512 or input.trials.len > 128 or input.phrase.len > 1024 or input.hypothesis.len > 256 or input.scope.len > 64) return error.EvaluationCapacity;
        for (input.targets_a) |t| try v.target.validate(t);
        for (input.targets_b) |t| try v.target.validate(t);
        const a = self.allocator;
        var c = input;
        c.phrase = try a.dupe(u8, input.phrase);
        errdefer a.free(c.phrase);
        c.hypothesis = try a.dupe(u8, input.hypothesis);
        errdefer a.free(c.hypothesis);
        c.scope = try a.dupe(u8, input.scope);
        errdefer a.free(c.scope);
        c.targets_a = try a.dupe(v.target.AcousticTarget, input.targets_a);
        errdefer a.free(c.targets_a);
        c.targets_b = try a.dupe(v.target.AcousticTarget, input.targets_b);
        errdefer a.free(c.targets_b);
        c.trials = try a.dupe(v.studio_blind.Trial, input.trials);
        errdefer a.free(c.trials);
        try self.comparisons.append(a, c);
    }
};
test "evaluation captures immutable parameters and rejects invalid scores" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var events: [4]v.event.PhonemeEvent = undefined;
    const seq = try v.english.parse("hello", &events);
    var targets: [4]v.target.AcousticTarget = undefined;
    _ = try v.planner.plan(seq.events(), &targets, .{ .language = .en });
    const r = Record{ .session_index = 1, .phrase = "hello", .language = .en, .voice_preset = "Default", .voice = .{}, .envelope = .single, .parameter_snapshot = &targets, .intelligibility = 2, .heard_as = "???", .problem = "l -> ow unclear", .hypothesis = "F2 endpoint", .decision = .pending };
    try store.append(r);
    targets[3].formants_end[1].frequency_hz = 1200;
    try std.testing.expectEqual(@as(f32, 1100), store.records.items[0].parameter_snapshot[3].formants_end[1].frequency_hz);
    var bad = r;
    bad.intelligibility = 0;
    try std.testing.expectError(error.InvalidScore, store.append(bad));
}
