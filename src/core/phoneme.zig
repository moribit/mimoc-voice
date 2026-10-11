pub const PhonemeId = enum(u8) { silence, a, i, u, e, o, k, g, s, sh, z, t, d, ch, ts, n, h, f, b, p, m, y, r, w, l, v, th, dh, ng, ae, ah, ih, uh, schwa, er, N, eh, aw, oy, j, iy, aa, ao, uw, ey, ay, ow };
pub fn vowel(p: PhonemeId) bool {
    return switch (p) {
        .a, .i, .u, .e, .o, .ae, .ah, .ih, .uh, .schwa, .er, .eh, .aw, .oy, .iy, .aa, .ao, .uw, .ey, .ay, .ow => true,
        else => false,
    };
}
pub fn voiced(p: PhonemeId) bool {
    return switch (p) {
        .silence, .k, .s, .sh, .t, .ch, .ts, .h, .f, .p, .th => false,
        else => true,
    };
}

pub fn diphthong(p: PhonemeId) bool {
    return switch (p) {
        .ey, .ay, .oy, .ow, .aw => true,
        else => false,
    };
}
pub const Class = enum { silence, vowel, plosive, fricative, nasal, approximant, affricate };
pub fn class(p: PhonemeId) Class {
    if (vowel(p)) return .vowel;
    return switch (p) {
        .silence => .silence,
        .k, .g, .t, .d, .p, .b => .plosive,
        .ch, .ts, .j => .affricate,
        .s, .sh, .z, .h, .f, .v, .th, .dh => .fricative,
        .m, .n, .N, .ng => .nasal,
        .l, .r, .w, .y => .approximant,
        else => unreachable,
    };
}
