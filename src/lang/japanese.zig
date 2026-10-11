const std = @import("std");
const P = @import("../core/phoneme.zig").PhonemeId;
const E = @import("../core/event.zig").PhonemeEvent;
const Seq = @import("sequence.zig").Sequence;
const Kana = struct { kana: u21, consonant: ?P, vowel: P };
const table = [_]Kana{ .{ .kana = 'ア', .consonant = null, .vowel = .a }, .{ .kana = 'イ', .consonant = null, .vowel = .i }, .{ .kana = 'ウ', .consonant = null, .vowel = .u }, .{ .kana = 'エ', .consonant = null, .vowel = .e }, .{ .kana = 'オ', .consonant = null, .vowel = .o }, .{ .kana = 'カ', .consonant = .k, .vowel = .a }, .{ .kana = 'キ', .consonant = .k, .vowel = .i }, .{ .kana = 'ク', .consonant = .k, .vowel = .u }, .{ .kana = 'ケ', .consonant = .k, .vowel = .e }, .{ .kana = 'コ', .consonant = .k, .vowel = .o }, .{ .kana = 'ガ', .consonant = .g, .vowel = .a }, .{ .kana = 'ギ', .consonant = .g, .vowel = .i }, .{ .kana = 'グ', .consonant = .g, .vowel = .u }, .{ .kana = 'ゲ', .consonant = .g, .vowel = .e }, .{ .kana = 'ゴ', .consonant = .g, .vowel = .o }, .{ .kana = 'サ', .consonant = .s, .vowel = .a }, .{ .kana = 'シ', .consonant = .sh, .vowel = .i }, .{ .kana = 'ス', .consonant = .s, .vowel = .u }, .{ .kana = 'セ', .consonant = .s, .vowel = .e }, .{ .kana = 'ソ', .consonant = .s, .vowel = .o }, .{ .kana = 'ザ', .consonant = .z, .vowel = .a }, .{ .kana = 'ジ', .consonant = .j, .vowel = .i }, .{ .kana = 'ズ', .consonant = .z, .vowel = .u }, .{ .kana = 'ゼ', .consonant = .z, .vowel = .e }, .{ .kana = 'ゾ', .consonant = .z, .vowel = .o }, .{ .kana = 'タ', .consonant = .t, .vowel = .a }, .{ .kana = 'チ', .consonant = .ch, .vowel = .i }, .{ .kana = 'ツ', .consonant = .ts, .vowel = .u }, .{ .kana = 'テ', .consonant = .t, .vowel = .e }, .{ .kana = 'ト', .consonant = .t, .vowel = .o }, .{ .kana = 'ダ', .consonant = .d, .vowel = .a }, .{ .kana = 'ヂ', .consonant = .j, .vowel = .i }, .{ .kana = 'ヅ', .consonant = .z, .vowel = .u }, .{ .kana = 'デ', .consonant = .d, .vowel = .e }, .{ .kana = 'ド', .consonant = .d, .vowel = .o }, .{ .kana = 'ナ', .consonant = .n, .vowel = .a }, .{ .kana = 'ニ', .consonant = .n, .vowel = .i }, .{ .kana = 'ヌ', .consonant = .n, .vowel = .u }, .{ .kana = 'ネ', .consonant = .n, .vowel = .e }, .{ .kana = 'ノ', .consonant = .n, .vowel = .o }, .{ .kana = 'ハ', .consonant = .h, .vowel = .a }, .{ .kana = 'ヒ', .consonant = .h, .vowel = .i }, .{ .kana = 'フ', .consonant = .f, .vowel = .u }, .{ .kana = 'ヘ', .consonant = .h, .vowel = .e }, .{ .kana = 'ホ', .consonant = .h, .vowel = .o }, .{ .kana = 'バ', .consonant = .b, .vowel = .a }, .{ .kana = 'ビ', .consonant = .b, .vowel = .i }, .{ .kana = 'ブ', .consonant = .b, .vowel = .u }, .{ .kana = 'ベ', .consonant = .b, .vowel = .e }, .{ .kana = 'ボ', .consonant = .b, .vowel = .o }, .{ .kana = 'パ', .consonant = .p, .vowel = .a }, .{ .kana = 'ピ', .consonant = .p, .vowel = .i }, .{ .kana = 'プ', .consonant = .p, .vowel = .u }, .{ .kana = 'ペ', .consonant = .p, .vowel = .e }, .{ .kana = 'ポ', .consonant = .p, .vowel = .o }, .{ .kana = 'マ', .consonant = .m, .vowel = .a }, .{ .kana = 'ミ', .consonant = .m, .vowel = .i }, .{ .kana = 'ム', .consonant = .m, .vowel = .u }, .{ .kana = 'メ', .consonant = .m, .vowel = .e }, .{ .kana = 'モ', .consonant = .m, .vowel = .o }, .{ .kana = 'ラ', .consonant = .r, .vowel = .a }, .{ .kana = 'リ', .consonant = .r, .vowel = .i }, .{ .kana = 'ル', .consonant = .r, .vowel = .u }, .{ .kana = 'レ', .consonant = .r, .vowel = .e }, .{ .kana = 'ロ', .consonant = .r, .vowel = .o }, .{ .kana = 'ヤ', .consonant = .y, .vowel = .a }, .{ .kana = 'ユ', .consonant = .y, .vowel = .u }, .{ .kana = 'ヨ', .consonant = .y, .vowel = .o }, .{ .kana = 'ワ', .consonant = .w, .vowel = .a }, .{ .kana = 'ヲ', .consonant = .w, .vowel = .o }, .{ .kana = 'ヴ', .consonant = .v, .vowel = .u }, .{ .kana = 'ァ', .consonant = null, .vowel = .a }, .{ .kana = 'ィ', .consonant = null, .vowel = .i }, .{ .kana = 'ゥ', .consonant = null, .vowel = .u }, .{ .kana = 'ェ', .consonant = null, .vowel = .e }, .{ .kana = 'ォ', .consonant = null, .vowel = .o } };
pub fn parse(text: []const u8, out: []E) !Seq {
    var seq = Seq{ .buffer = out };
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    var question = false;
    while (it.nextCodepoint()) |cp| {
        if (cp == 'ッ') {
            try seq.append(.silence, 100);
            continue;
        }
        if (cp == 'ー') {
            if (seq.len == 0 or !@import("../core/phoneme.zig").vowel(seq.buffer[seq.len - 1].phoneme)) return error.InvalidLongMark;
            seq.buffer[seq.len - 1].duration_ms = std.math.add(u16, seq.buffer[seq.len - 1].duration_ms, 140) catch return error.DurationOverflow;
            continue;
        }
        if (cp == 'ン') {
            try seq.append(.N, 140);
            continue;
        }
        if (cp == ' ' or cp == '\n' or cp == '\t') {
            try seq.append(.silence, 60);
            continue;
        }
        if (cp == '、' or cp == ',' or cp == '。' or cp == '.' or cp == '!' or cp == '！' or cp == '?' or cp == '？') {
            question = cp == '?' or cp == '？';
            try seq.append(.silence, if (question) 100 else 180);
            continue;
        }
        if (cp == 'ャ' or cp == 'ュ' or cp == 'ョ') {
            if (seq.len < 2 or seq.buffer[seq.len - 1].phoneme != .i) {
                seq.unsupported += 1;
                continue;
            }
            const c = seq.buffer[seq.len - 2].phoneme;
            seq.len -= 1;
            if (c != .sh and c != .ch and c != .j) {
                seq.buffer[seq.len - 1].duration_ms = 30;
                try seq.append(.y, 25);
            } else seq.buffer[seq.len - 1].duration_ms = 55;
            try seq.append(if (cp == 'ャ') .a else if (cp == 'ュ') .u else .o, 85);
            continue;
        }
        var found = false;
        for (table) |k| {
            if (k.kana != cp) continue;
            found = true;
            if (k.consonant) |c| try seq.append(c, if (c == .r) 30 else 45);
            try seq.append(k.vowel, if (k.consonant == null) 140 else if (k.consonant.? == .r) 110 else 95);
            break;
        }
        if (!found) {
            seq.unsupported += 1;
            try seq.append(.silence, 40);
        }
    }
    seq.contour(question);
    if (question and seq.len >= 2) {
        seq.buffer[seq.len - 2].pitch_end_scale = 1.32;
    }
    return seq;
}
test "all kana voiced semi voiced and palatalized" {
    var out: [512]E = undefined;
    for (table) |k| {
        var bytes: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(k.kana, &bytes);
        const s = try parse(bytes[0..n], &out);
        try std.testing.expect(s.len > 0 and s.unsupported == 0);
    }
    for ([_][]const u8{ "キャキュキョ", "シャシュショ", "チャチュチョ", "ニャヒャミャリャギャジャビャピャ" }) |text| {
        const s = try parse(text, &out);
        try std.testing.expectEqual(@as(usize, 0), s.unsupported);
    }
}
test "mora long geminate nasal invalid input" {
    var out: [64]E = undefined;
    const s = try parse("コンニチワ", &out);
    const expected = [_]P{ .k, .o, .N, .n, .i, .ch, .i, .w, .a };
    for (s.events(), expected) |e, p| try std.testing.expectEqual(p, e.phoneme);
    const t = try parse("メッセージ", &out);
    try std.testing.expectEqual(P.silence, t.events()[2].phoneme);
    try std.testing.expectEqual(@as(u16, 235), t.events()[4].duration_ms);
    const u = try parse("abc 空", &out);
    try std.testing.expectEqual(@as(usize, 4), u.unsupported);
    try std.testing.expectError(error.InvalidUtf8, parse("\xff", &out));
    try std.testing.expectError(error.NoSpace, parse("アイ", out[0..1]));
    try std.testing.expectError(error.InvalidLongMark, parse("ー", &out));
}
