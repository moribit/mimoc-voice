const std = @import("std");
const v = @import("voice");
extern fn usleep(c_uint) c_int;
fn now() !f64 {
    var t: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &t) != 0) return error.ClockFailed;
    return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.nsec)) / 1000000000;
}
fn bench() !void {
    var s = try v.synth.Synth.init(.{});
    var events: [512]v.event.PhonemeEvent = undefined;
    const seq = try v.japanese.parse("コンニチワオハヨウモーバスメッセージセツゾクバッテリーエラーコンニチワオハヨウモーバスメッセージセツゾクバッテリーエラーコンニチワオハヨウモーバスメッセージセツゾクバッテリーエラー", &events);
    var remaining: u16 = 10000;
    var used: usize = 0;
    for (seq.events()) |*event| {
        event.duration_ms = @min(event.duration_ms, remaining);
        remaining -= event.duration_ms;
        used += 1;
        if (remaining == 0) break;
    }
    if (remaining != 0) return error.BenchmarkTooShort;
    var targets: [512]v.target.AcousticTarget = undefined;
    try s.enqueue(try v.planner.plan(events[0..used], &targets, .{ .language = .ja }));
    var out: [512]i16 = undefined;
    var count: usize = 0;
    const start = try now();
    while (!s.finished()) count += s.render(&out);
    const elapsed = (try now()) - start;
    std.debug.print("16kHz / {d} frames / {d:.3} ms / {d:.0} PCM frames/s\nSynth peak heap allocation: 0 bytes; Synth size: {d} bytes; PCM chunk: {d} bytes\n", .{ count, elapsed * 1000, @as(f64, @floatFromInt(count)) / elapsed, @sizeOf(v.synth.Synth), @sizeOf(@TypeOf(out)) });
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const command = args.next() orelse {
        usage();
        return;
    };
    if (std.mem.eql(u8, command, "render-targets")) {
        const input = args.next() orelse return error.MissingTargets;
        var path: []const u8 = "voice.wav";
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) path = args.next() orelse return error.MissingOutput else return error.UnknownOption;
        }
        try replayTargets(input, path);
        return;
    }
    if (std.mem.eql(u8, command, "bench")) {
        try bench();
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        usage();
        return;
    }
    const sequence_mode = std.mem.eql(u8, command, "synth-sequence");
    const single = std.mem.eql(u8, command, "synth-phoneme");
    const play = std.mem.eql(u8, command, "play");
    if (!sequence_mode and !single and !play and !std.mem.eql(u8, command, "synth")) return error.UnknownCommand;
    var lang: []const u8 = "ja";
    var text: ?[]const u8 = null;
    var path: []const u8 = "voice.wav";
    var config = v.synth.Config{};
    var reference: []const u8 = "current";
    var scope: []const u8 = "whole";
    var selected: usize = 0;
    var metadata: ?[]const u8 = null;
    var options = v.planner.Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reference")) reference = args.next() orelse return error.MissingReference else if (std.mem.eql(u8, arg, "--scope")) scope = args.next() orelse return error.MissingScope else if (std.mem.eql(u8, arg, "--selected")) selected = try std.fmt.parseInt(usize, args.next() orelse return error.MissingIndex, 10) else if (std.mem.eql(u8, arg, "--targets")) metadata = args.next() orelse return error.MissingMetadata else if (std.mem.eql(u8, arg, "--timing")) {
            const value = args.next() orelse return error.MissingTiming;
            options.context_timing = try setting(value, "context", "fixed");
        } else if (std.mem.eql(u8, arg, "--transitions")) {
            const value = args.next() orelse return error.MissingTransition;
            options.context_transitions = try setting(value, "context", "fixed");
        } else if (std.mem.eql(u8, arg, "--noise")) {
            const value = args.next() orelse return error.MissingNoise;
            options.shaped_noise = try setting(value, "shaped", "legacy");
        } else if (std.mem.eql(u8, arg, "--glide")) {
            options.dynamic_vowels = try setting(args.next() orelse return error.MissingSetting, "on", "off");
        } else if (std.mem.eql(u8, arg, "--vowels")) {
            options.english_vowels = try setting(args.next() orelse return error.MissingSetting, "english", "japanese_approx");
        } else if (std.mem.eql(u8, arg, "--stress")) {
            options.stress_prosody = try setting(args.next() orelse return error.MissingSetting, "on", "off");
        } else if (std.mem.eql(u8, arg, "--envelope")) config.envelope_mode = std.meta.stringToEnum(v.synth.EnvelopeMode, args.next() orelse return error.MissingEnvelope) orelse return error.UnknownEnvelope else if (std.mem.eql(u8, arg, "--lang")) lang = args.next() orelse return error.MissingLanguage else if (std.mem.eql(u8, arg, "-o")) path = args.next() orelse return error.MissingOutput else if (std.mem.eql(u8, arg, "--rate")) config.sample_rate = try std.fmt.parseInt(u32, args.next() orelse return error.MissingRate, 10) else if (std.mem.eql(u8, arg, "--preset")) {
            const name = args.next() orelse return error.MissingPreset;
            var found = false;
            for (v.voice.presets) |preset| if (std.ascii.eqlIgnoreCase(name, preset.name)) {
                config.voice = preset.voice;
                found = true;
                break;
            };
            if (!found) return error.UnknownPreset;
        } else if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption else if (text == null) text = arg else return error.ExtraArgument;
    }
    const input = text orelse return error.MissingText;
    if (!std.mem.eql(u8, reference, "current")) {
        if (play or sequence_mode or metadata != null) return error.ReferenceExportOnly;
        try renderReference(reference, input, lang, single, path, config);
        return;
    }
    var events: [2048]v.event.PhonemeEvent = undefined;
    var seq = v.sequence.Sequence{ .buffer = &events };
    if (sequence_mode) {
        var it = std.mem.tokenizeScalar(u8, input, ' ');
        while (it.next()) |token| {
            const p = std.meta.stringToEnum(v.phoneme.PhonemeId, token) orelse return error.UnknownPhoneme;
            try seq.append(p, 100);
            if (std.mem.eql(u8, lang, "en")) seq.buffer[seq.len - 1].timing = .automatic;
        }
    } else if (single) {
        const p = std.meta.stringToEnum(v.phoneme.PhonemeId, input) orelse return error.UnknownPhoneme;
        try seq.append(p, 500);
    } else if (std.mem.eql(u8, lang, "ja")) seq = try v.japanese.parse(input, &events) else if (std.mem.eql(u8, lang, "en")) seq = try v.english.parse(input, &events) else return error.UnknownLanguage;
    if (seq.len == 0) return error.EmptySequence;
    std.debug.print("Phonemes: ", .{});
    for (seq.events()) |e| std.debug.print("{s} ", .{@tagName(e.phoneme)});
    std.debug.print("\n", .{});
    if (seq.unsupported > 0) std.debug.print("Unsupported input: {d} (rendered as pauses)\n", .{seq.unsupported});
    var synth = try v.synth.Synth.init(config);
    var targets: [2048]v.target.AcousticTarget = undefined;
    options.language = if (single) .neutral else if (std.mem.eql(u8, lang, "ja")) .ja else if (std.mem.eql(u8, lang, "en")) .en else return error.UnknownLanguage;
    const planned = try v.planner.plan(seq.events(), &targets, options);
    const range = try scopeRange(scope, selected, planned.len);
    try synth.enqueue(planned[range.start..range.end]);
    if (play) {
        var player = v.playback.Player{};
        defer player.stop();
        try player.start(&synth);
        while (!player.done()) _ = usleep(10000);
    } else {
        var name: [4096]u8 = undefined;
        if (path.len >= name.len) return error.PathTooLong;
        @memcpy(name[0..path.len], path);
        name[path.len] = 0;
        try v.wav.exportFile(name[0..path.len :0], &synth);
        std.debug.print("Saved {s}\n", .{path});
    }
    if (metadata) |output| try writeMetadata(output, input, options, config, seq.events(), planned, range, synth.peak, synth.numerical_faults);
}
fn usage() void {
    std.debug.print(
        \\mimoc-voice synth|play --lang ja|en "text" [-o voice.wav] [--rate 16000] [--preset Retro]
        \\mimoc-voice synth-phoneme a -o a.wav
        \\mimoc-voice synth-sequence "h schwa l ow" --lang en -o sequence.wav
        \\mimoc-voice render-targets plan.json -o replay.wav
        \\Diagnostic: --targets plan.json --scope whole|selected|previous_selected|selected_next|context --selected 2
        \\Factors: --envelope single|legacy_double --timing context|fixed --transitions context|fixed
        \\         --noise shaped|legacy --glide on|off --vowels english|japanese_approx --stress on|off
        \\Frozen references (export only): --reference phase5|envelope_single
        \\mimoc-voice bench
        \\
    , .{});
}

