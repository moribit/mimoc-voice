const E=@import("../core/event.zig").PhonemeEvent;const P=@import("../core/phoneme.zig").PhonemeId;
pub const Sequence=struct {buffer:[]E,len:usize=0,unsupported:usize=0,
 pub fn append(self:*Sequence,p:P,ms:u16) !void {if(self.len==self.buffer.len)return error.NoSpace;self.buffer[self.len]=.{.phoneme=p,.duration_ms=ms};self.len+=1;}
 pub fn events(self:*const Sequence) []E {return self.buffer[0..self.len];}
 pub fn contour(self:*Sequence,question:bool) void {for(self.events(),0..) |*e,i| {if(e.phoneme==.silence)continue;const fall=12*i/@max(self.len,1);e.pitch_hz=@intCast(135-fall+if(i%4==1)@as(usize,5) else 0);e.pitch_end_hz=if(question and i+1==self.len) 165 else e.pitch_hz-3;}}
};
