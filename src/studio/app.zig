const std = @import("std");
const v = @import("voice");
const m = @import("mimoc_ui");
const window = @import("window");
const font = @import("font");
const profile = .{ .desktop_input = true, .max_nodes = 256, .max_animations = 8, .diagnostics = true };
const Display = m.runtime.Runtime(profile);
const Ui = m.ui.Ui(u16, profile);
var display = Display{};
var pixels: [1200 * 100]u8 = undefined;
var model = v.studio_model.Model{};
var text: [1024]u8 = undefined;
var length: usize = 0;
var cursor: usize = 0;
var field = m.text_edit.Field{ .placeholder = "カタカナ / English" };
var page: usize = 0;
var status: []const u8 = "Ready";
var valid = true;
var player = v.playback.Player{};
var playing: v.studio_model.Snapshot = .{};
var audio: v.synth.Synth = undefined;
var dragging: ?usize = null;
var drag_previous: v.studio_model.Snapshot = .{};
var labels: [100][100]u8 = undefined;
var label_count: usize = 0;
var error_label: [128]u8 = undefined;
const Tab = enum { phoneme, trajectory, diagnostic, evaluation };
var tab: Tab = .phoneme;
var evaluation_store = v.evaluation.Store.init(std.heap.page_allocator);
var pending_blind: ?v.studio_blind.Choice = null;
var comparison_saved_trials: usize = 0;
var heard: [256]u8 = undefined;
var heard_len: usize = 0;
var heard_cursor: usize = 0;
var problem: [512]u8 = undefined;
var problem_len: usize = 0;
var problem_cursor: usize = 0;
var hypothesis: [256]u8 = undefined;
var hypothesis_len: usize = 0;
var hypothesis_cursor: usize = 0;
var evaluation_score: u8 = 3;
var decision: @FieldType(v.evaluation.Record, "decision") = .pending;
var heard_field = m.text_edit.Field{ .placeholder = "What did you hear?" };
var problem_field = m.text_edit.Field{ .placeholder = "Unclear phoneme / transition" };
var hypothesis_field = m.text_edit.Field{ .placeholder = "One hypothesis / one change" };
const advanced_names = [_][]const u8{ "Duration ms", "Pitch start Hz", "Pitch end Hz", "Amplitude start", "Amplitude end", "Voicing", "F1 start Hz", "F1 end Hz", "F2 start Hz", "F2 end Hz", "F3 start Hz", "F3 end Hz", "Transition in ms", "Transition out ms", "Stress label" };
const advanced_index = [_]usize{ 0, 1, 20, 21, 22, 23, 24, 27, 25, 28, 26, 29, 30, 31, 32 };
const advanced_step = [_]f32{ 10, 5, 5, 0.05, 0.05, 0.05, 25, 25, 25, 25, 25, 25, 5, 5, 1 };
const page_size = 8;
const scope_names = [_][]const u8{ "Whole phrase", "Selected", "Previous + selected", "Selected + next", "Previous + selected + next" };
const voice_names = [_][]const u8{ "Pitch Hz", "Speed", "Breath", "Formant scale", "Amplitude" };
const voice_min = [_]f32{ 40, 0.25, 0, 0.5, 0 };
const voice_max = [_]f32{ 400, 4, 1, 2, 1 };
const voice_step = [_]f32{ 5, 0.05, 0.01, 0.02, 0.05 };
const inspector_names = [_][]const u8{ "Duration ms", "Pitch Hz", "Noise", "F1 Hz", "F2 Hz", "F3 Hz", "F1 bandwidth", "F2 bandwidth", "F3 bandwidth", "Gain", "Attack ms", "Release ms", "F1 gain", "F2 gain", "F3 gain" };
const inspector_step = [_]f32{ 10, 5, 0.05, 25, 25, 25, 10, 10, 10, 0.05, 1, 1, 0.05, 0.05, 0.05 };
fn label(comptime format: []const u8, args: anytype) []const u8 {
    const out = std.fmt.bufPrint(&labels[label_count], format, args) catch "?";
    label_count += 1;
    return out;
}
fn fail(err: anyerror) void {
    status = std.fmt.bufPrint(&error_label, "{s}", .{@errorName(err)}) catch "Error";
}
fn target(logical: u16) u16 {
    return Ui.childId(Ui.rootId(1), logical);
}
fn textAt(ui: *Ui, id: u16, value: []const u8, x: i16, y: i16) void {
    ui.textWith(id, value, .{ .offset = .{ .x = x, .y = y } });
}
fn buttonAt(ui: *Ui, id: u16, value: []const u8, x: i16, y: i16, disabled: bool) void {
    ui.buttonWith(id, value, .{ .offset = .{ .x = x, .y = y }, .disabled = disabled });
}
fn rebuild() void {
    label_count = 0;
    field.text = text[0..length];
    field.cursor = cursor;
    var ui = Ui.begin(&display);
    var root = ui.stack(1, .{});
    textAt(&ui, 20, "MIMOC VOICE STUDIO", 20, 16);
    textAt(&ui, 21, "RULE-BASED / 16kHz / STREAMING", 360, 16);
    buttonAt(&ui, 3, if (!model.english) "[Japanese]" else "Japanese", 20, 45, false);
    buttonAt(&ui, 4, if (model.english) "[English]" else "English", 140, 45, false);
    ui.textField(2, &field, .{ .size = .{ .w = 600, .h = 30 }, .offset = .{ .x = 20, .y = 80 } });
    buttonAt(&ui, 6, "Play B", 20, 125, !valid or model.current.len == 0);
    buttonAt(&ui, 7, "Play A", 110, 125, if (model.has_pinned) model.pinned.len == 0 else !model.has_previous or model.previous.len == 0);
    buttonAt(&ui, 8, "Stop", 200, 125, false);
    buttonAt(&ui, 9, "Export WAV", 280, 125, !valid or model.current.len == 0);
    buttonAt(&ui, 10, "Play scope", 440, 125, model.current.len == 0);
    textAt(&ui, 22, "PHONEME TIMELINE", 20, 162);
    buttonAt(&ui, 110, "<", 540, 158, page == 0);
    buttonAt(&ui, 111, ">", 580, 158, (page + 1) * page_size >= model.current.len);
    const begin = page * page_size;
    for (begin..@min(begin + page_size, model.current.len)) |i| {
        buttonAt(&ui, @intCast(1000 + i - begin), label(ifFormat(), .{ if (model.selected == i) "[" else "", @tagName(model.current.events[i].phoneme), if (model.selected == i) "]" else "" }), @intCast(20 + (i - begin) * 72), 190, false);
    }
    textAt(&ui, 23, label("{d} phonemes / {d:.2}s", .{ model.current.len, @as(f32, @floatFromInt(model.total_frames)) / 16000 }), 20, 223);
    textAt(&ui, 24, "VOICE", 20, 250);
    for (v.voice.presets, 0..) |preset, i| buttonAt(&ui, @intCast(30 + i), preset.name, @intCast(120 + i * 96), 247, false);
    for (0..5) |i| {
        const y: i16 = @intCast(285 + i * 28);
        textAt(&ui, @intCast(40 + i), voice_names[i], 20, y);
        buttonAt(&ui, @intCast(200 + i * 2), "-", 170, y - 2, false);
        buttonAt(&ui, @intCast(201 + i * 2), "+", 580, y - 2, false);
        textAt(&ui, @intCast(50 + i), label("{d:.2}", .{model.voiceValue(i)}), 500, y);
        var scope = ui.stack(@intCast(700 + i), .{ .offset = .{ .x = 220, .y = y + 3 } });
        const normalized = (model.voiceValue(i) - voice_min[i]) / (voice_max[i] - voice_min[i]);
        ui.progressWith(1, @intFromFloat(normalized * 1000), 1000, .{ .width = 260 });
        scope.end();
    }
    textAt(&ui, 25, "PCM WAVEFORM / PHONEME BOUNDARIES", 20, 445);
    textAt(&ui, 26, "PITCH CONTOUR", 20, 585);
    textAt(&ui, 27, "Space: play   Esc: stop   Arrows: select", 20, 646);
    textAt(&ui, 28, status, 20, 677);
    textAt(&ui, 60, "PHONEME INSPECTOR", 660, 16);
    textAt(&ui, 61, if (model.selectedEvent()) |e| label("Selected {d}: {s}", .{ model.selected + 1, @tagName(e.phoneme) }) else "No phoneme", 660, 45);
    if (model.current.len > 0) {
        const i = model.selected;
        const prev = if (i > 0) @tagName(model.current.targets[i - 1].phoneme) else "-";
        const next = if (i + 1 < model.current.len) @tagName(model.current.targets[i + 1].phoneme) else "-";
        textAt(&ui, 68, label("{s} -> {s} -> {s}", .{ prev, @tagName(model.current.targets[i].phoneme), next }), 660, 66);
    }
    for ([_][]const u8{ "Phoneme", "Trajectory", "Diagnostic", "Human log" }, 0..) |name, i| buttonAt(&ui, @intCast(80 + i), label("{s}{s}{s}", .{ if (@backingInt(tab) == i) "[" else "", name, if (@backingInt(tab) == i) "]" else "" }), @intCast(660 + i * 108), 92, false);
    switch (tab) {
        .phoneme, .trajectory => {
            if (model.selectedTarget()) |t| buttonAt(&ui, 62, if (t.voicing > 0.5) "Voiced [ON]" else "Voiced [OFF]", 660, 128, false);
            const names = if (tab == .phoneme) &inspector_names else &advanced_names;
            for (0..15) |i| {
                const index = if (tab == .phoneme) i else advanced_index[i];
                const y: i16 = @intCast(165 + i * 28);
                textAt(&ui, @intCast(400 + i), names[i], 660, y);
                textAt(&ui, @intCast(420 + i), label("{d:.2}", .{model.inspectorValue(index)}), 845, y);
                buttonAt(&ui, @intCast(300 + i * 2), "-", 940, y - 2, model.current.len == 0);
                buttonAt(&ui, @intCast(301 + i * 2), "+", 980, y - 2, model.current.len == 0);
            }
            textAt(&ui, 69, if (tab == .trajectory) "Stress label only; edit timing/prosody separately" else "Body formants / shared bandwidth and gains", 660, 601);
            buttonAt(&ui, 63, "Store phoneme profile", 660, 632, model.current.len == 0);
            buttonAt(&ui, 64, "Undo / swap A-B", 850, 632, !model.has_previous);
        },
        .diagnostic => {
            textAt(&ui, 69, "PLAYBACK SCOPE", 660, 132);
            for (scope_names, 0..) |name, i| buttonAt(&ui, @intCast(120 + i), label("{s}{s}", .{ if (@backingInt(model.scope) == i) "* " else "", name }), 660, @intCast(159 + i * 26), model.current.len == 0);
            buttonAt(&ui, 125, if (model.current.envelope_mode == .single) "Envelope: single" else "Envelope: double (diagnostic)", 660, 300, false);
            buttonAt(&ui, 126, "Pin current as A", 660, 336, model.current.len == 0);
            buttonAt(&ui, 127, "Start blind A/B", 850, 336, model.current.len == 0);
            buttonAt(&ui, 128, "Play X", 660, 377, !model.blind.active);
            buttonAt(&ui, 129, "Play Y", 775, 377, !model.blind.active);
            textAt(&ui, 70, "Which is clearer?", 660, 411);
            const no_vote = !model.blind.active or model.blind.revealed or !model.blind.heard_x or !model.blind.heard_y;
            buttonAt(&ui, 130, "X", 660, 440, no_vote);
            buttonAt(&ui, 131, "Y", 720, 440, no_vote);
            buttonAt(&ui, 132, "Same", 780, 440, no_vote);
            buttonAt(&ui, 133, "Reveal / finish", 890, 440, !model.blind.active);
            textAt(&ui, 71, if (model.blind.revealed) label("New wins: {d}/{d} / old: {d} / same: {d}", .{ model.blind.new_wins, model.blind.len, model.blind.old_wins, model.blind.ties }) else label("Trial {d} / voted {d}; X/Y frozen", .{ model.blind.len + 1, model.blind.len }), 660, 480);
            textAt(&ui, 72, "Audition both to completion before voting", 660, 510);
            if (model.selectedTarget()) |t| buttonAt(&ui, 144, label("Noise shape: {s}", .{@tagName(t.noise_shape)}), 660, 651, false);
            for ([_][]const u8{ "Closure ms", "Burst ms", "Noise center Hz", "Noise bandwidth" }, 0..) |name, i| {
                const y: i16 = @intCast(545 + i * 26);
                textAt(&ui, @intCast(450 + i), name, 660, y);
                textAt(&ui, @intCast(460 + i), label("{d:.1}", .{model.inspectorValue(33 + i)}), 850, y);
                buttonAt(&ui, @intCast(340 + i * 2), "-", 940, y - 2, model.current.len == 0);
                buttonAt(&ui, @intCast(341 + i * 2), "+", 980, y - 2, model.current.len == 0);
            }
        },
        .evaluation => {
            textAt(&ui, 69, "HUMAN EVALUATION (no automatic quality score)", 660, 132);
            textAt(&ui, 70, label("Intelligibility: {d}/5", .{evaluation_score}), 660, 168);
            buttonAt(&ui, 134, "-", 860, 166, false);
            buttonAt(&ui, 135, "+", 910, 166, false);
            textAt(&ui, 71, "Heard as", 660, 208);
            heard_field.text = heard[0..heard_len];
            heard_field.cursor = heard_cursor;
            ui.textField(140, &heard_field, .{ .offset = .{ .x = 660, .y = 233 }, .size = .{ .w = 430, .h = 30 } });
            textAt(&ui, 72, "Problem note", 660, 282);
            problem_field.text = problem[0..problem_len];
            problem_field.cursor = problem_cursor;
            ui.textField(141, &problem_field, .{ .offset = .{ .x = 660, .y = 307 }, .size = .{ .w = 430, .h = 30 } });
            textAt(&ui, 73, "Single hypothesis / changed parameter", 660, 356);
            hypothesis_field.text = hypothesis[0..hypothesis_len];
            hypothesis_field.cursor = hypothesis_cursor;
            ui.textField(142, &hypothesis_field, .{ .offset = .{ .x = 660, .y = 381 }, .size = .{ .w = 430, .h = 30 } });
            buttonAt(&ui, 136, label("Decision: {s}", .{@tagName(decision)}), 660, 435, false);
            buttonAt(&ui, 137, "Record evaluation", 660, 482, model.current.len == 0);
            textAt(&ui, 74, label("Records: {d} / comparisons: {d}", .{ evaluation_store.records.items.len, evaluation_store.comparisons.items.len }), 660, 531);
            textAt(&ui, 75, "Save session persists scores and parameter snapshots", 660, 563);
            textAt(&ui, 76, "Keep/revert is a human decision; no auto adoption", 660, 597);
        },
    }
    buttonAt(&ui, 65, "Save session", 660, 678, false);
    buttonAt(&ui, 66, "Load session", 825, 678, false);
    textAt(&ui, 67, "A: pinned / previous    B: current", 660, 720);
    root.end();
    ui.finishChecked() catch |err| {
        std.debug.print("UI build error: {s} / {?}\n", .{ @errorName(err), ui.diagnostic() });
        fail(err);
        return;
    };
    m.headless.render(&display, &pixels, display.viewport.w, display.viewport.h) catch |err| {
        fail(err);
        return;
    };
    drawGraph();
    window.present(&pixels, .{ .w = display.viewport.w, .h = display.viewport.h });
}
fn ifFormat() []const u8 {
    return "{s}{s}{s}";
}
fn drawGraph() void {
    var surface = m.surface.Mono1.init(&pixels, display.viewport.w, display.viewport.h) catch return;
    var r = m.mono1.Renderer.init(&surface);
    r.rect(.{ .x = 20, .y = 466, .w = 600, .h = 108 }, true);
    r.hline(20, 520, 600, true);
    for (0..600) |i| r.vline(@intCast(20 + i), @intCast(520 - @divTrunc(@as(i32, model.maxima[i]), 600)), @intCast(@max(1, @divTrunc(@as(i32, model.maxima[i]) - model.minima[i], 600))), true);
    var offset: usize = 0;
    for (model.current.targets[0..model.current.len], 0..) |e, i| {
        const synth = v.synth.Synth.init(.{ .voice = model.current.voice }) catch return;
        const frames = synth.frames(e);
        const x: i16 = @intCast(20 + offset * 600 / @max(model.total_frames, 1));
        r.vline(x, 466, 108, true);
        if (i == model.selected) r.rect(.{ .x = x, .y = 468, .w = @intCast(@max(2, frames * 600 / @max(model.total_frames, 1))), .h = 104 }, true);
        const pitch = if (e.pitch_start_hz == 0) model.current.voice.base_pitch_hz * e.pitch_start_scale else @as(f32, @floatFromInt(e.pitch_start_hz));
        const end = if (e.pitch_end_hz == 0) model.current.voice.base_pitch_hz * e.pitch_end_scale else @as(f32, @floatFromInt(e.pitch_end_hz));
        const y: i16 = @intFromFloat(636 - std.math.clamp(pitch / 10, 4, 40));
        const ey: i16 = @intFromFloat(636 - std.math.clamp(end / 10, 4, 40));
        r.line(x, y, @intCast(20 + (offset + frames) * 600 / @max(model.total_frames, 1)), ey, true);
        offset += frames;
    }
}
fn refreshText() void {
    const unsupported = model.parse(text[0..length]) catch |err| {
        valid = false;
        fail(err);
        return;
    };
    valid = true;
    page = 0;
    status = if (unsupported == 0) "Ready" else "Unsupported characters rendered as pauses";
}
fn setText(value: []const u8) void {
    @memcpy(text[0..value.len], value);
    length = value.len;
    cursor = length;
    refreshText();
}
fn finishAudition() void {
    if (player.handle != null and player.done() and audio.finished()) {
        if (pending_blind) |side| model.blind.markHeard(side);
        pending_blind = null;
    }
}
fn playRange(snapshot: *const v.studio_model.Snapshot, scope: v.studio_model.Scope, selected: usize) !void {
    finishAudition();
    player.stop();
    pending_blind = null;
    const range = try v.studio_model.Model.range(snapshot, selected, scope);
    playing = snapshot.*;
    std.mem.copyForwards(v.event.PhonemeEvent, playing.events[0 .. range.end - range.start], snapshot.events[range.start..range.end]);
    std.mem.copyForwards(v.target.AcousticTarget, playing.targets[0 .. range.end - range.start], snapshot.targets[range.start..range.end]);
    playing.len = range.end - range.start;
    audio = try v.studio_model.Model.createSynth(&playing);
    try player.start(&audio);
    status = "Playing scope";
}
fn play(snapshot: *const v.studio_model.Snapshot, selected: bool) !void {
    try playRange(snapshot, if (selected) model.scope else .whole, model.selected);
}
fn playBlind(side: v.studio_blind.Choice) !void {
    if (!model.blind.active) return error.NoBlindTrial;
    const newer = (side == .x) == model.blind.x_is_new;
    try playRange(if (newer) &model.blind_b else &model.blind_a, model.blind_scope, model.blind_selected);
    pending_blind = side;
    status = if (side == .x) "Playing X" else "Playing Y";
}
extern fn arc4random() c_uint;
fn archiveBlind() !void {
    if (model.blind.len == 0 or comparison_saved_trials == model.blind.len) return;
    try evaluation_store.appendComparison(.{ .phrase = model.blind_b.phrase[0..model.blind_b.phrase_len], .language = model.blind_b.language, .hypothesis = hypothesis[0..hypothesis_len], .scope = @tagName(model.blind_scope), .selected = model.blind_selected, .voice_a = model.blind_a.voice, .voice_b = model.blind_b.voice, .envelope_a = model.blind_a.envelope_mode, .envelope_b = model.blind_b.envelope_mode, .targets_a = model.blind_a.targets[0..model.blind_a.len], .targets_b = model.blind_b.targets[0..model.blind_b.len], .trials = model.blind.trials[0..model.blind.len] });
    comparison_saved_trials = model.blind.len;
}
fn recordEvaluation() !void {
    try evaluation_store.append(.{ .session_index = @intCast(evaluation_store.records.items.len + 1), .scope = model.scope, .selected = model.selected, .phrase = model.current.phrase[0..model.current.phrase_len], .language = model.current.language, .voice_preset = @tagName(model.current.preset), .voice = model.current.voice, .envelope = model.current.envelope_mode, .parameter_snapshot = model.current.targets[0..model.current.len], .intelligibility = evaluation_score, .heard_as = heard[0..heard_len], .problem = problem[0..problem_len], .hypothesis = hypothesis[0..hypothesis_len], .decision = decision });
    status = "Evaluation recorded; Save session to persist";
}
extern fn voice_save_path([*]u8, usize) c_int;
fn exportTo(path: [:0]const u8) !void {
    var synth = try v.synth.Synth.init(.{ .voice = model.current.voice, .envelope_mode = model.current.envelope_mode });
    const range = try v.studio_model.Model.range(&model.current, model.selected, model.scope);
    try synth.enqueue(model.current.targets[range.start..range.end]);
    try v.wav.exportFile(path, &synth);
    status = "WAV exported";
}
fn exportWav() !void {
    var path: [4096]u8 = undefined;
    const result = voice_save_path(&path, path.len);
    if (result == 0) return;
    if (result < 0) return error.PathTooLong;
    const n = std.mem.indexOfScalar(u8, &path, 0) orelse return error.InvalidPath;
    try exportTo(path[0..n :0]);
}
fn slider(index: usize, x: i16) void {
    const t = std.math.clamp(@as(f32, @floatFromInt(x - 220)) / 260, 0, 1);
    model.editVoice(index, voice_min[index] + t * (voice_max[index] - voice_min[index])) catch |err| fail(err);
    if (dragging != null) model.previous = drag_previous;
}
fn activate(logical: u16) !void {
    switch (logical) {
        3, 4 => {
            model.english = logical == 4;
            refreshText();
        },
        6 => try play(&model.current, false),
        7 => try play(if (model.has_pinned) &model.pinned else &model.previous, false),
        8 => {
            finishAudition();
            player.stop();
            pending_blind = null;
            status = "Stopped";
        },
        9 => try exportWav(),
        10 => try play(&model.current, true),
        30...34 => {
            model.remember();
            model.current.voice = v.voice.presets[logical - 30].voice;
            model.current.preset = @fromBackingInt(@as(u3, @intCast(logical - 30)));
            try model.analyze();
        },
        62 => {
            model.remember();
            try model.editInspector(23, if (model.selectedTarget().?.voicing > 0.5) 0 else 1);
        },
        63 => {
            model.storeProfile();
            status = "Phoneme profile stored for subsequent text";
        },
        64 => try model.undo(),
        65 => try saveSession(),
        66 => try loadSession(),
        1000...1007 => {
            model.selected = page * page_size + logical - 1000;
        },
        110 => {
            if (page > 0) page -= 1;
        },
        111 => {
            if ((page + 1) * page_size < model.current.len) page += 1;
        },
        112, 113 => {},
        200...209 => {
            const i = (logical - 200) / 2;
            try model.editVoice(i, model.voiceValue(i) + (if (logical % 2 == 0) -voice_step[i] else voice_step[i]));
        },
        80...83 => tab = @fromBackingInt(@as(u2, @intCast(logical - 80))),
        120...124 => model.scope = @fromBackingInt(@as(u3, @intCast(logical - 120))),
        125 => {
            model.remember();
            model.current.envelope_mode = if (model.current.envelope_mode == .single) .legacy_double else .single;
            try model.analyze();
        },
        126 => {
            model.pinA();
            status = "Baseline A pinned; change one parameter for B";
        },
        127 => {
            try archiveBlind();
            try model.beginBlind(arc4random());
            comparison_saved_trials = 0;
            status = "Blind comparison frozen; audition X and Y";
        },
        128 => try playBlind(.x),
        129 => try playBlind(.y),
        130...132 => {
            finishAudition();
            try model.blind.vote(if (logical == 130) .x else if (logical == 131) .y else .same);
            status = "Vote stored; next randomized trial ready";
        },
        133 => {
            model.blind.revealed = true;
            try archiveBlind();
            status = "Blind results revealed";
        },
        144 => {
            model.remember();
            if (model.selectedTarget()) |t| {
                t.noise_shape = switch (t.noise_shape) {
                    .legacy => .broadband,
                    .broadband => .high_pass,
                    .high_pass => .band_pass,
                    .band_pass => .aspiration,
                    .aspiration => .legacy,
                };
                try model.analyze();
            }
        },
        134 => evaluation_score = @max(1, evaluation_score -| 1),
        135 => evaluation_score = @min(5, evaluation_score + 1),
        136 => decision = switch (decision) {
            .pending => .keep,
            .keep => .revert,
            .revert => .pending,
        },
        137 => try recordEvaluation(),
        340...347 => {
            const i = (logical - 340) / 2;
            const step: @TypeOf(@as(f32, 0)) = if (i < 2) 5 else 100;
            try model.editInspector(33 + i, model.inspectorValue(33 + i) + (if (logical % 2 == 0) -step else step));
        },
        300...329 => {
            const row = (logical - 300) / 2;
            const i = if (tab == .trajectory) advanced_index[row] else row;
            const step = if (tab == .trajectory) advanced_step[row] else inspector_step[row];
            try model.editInspector(i, model.inspectorValue(i) + (if (logical % 2 == 0) -step else step));
        },
        else => {},
    }
}
fn receive(event: m.input.InputEvent) void {
    switch (event) {
        .pointer_down => |p| {
            for (0..5) |i| {
                const y: i16 = @intCast(285 + i * 28);
                if (p.x >= 220 and p.x <= 480 and p.y >= y - 4 and p.y < y + 18) {
                    dragging = i;
                    drag_previous = model.current;
                    slider(i, p.x);
                    rebuild();
                    return;
                }
            }
        },
        .pointer_move => |p| {
            if (dragging) |i| {
                slider(i, p.x);
                rebuild();
                return;
            }
        },
        .pointer_up => |p| {
            if (dragging) |i| {
                slider(i, p.x);
                dragging = null;
                rebuild();
                return;
            }
        },
        else => {},
    }
    const was_editing = display.capturedFocus() != null;
    const result = display.dispatch(event);
    if (result.target == target(2) and (was_editing or result.interaction == .focus) and result.interaction != .focus) {
        if (m.text_edit.intent(event)) |edit| {
            if (edit == .submit) {
                if (valid) play(&model.current, false) catch |err| fail(err);
            } else {
                m.text_edit.apply(&text, &length, &cursor, edit) catch |err| {
                    fail(err);
                    rebuild();
                    return;
                };
                if (edit == .insert or edit == .backspace or edit == .delete) refreshText();
            }
        }
    }
    for ([_]u16{ 140, 141, 142 }) |id| {
        if (result.target == target(id) and was_editing and result.interaction != .focus) {
            if (m.text_edit.intent(event)) |edit| {
                if (id == 140) {
                    m.text_edit.apply(&heard, &heard_len, &heard_cursor, edit) catch |err| fail(err);
                } else if (id == 141) {
                    m.text_edit.apply(&problem, &problem_len, &problem_cursor, edit) catch |err| fail(err);
                } else {
                    m.text_edit.apply(&hypothesis, &hypothesis_len, &hypothesis_cursor, edit) catch |err| fail(err);
                }
            }
        }
    }
    if (result.activated) {
        const ids = [_]u16{ 3, 4, 6, 7, 8, 9, 10, 30, 31, 32, 33, 34, 62, 63, 64, 65, 66, 110, 111, 80, 81, 82, 83, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 144 };
        for (ids) |id| if (result.target == target(id)) {
            activate(id) catch |err| fail(err);
        };
        for (0..page_size) |i| {
            const id: u16 = @intCast(1000 + i);
            if (result.target == target(id)) {
                model.selected = page * page_size + i;
            }
        }
        for (200..210) |i| if (result.target == target(@intCast(i))) activate(@intCast(i)) catch |err| fail(err);
        for (340..348) |i| if (result.target == target(@intCast(i))) activate(@intCast(i)) catch |err| fail(err);
        for (300..330) |i| if (result.target == target(@intCast(i))) activate(@intCast(i)) catch |err| fail(err);
    }
    switch (event) {
        .key_down => |key| {
            if (key == .escape) {
                player.stop();
                status = "Stopped";
            }
            if (!was_editing) {
                if (key == .space and valid) play(&model.current, false) catch |err| fail(err);
                if (key == .left and model.selected > 0) model.selected -= 1;
                if (key == .right and model.selected + 1 < model.current.len) model.selected += 1;
                page = model.selected / page_size;
            }
        },
        else => {},
    }
    rebuild();
}
fn platformEvent(event: window.Event) void {
    switch (event) {
        .input => |e| receive(e),
        .tick => |now| {
            display.update(now);
            if (player.handle != null and player.done()) {
                finishAudition();
                player.stop();
                status = "Ready";
                rebuild();
            }
        },
        .resize => |size| {
            display.viewport = .{ .w = std.math.clamp(size.w, 1100, 1200), .h = std.math.clamp(size.h, 760, 800) };
            rebuild();
        },
        .focus_lost => {
            dragging = null;
            display.cancelInput();
            rebuild();
        },
    }
}
extern fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern fn fread([*]u8, usize, usize, *anyopaque) usize;
extern fn fseek(*anyopaque, c_long, c_int) c_int;
extern fn ftell(*anyopaque) c_long;
extern fn fclose(*anyopaque) c_int;
extern fn getenv([*:0]const u8) ?[*:0]const u8;
const Session = struct { version: u8 = 2, english: bool, voice: v.voice.Voice, events: []const v.event.PhonemeEvent, targets: ?[]const v.target.AcousticTarget = null, envelope_mode: v.synth.EnvelopeMode = .single, preset: @FieldType(v.studio_model.Snapshot, "preset") = .Default, profiles: []const ?v.voice.Parameters, text: []const u8, evaluations: []const v.evaluation.Record = &.{}, comparisons: []const v.evaluation.Comparison = &.{} };
fn saveSession() !void {
    try saveSessionTo("voice-session.json");
}
fn saveSessionTo(path: [*:0]const u8) !void {
    if (!valid) return error.InvalidInput;
    try archiveBlind();
    const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, Session{ .english = model.english, .voice = model.current.voice, .events = model.current.events[0..model.current.len], .targets = model.current.targets[0..model.current.len], .envelope_mode = model.current.envelope_mode, .preset = model.current.preset, .profiles = &model.profiles, .text = text[0..length], .evaluations = evaluation_store.records.items, .comparisons = evaluation_store.comparisons.items }, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len > 64 * 1024 * 1024) return error.SessionTooLarge;
    const f = fopen(path, "wb") orelse return error.OpenFailed;
    var closed = false;
    defer if (!closed) {
        _ = fclose(f);
    };
    if (fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.WriteFailed;
    closed = true;
    if (fclose(f) != 0) return error.WriteFailed;
    status = "Saved voice-session.json";
}
fn loadSession() !void {
    try loadSessionFrom("voice-session.json");
}
fn loadSessionFrom(path: [*:0]const u8) !void {
    const f = fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    if (fseek(f, 0, 2) != 0) return error.ReadFailed;
    const size = ftell(f);
    if (size < 0 or fseek(f, 0, 0) != 0) return error.ReadFailed;
    if (size > 64 * 1024 * 1024) return error.SessionTooLarge;
    const bytes = try std.heap.page_allocator.alloc(u8, @intCast(size));
    defer std.heap.page_allocator.free(bytes);
    const n = fread(bytes.ptr, 1, bytes.len, f);
    if (n != bytes.len) return error.ReadFailed;
    const parsed = try std.json.parseFromSlice(Session, std.heap.page_allocator, bytes[0..n], .{});
    defer parsed.deinit();
    const session = parsed.value;
    if ((session.version != 1 and session.version != 2) or session.events.len > v.studio_model.capacity or session.text.len > text.len or session.profiles.len > model.profiles.len or !std.unicode.utf8ValidateSlice(session.text)) return error.InvalidSession;
    var snapshot = v.studio_model.Snapshot{ .voice = session.voice, .len = session.events.len };
    @memcpy(snapshot.events[0..snapshot.len], session.events);
    snapshot.language = if (session.english) .en else .ja;
    @memcpy(snapshot.phrase[0..session.text.len], session.text);
    snapshot.phrase_len = session.text.len;
    snapshot.envelope_mode = session.envelope_mode;
    snapshot.preset = session.preset;
    var validation_targets: [v.studio_model.capacity]v.target.AcousticTarget = undefined;
    _ = try v.planner.plan(snapshot.events[0..snapshot.len], &validation_targets, .{ .language = snapshot.language });
    if (session.targets) |targets| {
        if (targets.len != snapshot.len) return error.InvalidSession;
        @memcpy(snapshot.targets[0..snapshot.len], targets);
    } else _ = try v.planner.plan(snapshot.events[0..snapshot.len], snapshot.targets[0..snapshot.len], .{ .language = snapshot.language });
    _ = try v.studio_model.Model.createSynth(&snapshot);
    for (session.profiles) |parameters| if (parameters) |q| {
        const es = [_]v.event.PhonemeEvent{.{ .phoneme = .ow, .parameters = q }};
        var targets: [1]v.target.AcousticTarget = undefined;
        _ = try v.planner.plan(&es, &targets, .{});
    };
    var loaded = v.evaluation.Store.init(std.heap.page_allocator);
    errdefer loaded.deinit();
    for (session.evaluations) |record| try loaded.append(record);
    for (session.comparisons) |comparison| try loaded.appendComparison(comparison);
    model.remember();
    model.has_pinned = false;
    model.blind = .{};
    comparison_saved_trials = 0;
    model.current = snapshot;
    @memset(&model.profiles, null);
    @memcpy(model.profiles[0..session.profiles.len], session.profiles);
    evaluation_store.deinit();
    evaluation_store = loaded;
    model.english = session.english;
    model.selected = 0;
    page = 0;
    @memcpy(text[0..session.text.len], session.text);
    length = session.text.len;
    cursor = length;
    valid = true;
    try model.analyze();
    status = "Loaded voice-session.json";
}
fn writeSnapshot(path: [*:0]const u8) void {
    const f = fopen(path, "wb") orelse return;
    defer _ = fclose(f);
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P4\n{d} {d}\n", .{ display.viewport.w, display.viewport.h }) catch return;
    _ = fwrite(header.ptr, 1, header.len, f);
    const surface = m.surface.Mono1.init(&pixels, display.viewport.w, display.viewport.h) catch return;
    var row: [150]u8 = undefined;
    const stride = (@as(usize, @intCast(display.viewport.w)) + 7) / 8;
    for (0..@intCast(display.viewport.h)) |y| {
        @memset(&row, 0);
        for (0..@intCast(display.viewport.w)) |x| if (surface.get(@intCast(x), @intCast(y))) {
            row[x / 8] |= @as(u8, 128) >> @as(u3, @intCast(x % 8));
        };
        _ = fwrite(&row, 1, stride, f);
    }
}

