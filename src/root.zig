pub const phoneme = @import("core/phoneme.zig");
pub const event = @import("core/event.zig");
pub const voice = @import("core/voice.zig");
pub const synth = @import("core/synth.zig");
test {
    _ = @import("core/noise.zig");
    _ = @import("core/oscillator.zig");
    _ = @import("core/resonator.zig");
    _ = @import("core/envelope.zig");
    _ = synth;
}
pub const japanese = @import("lang/japanese.zig");
pub const english = @import("lang/english.zig");
pub const sequence = @import("lang/sequence.zig");
test {
    _ = japanese;
    _ = english;
}
pub const wav = @import("audio/wav.zig");
pub const playback = @import("audio/playback.zig");
test {
    _ = wav;
}
test {
    _ = @import("quality_tests.zig");
}
