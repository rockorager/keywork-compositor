//! Core data-device objects tied to the compositor seat.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const slot_map = @import("slot_map.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
sources: SourceStore,
source_adapters: std.AutoHashMapUnmanaged(SourceId, *SourceResource),
devices: DeviceStore,
device_adapters: std.AutoHashMapUnmanaged(DeviceId, *DeviceResource),

const SourceStore = slot_map.SlotMap(SourceState, enum { data_source });
const SourceId = SourceStore.Id;
const SourceState = struct {
    actions_set: bool = false,
    dnd_actions: wl.DataDeviceManager.DndAction = .{},
};

const DeviceStore = slot_map.SlotMap(void, enum { data_device });
const DeviceId = DeviceStore.Id;

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
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.source_adapters.deinit(allocator);
    errdefer self.devices.deinit(allocator);
    errdefer self.device_adapters.deinit(allocator);
    self.global = try wl.Global.create(display, wl.DataDeviceManager, 3, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    std.debug.assert(self.sources.len() == 0);
    std.debug.assert(self.source_adapters.count() == 0);
    std.debug.assert(self.devices.len() == 0);
    std.debug.assert(self.device_adapters.count() == 0);
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
        const id = manager.sources.insert(manager.allocator, .{}) catch return error.OutOfMemory;
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
            .offer => {},
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
                state.actions_set = true;
                state.dnd_actions = set.dnd_actions;
            },
        }
    }

    fn handleDestroy(_: *wl.DataSource, self: *SourceResource) void {
        _ = self.manager.source_adapters.remove(self.id);
        _ = self.manager.sources.remove(self.id);
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
        const id = manager.devices.insert(manager.allocator, {}) catch return error.OutOfMemory;
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
    }

    fn handleRequest(
        resource: *wl.DataDevice,
        request: wl.DataDevice.Request,
        _: *DeviceResource,
    ) void {
        switch (request) {
            .release => resource.destroy(),
            // With no input capabilities there can be no valid input serial or
            // implicit grab, so selection and drag requests do not take effect.
            .start_drag, .set_selection => {},
        }
    }

    fn handleDestroy(_: *wl.DataDevice, self: *DeviceResource) void {
        _ = self.manager.device_adapters.remove(self.id);
        _ = self.manager.devices.remove(self.id);
        self.allocator.destroy(self);
    }
};