fn setting(value: []const u8, on: []const u8, off: []const u8) !bool {
    if (std.mem.eql(u8, value, on)) return true;
    if (std.mem.eql(u8, value, off)) return false;
    return error.UnknownSetting;
}
const Range = struct { start: usize, end: usize };
fn scopeRange(scope: []const u8, index: usize, len: usize) !Range {
    if (std.mem.eql(u8, scope, "whole")) return .{ .start = 0, .end = len };
    if (index >= len) return error.InvalidSelection;
    return if (std.mem.eql(u8, scope, "selected")) .{ .start = index, .end = index + 1 } else if (std.mem.eql(u8, scope, "previous_selected")) .{ .start = index -| 1, .end = index + 1 } else if (std.mem.eql(u8, scope, "selected_next")) .{ .start = index, .end = @min(len, index + 2) } else if (std.mem.eql(u8, scope, "context")) .{ .start = index -| 1, .end = @min(len, index + 2) } else error.UnknownScope;
}
fn zpath(path: []const u8, out: []u8) ![:0]u8 {
    if (path.len >= out.len) return error.PathTooLong;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}
extern fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern fn fclose(*anyopaque) c_int;
fn writeMetadata(path: []const u8, input: []const u8, options: v.planner.Options, config: v.synth.Config, events: []const v.event.PhonemeEvent, targets: []const v.target.AcousticTarget, range: Range, peak: f32, faults: usize) !void {
    var counts: [2048]usize = undefined;
    const synth = try v.synth.Synth.init(config);
    for (targets[range.start..range.end], 0..) |t, i| counts[i] = synth.frames(t);
    const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .schema = 1, .input = input, .planner = options, .synth = config, .events = events, .targets = targets[range.start..range.end], .range = range, .internal_peak = peak, .numerical_faults = faults, .frame_counts = counts[0 .. range.end - range.start] }, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(bytes);
    var name: [4096]u8 = undefined;
    const f = fopen(try zpath(path, &name), "wb") orelse return error.OpenFailed;
    var closed = false;
    defer if (!closed) {
        _ = fclose(f);
    };
    if (fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.WriteFailed;
    closed = true;
    if (fclose(f) != 0) return error.WriteFailed;
}
fn renderReference(reference: []const u8, input: []const u8, lang: []const u8, single: bool, path: []const u8, config: v.synth.Config) !void {
    const old = @import("voice").baseline;
    var events: [2048]old.event.PhonemeEvent = undefined;
    var count: usize = 0;
    if (single) {
        const p = std.meta.stringToEnum(@import("voice").baseline_phoneme.PhonemeId, input) orelse return error.UnknownPhoneme;
        events[0] = .{ .phoneme = p, .duration_ms = 500 };
        count = 1;
    } else if (std.mem.eql(u8, lang, "en")) {
        const seq = try old.english.parse(input, &events);
        count = seq.len;
    } else if (std.mem.eql(u8, lang, "ja")) {
        const seq = try old.japanese.parse(input, &events);
        count = seq.len;
    } else return error.UnknownLanguage;
    const old_config = @import("voice").baseline.synth.Config{ .sample_rate = config.sample_rate, .voice = .{ .base_pitch_hz = config.voice.base_pitch_hz, .speed = config.voice.speed, .amplitude = config.voice.amplitude, .breath = config.voice.breath, .formant_scale = config.voice.formant_scale, .waveform = std.meta.stringToEnum(@import("voice").baseline_voice.Waveform, @tagName(config.voice.waveform)).? } };
    var name: [4096]u8 = undefined;
    const filename = try zpath(path, &name);
    if (std.mem.eql(u8, reference, "phase5")) {
        var s = try old.synth.Synth.init(old_config);
        try s.enqueue(events[0..count]);
        try v.wav.exportFile(filename, &s);
    } else if (std.mem.eql(u8, reference, "envelope_single")) {
        var s = try v.envelope_reference.Synth.init(.{ .voice = old_config.voice, .sample_rate = old_config.sample_rate });
        try s.enqueue(events[0..count]);
        try v.wav.exportFile(filename, &s);
    } else return error.UnknownReference;
}

