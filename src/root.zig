pub const phoneme=@import("core/phoneme.zig");pub const event=@import("core/event.zig");pub const voice=@import("core/voice.zig");pub const synth=@import("core/synth.zig");
test { _=@import("core/noise.zig");_=@import("core/oscillator.zig");_=@import("core/resonator.zig");_=@import("core/envelope.zig");_ = synth; }
