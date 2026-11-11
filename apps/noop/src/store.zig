//! What survives a relaunch: the workspaces and how often to look, and the
//! items still worth showing. Both are JSON strings in `nanoui.kv`, which
//! keeps strings only: a Mac's defaults, a file elsewhere.
const std = @import("std");
const nanoui = @import("nanoui");
const types = @import("types.zig");

const settings_key = "noop.settings";
const items_key = "noop.items";

/// Items kept between launches: the newest few, so a quick relaunch does not
/// forget what the notch was showing. A day of history does not fit there.
pub const kept = 40;

// The shapes written out: plain JSON, with enum names as strings and a
// decision flattened into its item. Missing fields take their defaults, so
// a file from an older build still loads.
const WireWorkspace = struct {
    repo: []const u8 = "",
    path: []const u8 = "",
    agent: []const u8 = "claude",
    model: []const u8 = "",
};

const WireSettings = struct {
    workspaces: []const WireWorkspace = &.{},
    every: u32 = 60,
    participating_only: bool = false,
    unattended: bool = false,
};

const WireOption = struct {
    letter: []const u8 = "",
    text: []const u8 = "",
};

const WireItem = struct {
    key: []const u8 = "",
    repo: []const u8 = "",
    number: u32 = 0,
    kind: []const u8 = "issue",
    reason: []const u8 = "other",
    title: []const u8 = "",
    url: []const u8 = "",
    updated: []const u8 = "",
    body: []const u8 = "",
    state: []const u8 = "waiting",
    summary: []const u8 = "",
    question: []const u8 = "",
    options: []const WireOption = &.{},
    recommendation: []const u8 = "",
};

const WireItems = struct {
    items: []const WireItem = &.{},
};

/// The settings saved last time, or the defaults. A store that cannot be
/// read is not an error the notch can show: start from the defaults.
pub fn loadSettings(gpa: std.mem.Allocator, store: nanoui.kv.Store) types.Settings {
    const text = (store.get(gpa, settings_key) catch null) orelse return .{};
    defer gpa.free(text);
    return decodeSettings(gpa, text) catch .{};
}

fn decodeSettings(gpa: std.mem.Allocator, text: []const u8) !types.Settings {
    var s: types.Settings = .{};
    errdefer s.free(gpa);
    // The parse owns its scratch: everything kept is duped into the settings.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const wire = try std.json.parseFromSliceLeaky(WireSettings, arena.allocator(), text, .{
        .ignore_unknown_fields = true,
    });
    s.every = @max(30, wire.every);
    s.participating_only = wire.participating_only;
    s.unattended = wire.unattended;
    for (wire.workspaces) |w| {
        if (w.repo.len == 0 or w.path.len == 0) continue;
        // A binding saved before repos were checked can name a folder path
        // instead of `owner/name`: it would never answer, so it is dropped
        // rather than left to fail every poll.
        var clean: [120]u8 = undefined;
        const repo = try gpa.dupe(u8, types.repoFrom(&clean, w.repo) orelse continue);
        errdefer gpa.free(repo);
        const path = try gpa.dupe(u8, w.path);
        errdefer gpa.free(path);
        const model = try gpa.dupe(u8, w.model);
        errdefer gpa.free(model);
        try s.workspaces.append(gpa, .{
            .repo = repo,
            .path = path,
            .agent = std.meta.stringToEnum(types.Agent, w.agent) orelse .claude,
            .model = model,
        });
    }
    return s;
}

