//! The window: the top bar with the link field, the preview of what a link
//! turned out to be, the library's tabs and its rows, and the footer with
//! where downloads go.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const media = @import("model/media.zig");
const library = @import("model/library.zig");
const rows = @import("view_rows.zig");
const preview = @import("view_preview.zig");
const settings_view = @import("view_settings.zig");

/// The column the field, the tabs and the rows share: as wide as the window
/// allows, up to the island. `wFull` with a `maxW` would clamp the width but
/// leave the box at the left edge, so the width is worked out here and the
/// row centres it.
fn islandWidth(c: *ui.Context) f32 {
    return @min(theme.metrics.island, c.size.w - theme.metrics.gutter * 2);
}

pub fn view(a: *App, c: *ui.Context) void {
    const p = theme.of(c);
    // The framework's own widgets (a primary button, a caret, a selected
    // row) take their accent from the theme: it is nanodown's orange here.
    c.theme.accent = p.accent;
    c.theme.accent_hover = p.accent_hover;
    c.theme.accent_text = p.on_accent;
    a.now = @import("now.zig").ms();
    // A row asked to go last frame goes now, before this one is walked: the
    // list is drawn from indices worked out up front, so an item taken out
    // while it is being walked leaves the rest pointing past the end.
    a.reap();
    a.poll(c);
    // A link read on its own thread lands here, once it has.
    a.takeRead(c);
    // A capture that has had its time ends on the clock, not on a thread.
    a.tickCapture();
    if (a.preview.capturing) c.animationFrame();

    const root = ui.div(c).sizeFull().column().bg(p.paper);
    defer root.end();

    topBar(a, c, p);
    if (a.preview.item != null) preview.draw(a, c, p);

    // The tabs, and the list under them.
    const body = ui.div(c).grow().wFull().column();
    defer body.end();
    // The tabs stay put on every tab, so there is always a way back.
    tabs(a, c, p);
    // Subscriptions is the fifth tab, and it is not a filter over the
    // downloads: it shows what is followed.
    if (a.tab == 4) subscriptions(a, c, p) else list(a, c, p);

    footer(a, c, p);
    if (a.toastLive()) toast(a, c, p);
    if (a.show_settings) settings_view.draw(a, c, p);
    if (a.ask_quit) quitSheet(a, c, p);
}

fn topBar(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    // The bar holds one column, centred and no wider than the island: a
    // window dragged wide keeps its field at a readable width rather than
    // stretching it edge to edge.
    const bar = ui.div(c).wFull().h(theme.metrics.top).row().itemsCenter().justifyCenter().px(theme.metrics.gutter);
    defer bar.end();
    const island = ui.div(c).row().itemsCenter().gap(8).w(islandWidth(c));
    defer island.end();

    // The field: a link, or a search. Its own scope, so the buttons after it
    // are the bar's children and not the field's: a `defer` that ends the
    // field at the function's end would draw them inside its border.
    {
        const field = ui.div(c).grow().row().itemsCenter().gap(8).h(34).px(11).rounded(9).bg(p.raised).border(p.rule).borderW(1);
        defer field.end();
        // Reading a link is a network round trip, and the icon says so: a
        // magnifier over a field that is not searching is a small lie, and
        // the frame that used to freeze here now keeps drawing.
        if (a.preview.reading) {
            kit.spinner(c, .{ .size = 13, .color = p.dim });
        } else {
            ui.icon(c, "magnifyingglass", .{ .size = 13, .color = p.faint });
        }
        const r = ui.textField(c, &a.field, .{
            .placeholder = "Paste a link, or search your downloads",
            .width = .fill,
            .size = 14,
            .bare = true,
            .color = p.ink,
            .placeholder_color = p.faint,
            .select_all_on_focus = false,
        });
        if (r.submitted) a.submit(c);
        if (a.field.text().len == 0 and a.preview.item == null) {
            // The clipboard's link, offered rather than taken.
            if (a.clipboard_link.len > 0) {
                if (ui.button(c, "Paste copied link", .{ .variant = .ghost, .size = 12 }).clicked) {
                    a.field.set(a.clipboard_link);
                    a.submit(c);
                }
            }
        } else if (a.field.text().len > 0) {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "xmark" }).clicked) {
                a.field.clear();
                a.clearPreview();
                c.changed = true;
            }
        }
    }

    // The browser, and settings: outside the field, on the same line.
    if (ui.button(c, "", .{ .variant = .ghost, .size = 13, .icon = "globe" }).clicked) {
        a.say("The browser opens a page and catches what it plays", c);
    }
    if (ui.button(c, "", .{ .variant = .ghost, .size = 13, .icon = "gearshape" }).clicked) {
        a.show_settings = true;
        c.changed = true;
    }
}

