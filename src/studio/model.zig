const std = @import("std");
const v = @import("../root.zig");
pub const capacity = 512;
pub const columns = 600;
pub const Scope = enum { whole, selected, previous_selected, selected_next, context };
pub const Range = struct { start: usize, end: usize };
pub const Snapshot = struct { phrase: [1024]u8 = undefined, phrase_len: usize = 0, voice: v.voice.Voice = .{}, events: [capacity]v.event.PhonemeEvent = undefined, targets: [capacity]v.target.AcousticTarget = undefined, language: v.planner.Language = .ja, envelope_mode: v.synth.EnvelopeMode = .single, preset: enum { Default, Robot, Deep, Bright, Retro, Custom } = .Default, len: usize = 0 };
pub const Model = struct {
    current: Snapshot = .{},
    previous: Snapshot = .{},
    has_previous: bool = false,
    pinned: Snapshot = .{},
    has_pinned: bool = false,
    blind_a: Snapshot = .{},
    blind_b: Snapshot = .{},
    blind: v.studio_blind.Blind = .{},
    scope: Scope = .whole,
    blind_scope: Scope = .whole,
    blind_selected: usize = 0,
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
        if (text.len > self.current.phrase.len) return error.TextTooLong;
        @memcpy(self.current.phrase[0..text.len], text);
        self.current.phrase_len = text.len;
        self.current.len = seq.len;
        self.current.language = if (self.english) .en else .ja;
        self.selected = @min(self.selected, seq.len -| 1);
        for (self.current.events[0..seq.len]) |*e| e.parameters = self.profiles[@backingInt(e.phoneme)];
        _ = try v.planner.plan(self.current.events[0..seq.len], self.current.targets[0..seq.len], .{ .language = self.current.language });
        try self.analyze();
        return seq.unsupported;
    }
    pub fn pinA(self: *Model) void {
        self.pinned = self.current;
        self.has_pinned = true;
    }
    pub fn beginBlind(self: *Model, seed: u32) !void {
        const a = if (self.has_pinned) &self.pinned else if (self.has_previous) &self.previous else return error.NoBaseline;
        if (!std.mem.eql(u8, a.phrase[0..a.phrase_len], self.current.phrase[0..self.current.phrase_len]) or a.language != self.current.language) return error.ComparisonPhraseMismatch;
        if (a.len == 0 or self.current.len == 0) return error.EmptySequence;
        self.blind_a = a.*;
        self.blind_b = self.current;
        self.blind_scope = self.scope;
        self.blind_selected = self.selected;
        _ = try range(a, self.blind_selected, self.scope);
        _ = try range(&self.current, self.blind_selected, self.scope);
        self.blind.start(seed);
    }
    pub fn range(snapshot: *const Snapshot, selected: usize, scope: Scope) !Range {
        if (scope == .whole) return .{ .start = 0, .end = snapshot.len };
        if (selected >= snapshot.len) return error.InvalidSelection;
        return switch (scope) {
            .whole => unreachable,
            .selected => .{ .start = selected, .end = selected + 1 },
            .previous_selected => .{ .start = selected -| 1, .end = selected + 1 },
            .selected_next => .{ .start = selected, .end = @min(snapshot.len, selected + 2) },
            .context => .{ .start = selected -| 1, .end = @min(snapshot.len, selected + 2) },
        };
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
        var s = try v.synth.Synth.init(.{ .voice = snapshot.voice, .envelope_mode = snapshot.envelope_mode });
        try s.enqueue(snapshot.targets[0..snapshot.len]);
        return s;
    }
    pub fn analyze(self: *Model) !void {
        var s = try createSynth(&self.current);
        self.total_frames = 0;
        for (self.current.targets[0..self.current.len]) |e| self.total_frames += s.frames(e);
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
        if (!std.math.isFinite(value)) return error.InvalidParameter;
        self.remember();
        self.current.preset = .Custom;
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
    pub fn selectedTarget(self: *Model) ?*v.target.AcousticTarget {
        return if (self.current.len == 0) null else &self.current.targets[self.selected];
    }
    pub fn inspectorValue(self: *Model, index: usize) f32 {
        const t = self.selectedTarget() orelse return 0;
        return switch (index) {
            0 => @floatFromInt(t.duration_ms),
            1 => if (t.pitch_start_hz == 0) self.current.voice.base_pitch_hz * t.pitch_start_scale else @floatFromInt(t.pitch_start_hz),
            2 => t.noise,
            3, 4, 5 => t.formants_body[index - 3].frequency_hz,
            6, 7, 8 => t.formants_body[index - 6].bandwidth_hz,
            9 => t.gain,
            10 => t.attack_ms,
            11 => t.release_ms,
            12, 13, 14 => t.formants_body[index - 12].gain,
            20 => if (t.pitch_end_hz == 0) self.current.voice.base_pitch_hz * t.pitch_end_scale else @floatFromInt(t.pitch_end_hz),
            21 => t.amplitude_start,
            22 => t.amplitude_end,
            23 => t.voicing,
            24, 25, 26 => t.formants_start[index - 24].frequency_hz,
            27, 28, 29 => t.formants_end[index - 27].frequency_hz,
            30 => t.transition_in_ms,
            31 => t.transition_out_ms,
            32 => @floatFromInt(t.stress),
            33 => t.closure_ms,
            34 => t.burst_ms,
            35 => t.noise_frequency_hz,
            36 => t.noise_bandwidth_hz,
            else => 0,
        };
    }
    pub fn editInspector(self: *Model, index: usize, value: f32) !void {
        if (self.current.len == 0) return;
        if (!std.math.isFinite(value)) return error.InvalidParameter;
        self.remember();
        const e = self.selectedEvent().?;
        const q = self.selectedParameters().?;
        const t = self.selectedTarget().?;
        switch (index) {
            0 => {
                e.duration_ms = @intFromFloat(std.math.clamp(value, 10, 5000));
                e.timing = .explicit;
                t.duration_ms = e.duration_ms;
                t.closure_ms = @min(t.closure_ms, @as(f32, @floatFromInt(t.duration_ms)));
                t.burst_ms = @min(t.burst_ms, @as(f32, @floatFromInt(t.duration_ms)) - t.closure_ms);
            },
            1 => {
                e.pitch_hz = @intFromFloat(std.math.clamp(value, 40, 600));
                t.pitch_start_hz = e.pitch_hz;
            },
            2 => {
                q.noise = std.math.clamp(value, 0, 1);
                t.noise = q.noise;
            },
            3, 4, 5 => {
                const j = index - 3;
                q.formants[j].frequency_hz = std.math.clamp(value, 40, 7200);
                t.formants_body[j].frequency_hz = q.formants[j].frequency_hz;
                t.formants_start[j].frequency_hz = q.formants[j].frequency_hz;
                if (!t.glide) t.formants_end[j].frequency_hz = q.formants[j].frequency_hz;
            },
            6, 7, 8 => {
                const j = index - 6;
                q.formants[j].bandwidth_hz = std.math.clamp(value, 20, 2000);
                t.formants_body[j].bandwidth_hz = q.formants[j].bandwidth_hz;
                t.formants_start[j].bandwidth_hz = q.formants[j].bandwidth_hz;
                t.formants_end[j].bandwidth_hz = q.formants[j].bandwidth_hz;
            },
            9 => {
                q.gain = std.math.clamp(value, 0, 4);
                t.gain = q.gain;
            },
            10 => {
                q.attack_ms = std.math.clamp(value, 0, 1000);
                t.attack_ms = q.attack_ms;
            },
            11 => {
                q.release_ms = std.math.clamp(value, 0, 1000);
                t.release_ms = q.release_ms;
            },
            12, 13, 14 => {
                const j = index - 12;
                q.formants[j].gain = std.math.clamp(value, 0, 4);
                t.formants_body[j].gain = q.formants[j].gain;
                t.formants_start[j].gain = q.formants[j].gain;
                t.formants_end[j].gain = q.formants[j].gain;
            },
            20 => t.pitch_end_hz = @intFromFloat(std.math.clamp(value, 40, 600)),
            21 => t.amplitude_start = std.math.clamp(value, 0, 4),
            22 => t.amplitude_end = std.math.clamp(value, 0, 4),
            23 => {
                t.voicing = std.math.clamp(value, 0, 1);
                q.voiced = t.voicing > 0.5;
            },
            24, 25, 26 => t.formants_start[index - 24].frequency_hz = std.math.clamp(value, 40, 7200),
            27, 28, 29 => t.formants_end[index - 27].frequency_hz = std.math.clamp(value, 40, 7200),
            30 => t.transition_in_ms = std.math.clamp(value, 0, 5000),
            31 => t.transition_out_ms = std.math.clamp(value, 0, 5000),
            32 => {
                t.stress = @intFromFloat(std.math.clamp(value, 0, 2));
                e.stress = t.stress;
            },
            33 => t.closure_ms = std.math.clamp(value, 0, @as(f32, @floatFromInt(t.duration_ms)) - t.burst_ms),
            34 => t.burst_ms = std.math.clamp(value, 0, @as(f32, @floatFromInt(t.duration_ms)) - t.closure_ms),
            35 => t.noise_frequency_hz = std.math.clamp(value, 40, 7200),
            36 => t.noise_bandwidth_hz = std.math.clamp(value, 20, 7000),
            else => return error.InvalidParameter,
        }
        try v.target.validate(t.*);
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

test "diagnostic ranges preserve parent context and blind freezes snapshots" {
    var model = Model{};
    model.english = true;
    _ = try model.parse("hello");
    model.selected = 2;
    const pair = try Model.range(&model.current, 2, .selected_next);
    try std.testing.expectEqual(@as(usize, 2), pair.start);
    try std.testing.expectEqual(@as(usize, 4), pair.end);
    const ctx = try Model.range(&model.current, 0, .context);
    try std.testing.expectEqual(@as(usize, 0), ctx.start);
    try std.testing.expectEqual(@as(usize, 2), ctx.end);
    model.pinA();
    try model.editInspector(28, 1250);
    try model.beginBlind(42);
    const before = model.blind_b.targets[2].formants_end[1].frequency_hz;
    try model.editInspector(28, 1300);
    try std.testing.expectEqual(before, model.blind_b.targets[2].formants_end[1].frequency_hz);
}
