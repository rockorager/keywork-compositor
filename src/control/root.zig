//! Private API contract shared by Keywork's control server and client.

pub const interface_name = "dev.rockorager.keywork.compositor";
pub const socket_name = interface_name;
pub const environment_name = "KEYWORK_CONTROL";
pub const interface_description = @embedFile("control-interface");

pub const Direction = enum { next, previous, left, down, up, right };
pub const Layout = enum { master_stack, dwindle, scrolling };

pub const focus_method = interface_name ++ ".Focus";
pub const move_focused_method = interface_name ++ ".MoveFocused";
pub const set_layout_method = interface_name ++ ".SetLayout";
pub const switch_workspace_method = interface_name ++ ".SwitchWorkspace";
pub const move_focused_to_workspace_method = interface_name ++ ".MoveFocusedToWorkspace";

pub const minimum_workspace = 1;
pub const maximum_workspace = 10;

pub fn validWorkspace(workspace: i64) bool {
    return workspace >= minimum_workspace and workspace <= maximum_workspace;
}
