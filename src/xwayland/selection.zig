//! X11 and Wayland selection interoperability.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../wayland/data_device.zig");
const PrimarySelection = @import("../wayland/primary_selection.zig");
const c = @import("xcb.zig").c;

const wl = wayland.server.wl;
const log = std.log.scoped(.xwayland_selection);

const max_direct_transfer_size = 64 * 1024;
const invalid_fd: std.posix.fd_t = -1;

allocator: std.mem.Allocator,
event_loop: *wl.EventLoop,
connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
atoms: Atoms,
wayland_selection: WaylandSelection,
window: c.xcb_window_t,
transfers: std.ArrayList(*OutgoingTransfer),

pub const Atoms = struct {
    selection: c.xcb_atom_t,
    targets: c.xcb_atom_t,
    utf8_string: c.xcb_atom_t,
    text: c.xcb_atom_t,
};

pub const WaylandSelection = union(enum) {
    clipboard: *DataDevice,
    primary: *PrimarySelection,

    fn addListener(self: WaylandSelection, listener: DataDevice.SelectionListener) !void {
        switch (self) {
            .clipboard => |selection| try selection.addSelectionListener(listener),
            .primary => |selection| try selection.addSelectionListener(.{
                .context = listener.context,
                .changed = listener.changed,
                .offered = listener.offered,
            }),
        }
    }

    fn removeListener(self: WaylandSelection, context: *anyopaque) void {
        switch (self) {
            .clipboard => |selection| selection.removeSelectionListener(context),
            .primary => |selection| selection.removeSelectionListener(context),
        }
    }

    fn hasSelection(self: WaylandSelection) bool {
        return switch (self) {
            .clipboard => |selection| selection.hasSelection(),
            .primary => |selection| selection.hasSelection(),
        };
    }

    fn mimeTypes(self: WaylandSelection) []const [:0]const u8 {
        return switch (self) {
            .clipboard => |selection| selection.selectionMimeTypes(),
            .primary => |selection| selection.selectionMimeTypes(),
        };
    }

    fn send(self: WaylandSelection, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        switch (self) {
            .clipboard => |selection| selection.sendSelection(mime_type, fd),
            .primary => |selection| selection.sendSelection(mime_type, fd),
        }
    }
};

const OutgoingTransfer = struct {
    selection: *Self,
    request: c.xcb_selection_request_event_t,
    property: c.xcb_atom_t,
    fd: std.posix.fd_t,
    event_source: *wl.EventSource,
    data: std.ArrayList(u8) = .empty,

    fn destroy(self: *OutgoingTransfer) void {
        const selection = self.selection;
        self.event_source.remove();
        closeFd(&self.fd);
        self.data.deinit(selection.allocator);
        for (selection.transfers.items, 0..) |transfer, index| {
            if (transfer != self) continue;
            _ = selection.transfers.swapRemove(index);
            break;
        }
        selection.allocator.destroy(self);
    }

    fn fail(self: *OutgoingTransfer) void {
        self.selection.sendNotify(self.request, c.XCB_ATOM_NONE);
        self.destroy();
    }

    fn finish(self: *OutgoingTransfer) void {
        _ = c.xcb_change_property(
            self.selection.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.request.requestor,
            self.property,
            self.request.target,
            8,
            @intCast(self.data.items.len),
            if (self.data.items.len == 0) null else self.data.items.ptr,
        );
        self.selection.sendNotify(self.request, self.property);
        self.destroy();
    }

    fn readable(_: std.posix.fd_t, mask: wl.EventMask, self: *OutgoingTransfer) c_int {
        if (!(mask.readable or mask.hangup or mask.@"error")) return 0;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = std.c.read(self.fd, &buffer, buffer.len);
            if (result > 0) {
                const count: usize = @intCast(result);
                if (self.data.items.len + count > max_direct_transfer_size) {
                    log.warn("X11 selection transfer requires unsupported INCR transport", .{});
                    self.fail();
                    return 0;
                }
                self.data.appendSlice(self.selection.allocator, buffer[0..count]) catch {
                    self.fail();
                    return 0;
                };
                continue;
            }
            if (result == 0) {
                self.finish();
                return 0;
            }
            switch (std.posix.errno(result)) {
                .INTR => continue,
                .AGAIN => {
                    if (mask.hangup or mask.@"error") self.fail();
                    return 0;
                },
                else => {
                    self.fail();
                    return 0;
                },
            }
        }
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    connection: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    atoms: Atoms,
    wayland_selection: WaylandSelection,
) !void {
    self.* = .{
        .allocator = allocator,
        .event_loop = event_loop,
        .connection = connection,
        .screen = screen,
        .atoms = atoms,
        .wayland_selection = wayland_selection,
        .window = c.xcb_generate_id(connection),
        .transfers = .empty,
    };
    if (self.window == c.XCB_WINDOW_NONE) return error.XidAllocationFailed;
    errdefer self.transfers.deinit(allocator);
    const event_mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    try checkRequest(connection, c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        self.window,
        screen.root,
        0,
        0,
        10,
        10,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        c.XCB_CW_EVENT_MASK,
        &event_mask,
    ));
    errdefer _ = c.xcb_destroy_window(connection, self.window);
    try wayland_selection.addListener(.{
        .context = self,
        .changed = waylandSelectionChanged,
        .offered = waylandMimeOffered,
    });
    errdefer wayland_selection.removeListener(self);
    self.updateOwner();
}

