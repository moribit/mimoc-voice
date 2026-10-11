const std = @import("std");
const P = @import("../core/phoneme.zig").PhonemeId;
const E = @import("../core/event.zig").PhonemeEvent;
const Seq = @import("sequence.zig").Sequence;
const dictionary = @import("dictionary.zig");
pub const Context = enum { any, word_start, word_end, before_front_vowel };
pub const Rule = struct { pattern: []const u8, context: Context = .any, replacement: []const P };
pub const rules = [_]Rule{ .{ .pattern = "tion", .replacement = &.{ .sh, .schwa, .n } }, .{ .pattern = "igh", .replacement = &.{ .a, .i } }, .{ .pattern = "ch", .replacement = &.{.ch} }, .{ .pattern = "sh", .replacement = &.{.sh} }, .{ .pattern = "th", .replacement = &.{.th} }, .{ .pattern = "ph", .replacement = &.{.f} }, .{ .pattern = "ng", .replacement = &.{.ng} }, .{ .pattern = "ee", .replacement = &.{.i} }, .{ .pattern = "oo", .replacement = &.{.u} }, .{ .pattern = "ea", .replacement = &.{.i} }, .{ .pattern = "ai", .replacement = &.{ .e, .i } }, .{ .pattern = "ow", .replacement = &.{.o} }, .{ .pattern = "qu", .replacement = &.{ .k, .w } }, .{ .pattern = "e", .context = .word_end, .replacement = &.{} }, .{ .pattern = "c", .context = .before_front_vowel, .replacement = &.{.s} }, .{ .pattern = "g", .context = .before_front_vowel, .replacement = &.{.j} } };
fn emit(seq: *Seq, ps: []const P) !void {
    for (ps) |p| try seq.append(p, if (@import("../core/phoneme.zig").vowel(p)) 110 else 60);
}
fn word(seq: *Seq, w: []const u8) !void {
    for (dictionary.entries) |entry| if (std.mem.eql(u8, w, entry.word)) {
        try emit(seq, entry.phonemes);
        return;
    };
    var i: usize = 0;
    while (i < w.len) {
        if (w[i] == '\'') {
            i += 1;
            continue;
        }
        var matched = false;
        for (rules) |r| {
            if (!std.mem.startsWith(u8, w[i..], r.pattern)) continue;
            const end = i + r.pattern.len;
            const context = switch (r.context) {
                .any => true,
                .word_start => i == 0,
                .word_end => end == w.len and w.len > 2,
                .before_front_vowel => end < w.len and (w[end] == 'e' or w[end] == 'i' or w[end] == 'y'),
            };
            if (!context) continue;
            try emit(seq, r.replacement);
            i = end;
            matched = true;
            break;
        }
        if (matched) continue;
        const p: P = switch (w[i]) {
            'a' => .ae,
            'b' => .b,
            'c', 'k', 'q' => .k,
            'd' => .d,
            'e' => .eh,
            'f' => .f,
            'g' => .g,
            'h' => .h,
            'i' => .ih,
            'j' => .j,
            'l' => .l,
            'm' => .m,
            'n' => .n,
            'o' => .o,
            'p' => .p,
            'r' => .r,
            's' => .s,
            't' => .t,
            'u' => .uh,
            'v' => .v,
            'w' => .w,
            'x' => .k,
            'y' => .y,
            'z' => .z,
            else => .silence,
        };
        try emit(seq, &.{p});
        if (w[i] == 'x') try emit(seq, &.{.s});
        i += 1;
    }
}
pub fn parse(text: []const u8, out: []E) !Seq {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var seq = Seq{ .buffer = out };
    var i: usize = 0;
    var question = false;
    while (i < text.len) {
        if (std.ascii.isAlphabetic(text[i])) {
            var w: [128]u8 = undefined;
            var n: usize = 0;
            while (i < text.len and (std.ascii.isAlphabetic(text[i]) or text[i] == '\'')) : (i += 1) {
                if (n == w.len) return error.WordTooLong;
                w[n] = std.ascii.toLower(text[i]);
                n += 1;
            }
            question = false;
            try word(&seq, w[0..n]);
            continue;
        }
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            if (seq.len > 0 and seq.buffer[seq.len - 1].phoneme != .silence) try seq.append(.silence, 65);
        } else if (c == '.' or c == ',' or c == '!' or c == '?') {
            try seq.append(.silence, 180);
            question = c == '?';
        } else if (c == '\'') {
            // Apostrophes outside a word do not produce phonemes.
        } else {
            seq.unsupported += 1;
            try seq.append(.silence, 40);
            if (c >= 128) {
                i += (std.unicode.utf8ByteSequenceLength(c) catch unreachable);
                continue;
            }
        }
        i += 1;
    }
    seq.contour(question);
    if (question and seq.len >= 2) seq.buffer[seq.len - 2].pitch_end_scale = 1.36;
    return seq;
}
test "dictionary capitalization fallback digraph punctuation apostrophe" {
    var a: [256]E = undefined;
    var b: [256]E = undefined;
    const x = try parse("Hello WORLD", &a);
    const y = try parse("hello world", &b);
    try std.testing.expectEqualSlices(E, x.events(), y.events());
    const z = try parse("xyzzy ships can't?", &a);
    try std.testing.expect(z.len > 0 and z.unsupported == 0);
    const sh = try parse("ship", &a);
    try std.testing.expectEqual(P.sh, sh.events()[0].phoneme);
    for (dictionary.entries) |entry| {
        const s = try parse(entry.word, &a);
        try std.testing.expectEqual(entry.phonemes.len, s.len);
    }
    var long: [129]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectError(error.WordTooLong, parse(&long, &a));
}
