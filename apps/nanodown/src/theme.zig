//! nanodown's colors and measures, in nanomon's palette: warm charcoal in
//! dark and cream in light, amber for what is chosen and for what is
//! running, rust for what failed, sage for what finished. One hairline rule,
//! and the amber is the only saturated color in the window.
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    /// The window's ground.
    paper: ui.Color,
    /// A card, a row, a field.
    raised: ui.Color,
    /// A track, a well, an inset.
    well: ui.Color,
    /// Hairlines and separators.
    rule: ui.Color,
    /// The text.
    ink: ui.Color,
    /// The second line of a row.
    dim: ui.Color,
    /// A third line, a placeholder, a disabled label.
    faint: ui.Color,
    /// The one saturated color: the logo's warm orange.
    accent: ui.Color,
    /// The accent's hover.
    accent_hover: ui.Color,
    /// Text on the accent.
    on_accent: ui.Color,
    /// A download that finished.
    good: ui.Color,
    /// A download that failed.
    bad: ui.Color,
    /// A row that is picked: the accent, let into the ground.
    selection: ui.Color,
    /// A progress bar's groove, and a control's own ground.
    track: ui.Color,
    /// The overlay behind a sheet.
    scrim: ui.Color,
};

pub const light: Palette = .{
    .paper = .hex(0xfaf8f3),
    .raised = .hex(0xf0ece3),
    .well = .hex(0xe9e3d6),
    .rule = .hex(0xe4ded1),
    .ink = .hex(0x1a1813),
    .dim = .hex(0x6b6557),
    .faint = .hex(0xa8a090),
    .accent = .hex(0xc77d20),
    .accent_hover = .hex(0xa8691a),
    .on_accent = .hex(0xfffdf8),
    .good = .hex(0x5c7e47),
    .bad = .hex(0xb14228),
    .selection = .hex(0xf1e2cd),
    .track = .hex(0xebe5d9),
    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 0.28 },
};

pub const dark: Palette = .{
    .paper = .hex(0x16140f),
    .raised = .hex(0x1f1c16),
    .well = .hex(0x191712),
    .rule = .hex(0x2a271f),
    .ink = .hex(0xedeae2),
    .dim = .hex(0x9a9384),
    .faint = .hex(0x5c564b),
    .accent = .hex(0xe8a33d),
    .accent_hover = .hex(0xf2b455),
    .on_accent = .hex(0x16140f),
    .good = .hex(0x7fa86b),
    .bad = .hex(0xd2674f),
    .selection = .hex(0x403118),
    .track = .hex(0x221f19),
    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 0.5 },
};

pub fn of(c: *const ui.Context) *const Palette {
    return if (c.theme.dark) &dark else &light;
}

pub const metrics = struct {
    /// The top bar: the traffic lights and the field.
    pub const top: f32 = 52;
    /// Where the close button's center goes, from the window's top left.
    pub const lights_center: f32 = 26;
    /// The field starts past the lights.
    pub const field_left: f32 = 100;
    /// The library's tabs.
    pub const tabs: f32 = 44;
    /// The footer: the folder and its free space.
    pub const footer: f32 = 34;
    /// A row's picture.
    pub const thumb_w: f32 = 128;
    pub const thumb_h: f32 = 72;
    /// A row is as tall as its picture plus its padding, whatever its text
    /// does: rows that size themselves to their content come out ragged.
    pub const row_h: f32 = thumb_h + 20;
    /// A row's height, and the air around it.
    pub const row: f32 = 96;
    pub const row_gap: f32 = 8;
    /// The page's own margin.
    pub const gutter: f32 = 20;
    /// The widest the field and the list go. A window dragged wide keeps its
    /// content in a column instead of stretching a search box across it.
    pub const island: f32 = 640;
    /// A card's radius, and a picture's.
    pub const radius: f32 = 12;
    pub const thumb_radius: f32 = 8;
};

/// The fonts, as nanomon names them: Geist for words, JetBrains Mono for
/// figures. Both fall back to the system's own if they are not installed.
pub const font = "Geist";
pub const mono_font = "JetBrains Mono";

/// A size of text, as the site uses them.
pub const type_scale = struct {
    pub const title: f32 = 15;
    pub const body: f32 = 13;
    pub const small: f32 = 12;
    pub const tiny: f32 = 11;
    pub const display: f32 = 22;
};
