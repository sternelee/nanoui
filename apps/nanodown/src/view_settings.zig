//! Settings, over the window: the tabs down the side, the rows for the tab
//! chosen, and the licence at the end. A Pro row wears a lock while the app
//! is free.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const settings = @import("model/settings.zig");
const license = @import("model/license.zig");

const tabs = [_][]const u8{ "General", "Formats", "Network", "Browser", "Command Line", "License" };

pub fn draw(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    // The scrim covers the window and takes the click that closes it. It is
    // fixed, so it is placed from the window's own corner rather than laid
    // out by a parent.
    const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).bg(p.scrim);
    const back_it = back.interaction();
    defer back.end();
    if (back_it.clicked) {
        a.show_settings = false;
        c.changed = true;
        return;
    }

    // The card is centered by hand: a fixed box is not laid out by its
    // parent, so `itemsCenter` on a wrapper would not move it.
    const w: f32 = @min(620, c.size.w - 32);
    // Tall enough for the longest tab: General has a dozen rows, and a card
    // that stops short of them clips the last one against its own edge.
    const h: f32 = @min(560, c.size.h - 48);
    const card = ui.div(c).fixed().offset((c.size.w - w) / 2, (c.size.h - h) / 2).w(w).h(h).row().itemsStretch().rounded(14).bg(p.raised).shadow(.{ .color = p.scrim, .blur = 40, .y = 14 }).clip();
    defer card.end();

    side(a, c, p);
    // A hairline between the tabs and the body: without it the two columns
    // are told apart only by their backgrounds, which is a very quiet line.
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = p.rule }, .none, null);
    // The right column fills the card's height, so the body under the head
    // has the rest of it to scroll in.
    const right = ui.div(c).column().grow().hFull().gap(0);
    defer right.end();
    head(a, c, p);
    body(a, c, p);
}

fn side(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const col = ui.div(c).w(150).hFull().column().itemsStart().gap(2).p(10).bg(p.well);
    defer col.end();
    for (tabs, 0..) |name, i| {
        const on = a.settings_tab == i;
        var item = ui.div(c).row().itemsCenter().h(28).px(9).rounded(6).control();
        item = if (on) item.bg(p.raised) else item.hover(p.rule);
        const it = item.interaction();
        defer item.end();
        ui.text(c, name, .{ .size = 12, .weight = if (on) .medium else .regular, .color = if (on) p.ink else p.dim });
        if (it.clicked and !on) {
            a.settings_tab = i;
            c.changed = true;
        }
    }
}

fn head(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const bar = ui.div(c).wFull().h(46).row().itemsCenter().px(16).gap(8).border(p.rule).borderW(1);
    _ = &bar;
    defer bar.end();
    ui.text(c, tabs[a.settings_tab], .{ .size = 14, .weight = .semibold, .color = p.ink });
    ui.spacer(c);
    if (ui.button(c, "", .{ .variant = .ghost, .size = 13, .icon = "xmark" }).clicked) {
        a.show_settings = false;
        a.save();
        c.changed = true;
    }
}

fn body(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const area = ui.div(c).grow().wFull().column().gap(2).p(16).scrollY().scrollbar(.{ .overlay = p.faint });
    defer area.end();
    if (a.settings_tab == 5) {
        licence(a, c, p);
        return;
    }
    const tab: settings.Setting.Tab = switch (a.settings_tab) {
        0 => .general,
        1 => .formats,
        2 => .network,
        3 => .browser,
        else => .command_line,
    };
    for (settings.all) |s| {
        if (s.tab != tab) continue;
        settingRow(a, c, p, s);
    }
    if (tab == .command_line) commandLine(a, c, p);
    if (tab == .general) whereKept(a, c, p);
    // Room under the last row, so a scrolled-to-the-end tab does not end with
    // a line sliced by the card's own edge.
    const pad = ui.div(c).wFull().h(12);
    defer pad.end();
}

