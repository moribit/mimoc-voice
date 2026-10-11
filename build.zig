const std = @import("std");
pub fn build(b: *std.Build) void {
 const target=b.standardTargetOptions(.{}); const optimize=b.standardOptimizeOption(.{});
 const lib=b.addModule("mimoc_voice", .{.root_source_file=b.path("src/root.zig"),.target=target,.optimize=optimize});
 const test_run=b.addRunArtifact(b.addTest(.{.root_module=lib})); b.step("test","Run tests").dependOn(&test_run.step);
 const exe=b.addExecutable(.{.name="mimoc-voice",.root_module=b.createModule(.{.root_source_file=b.path("src/main.zig"),.target=target,.optimize=optimize,.link_libc=true})}); exe.root_module.addImport("voice",lib); b.installArtifact(exe);
 const run=b.addRunArtifact(exe); run.addPassthruArgs(); b.step("run","CLI").dependOn(&run.step);
 const bench=b.addRunArtifact(exe); bench.addArg("bench"); b.step("bench","10 second streaming benchmark").dependOn(&bench.step);
 const ui_path=b.option([]const u8,"mimoc-ui","Path to existing mimoc-ui checkout") orelse "../mimoc-ui";
 if(target.result.os.tag==.macos) {
 const ui=b.createModule(.{.root_source_file=.{.cwd_relative=b.pathJoin(&.{ui_path,"src/root.zig"})},.target=target,.optimize=optimize});
 const win=b.createModule(.{.root_source_file=.{.cwd_relative=b.pathJoin(&.{ui_path,"src/platform/macos/window.zig"})},.target=target,.optimize=optimize}); win.addImport("mimoc_ui",ui);
 const font=b.createModule(.{.root_source_file=.{.cwd_relative=b.pathJoin(&.{ui_path,"src/platform/macos/font.zig"})},.target=target,.optimize=optimize}); font.addImport("mimoc_ui",ui);
 const studio=b.addExecutable(.{.name="mimoc-voice-studio",.root_module=b.createModule(.{.root_source_file=b.path("src/studio/app.zig"),.target=target,.optimize=optimize,.link_libc=true})});
 studio.root_module.addImport("voice",lib); studio.root_module.addImport("mimoc_ui",ui); studio.root_module.addImport("window",win); studio.root_module.addImport("font",font);
 inline for(.{"window.m","font.m"}) |f| studio.root_module.addCSourceFile(.{.file=.{.cwd_relative=b.pathJoin(&.{ui_path,"src/platform/macos",f})},.flags=&.{"-fobjc-arc"}});
 inline for(.{"AppKit","Foundation","CoreText","CoreGraphics"}) |f| studio.root_module.linkFramework(f,.{});
 b.installArtifact(studio); b.step("studio","Run Voice Studio").dependOn(&b.addRunArtifact(studio).step); b.step("check-studio","Compile Studio").dependOn(&studio.step);
 }
 const embedded=b.addObject(.{.name="voice-embedded",.root_module=b.createModule(.{.root_source_file=b.path("src/embedded.zig"),.target=b.resolveTargetQuery(.{.cpu_arch=.riscv32,.os_tag=.freestanding,.abi=.eabi}),.optimize=.small})}); b.step("check-embedded","Compile allocation-free core for freestanding RV32").dependOn(&embedded.step);
}