extern fn fread([*]u8, usize, usize, *anyopaque) usize;
extern fn fseek(*anyopaque, c_long, c_int) c_int;
extern fn ftell(*anyopaque) c_long;
fn replayTargets(input: []const u8, output: []const u8) !void {
    var path: [4096]u8 = undefined;
    const file = fopen(try zpath(input, &path), "rb") orelse return error.OpenFailed;
    defer _ = fclose(file);
    if (fseek(file, 0, 2) != 0) return error.ReadFailed;
    const size = ftell(file);
    if (size < 0 or fseek(file, 0, 0) != 0) return error.ReadFailed;
    if (size > 64 * 1024 * 1024) return error.TargetFileTooLarge;
    const bytes = try std.heap.page_allocator.alloc(u8, @intCast(size));
    defer std.heap.page_allocator.free(bytes);
    const count = fread(bytes.ptr, 1, bytes.len, file);
    if (count != bytes.len) return error.ReadFailed;
    const Replay = struct { synth: v.synth.Config, targets: []const v.target.AcousticTarget };
    const parsed = try std.json.parseFromSlice(Replay, std.heap.page_allocator, bytes[0..count], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.targets.len > 2048) return error.TargetCapacity;
    var synth = try v.synth.Synth.init(parsed.value.synth);
    try synth.enqueue(parsed.value.targets);
    try v.wav.exportFile(try zpath(output, &path), &synth);
}
