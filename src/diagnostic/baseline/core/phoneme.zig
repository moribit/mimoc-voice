pub const PhonemeId = enum(u8) { silence, a, i, u, e, o, k, g, s, sh, z, t, d, ch, ts, n, h, f, b, p, m, y, r, w, l, v, th, dh, ng, ae, ah, ih, uh, schwa, er, N, eh, aw, oy, j };
pub fn vowel(p: PhonemeId) bool {
    return switch (p) {
        .a, .i, .u, .e, .o, .ae, .ah, .ih, .uh, .schwa, .er, .eh, .aw, .oy => true,
        else => false,
    };
}
pub fn voiced(p: PhonemeId) bool {
    return switch (p) {
        .silence, .k, .s, .sh, .t, .ch, .ts, .h, .f, .p, .th => false,
        else => true,
    };
}
