//! A notch app: an island in the row across the top of the screen that the
//! menu bar shares with the notch. The window is borderless and
//! transparent, at the menu bar's own level (`.level = .island`), as tall as
//! that row (`nanoui.screens.mainScreen()`) and centered where the notch is;
//! under the pointer it spreads open, wide and down, and shows more. On a
//! Mac without a notch it is the same island, floating in the menu bar's
//! row.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "notch" });
    defer app.destroy();
    const scr = nanoui.screens.mainScreen() orelse return error.NoScreen;
    const w = 420.0;
    // The notch's own row where there is one, the menu bar's otherwise,
    // and room below it for the island to spread into.
    const row_h = @max(32, scr.menuBarHeight());
    const open_h = row_h + 46;
    var isle: Island = .{ .row_h = @floatCast(row_h), .open_h = @floatCast(open_h) };
    _ = try app.newWindow(.{
        .title = "notch",
        .width = w,
        .height = open_h,
        .x = (scr.frame.width - w) / 2,
        .y = 0,
        .resizable = false,
        .decorations = false,
        .kind = .panel,
        .non_activating = true,
        .all_spaces = true,
        .skip_taskbar = true,
        .level = .island,
        .transparent = true,
        .content = .{ .view = .init(&isle, Island.view) },
    });
    try app.run();
}

const dark: ui.Color = .hex(0x0e0e12);
const white: ui.Color = .hex(0xf2f2f7);
const gray: ui.Color = .hex(0xb0b0ba);

const Island = struct {
    row_h: f32,
    open_h: f32,

    fn view(is: *Island, c: *ui.Context) void {
        const closed: f32 = 190;
        // Closed, a notch's width, moved to the middle of the window; under
        // the pointer, the window's whole width, in one spring.
        const f = ui.motion.frame(c, .{
            .target = .{ .x = (c.size.w - closed) / 2, .width = closed },
            .hover = .{ .x = 0, .width = c.size.w },
            .press = .{ .scale = 0.97 },
            .transition = .{ .spring = ui.motion.Spring.visual(0.22, 0) },
        });
        // The notch is cut from the screen's top edge: square along it, no
        // border line where it meets the screen, rounded only underneath —
        // a square piece over a same-colored capsule, their overlap hiding
        // the capsule's upper rounding.
        const isle = ui.div(c).absolute().w(closed).row().itemsCenter().clip().control().motion(f)
            // Pressing shrinks it from the screen's top edge, not about its
            // middle: a middle-anchored shrink lifts the island's top off
            // that edge and opens a seam over the menu bar.
            .scaleAnchor(0.5, 0);
        defer isle.end();
        // The island's own height, from the notch's row to the open one, in
        // the same spring as its width; the shape and the content follow it.
        const open = isle.hovered();
        const ih = ui.motion.number(c, "h", if (open) is.open_h else is.row_h, .{ .spring = ui.motion.Spring.visual(0.22, 0) });
        _ = isle.h(ih);
        const r: f32 = 16; // the bottom's rounding, half the closed row
        ui.div(c).absolute().offset(0, 0).wFull().h(ih - r).bg(dark).end();
        ui.div(c).absolute().offset(0, ih - 2 * r).wFull().h(2 * r).roundedFull().bg(dark).end();
        const content = ui.div(c).column().px(16).pt(8).pb(10).gap(10).sizeFull();
        defer content.end();
        {
            const line = ui.div(c).row().itemsCenter().gap(10);
            defer line.end();
            ui.icon(c, "music.note", .{ .size = 13, .color = white });
            ui.text(c, "Notch Radio", .{ .size = 12, .weight = .semibold, .color = white });
            ui.div(c).grow().end();
            // The controls, seen once the island is open.
            const of = ui.motion.frame(c, .{
                .target = .{ .opacity = if (open) 1.0 else 0.0 },
                .transition = .{ .tween = .{ .duration = 0.15, .ease = .ease_out } },
            });
            const controls = ui.div(c).row().itemsCenter().gap(14).motion(of);
            defer controls.end();
            ui.icon(c, "backward.fill", .{ .size = 12, .color = gray });
            ui.icon(c, "play.fill", .{ .size = 13, .color = white });
            ui.icon(c, "forward.fill", .{ .size = 12, .color = gray });
        }
        // Under the pointer: what is playing, and how far.
        if (ui.motion.present(c, "more", open and ih > is.row_h + 26, .{
            .initial = .{ .y = 10, .opacity = 0 },
            .exit = .{ .opacity = 0 },
            .transition = .{ .tween = .{ .duration = 0.15, .ease = .ease_out } },
        })) |mf| {
            const more = ui.div(c).column().gap(6).motion(mf);
            defer more.end();
            {
                const track = ui.div(c).wFull().h(4).bg(.hex(0x2c2c33)).rounded(2);
                defer track.end();
                ui.div(c).absolute().offset(0, 0).h(4).w(120).bg(white).rounded(2).end();
            }
            const labels = ui.div(c).row().itemsCenter().justifyBetween().wFull();
            defer labels.end();
            ui.text(c, "0:42", .{ .size = 11, .color = gray });
            ui.text(c, "Play Queue · nanoui", .{ .size = 11, .color = gray });
            ui.text(c, "-2:13", .{ .size = 11, .color = gray });
        }
    }
};