pub fn main() void {
    display.viewport = .{ .w = 1100, .h = 760 };
    display.setFontProvider(font.provider);
    defer evaluation_store.deinit();
    model.english = true;
    setText("hello");
    rebuild();
    if (getenv("MIMOC_VOICE_TAB")) |name| tab = std.meta.stringToEnum(Tab, std.mem.span(name)) orelse .phoneme;
    rebuild();
    if (getenv("MIMOC_VOICE_SNAPSHOT")) |path| {
        writeSnapshot(path);
        return;
    }
    window.run(&pixels, .{ .w = display.viewport.w, .h = display.viewport.h }, 1, "Mimoc Voice Studio", platformEvent);
    player.stop();
}
test "native Studio text input selection inspector and voice buttons" {
    display = .{};
    display.viewport = .{ .w = 1100, .h = 760 };
    display.setFontProvider(font.provider);
    model = .{};
    setText("コンニチワ");
    rebuild();
    try std.testing.expect(display.captureFocus(target(2)));
    length = 0;
    cursor = 0;
    rebuild();
    receive(.{ .text = "オハヨウ" });
    try std.testing.expectEqualStrings("オハヨウ", text[0..length]);
    try std.testing.expectEqual(@as(usize, 6), model.current.len);
    try activate(201);
    try std.testing.expectEqual(@as(f32, 130), model.current.voice.base_pitch_hz);
    try activate(303);
    try std.testing.expect(model.current.events[0].pitch_hz > 0);
    try exportTo("/tmp/mimoc-studio-test.wav");
    try std.testing.expectEqualStrings("WAV exported", status);
}