pub fn deinit(self: *Self) void {
    self.wayland_selection.removeListener(self);
    while (self.transfers.items.len > 0) {
        self.transfers.items[self.transfers.items.len - 1].destroy();
    }
    self.releaseOwnership();
    _ = c.xcb_destroy_window(self.connection, self.window);
    _ = c.xcb_flush(self.connection);
    self.transfers.deinit(self.allocator);
    self.* = undefined;
}

pub fn handlesSelection(self: *const Self, atom: c.xcb_atom_t) bool {
    return self.atoms.selection == atom;
}

pub fn handleRequest(self: *Self, request: *const c.xcb_selection_request_event_t) void {
    if (request.owner != self.window or request.selection != self.atoms.selection) return;
    if (!self.wayland_selection.hasSelection()) {
        self.sendNotify(request.*, c.XCB_ATOM_NONE);
        return;
    }
    const property = if (request.property == c.XCB_ATOM_NONE) request.target else request.property;
    if (request.target == self.atoms.targets) {
        self.sendTargets(request.*, property);
    } else {
        self.sendData(request.*, property);
    }
}

pub fn handleRequestorDestroyed(self: *Self, window: c.xcb_window_t) void {
    var index: usize = 0;
    while (index < self.transfers.items.len) {
        const transfer = self.transfers.items[index];
        if (transfer.request.requestor == window) {
            transfer.destroy();
        } else {
            index += 1;
        }
    }
}

fn waylandSelectionChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.updateOwner();
}

fn waylandMimeOffered(_: *anyopaque, _: [*:0]const u8) void {}

fn updateOwner(self: *Self) void {
    if (!self.wayland_selection.hasSelection()) {
        self.releaseOwnership();
        _ = c.xcb_flush(self.connection);
        return;
    }
    _ = c.xcb_set_selection_owner(
        self.connection,
        self.window,
        self.atoms.selection,
        c.XCB_CURRENT_TIME,
    );
    if (c.xcb_flush(self.connection) <= 0) {
        log.err("failed to update X11 selection ownership", .{});
    }
}

fn releaseOwnership(self: *Self) void {
    const reply = c.xcb_get_selection_owner_reply(
        self.connection,
        c.xcb_get_selection_owner(self.connection, self.atoms.selection),
        null,
    ) orelse return;
    defer std.c.free(reply);
    if (reply.*.owner != self.window) return;
    _ = c.xcb_set_selection_owner(
        self.connection,
        c.XCB_WINDOW_NONE,
        self.atoms.selection,
        c.XCB_CURRENT_TIME,
    );
}

