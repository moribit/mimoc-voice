const S=@import("core/synth.zig").Synth; const E=@import("core/event.zig").PhonemeEvent;
export fn render_voice(out:[*]i16,len:usize) usize {var s=S.init(.{}) catch return 0;const e=[_]E{.{.phoneme=.a}};s.enqueue(&e) catch return 0;return s.render(out[0..len]);}
