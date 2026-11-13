//! nanodown's tests: the model, the engine and the views, offscreen.
const std = @import("std");

test {
    _ = @import("model/media.zig");
    _ = @import("model/download.zig");
    _ = @import("model/settings.zig");
    _ = @import("model/library.zig");
    _ = @import("model/subscription.zig");
    _ = @import("model/license.zig");
    _ = @import("engine/http.zig");
    _ = @import("engine/hls.zig");
    _ = @import("engine/dash.zig");
    _ = @import("engine/mux.zig");
    _ = @import("engine/mux_write.zig");
    _ = @import("engine/mux_tests.zig");
    _ = @import("engine/extract.zig");
    _ = @import("engine/manifest.zig");
    _ = @import("engine/page_tests.zig");
    _ = @import("engine/capture.zig");
    _ = @import("store.zig");
    _ = @import("capture_flow.zig");
    _ = @import("engine/job.zig");
    _ = @import("thumbs.zig");
    _ = @import("cli.zig");
    _ = @import("app.zig");
    _ = @import("view.zig");
    _ = @import("view_rows.zig");
    _ = @import("view_preview.zig");
    _ = @import("view_settings.zig");
}