fn tabs(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const wrap = ui.div(c).wFull().column();
    defer wrap.end();
    {
        // The same column as the field above, so the first tab starts where
        // the field does rather than at the window's edge.
        const bar = ui.div(c).wFull().h(theme.metrics.tabs).row().itemsCenter().justifyCenter().px(theme.metrics.gutter);
        defer bar.end();
        const island = ui.div(c).row().itemsCenter().gap(2).w(islandWidth(c));
        defer island.end();
        const names = [_][]const u8{ "All", "Videos", "Audio", "Failed", "Subscriptions" };
        for (names, 0..) |name, i| {
            const on = a.tab == i;
            var t = ui.div(c).row().itemsCenter().gap(6).px(10).h(26).rounded(7).control();
            t = if (on) t.bg(p.raised).border(p.rule).borderW(1) else t.hover(p.well);
            const it = t.interaction();
            defer t.end();
            ui.text(c, name, .{ .size = 13, .weight = if (on) .medium else .regular, .color = if (on) p.ink else p.dim });
            if (i == 0 and a.lib.running() > 0) {
                ui.text(c, c.print("{d}", .{a.lib.running()}), .{ .size = 11, .color = p.accent, .tabular = true });
            }
            if (it.clicked and !on) {
                a.tab = i;
                a.lib.filter = library.Filter.ofIndex(i);
                a.lib.selected = null;
                c.changed = true;
            }
        }
        ui.spacer(c);
        // Clearing finished downloads belongs to the list, not to what is
        // followed.
        if (a.tab != 4 and a.lib.items.items.len > 0) {
            if (ui.button(c, "Clear finished", .{ .variant = .secondary, .size = 11 }).clicked) {
                _ = a.lib.clearFinished();
                a.save();
                c.changed = true;
            }
        }
    }
    // A hairline under the bar: without it the tabs float over the list and
    // the eye has no line to tell a header from its content.
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.rule }, .none, null);
}

fn list(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const area = ui.div(c).grow().wFull().column().itemsCenter().px(theme.metrics.gutter).pt(10).pb(8);
    defer area.end();
    const island = ui.div(c).grow().w(islandWidth(c)).column().gap(theme.metrics.row_gap);
    defer island.end();

    var buf: [512]usize = undefined;
    const shown = a.lib.rows(&buf);
    if (shown.len == 0) {
        empty(a, c, p);
        return;
    }
    // The overlay bar: it appears while the list moves and fades after, the
    // way a Mac list does. The default is a permanent black line down the
    // side, which reads as a border rather than something that can be dragged.
    const scroll = ui.div(c).grow().wFull().column().gap(theme.metrics.row_gap).scrollY().scrollbar(.{ .overlay = p.faint });
    defer scroll.end();
    for (shown) |i| {
        const d = &a.lib.items.items[i];
        rows.draw(a, c, p, d, i);
    }
}

fn empty(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    // A link is already open above: the list's own emptiness is not the
    // thing to say then.
    if (a.preview.item != null) return;
    const box = ui.div(c).grow().wFull().column().itemsCenter().justifyCenter().gap(10);
    defer box.end();
    ui.icon(c, "arrow.down.circle", .{ .size = 34, .color = p.faint });
    const line = if (a.lib.query.len > 0) "Nothing matches that search" else switch (a.lib.filter) {
        .failed => "Nothing has failed",
        .audio => "No audio yet",
        .videos => "No videos yet",
        else => "Paste a link to download it",
    };
    ui.text(c, line, .{ .size = 14, .color = p.dim });
    if (a.lib.query.len == 0 and a.lib.filter == .all) {
        ui.text(c, "Videos, audio and live streams, from any page that plays them", .{ .size = 12, .color = p.faint });
    }
}

