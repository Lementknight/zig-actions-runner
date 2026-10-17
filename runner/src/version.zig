//! This build's version, as `--version` and every job's "Set up job" report it.
//!
//! The text comes from `versionFile` in build.zig — `git describe` where there is a repository to
//! ask, the `-Dversion` flag where the release workflow or the image build passes one, and the
//! package's version where there is neither. Trailing newline from git's output trimmed here rather
//! than there, so the build step stays a plain capture of a command.

const std = @import("std");

pub const string = std.mem.trim(u8, @embedFile("build_version"), " \t\r\n");