fn sendTargets(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    var targets: std.ArrayList(c.xcb_atom_t) = .empty;
    defer targets.deinit(self.allocator);
    targets.append(self.allocator, self.atoms.targets) catch return self.sendNotify(request, c.XCB_ATOM_NONE);
    for (self.wayland_selection.mimeTypes()) |mime_type| {
        const atom = self.mimeAtom(mime_type) orelse continue;
        if (std.mem.indexOfScalar(c.xcb_atom_t, targets.items, atom) != null) continue;
        targets.append(self.allocator, atom) catch return self.sendNotify(request, c.XCB_ATOM_NONE);
    }
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        request.requestor,
        property,
        c.XCB_ATOM_ATOM,
        32,
        @intCast(targets.items.len),
        targets.items.ptr,
    );
    self.sendNotify(request, property);
}

fn sendData(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    const mime_type = self.mimeForTarget(request.target) orelse {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) < 0) {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    }
    var read_fd = fds[0];
    var write_fd = fds[1];
    defer closeFd(&read_fd);
    defer closeFd(&write_fd);
    setNonblocking(read_fd) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    const transfer = self.allocator.create(OutgoingTransfer) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    var transfer_registered = false;
    defer if (!transfer_registered) self.allocator.destroy(transfer);
    transfer.* = .{
        .selection = self,
        .request = request,
        .property = property,
        .fd = read_fd,
        .event_source = undefined,
    };
    const event_source = self.event_loop.addFd(
        *OutgoingTransfer,
        read_fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        OutgoingTransfer.readable,
        transfer,
    ) catch {
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    transfer.event_source = event_source;
    self.transfers.append(self.allocator, transfer) catch {
        event_source.remove();
        self.sendNotify(request, c.XCB_ATOM_NONE);
        return;
    };
    transfer_registered = true;
    read_fd = invalid_fd;
    self.wayland_selection.send(mime_type.ptr, write_fd);
    closeFd(&write_fd);
}

fn sendNotify(self: *Self, request: c.xcb_selection_request_event_t, property: c.xcb_atom_t) void {
    var event = std.mem.zeroes(c.xcb_selection_notify_event_t);
    event.response_type = c.XCB_SELECTION_NOTIFY;
    event.time = request.time;
    event.requestor = request.requestor;
    event.selection = request.selection;
    event.target = request.target;
    event.property = property;
    _ = c.xcb_send_event(
        self.connection,
        0,
        request.requestor,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    );
    _ = c.xcb_flush(self.connection);
}

fn mimeAtom(self: *Self, mime_type: [:0]const u8) ?c.xcb_atom_t {
    if (std.mem.eql(u8, mime_type, "text/plain;charset=utf-8")) return self.atoms.utf8_string;
    if (std.mem.eql(u8, mime_type, "text/plain")) return self.atoms.text;
    if (mime_type.len > std.math.maxInt(u16)) return null;
    const reply = c.xcb_intern_atom_reply(
        self.connection,
        c.xcb_intern_atom(self.connection, 0, @intCast(mime_type.len), mime_type.ptr),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn mimeForTarget(self: *Self, target: c.xcb_atom_t) ?[:0]const u8 {
    for (self.wayland_selection.mimeTypes()) |mime_type| {
        if (self.mimeAtom(mime_type)) |atom| {
            if (atom == target) return mime_type;
        }
    }
    return null;
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.SetNonblockingFailed;
    var status: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = true;
    if (std.c.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(c_int, @intCast(@as(u32, @bitCast(status)))),
    ) < 0) return error.SetNonblockingFailed;
}

fn closeFd(fd: *std.posix.fd_t) void {
    if (fd.* < 0) return;
    _ = std.c.close(fd.*);
    fd.* = invalid_fd;
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    return error.X11RequestFailed;
}
