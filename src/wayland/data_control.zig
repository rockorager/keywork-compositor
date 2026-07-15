//! Privileged ext-data-control-v1 clipboard management.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("data_device.zig");
const PrimarySelection = @import("primary_selection.zig");
const Seat = @import("seat.zig");
const SecurityContext = @import("security_context.zig");
const SelectionSource = @import("selection_source.zig").Source;

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
seats: std.ArrayList(*SeatState),
sources: std.ArrayList(*Source),

const Kind = enum { regular, primary };

const Channel = struct {
    source: ?*Source = null,
    generation: u64 = 0,
};

const SeatState = struct {
    manager: *Self,
    seat: *Seat,
    data_device: ?*DataDevice = null,
    primary_selection: ?*PrimarySelection = null,
    removed: bool = false,
    regular: Channel = .{},
    primary: Channel = .{},
    devices: std.ArrayList(*Device) = .empty,

    fn channel(self: *SeatState, kind: Kind) *Channel {
        return switch (kind) {
            .regular => &self.regular,
            .primary => &self.primary,
        };
    }

    fn replace(self: *SeatState, kind: Kind, source: ?*Source, cancel_old: bool) void {
        if (self.data_device) |data_device| {
            switch (kind) {
                .regular => data_device.setExternalSelection(if (source) |value| &value.callbacks else null),
                .primary => self.primary_selection.?.setExternalSelection(
                    if (source) |value| &value.callbacks else null,
                ),
            }
            return;
        }
        const selection = self.channel(kind);
        if (selection.source == source) return;
        const old = selection.source;
        selection.source = source;
        selection.generation +%= 1;
        if (!self.removed) self.broadcast(kind);
        if (cancel_old) if (old) |value| value.callbacks.cancel(value.callbacks.context);
    }

    fn broadcast(self: *SeatState, kind: Kind) void {
        for (self.devices.items) |device| device.sendSelection(kind) catch device.resource.postNoMemory();
    }

    fn hasSelection(self: *SeatState, kind: Kind) bool {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.hasSelection(),
            .primary => self.primary_selection.?.hasSelection(),
        };
        return self.channel(kind).source != null;
    }

    fn generation(self: *SeatState, kind: Kind) u64 {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.selectionGeneration(),
            .primary => self.primary_selection.?.selectionGeneration(),
        };
        return self.channel(kind).generation;
    }

    fn mimeTypes(self: *SeatState, kind: Kind) []const [:0]const u8 {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.selectionMimeTypes(),
            .primary => self.primary_selection.?.selectionMimeTypes(),
        };
        const source = self.channel(kind).source orelse return &.{};
        return source.callbacks.mime_types(source.callbacks.context);
    }

    fn send(self: *SeatState, kind: Kind, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        if (self.data_device) |data_device| {
            switch (kind) {
                .regular => data_device.sendSelection(mime_type, fd),
                .primary => self.primary_selection.?.sendSelection(mime_type, fd),
            }
            return;
        }
        const source = self.channel(kind).source orelse return;
        if (source.callbacks.hasMime(mime_type)) {
            source.callbacks.send(source.callbacks.context, mime_type, fd);
        }
    }

    fn offered(self: *SeatState, kind: Kind, mime_type: [*:0]const u8) void {
        const current_generation = self.generation(kind);
        for (self.devices.items) |device| {
            for (device.offers.items) |offer| {
                if (offer.kind == kind and offer.generation == current_generation) {
                    offer.resource.sendOffer(mime_type);
                }
            }
        }
    }
};