extern fn usleep(c_uint) c_int;
fn click(logical: u16) !void {
    const rect = display.presentationRect(target(logical)) orelse return error.MissingWidget;
    receive(.{ .pointer_down = .{ .x = rect.x + 2, .y = rect.y + 2 } });
    receive(.{ .pointer_up = .{ .x = rect.x + 2, .y = rect.y + 2 } });
}
test "six required phrases via Studio input play stop and WAV export" {
    display = .{};
    display.viewport = .{ .w = 1100, .h = 760 };
    display.setFontProvider(font.provider);
    model = .{};
    setText("コンニチワ");
    rebuild();
    const cases = [_]struct { text: []const u8, en: bool, path: [:0]const u8 }{ .{ .text = "コンニチワ", .en = false, .path = "/tmp/studio-konnichiwa.wav" }, .{ .text = "オハヨウ", .en = false, .path = "/tmp/studio-ohayou.wav" }, .{ .text = "モーバス", .en = false, .path = "/tmp/studio-mobus.wav" }, .{ .text = "hello world", .en = true, .path = "/tmp/studio-hello-world.wav" }, .{ .text = "system ready", .en = true, .path = "/tmp/studio-system-ready.wav" }, .{ .text = "battery low", .en = true, .path = "/tmp/studio-battery-low.wav" } };
    for (cases) |case| {
        try click(if (case.en) 4 else 3);
        length = 0;
        cursor = 0;
        rebuild();
        try std.testing.expect(display.captureFocus(target(2)));
        receive(.{ .text = case.text });
        try std.testing.expect(valid);
        try std.testing.expectEqualStrings(case.text, text[0..length]);
        try std.testing.expect(model.current.len > 0);
        try click(6);
        try std.testing.expect(player.handle != null);
        var ticks: usize = 0;
        while (!player.done() and ticks < 500) : (ticks += 1) {
            _ = usleep(10000);
        }
        try std.testing.expect(player.done());
        try std.testing.expect(audio.finished());
        try click(8);
        try std.testing.expect(player.handle == null);
        try exportTo(case.path);
        try std.testing.expectEqualStrings("WAV exported", status);
    }
    try click(1001);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    try click(307);
    try std.testing.expect(model.current.events[1].parameters != null);
    // Exercise paged timelines and the A/B state after a slider gesture.
    setText("アイウエオアイウエオアイウエオアイウエオ");
    rebuild();
    try click(111);
    try std.testing.expectEqual(@as(usize, 1), page);
    try click(1001);
    try std.testing.expectEqual(@as(usize, 9), model.selected);
    const before = model.current.voice.base_pitch_hz;
    receive(.{ .pointer_down = .{ .x = 350, .y = 290 } });
    receive(.{ .pointer_move = .{ .x = 450, .y = 290 } });
    receive(.{ .pointer_up = .{ .x = 450, .y = 290 } });
    try std.testing.expectEqual(before, model.previous.voice.base_pitch_hz);
    try std.testing.expect(model.current.voice.base_pitch_hz > before);
}

