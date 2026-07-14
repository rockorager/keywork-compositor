//! Core data-device objects tied to the compositor seat.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const slot_map = @import("../slot_map.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
sources: SourceStore,
source_adapters: std.AutoHashMapUnmanaged(SourceId, *SourceResource),
devices: DeviceStore,
device_adapters: std.AutoHashMapUnmanaged(DeviceId, *DeviceResource),
offers: OfferStore,
offer_adapters: std.AutoHashMapUnmanaged(OfferId, *OfferResource),
selection: ?SourceId,
selection_serial: u32,
focused_client: ?*wl.Client,

const SourceStore = slot_map.SlotMap(SourceState, enum { data_source });
const SourceId = SourceStore.Id;
const SourceState = struct {
    resource: *wl.DataSource,
    mime_types: std.ArrayList([:0]u8) = .empty,
    used: bool = false,
    actions_set: bool = false,
    dnd_actions: wl.DataDeviceManager.DndAction = .{},

    fn deinit(self: *SourceState, allocator: std.mem.Allocator) void {
        for (self.mime_types.items) |mime_type| allocator.free(mime_type);
        self.mime_types.deinit(allocator);
        self.* = undefined;
    }
};

const DeviceStore = slot_map.SlotMap(DeviceState, enum { data_device });
const DeviceId = DeviceStore.Id;
const DeviceState = struct {
    resource: *wl.DataDevice,
};

