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
    if (std.mem.eql(u8, command, "bench")) {
        try bench();
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        usage();
        return;
    }
    const single = std.mem.eql(u8, command, "synth-phoneme");
    const play = std.mem.eql(u8, command, "play");
    if (!single and !play and !std.mem.eql(u8, command, "synth")) return error.UnknownCommand;
    var lang: []const u8 = "ja";
    var text: ?[]const u8 = null;
    var path: []const u8 = "voice.wav";
    var config = v.synth.Config{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--envelope")) config.envelope_mode = std.meta.stringToEnum(v.synth.EnvelopeMode, args.next() orelse return error.MissingEnvelope) orelse return error.UnknownEnvelope else if (std.mem.eql(u8, arg, "--lang")) lang = args.next() orelse return error.MissingLanguage else if (std.mem.eql(u8, arg, "-o")) path = args.next() orelse return error.MissingOutput else if (std.mem.eql(u8, arg, "--rate")) config.sample_rate = try std.fmt.parseInt(u32, args.next() orelse return error.MissingRate, 10) else if (std.mem.eql(u8, arg, "--preset")) {
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
    var events: [2048]v.event.PhonemeEvent = undefined;
    var seq = v.sequence.Sequence{ .buffer = &events };
    if (single) {
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
    try synth.enqueue(try v.planner.plan(seq.events(), &targets, .{ .language = if (single) .neutral else if (std.mem.eql(u8, lang, "ja")) .ja else .en }));
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
}
fn usage() void {
    std.debug.print("mimoc-voice synth|play --lang ja|en \"text\" [-o voice.wav] [--rate 16000] [--preset Retro]\nmimoc-voice synth-phoneme a -o a.wav\nmimoc-voice bench\n", .{});
}