test "Studio session round trip and invalid session preserve state" {
    model = .{};
    model.english = false;
    setText("モーバス");
    model.selected = 1;
    try model.editInspector(3, 950);
    model.storeProfile();
    try model.editVoice(0, 190);
    try saveSessionTo("/tmp/mimoc-voice-session-test.json");
    model.current.voice.base_pitch_hz = 80;
    try loadSessionFrom("/tmp/mimoc-voice-session-test.json");
    try std.testing.expectEqual(@as(f32, 190), model.current.voice.base_pitch_hz);
    try std.testing.expectEqualStrings("モーバス", text[0..length]);
    try std.testing.expectEqual(@as(f32, 950), model.profiles[@backingInt(v.phoneme.PhonemeId.o)].?.formants[0].frequency_hz);
    // Phase 5 had 41 profile slots and no targets or evaluation records.
    const legacy = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .version = @as(u8, 1),
        .english = false,
        .voice = model.current.voice,
        .events = model.current.events[0..model.current.len],
        .profiles = model.profiles[0..41],
        .text = text[0..length],
    }, .{});
    defer std.testing.allocator.free(legacy);
    const old = fopen("/tmp/mimoc-v1-session.json", "wb") orelse return error.OpenFailed;
    try std.testing.expectEqual(legacy.len, fwrite(legacy.ptr, 1, legacy.len, old));
    _ = fclose(old);
    try loadSessionFrom("/tmp/mimoc-v1-session.json");
    try std.testing.expectEqual(@as(f32, 190), model.current.voice.base_pitch_hz);
    try std.testing.expectEqualStrings("モーバス", text[0..length]);
    try std.testing.expectEqual(model.current.events[1].duration_ms, model.current.targets[1].duration_ms);
    try std.testing.expectEqual(@as(f32, 950), model.current.targets[1].formants_body[0].frequency_hz);
    const f = fopen("/tmp/mimoc-invalid-session.json", "wb") orelse return error.OpenFailed;
    const bad = "{}";
    _ = fwrite(bad.ptr, 1, bad.len, f);
    _ = fclose(f);
    try std.testing.expectError(error.MissingField, loadSessionFrom("/tmp/mimoc-invalid-session.json"));
    try std.testing.expectEqual(@as(f32, 190), model.current.voice.base_pitch_hz);
}