fn settingRow(a: *App, c: *ui.Context, p: *const theme.Palette, s: settings.Setting) void {
    const locked = s.pro and !a.pro();
    // A choice with several options needs the width of the card, so its
    // options go under the label: side by side, the options squeeze the
    // label until it reads "Check for new vi…".
    const stacked = s.kind == .choice and s.choices.len > 2;
    const line = ui.div(c).wFull().column().gap(6).py(7);
    defer line.end();
    {
        // The label row, in its own scope: a `defer` that ended it at the
        // function's end would draw the controls inside it.
        const top = ui.div(c).wFull().row().itemsCenter().gap(10);
        defer top.end();
        {
            // The label column takes the rest of the row, so every control
            // lands on the same right edge. Its own scope matters twice over:
            // a `defer` left to the block's end keeps the control inside this
            // column, where it drops under the label at the left edge.
            const col = ui.div(c).column().grow().gap(1);
            defer col.end();
            const title = ui.div(c).row().itemsCenter().gap(5);
            defer title.end();
            ui.text(c, s.label, .{ .size = 12, .color = if (locked) p.faint else p.ink, .truncate = .ellipsis });
            if (s.pro) {
                ui.text(c, "Pro", .{ .size = 9, .weight = .medium, .color = if (a.pro()) p.good else p.accent });
            }
        }
        if (s.kind == .flag) {
            toggle(a, c, p, s, locked);
            return;
        }
        if (s.kind == .choice and !stacked) {
            choice(a, c, p, s, locked);
            return;
        }
        if (s.kind == .number) {
            number(a, c, p, s, locked);
            return;
        }
    }
    if (s.kind == .choice) {
        // Under the label, with the whole card's width for its options.
        choice(a, c, p, s, locked);
        return;
    }
    // Text: the folder, a template, a proxy. Under the label and across the
    // card: a path is long, and a short field beside the label left most of
    // the row empty.
    const buf = textBuffer(a, s.key);
    const r = ui.textField(c, buf, .{ .width = .fill, .size = 11, .placeholder = s.default, .color = p.ink });
    if (r.changed) {
        a.values.set(s.key, buf.text()) catch {};
        if (std.mem.eql(u8, s.key, "save_to")) {
            // The library's folder is the setting: the footer reads it, and
            // the next download goes there.
            a.gpa.free(a.folder);
            a.folder = a.gpa.dupe(u8, if (buf.text().len > 0) buf.text() else a.values.get("save_to")) catch "";
        }
        c.changed = true;
    }
}

fn toggle(a: *App, c: *ui.Context, p: *const theme.Palette, s: settings.Setting, locked: bool) void {
    const on = a.values.flag(s.key);
    const box = ui.div(c).w(34).h(20).rounded(10).bg(if (on) (if (locked) p.faint else p.accent) else p.rule).control();
    const it = box.interaction();
    defer box.end();
    const knob = ui.div(c).absolute().offset(if (on) 16 else 2, 2).w(16).h(16).rounded(8).bg(p.raised).shadow(.{ .color = p.scrim, .blur = 2, .y = 1 });
    defer knob.end();
    if (it.clicked) {
        if (locked) {
            a.say("That one is Pro", c);
            return;
        }
        a.values.set(s.key, if (on) "false" else "true") catch {};
        c.changed = true;
    }
}

fn choice(a: *App, c: *ui.Context, p: *const theme.Palette, s: settings.Setting, locked: bool) void {
    const current = a.values.get(s.key);
    const chips = ui.div(c).row().itemsCenter().gap(4);
    defer chips.end();
    for (s.choices) |name| {
        const on = std.mem.eql(u8, name, current);
        var chip = ui.div(c).px(8).h(22).itemsCenter().justifyCenter().rounded(5).control();
        chip = if (on) chip.bg(p.accent) else chip.bg(p.well).hover(p.rule);
        const it = chip.interaction();
        defer chip.end();
        ui.text(c, name, .{ .size = 10, .color = if (on) p.on_accent else if (locked) p.faint else p.dim });
        if (it.clicked and !on) {
            if (locked) {
                a.say("That one is Pro", c);
                return;
            }
            a.values.set(s.key, name) catch {};
            c.changed = true;
        }
    }
}

fn number(a: *App, c: *ui.Context, p: *const theme.Palette, s: settings.Setting, locked: bool) void {
    const v = a.values.number(s.key);
    const top = settings.ceiling(s.key, a.pro());
    const stepper = ui.div(c).row().itemsCenter().gap(6);
    defer stepper.end();
    if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "minus", .disabled = v == 0 }).clicked) {
        a.values.set(s.key, c.print("{d}", .{v -| 1})) catch {};
        c.changed = true;
    }
    ui.text(c, c.print("{d}", .{v}), .{ .size = 12, .color = if (locked) p.faint else p.ink, .tabular = true });
    if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "plus", .disabled = v >= top }).clicked) {
        a.values.set(s.key, c.print("{d}", .{@min(v + 1, top)})) catch {};
        c.changed = true;
    }
    if (top > 0) ui.text(c, c.print("max {d}", .{top}), .{ .size = 10, .color = p.faint, .tabular = true });
}

