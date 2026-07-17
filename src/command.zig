//! Typed commands understood by the built-in compositor policy.

pub const Command = union(enum) {
    focus_next,
    focus_previous,
    move_focused_next,
    move_focused_previous,
    layout_tiled,
    layout_scrolling,
    switch_workspace: u8,
    move_to_workspace: u8,
};
