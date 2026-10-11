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
    buttonAt(&ui, 7, "Play A", 110, 125, !model.has_previous or model.previous.len == 0);
    buttonAt(&ui, 8, "Stop", 200, 125, false);
    buttonAt(&ui, 9, "Export WAV", 280, 125, !valid or model.current.len == 0);
    buttonAt(&ui, 10, "Play selected", 440, 125, model.current.len == 0);
    textAt(&ui, 22, "PHONEME TIMELINE", 20, 162);
    buttonAt(&ui, 110, "<", 540, 158, page == 0);
    buttonAt(&ui, 111, ">", 580, 158, (page + 1) * 12 >= model.current.len);
    const begin = page * 12;
    for (begin..@min(begin + 12, model.current.len)) |i| {
        buttonAt(&ui, @intCast(1000 + i - begin), label(ifFormat(), .{ if (model.selected == i) "[" else "", @tagName(model.current.events[i].phoneme), if (model.selected == i) "]" else "" }), @intCast(20 + (i - begin) * 50), 190, false);
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
    if (model.selectedParameters()) |q| buttonAt(&ui, 62, if (q.voiced) "Voiced [ON]" else "Voiced [OFF]", 660, 78, false);
    for (0..inspector_names.len) |i| {
        const y: i16 = @intCast(115 + i * 28);
        textAt(&ui, @intCast(400 + i), inspector_names[i], 660, y);
        textAt(&ui, @intCast(420 + i), label("{d:.2}", .{model.inspectorValue(i)}), 815, y);
        buttonAt(&ui, @intCast(300 + i * 2), "-", 900, y - 2, model.current.len == 0);
        buttonAt(&ui, @intCast(301 + i * 2), "+", 940, y - 2, model.current.len == 0);
    }
    buttonAt(&ui, 63, "Store phoneme profile", 660, 550, model.current.len == 0);
    buttonAt(&ui, 64, "Undo / swap A-B", 660, 586, !model.has_previous);
    buttonAt(&ui, 65, "Save session", 660, 622, false);
    buttonAt(&ui, 66, "Load session", 825, 622, false);
    textAt(&ui, 67, "A: previous / B: current", 660, 677);
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
    for (model.current.events[0..model.current.len], 0..) |e, i| {
        const synth = v.synth.Synth.init(.{ .voice = model.current.voice }) catch return;
        const frames = synth.frames(e);
        const x: i16 = @intCast(20 + offset * 600 / @max(model.total_frames, 1));
        r.vline(x, 466, 108, true);
        if (i == model.selected) r.rect(.{ .x = x, .y = 468, .w = @intCast(@max(2, frames * 600 / @max(model.total_frames, 1))), .h = 104 }, true);
        const pitch = if (e.pitch_hz == 0) model.current.voice.base_pitch_hz * e.pitch_scale else @as(f32, @floatFromInt(e.pitch_hz));
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
fn play(snapshot: *const v.studio_model.Snapshot, selected: bool) !void {
    player.stop();
    playing = snapshot.*;
    if (selected) {
        playing.events[0] = snapshot.events[model.selected];
        playing.len = 1;
    }
    audio = try v.studio_model.Model.createSynth(&playing);
    try player.start(&audio);
    status = if (selected) "Playing selected phoneme" else "Playing";
}
extern fn voice_save_path([*]u8, usize) c_int;
fn exportTo(path: [:0]const u8) !void {
    var synth = try v.studio_model.Model.createSynth(&model.current);
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
        7 => try play(&model.previous, false),
        8 => {
            player.stop();
            status = "Stopped";
        },
        9 => try exportWav(),
        10 => try play(&model.current, true),
        30...34 => {
            model.remember();
            model.current.voice = v.voice.presets[logical - 30].voice;
            try model.analyze();
        },
        62 => {
            model.remember();
            if (model.selectedParameters()) |q| q.voiced = !q.voiced;
            try model.analyze();
        },
        63 => {
            model.storeProfile();
            status = "Phoneme profile stored for subsequent text";
        },
        64 => try model.undo(),
        65 => try saveSession(),
        66 => try loadSession(),
        1000...1011 => {
            model.selected = page * 12 + logical - 1000;
        },
        110 => {
            if (page > 0) page -= 1;
        },
        111 => {
            if ((page + 1) * 12 < model.current.len) page += 1;
        },
        112, 113 => {},
        200...209 => {
            const i = (logical - 200) / 2;
            try model.editVoice(i, model.voiceValue(i) + (if (logical % 2 == 0) -voice_step[i] else voice_step[i]));
        },
        300...329 => {
            const i = (logical - 300) / 2;
            try model.editInspector(i, model.inspectorValue(i) + (if (logical % 2 == 0) -inspector_step[i] else inspector_step[i]));
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
    if (result.activated) {
        const ids = [_]u16{ 3, 4, 6, 7, 8, 9, 10, 30, 31, 32, 33, 34, 62, 63, 64, 65, 66, 110, 111 };
        for (ids) |id| if (result.target == target(id)) {
            activate(id) catch |err| fail(err);
        };
        for (0..12) |i| {
            const id: u16 = @intCast(1000 + i);
            if (result.target == target(id)) {
                model.selected = page * 12 + i;
            }
        }
        for (200..210) |i| if (result.target == target(@intCast(i))) activate(@intCast(i)) catch |err| fail(err);
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
                page = model.selected / 12;
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
                player.stop();
                status = "Ready";
                rebuild();
            }
        },
        .resize => |size| {
            display.viewport = .{ .w = std.math.clamp(size.w, 1000, 1200), .h = std.math.clamp(size.h, 720, 800) };
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
extern fn fclose(*anyopaque) c_int;
extern fn getenv([*:0]const u8) ?[*:0]const u8;
const Session = struct { version: u8 = 1, english: bool, voice: v.voice.Voice, events: []const v.event.PhonemeEvent, profiles: @TypeOf(model.profiles), text: []const u8 };
fn saveSession() !void {
    try saveSessionTo("voice-session.json");
}
fn saveSessionTo(path: [*:0]const u8) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, Session{ .english = model.english, .voice = model.current.voice, .events = model.current.events[0..model.current.len], .profiles = model.profiles, .text = text[0..length] }, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(bytes);
    const f = fopen(path, "wb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    if (fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.WriteFailed;
    status = "Saved voice-session.json";
}
fn loadSession() !void {
    try loadSessionFrom("voice-session.json");
}
fn loadSessionFrom(path: [*:0]const u8) !void {
    var bytes: [1024 * 1024]u8 = undefined;
    const f = fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    const n = fread(&bytes, 1, bytes.len, f);
    if (n == bytes.len) return error.SessionTooLarge;
    const parsed = try std.json.parseFromSlice(Session, std.heap.page_allocator, bytes[0..n], .{});
    defer parsed.deinit();
    const session = parsed.value;
    if (session.version != 1 or session.events.len > v.studio_model.capacity or session.text.len > text.len or !std.unicode.utf8ValidateSlice(session.text)) return error.InvalidSession;
    var snapshot = v.studio_model.Snapshot{ .voice = session.voice, .len = session.events.len };
    @memcpy(snapshot.events[0..snapshot.len], session.events);
    _ = try v.studio_model.Model.createSynth(&snapshot);
    for (session.profiles) |parameters| if (parameters) |q| {
        var check = try v.synth.Synth.init(.{});
        const es = [_]v.event.PhonemeEvent{.{ .phoneme = .a, .parameters = q }};
        try check.enqueue(&es);
    };
    model.remember();
    model.current = snapshot;
    model.profiles = session.profiles;
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
    const header = "P4\n1000 720\n";
    _ = fwrite(header.ptr, 1, header.len, f);
    const surface = m.surface.Mono1.init(&pixels, 1000, 720) catch return;
    var row: [125]u8 = undefined;
    for (0..720) |y| {
        @memset(&row, 0);
        for (0..1000) |x| if (surface.get(@intCast(x), @intCast(y))) {
            row[x / 8] |= @as(u8, 128) >> @as(u3, @intCast(x % 8));
        };
        _ = fwrite(&row, 1, row.len, f);
    }
}
pub fn main() void {
    display.viewport = .{ .w = 1000, .h = 720 };
    display.setFontProvider(font.provider);
    setText("コンニチワ");
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
    display.viewport = .{ .w = 1000, .h = 720 };
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
    display.viewport = .{ .w = 1000, .h = 720 };
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
    try std.testing.expectEqual(@as(usize, 13), model.selected);
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
    const f = fopen("/tmp/mimoc-invalid-session.json", "wb") orelse return error.OpenFailed;
    const bad = "{}";
    _ = fwrite(bad.ptr, 1, bad.len, f);
    _ = fclose(f);
    try std.testing.expectError(error.MissingField, loadSessionFrom("/tmp/mimoc-invalid-session.json"));
    try std.testing.expectEqual(@as(f32, 190), model.current.voice.base_pitch_hz);
}