/// The licence: the trial, the key, and what Pro adds.
fn licence(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const now = @import("now.zig").secs();
    const col = ui.div(c).wFull().column().gap(10);
    defer col.end();
    ui.text(c, if (a.pro()) "Pro" else "Free", .{ .size = 16, .weight = .semibold, .color = p.ink });
    if (a.pro()) {
        ui.text(c, "Every format, every connection, the command line and the AI agent.", .{ .size = 11, .color = p.dim, .wrap = true });
        if (a.licence.key.len > 0) {
            ui.text(c, c.print("Key {s}", .{a.licence.key}), .{ .size = 11, .color = p.faint, .mono = true });
        }
        if (ui.button(c, "Deactivate this computer", .{ .variant = .ghost, .size = 12 }).clicked) {
            a.licence.deactivate();
            a.save();
            c.changed = true;
        }
        return;
    }
    const left = a.licence.trialDaysLeft(now);
    if (left > 0) {
        ui.text(c, c.print("{d} days of Pro left in the trial", .{left}), .{ .size = 12, .color = p.accent, .tabular = true });
    } else {
        ui.text(c, "The trial has ended. Everything below is Pro.", .{ .size = 12, .color = p.dim, .wrap = true });
        if (ui.button(c, "Start the 14-day trial", .{ .variant = .primary, .size = 12 }).clicked) {
            _ = a.licence.startTrial(now) catch false;
            a.save();
            c.changed = true;
        }
    }
    const adds = [_][]const u8{
        "MP3, FLAC, Opus, WAV, MKV and MOV",
        "8 downloads at once, 16 connections each",
        "A folder for each site and each playlist",
        "Your own file names, and media server folders",
        "Channels and playlists you follow",
        "Recording a live stream",
        "The nanodown command, and the AI agent",
    };
    for (adds) |line| {
        const r = ui.div(c).row().itemsCenter().gap(7);
        defer r.end();
        ui.icon(c, "checkmark", .{ .size = 10, .color = p.good });
        ui.text(c, line, .{ .size = 11, .color = p.dim });
    }
    ui.text(c, "$19 once, for three computers. $9.50 until 14 November.", .{ .size = 11, .color = p.faint });
    const keyRow = ui.div(c).row().itemsCenter().gap(8);
    defer keyRow.end();
    _ = ui.textField(c, &a.key_field, .{ .width = .{ .px = 240 }, .size = 12, .placeholder = "Your key", .mono = true, .color = p.ink });
    if (ui.button(c, "Activate", .{ .variant = .primary, .size = 12 }).clicked) {
        a.licence.activate(a.key_field.text(), now) catch |e| {
            a.say(switch (e) {
                error.BadKey => "That key isn't right",
                error.TooManyComputers => "That key is on three computers already",
                else => "That key didn't work",
            }, c);
            return;
        };
        a.save();
        a.say("Pro is on", c);
    }
}

fn commandLine(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const box = ui.div(c).wFull().column().gap(6).p(10).rounded(8).bg(p.well);
    defer box.end();
    ui.text(c, "The nanodown command", .{ .size = 12, .weight = .medium, .color = p.ink });
    ui.text(c, "The app is the command: with arguments it runs them, without it opens the window. It uses these settings and these sign-ins, and what it downloads shows in the library.", .{ .size = 11, .color = p.dim, .wrap = true });
    const code = ui.div(c).wFull().p(8).rounded(6).bg(p.paper);
    defer code.end();
    ui.text(c, "nanodown get https://youtu.be/… -q 1080 -o ~/Movies", .{ .size = 11, .mono = true, .color = p.ink, .truncate = .ellipsis });
    if (ui.button(c, "Install the nanodown command", .{ .variant = .secondary, .size = 12 }).clicked) {
        a.say("Put it in /usr/local/bin, or link it from ~/.local/bin", c);
    }
}

fn whereKept(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const box = ui.div(c).wFull().column().gap(4).p(10).rounded(8).bg(p.well);
    defer box.end();
    ui.text(c, "Where they're kept", .{ .size = 12, .weight = .medium, .color = p.ink });
    ui.text(c, a.folder, .{ .size = 11, .mono = true, .color = p.dim, .truncate = .ellipsis });
    if (ui.button(c, "Open the folder", .{ .variant = .ghost, .size = 11 }).clicked) {
        _ = nanoui.shell.openPath(a.folder);
    }
}

/// The buffer a text setting types into. It lives on the app and is filled
/// once: a buffer rebuilt from the value every frame would put the caret back
/// at the start and lose a keystroke between the value being stored and the
/// next frame. `save_to` starts from the folder the app already resolved,
/// which is where downloads actually go.
fn textBuffer(a: *App, key: []const u8) *ui.TextBuffer {
    for (settings.text_fields, 0..) |k, i| {
        if (!std.mem.eql(u8, k, key)) continue;
        const buf = &a.settings_text[i];
        if (!a.settings_text_filled[i]) {
            const start = if (std.mem.eql(u8, key, "save_to") and a.folder.len > 0)
                a.folder
            else
                a.values.get(key);
            buf.set(start);
            a.settings_text_filled[i] = true;
        }
        return buf;
    }
    // Not a text setting: nothing to type into. The caller only reaches here
    // for one, so the first buffer is as good a fallback as any.
    return &a.settings_text[0];
}
