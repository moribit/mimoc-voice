const std = @import("std");
const v = @import("../root.zig");
pub const capacity = 512;
pub const columns = 600;
pub const Snapshot = struct { voice: v.voice.Voice = .{}, events: [capacity]v.event.PhonemeEvent = undefined, len: usize = 0 };
pub const Model = struct {
    current: Snapshot = .{},
    previous: Snapshot = .{},
    has_previous: bool = false,
    selected: usize = 0,
    english: bool = false,
    profiles: [std.meta.tags(v.phoneme.PhonemeId).len]?v.voice.Parameters = @splat(null),
    minima: [columns]i16 = @splat(0),
    maxima: [columns]i16 = @splat(0),
    total_frames: usize = 0,
    pub fn remember(self: *Model) void {
        self.previous = self.current;
        self.has_previous = true;
    }
    pub fn parse(self: *Model, text: []const u8) !usize {
        var out: [capacity]v.event.PhonemeEvent = undefined;
        const seq = if (self.english) try v.english.parse(text, &out) else try v.japanese.parse(text, &out);
        self.remember();
        @memcpy(self.current.events[0..seq.len], seq.events());
        self.current.len = seq.len;
        self.selected = @min(self.selected, seq.len -| 1);
        for (self.current.events[0..seq.len]) |*e| e.parameters = self.profiles[@backingInt(e.phoneme)];
        try self.analyze();
        return seq.unsupported;
    }
    pub fn selectedEvent(self: *Model) ?*v.event.PhonemeEvent {
        return if (self.current.len == 0) null else &self.current.events[self.selected];
    }
    pub fn selectedParameters(self: *Model) ?*v.voice.Parameters {
        const e = self.selectedEvent() orelse return null;
        if (e.parameters == null) e.parameters = v.voice.parameters(e.phoneme);
        return &e.parameters.?;
    }
    pub fn storeProfile(self: *Model) void {
        const e = self.selectedEvent() orelse return;
        self.profiles[@backingInt(e.phoneme)] = e.parameters orelse v.voice.parameters(e.phoneme);
    }
    pub fn undo(self: *Model) !void {
        if (!self.has_previous) return;
        const old = self.current;
        self.current = self.previous;
        self.previous = old;
        self.selected = @min(self.selected, self.current.len -| 1);
        try self.analyze();
    }
    pub fn createSynth(snapshot: *const Snapshot) !v.synth.Synth {
        var s = try v.synth.Synth.init(.{ .voice = snapshot.voice });
        try s.enqueue(snapshot.events[0..snapshot.len]);
        return s;
    }
    pub fn analyze(self: *Model) !void {
        var s = try createSynth(&self.current);
        self.total_frames = 0;
        for (self.current.events[0..self.current.len]) |e| self.total_frames += s.frames(e);
        @memset(&self.minima, 0);
        @memset(&self.maxima, 0);
        var buf: [512]i16 = undefined;
        var offset: usize = 0;
        while (!s.finished()) {
            const n = s.render(&buf);
            for (buf[0..n], 0..) |x, i| {
                const bin = @min(columns - 1, (offset + i) * columns / @max(self.total_frames, 1));
                self.minima[bin] = @min(self.minima[bin], x);
                self.maxima[bin] = @max(self.maxima[bin], x);
            }
            offset += n;
        }
    }
    pub fn editVoice(self: *Model, index: usize, value: f32) !void {
        self.remember();
        switch (index) {
            0 => self.current.voice.base_pitch_hz = std.math.clamp(value, 40, 400),
            1 => self.current.voice.speed = std.math.clamp(value, 0.25, 4),
            2 => self.current.voice.breath = std.math.clamp(value, 0, 1),
            3 => self.current.voice.formant_scale = std.math.clamp(value, 0.5, 2),
            4 => self.current.voice.amplitude = std.math.clamp(value, 0, 1),
            else => return error.InvalidParameter,
        }
        try self.analyze();
    }
    pub fn voiceValue(self: *const Model, index: usize) f32 {
        return switch (index) {
            0 => self.current.voice.base_pitch_hz,
            1 => self.current.voice.speed,
            2 => self.current.voice.breath,
            3 => self.current.voice.formant_scale,
            else => self.current.voice.amplitude,
        };
    }
    pub fn inspectorValue(self: *Model, index: usize) f32 {
        const e = self.selectedEvent() orelse return 0;
        const q = self.selectedParameters().?;
        return switch (index) {
            0 => @floatFromInt(e.duration_ms),
            1 => if (e.pitch_hz == 0) self.current.voice.base_pitch_hz * e.pitch_scale else @floatFromInt(e.pitch_hz),
            2 => q.noise,
            3, 4, 5 => q.formants[index - 3].frequency_hz,
            6, 7, 8 => q.formants[index - 6].bandwidth_hz,
            9 => q.gain,
            10 => q.attack_ms,
            11 => q.release_ms,
            12, 13, 14 => q.formants[index - 12].gain,
            else => 0,
        };
    }
    pub fn editInspector(self: *Model, index: usize, value: f32) !void {
        if (self.current.len == 0) return;
        self.remember();
        const e = self.selectedEvent().?;
        const q = self.selectedParameters().?;
        switch (index) {
            0 => e.duration_ms = @intFromFloat(std.math.clamp(value, 10, 5000)),
            1 => {
                e.pitch_hz = @intFromFloat(std.math.clamp(value, 40, 600));
                e.pitch_end_hz = e.pitch_hz;
            },
            2 => q.noise = std.math.clamp(value, 0, 1),
            3, 4, 5 => q.formants[index - 3].frequency_hz = std.math.clamp(value, 40, 7200),
            6, 7, 8 => q.formants[index - 6].bandwidth_hz = std.math.clamp(value, 20, 2000),
            9 => q.gain = std.math.clamp(value, 0, 4),
            10 => q.attack_ms = std.math.clamp(value, 0, 1000),
            11 => q.release_ms = std.math.clamp(value, 0, 1000),
            12, 13, 14 => q.formants[index - 12].gain = std.math.clamp(value, 0, 4),
            else => return error.InvalidParameter,
        }
        try self.analyze();
    }
};
test "Studio edits comparison profile reuse and graph use common core" {
    var model = Model{};
    _ = try model.parse("コンニチワ");
    try std.testing.expectEqual(@as(usize, 11200), model.total_frames);
    try model.editVoice(0, 180);
    try std.testing.expectEqual(@as(f32, 125), model.previous.voice.base_pitch_hz);
    try model.undo();
    try std.testing.expectEqual(@as(f32, 125), model.current.voice.base_pitch_hz);
    model.selected = 1;
    try model.editInspector(3, 950);
    model.storeProfile();
    _ = try model.parse("オ");
    try std.testing.expectEqual(@as(f32, 950), model.current.events[0].parameters.?.formants[0].frequency_hz);
    try std.testing.expect(model.maxima[100] > 0);
}