const Source = struct {
    manager: *Self,
    resource: *ext.DataControlSourceV1,
    mime_types: std.ArrayList([:0]u8) = .empty,
    used: bool = false,
    cancelled: bool = false,
    callbacks: SelectionSource,

    fn create(manager: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try ext.DataControlSourceV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(Source);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .callbacks = .{ .context = self, .mime_types = callbackMimes, .send = callbackSend, .cancel = callbackCancel },
        };
        try manager.sources.append(manager.allocator, self);
        resource.setHandler(*Source, handleRequest, handleDestroy, self);
    }

    fn callbackMimes(context: *anyopaque) []const [:0]const u8 {
        const self: *Source = @ptrCast(@alignCast(context));
        return @ptrCast(self.mime_types.items);
    }

    fn callbackSend(context: *anyopaque, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        const self: *Source = @ptrCast(@alignCast(context));
        self.resource.sendSend(mime_type, fd);
    }

    fn callbackCancel(context: *anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(context));
        if (self.cancelled) return;
        self.cancelled = true;
        self.resource.sendCancelled();
    }

    fn handleRequest(resource: *ext.DataControlSourceV1, request: ext.DataControlSourceV1.Request, self: *Source) void {
        switch (request) {
            .offer => |offer| {
                if (self.used) {
                    resource.postError(.invalid_offer, "cannot add a MIME type after using the source");
                    return;
                }
                const value = std.mem.span(offer.mime_type);
                for (self.mime_types.items) |existing| if (std.mem.eql(u8, existing, value)) return;
                const copy = self.manager.allocator.dupeZ(u8, value) catch return resource.postNoMemory();
                self.mime_types.append(self.manager.allocator, copy) catch {
                    self.manager.allocator.free(copy);
                    resource.postNoMemory();
                };
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *ext.DataControlSourceV1, self: *Source) void {
        for (self.manager.seats.items) |seat| {
            if (seat.data_device) |data_device| {
                data_device.externalSourceDestroyed(&self.callbacks);
                seat.primary_selection.?.externalSourceDestroyed(&self.callbacks);
            } else {
                if (seat.regular.source == self) seat.replace(.regular, null, false);
                if (seat.primary.source == self) seat.replace(.primary, null, false);
            }
        }
        for (self.manager.sources.items, 0..) |source, index| if (source == self) {
            _ = self.manager.sources.swapRemove(index);
            break;
        };
        for (self.mime_types.items) |mime_type| self.manager.allocator.free(mime_type);
        self.mime_types.deinit(self.manager.allocator);
        self.manager.allocator.destroy(self);
    }
};

const Device = struct {
    state: *SeatState,
    resource: *ext.DataControlDeviceV1,
    offers: std.ArrayList(*Offer) = .empty,

    fn create(state: *SeatState, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try ext.DataControlDeviceV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try state.manager.allocator.create(Device);
        errdefer state.manager.allocator.destroy(self);
        self.* = .{ .state = state, .resource = resource };
        try state.devices.append(state.manager.allocator, self);
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
        self.sendSelection(.regular) catch {
            resource.postNoMemory();
            return;
        };
        self.sendSelection(.primary) catch resource.postNoMemory();
    }

    fn set(self: *Device, resource: *ext.DataControlDeviceV1, kind: Kind, source_resource: ?*ext.DataControlSourceV1) void {
        if (self.state.removed) return;
        const source = if (source_resource) |candidate| blk: {
            var found: ?*Source = null;
            for (self.state.manager.sources.items) |item| if (item.resource == candidate) {
                found = item;
                break;
            };
            break :blk found orelse return;
        } else null;
        if (source) |value| {
            if (value.used) return resource.postError(.used_source, "data-control source was already used");
            value.used = true;
        }
        self.state.replace(kind, source, true);
    }

    fn handleRequest(resource: *ext.DataControlDeviceV1, request: ext.DataControlDeviceV1.Request, self: *Device) void {
        switch (request) {
            .set_selection => |request_set| self.set(resource, .regular, request_set.source),
            .set_primary_selection => |request_set| self.set(resource, .primary, request_set.source),
            .destroy => resource.destroy(),
        }
    }

    fn sendSelection(self: *Device, kind: Kind) !void {
        if (!self.state.hasSelection(kind)) {
            switch (kind) {
                .regular => self.resource.sendSelection(null),
                .primary => self.resource.sendPrimarySelection(null),
            }
            return;
        }
        const offer = try Offer.create(self, kind, self.state.generation(kind));
        self.resource.sendDataOffer(offer.resource);
        for (self.state.mimeTypes(kind)) |mime_type| offer.resource.sendOffer(mime_type.ptr);
        switch (kind) {
            .regular => self.resource.sendSelection(offer.resource),
            .primary => self.resource.sendPrimarySelection(offer.resource),
        }
    }

    fn handleDestroy(_: *ext.DataControlDeviceV1, self: *Device) void {
        for (self.state.devices.items, 0..) |device, index| if (device == self) {
            _ = self.state.devices.swapRemove(index);
            break;
        };
        for (self.offers.items) |offer| offer.device = null;
        self.offers.deinit(self.state.manager.allocator);
        self.state.manager.allocator.destroy(self);
    }
};

const Offer = struct {
    manager: *Self,
    device: ?*Device,
    io: std.Io,
    resource: *ext.DataControlOfferV1,
    kind: Kind,
    generation: u64,

    fn create(device: *Device, kind: Kind, generation: u64) !*Offer {
        const resource = try ext.DataControlOfferV1.create(device.resource.getClient(), device.resource.getVersion(), 0);
        errdefer resource.destroy();
        const self = try device.state.manager.allocator.create(Offer);
        errdefer device.state.manager.allocator.destroy(self);
        self.* = .{
            .manager = device.state.manager,
            .device = device,
            .io = device.state.seat.io,
            .resource = resource,
            .kind = kind,
            .generation = generation,
        };
        try device.offers.append(device.state.manager.allocator, self);
        resource.setHandler(*Offer, handleRequest, handleDestroy, self);
        return self;
    }

    fn handleRequest(resource: *ext.DataControlOfferV1, request: ext.DataControlOfferV1.Request, self: *Offer) void {
        switch (request) {
            .receive => |receive| {
                defer (std.Io.File{
                    .handle = receive.fd,
                    .flags = .{ .nonblocking = false },
                }).close(self.io);
                const device = self.device orelse return;
                if (device.state.removed or device.state.generation(self.kind) != self.generation) return;
                if (!hasMime(device.state.mimeTypes(self.kind), receive.mime_type)) return;
                device.state.send(self.kind, receive.mime_type, receive.fd);
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *ext.DataControlOfferV1, self: *Offer) void {
        if (self.device) |device| for (device.offers.items, 0..) |offer, index| if (offer == self) {
            _ = device.offers.swapRemove(index);
            break;
        };
        self.manager.allocator.destroy(self);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    default_seat: *Seat,
    data_device: *DataDevice,
    primary_selection: *PrimarySelection,
) !void {
    self.* = .{ .allocator = allocator, .global = undefined, .security_context = security_context, .seats = .empty, .sources = .empty };
    errdefer self.seats.deinit(allocator);
    errdefer self.sources.deinit(allocator);
    self.global = try wl.Global.create(display, ext.DataControlManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    const state = try self.addSeatState(default_seat);
    state.data_device = data_device;
    state.primary_selection = primary_selection;
    data_device.setSelectionListener(.{
        .context = state,
        .changed = regularSelectionChanged,
        .offered = regularMimeOffered,
    });
    primary_selection.setSelectionListener(.{
        .context = state,
        .changed = primarySelectionChanged,
        .offered = primaryMimeOffered,
    });
}

pub fn deinit(self: *Self) void {
    for (self.seats.items) |state| {
        if (state.data_device) |data_device| {
            data_device.clearSelectionListener(state);
            state.primary_selection.?.clearSelectionListener(state);
        }
    }
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.sources.items.len == 0);
    for (self.seats.items) |state| {
        std.debug.assert(state.devices.items.len == 0);
        state.devices.deinit(self.allocator);
        self.allocator.destroy(state);
    }
    self.sources.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.* = undefined;
}

pub fn addSeat(self: *Self, seat: *Seat) !void {
    _ = try self.addSeatState(seat);
}

fn addSeatState(self: *Self, seat: *Seat) !*SeatState {
    const state = try self.allocator.create(SeatState);
    errdefer self.allocator.destroy(state);
    state.* = .{ .manager = self, .seat = seat };
    try self.seats.append(self.allocator, state);
    return state;
}

pub fn removeSeat(self: *Self, seat: *Seat) void {
    for (self.seats.items) |state| if (state.seat == seat and !state.removed) {
        state.removed = true;
        state.replace(.regular, null, true);
        state.replace(.primary, null, true);
        for (state.devices.items) |device| device.resource.sendFinished();
        return;
    };
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.DataControlManagerV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(resource: *ext.DataControlManagerV1, request: ext.DataControlManagerV1.Request, self: *Self) void {
    switch (request) {
        .create_data_source => |create| Source.create(self, resource.getClient(), resource.getVersion(), create.id) catch resource.postNoMemory(),
        .get_data_device => |get| {
            for (self.seats.items) |state| if (!state.removed and state.seat.ownsResource(get.seat)) {
                Device.create(state, resource.getClient(), resource.getVersion(), get.id) catch resource.postNoMemory();
                return;
            };
            const inert = ext.DataControlDeviceV1.create(resource.getClient(), resource.getVersion(), get.id) catch return resource.postNoMemory();
            inert.sendFinished();
            inert.setHandler(?*anyopaque, inertRequest, null, null);
        },
        .destroy => resource.destroy(),
    }
}

fn inertRequest(resource: *ext.DataControlDeviceV1, request: ext.DataControlDeviceV1.Request, _: ?*anyopaque) void {
    if (request == .destroy) resource.destroy();
}

fn regularSelectionChanged(context: *anyopaque) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.broadcast(.regular);
}

fn primarySelectionChanged(context: *anyopaque) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.broadcast(.primary);
}

fn regularMimeOffered(context: *anyopaque, mime_type: [*:0]const u8) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.offered(.regular, mime_type);
}

fn primaryMimeOffered(context: *anyopaque, mime_type: [*:0]const u8) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.offered(.primary, mime_type);
}

fn hasMime(mime_types: []const [:0]const u8, mime_type: [*:0]const u8) bool {
    const requested = std.mem.span(mime_type);
    for (mime_types) |offered| {
        if (std.mem.eql(u8, offered, requested)) return true;
    }
    return false;
}
