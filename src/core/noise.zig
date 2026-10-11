const std=@import("std");
pub const Noise=struct { state:u32=0x12345678,pub fn next(self:*Noise) f32 { var x=self.state; x^=x<<13; x^=x>>17; x^=x<<5; self.state=x; return @as(f32,@floatFromInt(x))/2147483648.0-1; } };
test "noise deterministic bounded" { var a=Noise{}; var b=Noise{}; for(0..1000) |_| {const x=a.next(); try std.testing.expect(x>=-1 and x<=1); try std.testing.expectEqual(x,b.next());} }
