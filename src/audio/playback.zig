const builtin = @import("builtin");
const S = @import("../core/synth.zig").Synth;
extern fn voice_audio_start(*anyopaque, *const fn (*anyopaque, [*]i16, usize) callconv(.c) usize, c_uint) ?*anyopaque;
extern fn voice_audio_done(*anyopaque) c_int;
extern fn voice_audio_stop(*anyopaque) void;
pub const Player = struct {
    handle: ?*anyopaque = null,
    pub fn start(self: *Player, synth: *S) !void {
        self.stop();
        if (builtin.os.tag != .macos) return error.PlaybackUnsupported;
        self.handle = voice_audio_start(synth, pull, synth.config.sample_rate) orelse return error.AudioDeviceFailed;
    }
    pub fn done(self: *const Player) bool {
        if (builtin.os.tag != .macos) return true;
        return if (self.handle) |h| voice_audio_done(h) != 0 else true;
    }
    pub fn stop(self: *Player) void {
        if (builtin.os.tag == .macos) if (self.handle) |h| voice_audio_stop(h);
        self.handle = null;
    }
    fn pull(ctx: *anyopaque, out: [*]i16, len: usize) callconv(.c) usize {
        const s: *S = @ptrCast(@alignCast(ctx));
        return s.render(out[0..len]);
    }
};