fn footer(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    // The same column as everything above it: a folder path running to the
    // window's edge while the list stops at the island reads as two layouts.
    const bar = ui.div(c).wFull().h(theme.metrics.footer).row().itemsCenter().justifyCenter().px(theme.metrics.gutter).border(p.rule).borderW(1);
    defer bar.end();
    const island = ui.div(c).row().itemsCenter().gap(8).w(islandWidth(c));
    defer island.end();
    ui.icon(c, "folder", .{ .size = 12, .color = p.faint });
    {
        // The path takes what is left and no more. A text box with no width
        // of its own keeps its natural width, so a long folder pushed the
        // buttons past the island's right edge instead of shortening.
        const room = ui.div(c).grow().row().itemsCenter().clip();
        defer room.end();
        ui.text(c, a.folder, .{ .size = 11, .color = p.dim, .truncate = .ellipsis });
    }
    if (a.lib.queued() > 0) {
        ui.text(c, c.print("{d} waiting", .{a.lib.queued()}), .{ .size = 11, .color = p.faint, .tabular = true });
    }
    if (a.pro()) {
        ui.text(c, "Pro", .{ .size = 11, .weight = .medium, .color = p.accent });
    } else {
        const left = a.licence.trialDaysLeft(@import("now.zig").secs());
        if (left > 0) {
            ui.text(c, c.print("Trial: {d} days left", .{left}), .{ .size = 11, .color = p.faint, .tabular = true });
        } else if (ui.button(c, "Get Pro", .{ .variant = .secondary, .size = 11 }).clicked) {
            a.show_settings = true;
            a.settings_tab = 5;
            c.changed = true;
        }
    }
}

fn subscriptions(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const area = ui.div(c).grow().wFull().column().px(theme.metrics.gutter).gap(6).scrollY();
    defer area.end();
    if (a.subs.items.items.len == 0) {
        const box = ui.div(c).grow().wFull().column().itemsCenter().justifyCenter().gap(10);
        defer box.end();
        ui.icon(c, "arrow.triangle.branch", .{ .size = 32, .color = p.faint });
        ui.text(c, "No subscriptions yet", .{ .size = 14, .color = p.dim });
        ui.text(c, "A channel or a playlist you follow shows its new videos here", .{ .size = 12, .color = p.faint });
        return;
    }
    for (a.subs.items.items) |*s| {
        const row = ui.div(c).wFull().row().itemsCenter().gap(10).p(10).rounded(theme.metrics.radius).bg(p.raised).border(p.rule).borderW(1);
        defer row.end();
        ui.icon(c, "arrow.triangle.branch", .{ .size = 15, .color = p.accent });
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        ui.text(c, s.title, .{ .size = 13, .weight = .medium, .color = p.ink, .truncate = .ellipsis });
        ui.text(c, c.print("{s} · {s}", .{ s.site.title(), s.as.label() }), .{ .size = 11, .color = p.faint });
        if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) {
            a.subs.remove(s.id);
            c.changed = true;
        }
    }
}

fn toast(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const box = ui.div(c).absolute().offset(theme.metrics.field_left, theme.metrics.top + 6).row().itemsCenter().gap(8).px(12).py(8).rounded(9).bg(p.ink).shadow(.{ .color = p.scrim, .blur = 16, .y = 4 });
    defer box.end();
    ui.text(c, a.toast, .{ .size = 12, .color = p.paper });
    // It goes on its own.
    c.animationFrame();
}

/// The sheet that asks about downloads still running.
fn quitSheet(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).bg(p.scrim).itemsCenter().justifyCenter();
    defer scrim.end();
    const card = ui.div(c).w(380).column().gap(12).p(20).rounded(14).bg(p.raised).shadow(.{ .color = p.scrim, .blur = 30, .y = 10 });
    defer card.end();
    ui.text(c, "Downloads are still running", .{ .size = 15, .weight = .semibold, .color = p.ink });
    ui.text(c, "Quitting stops them. They pick up where they left off next time.", .{ .size = 12, .color = p.dim, .wrap = true });
    const row = ui.div(c).row().gap(8).justifyEnd();
    defer row.end();
    if (ui.button(c, "Keep downloading", .{ .variant = .ghost, .size = 13 }).clicked) {
        a.ask_quit = false;
        c.changed = true;
    }
    if (ui.button(c, "Quit anyway", .{ .variant = .danger, .size = 13 }).clicked) {
        a.ask_quit = false;
        if (a.window) |w| w.close();
    }
}
