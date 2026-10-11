const std=@import("std");
pub const Resonator=struct { y1:f32=0,y2:f32=0,a:f32=0,b:f32=0,gain:f32=0,
 pub fn configure(self:*Resonator,f:@import("voice.zig").Formant,rate:f32) void {const r=@exp(-std.math.pi*std.math.clamp(f.bandwidth_hz,20,2000)/rate); self.a=2*r*@cos(2*std.math.pi*std.math.clamp(f.frequency_hz,40,rate*0.45)/rate);self.b=-r*r;self.gain=(1-r)*f.gain;}
 pub fn process(self:*Resonator,x:f32) f32 {const y=self.gain*x+self.a*self.y1+self.b*self.y2;self.y2=self.y1;self.y1=y;return y;}
};
test "resonator stable impulse decay" {var r=Resonator{};r.configure(.{.frequency_hz=800},16000);_ =r.process(1);for(0..16000) |_|try std.testing.expect(std.math.isFinite(r.process(0)));try std.testing.expect(@abs(r.y1)<0.00001);}
