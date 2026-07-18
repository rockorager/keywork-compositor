//! Typed commands understood by the built-in compositor policy.

pub const Direction = enum {
    left,
    down,
    up,
    right,
};

pub const WindowTarget = enum {
    focused,
};

pub const Command = union(enum) {
    focus_next,
    focus_previous,
    focus_direction: Direction,
    move_focused_next,
    move_focused_previous,
    move_focused_direction: Direction,
    close: WindowTarget,
    toggle_fullscreen: WindowTarget,
    toggle_floating: WindowTarget,
    layout_master_stack,
    layout_dwindle,
    layout_scrolling,
    switch_workspace: u8,
    move_to_workspace: u8,
};
