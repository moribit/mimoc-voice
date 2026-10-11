pub const PhonemeEvent=struct { phoneme:@import("phoneme.zig").PhonemeId,duration_ms:u16=100,pitch_hz:u16=0,pitch_end_hz:u16=0,parameters:?@import("voice.zig").Parameters=null, stress:u8=0 };
