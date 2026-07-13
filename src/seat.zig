//! Wayland seat global and capability boundary.

const Self = @This();

const wayland = @import("wayland");

const wl = wayland.server.wl;

global: *wl.Global,

pub fn init(self: *Self, display: *wl.Server) !void {
    self.global = try wl.Global.create(display, wl.Seat, 10, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    return self.global.getName(client);
}

pub fn ownsResource(self: *Self, resource: *wl.Seat) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Seat.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
    if (version >= wl.Seat.name_since_version) resource.sendName("seat0");
    resource.sendCapabilities(.{});
}

fn handleRequest(resource: *wl.Seat, request: wl.Seat.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
        .get_pointer, .get_keyboard, .get_touch => resource.postError(
            .missing_capability,
            "seat does not currently provide this input capability",
        ),
    }
}