pub fn saveSettings(gpa: std.mem.Allocator, store: nanoui.kv.Store, s: *const types.Settings) !void {
    var workspaces = std.ArrayList(WireWorkspace).empty;
    defer workspaces.deinit(gpa);
    for (s.workspaces.items) |w| try workspaces.append(gpa, .{
        .repo = w.repo,
        .path = w.path,
        .agent = @tagName(w.agent),
        .model = w.model,
    });
    const wire: WireSettings = .{
        .workspaces = workspaces.items,
        .every = s.every,
        .participating_only = s.participating_only,
        .unattended = s.unattended,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(wire, .{}, &out.writer);
    try store.set(settings_key, out.written());
}

/// The items saved last time: the ones the notch still shows. A run does
/// not survive a relaunch, so an item caught mid-run comes back waiting.
pub fn loadItems(gpa: std.mem.Allocator, store: nanoui.kv.Store) []types.Item {
    const text = (store.get(gpa, items_key) catch null) orelse return &.{};
    defer gpa.free(text);
    return decodeItems(gpa, text) catch &.{};
}

fn decodeItems(gpa: std.mem.Allocator, text: []const u8) ![]types.Item {
    // The wire copy is only scaffolding: it dies with the arena, and every
    // string the notch keeps is duplicated into `gpa` by decodeItem.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wire = try std.json.parseFromSliceLeaky(WireItems, arena.allocator(), text, .{
        .ignore_unknown_fields = true,
    });
    var out = std.ArrayList(types.Item).empty;
    errdefer {
        for (out.items) |*i| i.free(gpa);
        out.deinit(gpa);
    }
    for (wire.items) |w| {
        if (out.items.len >= kept) break;
        if (w.key.len == 0) continue;
        const kind = std.meta.stringToEnum(types.Kind, w.kind) orelse .issue;
        var state = std.meta.stringToEnum(types.State, w.state) orelse .waiting;
        if (state == .running or state == .done or state == .failed) state = .waiting;
        const item = try decodeItem(gpa, w, kind, state);
        if (!item.state.shown() and item.decision == null) {
            var spent = item;
            spent.free(gpa);
            continue;
        }
        try out.append(gpa, item);
    }
    return out.toOwnedSlice(gpa);
}

fn decodeItem(gpa: std.mem.Allocator, w: WireItem, kind: types.Kind, state: types.State) !types.Item {
    var i: types.Item = .{
        .key = try gpa.dupe(u8, w.key),
        .repo = try gpa.dupe(u8, w.repo),
        .number = w.number,
        .kind = kind,
        .reason = std.meta.stringToEnum(types.Reason, w.reason) orelse .other,
        .title = try gpa.dupe(u8, w.title),
        .url = try gpa.dupe(u8, w.url),
        .updated = try gpa.dupe(u8, w.updated),
        .body = try gpa.dupe(u8, w.body),
        .state = state,
        .summary = try gpa.dupe(u8, w.summary),
    };
    errdefer i.free(gpa);
    if (state == .needs_decision and w.question.len > 0) {
        var options = std.ArrayList(types.Option).empty;
        for (w.options) |o| try options.append(gpa, .{
            .letter = if (o.letter.len > 0) o.letter else "A",
            .text = try gpa.dupe(u8, o.text),
        });
        i.decision = .{
            .question = try gpa.dupe(u8, w.question),
            .options = options,
            .recommendation = try gpa.dupe(u8, w.recommendation),
        };
    }
    return i;
}

/// Every item worth saving, newest first (they arrive that way).
pub fn saveItems(gpa: std.mem.Allocator, store: nanoui.kv.Store, items: []const types.Item) !void {
    var list = std.ArrayList(WireItem).empty;
    // Each item's options outlive the wire item pointing at them, so they
    // are kept here until the JSON is written.
    var opts: std.ArrayList(std.ArrayList(WireOption)) = .empty;
    defer {
        for (opts.items) |*o| o.deinit(gpa);
        opts.deinit(gpa);
        list.deinit(gpa);
    }
    for (items) |i| {
        if (list.items.len >= kept) break;
        if (!i.state.shown() and i.decision == null) continue;
        var options = std.ArrayList(WireOption).empty;
        if (i.decision) |d| for (d.options.items) |o| try options.append(gpa, .{
            .letter = o.letter,
            .text = o.text,
        });
        try opts.append(gpa, options);
        try list.append(gpa, .{
            .key = i.key,
            .repo = i.repo,
            .number = i.number,
            .kind = @tagName(i.kind),
            .reason = @tagName(i.reason),
            .title = i.title,
            .url = i.url,
            .updated = i.updated,
            .body = i.body,
            .state = @tagName(i.state),
            .summary = i.summary,
            .question = if (i.decision) |d| d.question else "",
            .options = options.items,
            .recommendation = if (i.decision) |d| d.recommendation else "",
        });
    }
    const wire: WireItems = .{ .items = list.items };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(wire, .{}, &out.writer);
    try store.set(items_key, out.written());
}
