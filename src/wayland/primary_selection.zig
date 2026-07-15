//! Primary-selection transfer tied to keyboard focus.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const slot_map = @import("../slot_map.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
sources: SourceStore,
devices: DeviceStore,
offers: OfferStore,
selection: ?SourceId,
selection_serial: u32,
focused_client: ?*wl.Client,

const SourceStore = slot_map.SlotMap(SourceState, enum { primary_selection_source });
const SourceId = SourceStore.Id;
const SourceState = struct {
    resource: *zwp.PrimarySelectionSourceV1,
    mime_types: std.ArrayList([:0]u8) = .empty,
    cancelled: bool = false,

    fn deinit(self: *SourceState, allocator: std.mem.Allocator) void {
        for (self.mime_types.items) |mime_type| allocator.free(mime_type);
        self.mime_types.deinit(allocator);
        self.* = undefined;
    }
};

const DeviceStore = slot_map.SlotMap(DeviceState, enum { primary_selection_device });
const DeviceId = DeviceStore.Id;
const DeviceState = struct {
    resource: *zwp.PrimarySelectionDeviceV1,
};

const OfferStore = slot_map.SlotMap(OfferState, enum { primary_selection_offer });
const OfferId = OfferStore.Id;
const OfferState = struct {
    device: DeviceId,
    source: ?SourceId,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .seat = seat,
        .sources = .{},
        .devices = .{},
        .offers = .{},
        .selection = null,
        .selection_serial = 0,
        .focused_client = null,
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.devices.deinit(allocator);
    errdefer self.offers.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        zwp.PrimarySelectionDeviceManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{
        .context = self,
        .changed = keyboardFocusChanged,
    });
}

pub fn deinit(self: *Self) void {
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    std.debug.assert(self.sources.len() == 0);
    std.debug.assert(self.devices.len() == 0);
    std.debug.assert(self.offers.len() == 0);
    self.offers.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.PrimarySelectionDeviceManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *zwp.PrimarySelectionDeviceManagerV1,
    request: zwp.PrimarySelectionDeviceManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_source => |create| SourceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_device => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                createInertDevice(
                    resource.getClient(),
                    resource.getVersion(),
                    get.id,
                ) catch resource.postNoMemory();
                return;
            }
            DeviceResource.create(
                self,
                resource.getClient(),
                resource.getVersion(),
                get.id,
            ) catch resource.postNoMemory();
        },
        .destroy => resource.destroy(),
    }
}

fn createInertDevice(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try zwp.PrimarySelectionDeviceV1.create(client, version, id);
    resource.setHandler(?*anyopaque, inertDeviceRequest, null, null);
}

fn inertDeviceRequest(
    resource: *zwp.PrimarySelectionDeviceV1,
    request: zwp.PrimarySelectionDeviceV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_selection => {},
    }
}

const SourceResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: SourceId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.PrimarySelectionSourceV1.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(SourceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.sources.insert(manager.allocator, .{
            .resource = resource,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.sources.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        resource.setHandler(
            *SourceResource,
            SourceResource.handleRequest,
            SourceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionSourceV1,
        request: zwp.PrimarySelectionSourceV1.Request,
        self: *SourceResource,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(resource, request_offer.mime_type),
            .destroy => resource.destroy(),
        }
    }

    fn offer(
        self: *SourceResource,
        resource: *zwp.PrimarySelectionSourceV1,
        mime_type: [*:0]const u8,
    ) void {
        const state = self.manager.sources.get(self.id) orelse return;
        if (state.cancelled) return;
        const value = std.mem.span(mime_type);
        for (state.mime_types.items) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        const copy = self.allocator.dupeZ(u8, value) catch {
            resource.postNoMemory();
            return;
        };
        state.mime_types.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            resource.postNoMemory();
        };
    }

    fn handleDestroy(_: *zwp.PrimarySelectionSourceV1, self: *SourceResource) void {
        self.manager.sourceDestroyed(self.id);
        var state = self.manager.sources.remove(self.id) orelse {
            self.allocator.destroy(self);
            return;
        };
        state.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const DeviceResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: DeviceId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.PrimarySelectionDeviceV1.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(DeviceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.devices.insert(manager.allocator, .{
            .resource = resource,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.devices.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        resource.setHandler(
            *DeviceResource,
            DeviceResource.handleRequest,
            DeviceResource.handleDestroy,
            self,
        );
        if (manager.focused_client == client) {
            manager.sendSelectionToDevice(id) catch resource.postNoMemory();
        }
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionDeviceV1,
        request: zwp.PrimarySelectionDeviceV1.Request,
        self: *DeviceResource,
    ) void {
        switch (request) {
            .set_selection => |set| self.setSelection(resource, set.source, set.serial),
            .destroy => resource.destroy(),
        }
    }

    fn setSelection(
        self: *DeviceResource,
        resource: *zwp.PrimarySelectionDeviceV1,
        source_resource: ?*zwp.PrimarySelectionSourceV1,
        serial: u32,
    ) void {
        const source_id = if (source_resource) |source| source: {
            const data = source.getUserData() orelse return;
            const adapter: *SourceResource = @ptrCast(@alignCast(data));
            if (adapter.manager != self.manager or source.getClient() != resource.getClient()) return;
            const state = self.manager.sources.get(adapter.id) orelse return;
            if (state.cancelled) return;
            break :source adapter.id;
        } else null;

        if (!self.manager.seat.acceptsSelectionSerial(resource.getClient(), serial)) return;
        self.manager.setSelection(source_id, serial);
    }

    fn handleDestroy(_: *zwp.PrimarySelectionDeviceV1, self: *DeviceResource) void {
        self.manager.deviceDestroyed(self.id);
        _ = self.manager.devices.remove(self.id);
        self.allocator.destroy(self);
    }
};

const OfferResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: OfferId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        device_id: DeviceId,
        source_id: SourceId,
    ) error{ OutOfMemory, ResourceCreateFailed }!*zwp.PrimarySelectionOfferV1 {
        const resource = try zwp.PrimarySelectionOfferV1.create(client, version, 0);
        errdefer resource.destroy();
        const self = manager.allocator.create(OfferResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.offers.insert(manager.allocator, .{
            .device = device_id,
            .source = source_id,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.offers.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        resource.setHandler(
            *OfferResource,
            OfferResource.handleRequest,
            OfferResource.handleDestroy,
            self,
        );
        return resource;
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionOfferV1,
        request: zwp.PrimarySelectionOfferV1.Request,
        self: *OfferResource,
    ) void {
        switch (request) {
            .receive => |receive| {
                defer (std.Io.File{
                    .handle = receive.fd,
                    .flags = .{ .nonblocking = false },
                }).close(self.manager.seat.io);
                const offer = self.manager.offers.get(self.id) orelse return;
                const source_id = offer.source orelse return;
                const source = self.manager.sources.get(source_id) orelse return;
                source.resource.sendSend(receive.mime_type, receive.fd);
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.PrimarySelectionOfferV1, self: *OfferResource) void {
        _ = self.manager.offers.remove(self.id);
        self.allocator.destroy(self);
    }
};

fn keyboardFocusChanged(context: *anyopaque, client: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.focused_client == client) return;
    const old_client = self.focused_client;
    self.invalidateOffers();
    self.focused_client = client;
    if (old_client) |old| self.sendNullSelectionToClient(old);
    if (client) |focused| self.sendSelectionToClient(focused);
}

fn setSelection(self: *Self, source_id: ?SourceId, serial: u32) void {
    if (self.selection != null and Seat.serialIsOlder(serial, self.selection_serial)) return;
    const old_source = self.selection;
    if (std.meta.eql(old_source, source_id)) {
        self.selection_serial = serial;
        return;
    }
    self.selection = source_id;
    self.selection_serial = serial;
    self.invalidateOffers();
    if (old_source) |id| {
        if (self.sources.get(id)) |source| {
            source.cancelled = true;
            source.resource.sendCancelled();
        }
    }
    if (self.focused_client) |client| self.sendSelectionToClient(client);
}

fn sourceDestroyed(self: *Self, id: SourceId) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.source) |source_id| {
            if (std.meta.eql(source_id, id)) entry.value.source = null;
        }
    }
    if (self.selection) |selection| {
        if (!std.meta.eql(selection, id)) return;
        self.selection = null;
        if (self.focused_client) |client| self.sendNullSelectionToClient(client);
    }
}

fn deviceDestroyed(self: *Self, id: DeviceId) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.device, id)) entry.value.source = null;
    }
}

fn invalidateOffers(self: *Self) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| entry.value.source = null;
}

fn sendSelectionToClient(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() != client) continue;
        self.sendSelectionToDevice(entry.id) catch entry.value.resource.postNoMemory();
    }
}

fn sendNullSelectionToClient(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendSelection(null);
    }
}

fn sendSelectionToDevice(
    self: *Self,
    device_id: DeviceId,
) error{ OutOfMemory, ResourceCreateFailed }!void {
    const device = self.devices.get(device_id) orelse return;
    const source_id = self.selection orelse {
        device.resource.sendSelection(null);
        return;
    };
    const source = self.sources.get(source_id) orelse {
        self.selection = null;
        device.resource.sendSelection(null);
        return;
    };
    const offer = try OfferResource.create(
        self,
        device.resource.getClient(),
        device.resource.getVersion(),
        device_id,
        source_id,
    );
    device.resource.sendDataOffer(offer);
    for (source.mime_types.items) |mime_type| offer.sendOffer(mime_type.ptr);
    device.resource.sendSelection(offer);
}