const OfferStore = slot_map.SlotMap(OfferState, enum { data_offer });
const OfferId = OfferStore.Id;
const OfferState = struct {
    resource: *wl.DataOffer,
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
        .source_adapters = .empty,
        .devices = .{},
        .device_adapters = .empty,
        .offers = .{},
        .offer_adapters = .empty,
        .selection = null,
        .selection_serial = 0,
        .focused_client = null,
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.source_adapters.deinit(allocator);
    errdefer self.devices.deinit(allocator);
    errdefer self.device_adapters.deinit(allocator);
    errdefer self.offers.deinit(allocator);
    errdefer self.offer_adapters.deinit(allocator);
    self.global = try wl.Global.create(display, wl.DataDeviceManager, 3, *Self, self, bind);
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
    std.debug.assert(self.source_adapters.count() == 0);
    std.debug.assert(self.devices.len() == 0);
    std.debug.assert(self.device_adapters.count() == 0);
    std.debug.assert(self.offers.len() == 0);
    std.debug.assert(self.offer_adapters.count() == 0);
    self.offer_adapters.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.source_adapters.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.device_adapters.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.DataDeviceManager.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wl.DataDeviceManager,
    request: wl.DataDeviceManager.Request,
    self: *Self,
) void {
    switch (request) {
        .create_data_source => |create| SourceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_data_device => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                resource.getClient().postImplementationError("unknown wl_seat resource");
                return;
            }
            DeviceResource.create(
                self,
                resource.getClient(),
                resource.getVersion(),
                get.id,
            ) catch resource.postNoMemory();
        },
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
        const resource = try wl.DataSource.create(client, version, protocol_id);
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
        manager.source_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
        resource.setHandler(
            *SourceResource,
            SourceResource.handleRequest,
            SourceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wl.DataSource,
        request: wl.DataSource.Request,
        self: *SourceResource,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(resource, request_offer.mime_type),
            .destroy => resource.destroy(),
            .set_actions => |set| {
                const state = self.manager.sources.get(self.id) orelse return;
                const action_bits: u32 = @bitCast(set.dnd_actions);
                if (action_bits & ~@as(u32, 7) != 0) {
                    resource.postError(.invalid_action_mask, "invalid drag-and-drop action mask");
                    return;
                }
                if (state.actions_set) {
                    resource.postError(.invalid_source, "drag-and-drop actions were already set");
                    return;
                }
                if (state.used) {
                    resource.postError(.invalid_source, "data source is already in use");
                    return;
                }
                state.actions_set = true;
                state.dnd_actions = set.dnd_actions;
            },
        }
    }

    fn offer(self: *SourceResource, resource: *wl.DataSource, mime_type: [*:0]const u8) void {
        const state = self.manager.sources.get(self.id) orelse return;
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

    fn handleDestroy(_: *wl.DataSource, self: *SourceResource) void {
        self.manager.sourceDestroyed(self.id);
        _ = self.manager.source_adapters.remove(self.id);
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
        const resource = try wl.DataDevice.create(client, version, protocol_id);
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
        manager.device_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
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
        resource: *wl.DataDevice,
        request: wl.DataDevice.Request,
        self: *DeviceResource,
    ) void {
        switch (request) {
            .release => resource.destroy(),
            .start_drag => |start| self.rejectDrag(resource, start.source, start.serial),
            .set_selection => |set| self.setSelection(resource, set.source, set.serial),
        }
    }

    fn rejectDrag(
        self: *DeviceResource,
        resource: *wl.DataDevice,
        source_resource: ?*wl.DataSource,
        _: u32,
    ) void {
        const source = source_resource orelse return;
        const data = source.getUserData() orelse return;
        const adapter: *SourceResource = @ptrCast(@alignCast(data));
        if (adapter.manager != self.manager or source.getClient() != resource.getClient()) return;
        const state = self.manager.sources.get(adapter.id) orelse return;
        if (state.used) {
            resource.postError(.used_source, "data source was already used");
            return;
        }
        state.used = true;
        if (source.getVersion() >= 3) source.sendCancelled();
    }

    fn setSelection(
        self: *DeviceResource,
        resource: *wl.DataDevice,
        source_resource: ?*wl.DataSource,
        serial: u32,
    ) void {
        const source_id = if (source_resource) |source| source: {
            const data = source.getUserData() orelse return;
            const adapter: *SourceResource = @ptrCast(@alignCast(data));
            if (adapter.manager != self.manager or source.getClient() != resource.getClient()) return;
            const state = self.manager.sources.get(adapter.id) orelse return;
            if (state.actions_set) {
                source.postError(.invalid_source, "drag-and-drop source used for selection");
                return;
            }
            if (state.used) {
                resource.postError(.used_source, "data source was already used");
                return;
            }
            state.used = true;
            break :source adapter.id;
        } else null;

        if (!self.manager.seat.acceptsSelectionSerial(resource.getClient(), serial)) return;
        self.manager.setSelection(source_id, serial);
    }

    fn handleDestroy(_: *wl.DataDevice, self: *DeviceResource) void {
        self.manager.deviceDestroyed(self.id);
        _ = self.manager.device_adapters.remove(self.id);
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
    ) error{ OutOfMemory, ResourceCreateFailed }!*wl.DataOffer {
        const resource = try wl.DataOffer.create(client, version, 0);
        errdefer resource.destroy();
        const self = manager.allocator.create(OfferResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.offers.insert(manager.allocator, .{
            .resource = resource,
            .device = device_id,
            .source = source_id,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.offers.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        manager.offer_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
        resource.setHandler(
            *OfferResource,
            OfferResource.handleRequest,
            OfferResource.handleDestroy,
            self,
        );
        return resource;
    }

    fn handleRequest(
        resource: *wl.DataOffer,
        request: wl.DataOffer.Request,
        self: *OfferResource,
    ) void {
        switch (request) {
            .accept => {},
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
            .finish => resource.postError(.invalid_finish, "selection offer cannot be finished"),
            .set_actions => resource.postError(
                .invalid_offer,
                "drag-and-drop actions are invalid for a selection offer",
            ),
        }
    }

    fn handleDestroy(_: *wl.DataOffer, self: *OfferResource) void {
        _ = self.manager.offer_adapters.remove(self.id);
        _ = self.manager.offers.remove(self.id);
        self.allocator.destroy(self);
    }
};

fn keyboardFocusChanged(context: *anyopaque, client: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.focused_client == client) return;
    self.invalidateOffers();
    self.focused_client = client;
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
        if (self.sources.get(id)) |source| source.resource.sendCancelled();
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
        if (self.focused_client) |client| self.sendSelectionToClient(client);
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