fn awaitAudition() !void {
    var ticks: usize = 0;
    while (!player.done() and ticks < 500) : (ticks += 1) {
        _ = usleep(10000);
    }
    try std.testing.expect(player.done());
    try std.testing.expect(audio.finished());
    finishAudition();
}
test "diagnostic scopes trajectory blind trials and human log session round trip" {
    // Scores below are synthetic test fixtures, never recorded as human listening results.
    evaluation_store.deinit();
    evaluation_store = v.evaluation.Store.init(std.heap.page_allocator);
    defer {
        evaluation_store.deinit();
        evaluation_store = v.evaluation.Store.init(std.heap.page_allocator);
    }
    display = .{};
    display.viewport = .{ .w = 1100, .h = 760 };
    display.setFontProvider(font.provider);
    model = .{};
    model.english = true;
    tab = .diagnostic;
    setText("hello");
    rebuild();
    model.selected = 2;
    for (120..125) |scope_id| {
        try click(@intCast(scope_id));
        const range = try v.studio_model.Model.range(&model.current, 2, model.scope);
        try click(10);
        try awaitAudition();
        try std.testing.expectEqual(range.end - range.start, playing.len);
        try std.testing.expectEqual(model.current.targets[range.start].formants_start[0].frequency_hz, playing.targets[0].formants_start[0].frequency_hz);
        try click(8);
    }
    try click(123);
    try click(126);
    try click(81);
    try click(319);
    try std.testing.expect(model.current.targets[2].formants_end[1].frequency_hz != model.pinned.targets[2].formants_end[1].frequency_hz);
    try click(82);
    try click(127);
    for (0..5) |i| {
        try click(128);
        try awaitAudition();
        rebuild();
        try click(129);
        try awaitAudition();
        rebuild();
        try click(if (i == 4) 132 else if (model.blind.x_is_new) 130 else 131);
    }
    try std.testing.expectEqual(@as(usize, 4), model.blind.new_wins);
    try std.testing.expectEqual(@as(usize, 1), model.blind.ties);
    try click(133);
    try std.testing.expectEqual(@as(usize, 1), evaluation_store.comparisons.items.len);
    try click(83);
    try std.testing.expect(display.captureFocus(target(140)));
    receive(.{ .text = "synthetic fixture" });
    try std.testing.expectEqualStrings("synthetic fixture", heard[0..heard_len]);
    try std.testing.expect(display.captureFocus(target(141)));
    receive(.{ .text = "l -> ow unclear (fixture)" });
    try std.testing.expect(display.captureFocus(target(142)));
    receive(.{ .text = "F2 end +25 Hz (fixture)" });
    try click(137);
    try std.testing.expectEqual(@as(usize, 1), evaluation_store.records.items.len);
    const preserved = model.current.targets[2].formants_end[1].frequency_hz;
    try saveSessionTo("/tmp/mimoc-phase6-session-test.json");
    try model.editInspector(28, 1500);
    try loadSessionFrom("/tmp/mimoc-phase6-session-test.json");
    try std.testing.expectEqual(preserved, model.current.targets[2].formants_end[1].frequency_hz);
    try std.testing.expectEqual(@as(usize, 1), evaluation_store.records.items.len);
    try std.testing.expectEqual(@as(usize, 5), evaluation_store.comparisons.items[0].trials.len);
    try std.testing.expectEqualStrings("synthetic fixture", evaluation_store.records.items[0].heard_as);
    try std.testing.expectEqualStrings("hello", evaluation_store.records.items[0].phrase);
    tab = .phoneme;
    heard_len = 0;
    problem_len = 0;
    hypothesis_len = 0;
    player.stop();
    model.scope = .whole;
}
