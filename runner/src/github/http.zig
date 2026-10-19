//! The process's HTTP client. One client loads the CA bundle once and keeps connections alive; a
//! client per request (what the runner did before) loaded the bundle every time, into memory that a
//! waiting runner only frees after its next job, so idle runners grew by hundreds of KB per poll.
const std = @import("std");

/// Set by `main` for the runner (its allocator must be thread-safe: runners share it). Unset in
/// tests and one-off commands, where each request gets its own client.
pub var shared: ?*std.http.Client = null;

/// The shared client, or `local` (owned by the caller) when there is none.
pub fn client(local: *std.http.Client) *std.http.Client {
    return shared orelse local;
}

/// `client.fetch`, tried again while a kept-alive connection turns out to be closed (no byte came
/// back, so nothing was processed or written; see `broker.request`).
pub fn fetch(
    c: *std.http.Client,
    options: std.http.Client.FetchOptions,
) !std.http.Client.FetchResult {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return c.fetch(options) catch |err| switch (err) {
            error.HttpConnectionClosing => if (attempt < 8) continue else err,
            else => err,
        };
    }
}
