//! nanodown's colors and measures, read off the site's own stylesheet:
//! a warm paper in light, a near-black in dark, one hairline rule, and a
//! single warm accent that is the only saturated color in the window.
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
    /// The overlay behind a sheet.
    scrim: ui.Color,
};

pub const light: Palette = .{
    .paper = .hex(0xf7f6f3),
    .raised = .hex(0xffffff),
    .well = .hex(0xefede8),
    .rule = .hex(0xe4e2dc),
    .ink = .hex(0x141414),
    .dim = .hex(0x7a7975),
    .faint = .hex(0xa8a6a0),
    .accent = .hex(0xf4622f),
    .accent_hover = .hex(0xdd4f1e),
    .on_accent = .hex(0xffffff),
    .good = .hex(0x2f9e5f),
    .bad = .hex(0xd23f3f),
    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 0.28 },
};

pub const dark: Palette = .{
    .paper = .hex(0x111110),
    .raised = .hex(0x1d1d1c),
    .well = .hex(0x1a1a19),
    .rule = .hex(0x262624),
    .ink = .hex(0xecebe8),
    .dim = .hex(0x8a8985),
    .faint = .hex(0x5c5b58),
    .accent = .hex(0xff6b35),
    .accent_hover = .hex(0xff8250),
    .on_accent = .hex(0x141414),
    .good = .hex(0x4ecb71),
    .bad = .hex(0xff5f56),
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

/// A size of text, as the site uses them.
pub const type_scale = struct {
    pub const title: f32 = 15;
    pub const body: f32 = 13;
    pub const small: f32 = 12;
    pub const tiny: f32 = 11;
    pub const display: f32 = 22;
};
