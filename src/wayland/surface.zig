//! Server-side wl_surface state and shared-memory buffer snapshots.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const render_types = @import("../render/types.zig");
const slot_map = @import("../slot_map.zig");
const WaylandRegion = @import("region.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
store: *Store,
id: Id,
resource: *wl.Surface,
pending_attachment: Attachment,
has_pending_attachment: bool,
role_handler: ?RoleHandler,
viewport_handler: ?ViewportHandler,
commit_listeners: std.ArrayList(*CommitListener),

pub const Store = slot_map.SlotMap(State, enum { surface });
pub const Id = Store.Id;

pub const State = struct {
    resource: *wl.Surface,
    pending_offset_x: i32,
    pending_offset_y: i32,
    current_offset_x: i32,
    current_offset_y: i32,
    pending_scale: i32,
    current_scale: i32,
    pending_transform: wl.Output.Transform,
    current_transform: wl.Output.Transform,
    pending_viewport: ViewportState,
    current_viewport: ViewportState,
    pending_surface_damage: Region,
    pending_buffer_damage: Region,
    pending_opaque: Region,
    current_opaque: Region,
    pending_input: InputRegion,
    current_input: InputRegion,
    callbacks: std.ArrayList(*FrameCallback),
    commit_feedbacks: std.ArrayList(*CommitFeedback),
    presentation_submitted: bool,
    commit_after_submission: bool,
    current_buffer: ?BufferSnapshot,
    cached_buffer: ?BufferSnapshot,
    cached_attachment_changed: bool,
    cached_offset_x: i32,
    cached_offset_y: i32,
    cached_scale: i32,
    cached_transform: wl.Output.Transform,
    cached_viewport: ViewportState,
    cached_surface_damage: Region,
    cached_buffer_damage: Region,
    cached_opaque: Region,
    cached_input: InputRegion,
    has_cached_state: bool,
    role: ?Role,
    has_committed: bool,

    fn init(resource: *wl.Surface) State {
        return .{
            .resource = resource,
            .pending_offset_x = 0,
            .pending_offset_y = 0,
            .current_offset_x = 0,
            .current_offset_y = 0,
            .pending_scale = 1,
            .current_scale = 1,
            .pending_transform = .normal,
            .current_transform = .normal,
            .pending_viewport = .{},
            .current_viewport = .{},
            .pending_surface_damage = Region.init(),
            .pending_buffer_damage = Region.init(),
            .pending_opaque = Region.init(),
            .current_opaque = Region.init(),
            .pending_input = InputRegion.init(),
            .current_input = InputRegion.init(),
            .callbacks = .empty,
            .commit_feedbacks = .empty,
            .presentation_submitted = false,
            .commit_after_submission = false,
            .current_buffer = null,
            .cached_buffer = null,
            .cached_attachment_changed = false,
            .cached_offset_x = 0,
            .cached_offset_y = 0,
            .cached_scale = 1,
            .cached_transform = .normal,
            .cached_viewport = .{},
            .cached_surface_damage = Region.init(),
            .cached_buffer_damage = Region.init(),
            .cached_opaque = Region.init(),
            .cached_input = InputRegion.init(),
            .has_cached_state = false,
            .role = null,
            .has_committed = false,
        };
    }

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        std.debug.assert(self.callbacks.items.len == 0);
        std.debug.assert(self.commit_feedbacks.items.len == 0);
        self.callbacks.deinit(allocator);
        self.commit_feedbacks.deinit(allocator);
        if (self.current_buffer) |*current| current.deinit();
        if (self.cached_buffer) |*cached| cached.deinit();
        self.pending_surface_damage.deinit();
        self.pending_buffer_damage.deinit();
        self.cached_surface_damage.deinit();
        self.cached_buffer_damage.deinit();
        self.pending_opaque.deinit();
        self.current_opaque.deinit();
        self.cached_opaque.deinit();
        self.pending_input.deinit();
        self.current_input.deinit();
        self.cached_input.deinit();
        self.* = undefined;
    }
};

pub const CreateError = error{
    OutOfMemory,
    ResourceCreateFailed,
};

pub fn create(
    allocator: std.mem.Allocator,
    store: *Store,
    client: *wl.Client,
    version: u32,
    id: u32,
) CreateError!*Self {
    const resource = try wl.Surface.create(client, version, id);
    errdefer resource.destroy();

    const self = allocator.create(Self) catch return error.OutOfMemory;
    errdefer allocator.destroy(self);

    var surface_state = State.init(resource);
    errdefer surface_state.deinit(allocator);
    const state_id = store.insert(allocator, surface_state) catch return error.OutOfMemory;

    self.* = .{
        .allocator = allocator,
        .store = store,
        .id = state_id,
        .resource = resource,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .commit_listeners = .empty,
    };

    resource.setHandler(*Self, handleRequest, handleDestroy, self);
    return self;
}

pub fn fromResource(resource: *wl.Surface) *Self {
    return @ptrCast(@alignCast(resource.getUserData().?));
}

pub fn handle(self: *const Self) Id {
    return self.id;
}

pub fn waylandResource(self: *Self) *wl.Surface {
    return self.resource;
}

pub fn state(self: *Self) *State {
    return self.store.get(self.id) orelse unreachable;
}

pub fn resourceFor(store: *Store, id: Id) ?*wl.Surface {
    const surface_state = store.get(id) orelse return null;
    return surface_state.resource;
}

pub const RoleError = error{
    AlreadyAssigned,
    AlreadyReserved,
    NotReserved,
};

pub const ViewportSource = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ViewportState = struct {
    source: ?ViewportSource = null,
    destination: ?render_types.Size = null,
};

pub const ViewportHandler = struct {
    context: *anyopaque,
    resource: *wp.Viewport,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setViewportHandler(self: *Self, handler: ViewportHandler) error{AlreadyExists}!void {
    if (self.viewport_handler != null) return error.AlreadyExists;
    self.viewport_handler = handler;
}

pub fn clearViewportHandler(self: *Self) void {
    std.debug.assert(self.viewport_handler != null);
    self.viewport_handler = null;
    self.state().pending_viewport = .{};
}

pub fn setViewportSource(self: *Self, source: ?ViewportSource) void {
    std.debug.assert(self.viewport_handler != null);
    self.state().pending_viewport.source = source;
}

pub fn setViewportDestination(self: *Self, destination: ?render_types.Size) void {
    std.debug.assert(self.viewport_handler != null);
    self.state().pending_viewport.destination = destination;
}

pub const Role = enum {
    xdg_toplevel,
    xdg_popup,
    subsurface,
    cursor,
    river_decoration,
    river_shell_surface,
};

pub const CommitInfo = struct {
    attachment_changed: bool,
    had_buffer: bool,
    has_buffer: bool,
    offset_x: i32,
    offset_y: i32,
};

pub const CommitAction = enum {
    apply,
    cache,
    apply_cached,
    reject,
};

pub const RoleHandler = struct {
    context: *anyopaque,
    before_commit: *const fn (*anyopaque, CommitInfo) CommitAction,
    after_commit: *const fn (*anyopaque, CommitInfo) void,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const CommitListener = struct {
    context: *anyopaque,
    applied: *const fn (*anyopaque) void,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const CommitFeedback = struct {
    context: *anyopaque,
    presented: *const fn (*anyopaque, presentation.Info) void,
    discarded: *const fn (*anyopaque) void,
    state: Status = .pending,

    pub const Status = enum {
        pending,
        cached,
        active,
        submitted,
    };
};

pub fn reserveRole(self: *Self, role: Role, handler: RoleHandler) RoleError!void {
    const surface_state = self.state();
    if (surface_state.role) |assigned| {
        if (assigned != role) return error.AlreadyAssigned;
    }
    if (self.role_handler != null) return error.AlreadyReserved;

    self.role_handler = handler;
}

pub fn assignReservedRole(self: *Self, role: Role, context: *anyopaque) RoleError!void {
    const surface_state = self.state();
    if (surface_state.role) |assigned| {
        if (assigned != role) return error.AlreadyAssigned;
    }
    const handler = self.role_handler orelse return error.NotReserved;
    if (handler.context != context) return error.NotReserved;
    surface_state.role = role;
}

pub fn assignedRole(self: *Self) ?Role {
    return self.state().role;
}

pub fn hasBufferAttachedOrCommitted(self: *Self) bool {
    return self.pending_attachment.shm != null or self.state().current_buffer != null;
}

pub fn releaseRole(self: *Self, context: *anyopaque) void {
    const handler = self.role_handler orelse return;
    std.debug.assert(handler.context == context);
    self.role_handler = null;
}

pub fn addCommitListener(
    self: *Self,
    listener: *CommitListener,
) error{OutOfMemory}!void {
    try self.commit_listeners.append(self.allocator, listener);
}

pub fn removeCommitListener(self: *Self, listener: *CommitListener) void {
    for (self.commit_listeners.items, 0..) |candidate, index| {
        if (candidate == listener) {
            _ = self.commit_listeners.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

pub fn addCommitFeedback(self: *Self, feedback: *CommitFeedback) error{OutOfMemory}!void {
    feedback.state = .pending;
    try self.state().commit_feedbacks.append(self.allocator, feedback);
}

pub fn removeCommitFeedback(store: *Store, id: Id, feedback: *CommitFeedback) void {
    const surface_state = store.get(id) orelse unreachable;
    for (surface_state.commit_feedbacks.items, 0..) |candidate, index| {
        if (candidate == feedback) {
            _ = surface_state.commit_feedbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

pub fn applyCachedCommit(self: *Self) void {
    if (!self.state().has_cached_state) return;
    applyCached(self);
}

pub fn hasCachedCommit(self: *Self) bool {
    return self.state().has_cached_state;
}

pub fn discardCachedCommit(self: *Self) void {
    const surface_state = self.state();
    if (surface_state.cached_buffer) |*cached| cached.deinit();
    surface_state.cached_buffer = null;
    surface_state.cached_attachment_changed = false;
    surface_state.cached_offset_x = 0;
    surface_state.cached_offset_y = 0;
    surface_state.cached_surface_damage.clear();
    surface_state.cached_buffer_damage.clear();
    surface_state.has_cached_state = false;

    var index = surface_state.callbacks.items.len;
    while (index > 0) {
        index -= 1;
        const callback = surface_state.callbacks.items[index];
        if (callback.state == .cached) callback.resource.destroy();
    }
    discardCommitFeedbacks(surface_state, .cached);
}

pub fn sendFrameDone(self: *Self, time_milliseconds: u32) void {
    sendFrameDoneFor(self.store, self.id, time_milliseconds);
}

/// The returned snapshot is borrowed from the store and is invalidated by a
/// replacement commit or any store insertion that reallocates its slots.
pub fn currentBuffer(store: *Store, id: Id) ?*BufferSnapshot {
    const surface_state = store.get(id) orelse return null;
    return if (surface_state.current_buffer) |*buffer| buffer else null;
}

pub fn acceptsInput(store: *Store, id: Id, x: f64, y: f64) bool {
    const surface_state = store.get(id) orelse return false;
    const buffer = if (surface_state.current_buffer) |*current| current else return false;
    if (x < 0 or y < 0 or
        x >= @as(f64, @floatFromInt(buffer.logical_size.width)) or
        y >= @as(f64, @floatFromInt(buffer.logical_size.height))) return false;
    if (surface_state.current_input.infinite) return true;
    if (x > std.math.maxInt(i32) or y > std.math.maxInt(i32)) return false;
    return surface_state.current_input.value.contains(
        @intFromFloat(@floor(x)),
        @intFromFloat(@floor(y)),
    );
}

pub fn sendFrameDoneFor(store: *Store, id: Id, time_milliseconds: u32) void {
    const surface_state = store.get(id) orelse return;
    while (true) {
        const callback = for (surface_state.callbacks.items) |candidate| {
            if (candidate.state == .submitted) break candidate;
        } else return;

        callback.resource.destroySendDone(time_milliseconds);
    }
}

pub fn submitPresentationFor(store: *Store, id: Id) void {
    const surface_state = store.get(id) orelse return;
    if (surface_state.presentation_submitted) return;
    surface_state.presentation_submitted = true;
    surface_state.commit_after_submission = false;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .active) callback.state = .submitted;
    }
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == .active) feedback.state = .submitted;
    }
}

pub fn finishPresentation(store: *Store, info: presentation.Info) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (!surface_state.presentation_submitted) continue;
        surface_state.presentation_submitted = false;
        surface_state.commit_after_submission = false;
        sendFrameDoneFor(store, entry.id, info.timestamp.milliseconds());
        while (commitFeedbackWithState(surface_state, .submitted)) |feedback| {
            feedback.presented(feedback.context, info);
        }
    }
}

pub fn discardPresentation(store: *Store) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (!surface_state.presentation_submitted) continue;
        surface_state.presentation_submitted = false;
        for (surface_state.callbacks.items) |callback| {
            if (callback.state == .submitted) callback.state = .active;
        }
        if (surface_state.commit_after_submission) {
            discardCommitFeedbacks(surface_state, .submitted);
        } else {
            setCommitFeedbackState(surface_state, .submitted, .active);
        }
        surface_state.commit_after_submission = false;
    }
}

fn handleRequest(resource: *wl.Surface, request: wl.Surface.Request, self: *Self) void {
    const surface_state = self.state();
    switch (request) {
        .destroy => resource.destroy(),
        .attach => |attach| {
            if (resource.getVersion() >= 5 and (attach.x != 0 or attach.y != 0)) {
                resource.postError(.invalid_offset, "attach offset requires wl_surface.offset");
                return;
            }
            self.pending_attachment.set(attach.buffer) catch {
                resource.getClient().postImplementationError("unsupported wl_buffer type");
                return;
            };
            self.has_pending_attachment = true;
            if (resource.getVersion() < 5) {
                surface_state.pending_offset_x = attach.x;
                surface_state.pending_offset_y = attach.y;
            }
        },
        .damage => |damage| surface_state.pending_surface_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
        .frame => |frame| createFrameCallback(self, frame.callback) catch
            resource.postNoMemory(),
        .set_opaque_region => |set| {
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                surface_state.pending_opaque.copyFrom(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                surface_state.pending_opaque.clear();
            }
        },
        .set_input_region => |set| {
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                surface_state.pending_input.set(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                surface_state.pending_input.setInfinite();
            }
        },
        .commit => commit(self),
        .set_buffer_transform => |set| {
            if (!validTransform(set.transform)) {
                resource.postError(.invalid_transform, "invalid buffer transform");
                return;
            }
            surface_state.pending_transform = set.transform;
        },
        .set_buffer_scale => |set| {
            if (set.scale <= 0) {
                resource.postError(.invalid_scale, "buffer scale must be positive");
                return;
            }
            surface_state.pending_scale = set.scale;
        },
        .damage_buffer => |damage| surface_state.pending_buffer_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
        .offset => |offset| {
            surface_state.pending_offset_x = offset.x;
            surface_state.pending_offset_y = offset.y;
        },
    }
}

fn commit(self: *Self) void {
    const commit_info = pendingCommitInfo(self);
    const action = if (self.role_handler) |handler|
        handler.before_commit(handler.context, commit_info)
    else
        CommitAction.apply;

    switch (action) {
        .apply => {
            std.debug.assert(!self.state().has_cached_state);
            applyPending(self, commit_info);
        },
        .cache => _ = cachePending(self),
        .apply_cached => {
            if (cachePending(self)) applyCached(self);
        },
        .reject => discardCommitFeedbacks(self.state(), .pending),
    }
}

fn pendingCommitInfo(self: *Self) CommitInfo {
    const surface_state = self.state();
    return .{
        .attachment_changed = self.has_pending_attachment,
        .had_buffer = surface_state.current_buffer != null,
        .has_buffer = if (self.has_pending_attachment)
            self.pending_attachment.shm != null
        else if (surface_state.cached_attachment_changed)
            surface_state.cached_buffer != null
        else
            surface_state.current_buffer != null,
        .offset_x = surface_state.pending_offset_x,
        .offset_y = surface_state.pending_offset_y,
    };
}

fn applyPending(self: *Self, commit_info: CommitInfo) void {
    const surface_state = self.state();

    surface_state.current_opaque.copyFrom(&surface_state.pending_opaque) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_input.copyFrom(&surface_state.pending_input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (self.has_pending_attachment) {
        var snapshot: ?BufferSnapshot = null;
        if (self.pending_attachment.shm) |shm_buffer| {
            snapshot = BufferSnapshot.copyShm(
                self.allocator,
                shm_buffer,
                surface_state.pending_scale,
                surface_state.pending_transform,
                surface_state.pending_viewport,
            ) catch |err| {
                postBufferError(self, err);
                return;
            };
        }

        if (surface_state.current_buffer) |*current| current.deinit();
        surface_state.current_buffer = snapshot;

        if (self.pending_attachment.resource) |buffer| buffer.sendRelease();
        self.pending_attachment.clear();
        self.has_pending_attachment = false;
    } else if (surface_state.current_buffer) |*current| {
        current.updateGeometry(
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
        ) catch |err| {
            postBufferError(self, err);
            return;
        };
    }

    surface_state.current_scale = surface_state.pending_scale;
    surface_state.current_transform = surface_state.pending_transform;
    surface_state.current_viewport = surface_state.pending_viewport;
    surface_state.current_offset_x = surface_state.pending_offset_x;
    surface_state.current_offset_y = surface_state.pending_offset_y;
    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_committed = true;
    if (surface_state.presentation_submitted) surface_state.commit_after_submission = true;
    discardCommitFeedbacks(surface_state, .active);
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) callback.state = .active;
    }
    if (commit_info.has_buffer) {
        setCommitFeedbackState(surface_state, .pending, .active);
    } else {
        discardCommitFeedbacks(surface_state, .pending);
    }

    finishApplied(self, commit_info);
}

fn cachePending(self: *Self) bool {
    const surface_state = self.state();
    var snapshot: ?BufferSnapshot = null;
    defer if (snapshot) |*buffer| buffer.deinit();

    if (self.has_pending_attachment) {
        if (self.pending_attachment.shm) |shm_buffer| {
            snapshot = BufferSnapshot.copyShm(
                self.allocator,
                shm_buffer,
                surface_state.pending_scale,
                surface_state.pending_transform,
                surface_state.pending_viewport,
            ) catch |err| {
                postBufferError(self, err);
                return false;
            };
        }
    } else {
        const buffer = if (surface_state.cached_attachment_changed)
            if (surface_state.cached_buffer) |*cached| cached else null
        else if (surface_state.current_buffer) |*current|
            current
        else
            null;
        if (buffer) |existing| {
            _ = viewportGeometry(
                existing.buffer_size,
                surface_state.pending_scale,
                surface_state.pending_transform,
                surface_state.pending_viewport,
            ) catch |err| {
                postBufferError(self, err);
                return false;
            };
        }
    }

    surface_state.cached_opaque.copyFrom(&surface_state.pending_opaque) catch {
        self.resource.postNoMemory();
        return false;
    };
    surface_state.cached_input.copyFrom(&surface_state.pending_input) catch {
        self.resource.postNoMemory();
        return false;
    };
    surface_state.cached_surface_damage.unionWith(&surface_state.pending_surface_damage) catch {
        self.resource.postNoMemory();
        return false;
    };
    surface_state.cached_buffer_damage.unionWith(&surface_state.pending_buffer_damage) catch {
        self.resource.postNoMemory();
        return false;
    };

    if (self.has_pending_attachment) {
        discardCommitFeedbacks(surface_state, .cached);
        if (surface_state.cached_buffer) |*cached| cached.deinit();
        surface_state.cached_buffer = snapshot;
        snapshot = null;
        surface_state.cached_attachment_changed = true;

        if (self.pending_attachment.resource) |buffer| buffer.sendRelease();
        self.pending_attachment.clear();
        self.has_pending_attachment = false;
    }

    surface_state.cached_scale = surface_state.pending_scale;
    surface_state.cached_transform = surface_state.pending_transform;
    surface_state.cached_viewport = surface_state.pending_viewport;
    surface_state.cached_offset_x +|= surface_state.pending_offset_x;
    surface_state.cached_offset_y +|= surface_state.pending_offset_y;
    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_cached_state = true;
    surface_state.has_committed = true;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) callback.state = .cached;
    }
    setCommitFeedbackState(surface_state, .pending, .cached);
    return true;
}

fn applyCached(self: *Self) void {
    const surface_state = self.state();
    std.debug.assert(surface_state.has_cached_state);
    const commit_info: CommitInfo = .{
        .attachment_changed = surface_state.cached_attachment_changed,
        .had_buffer = surface_state.current_buffer != null,
        .has_buffer = if (surface_state.cached_attachment_changed)
            surface_state.cached_buffer != null
        else
            surface_state.current_buffer != null,
        .offset_x = surface_state.cached_offset_x,
        .offset_y = surface_state.cached_offset_y,
    };

    surface_state.current_opaque.copyFrom(&surface_state.cached_opaque) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_input.copyFrom(&surface_state.cached_input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (surface_state.cached_attachment_changed) {
        if (surface_state.current_buffer) |*current| current.deinit();
        surface_state.current_buffer = surface_state.cached_buffer;
        surface_state.cached_buffer = null;
        surface_state.cached_attachment_changed = false;
    }
    if (surface_state.current_buffer) |*current| {
        current.updateGeometry(
            surface_state.cached_scale,
            surface_state.cached_transform,
            surface_state.cached_viewport,
        ) catch unreachable;
    }

    surface_state.current_scale = surface_state.cached_scale;
    surface_state.current_transform = surface_state.cached_transform;
    surface_state.current_viewport = surface_state.cached_viewport;
    surface_state.current_offset_x = surface_state.cached_offset_x;
    surface_state.current_offset_y = surface_state.cached_offset_y;
    surface_state.cached_offset_x = 0;
    surface_state.cached_offset_y = 0;
    surface_state.cached_surface_damage.clear();
    surface_state.cached_buffer_damage.clear();
    surface_state.has_cached_state = false;
    if (surface_state.presentation_submitted) surface_state.commit_after_submission = true;
    discardCommitFeedbacks(surface_state, .active);
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .cached) callback.state = .active;
    }
    if (commit_info.has_buffer) {
        setCommitFeedbackState(surface_state, .cached, .active);
    } else {
        discardCommitFeedbacks(surface_state, .cached);
    }

    finishApplied(self, commit_info);
}

fn postBufferError(self: *Self, err: BufferSnapshot.Error) void {
    switch (err) {
        error.OutOfMemory => self.resource.postNoMemory(),
        error.InvalidSize => self.resource.postError(
            .invalid_size,
            "buffer dimensions are incompatible with surface state",
        ),
        error.InvalidBuffer => self.resource.getClient().postImplementationError(
            "invalid shared-memory buffer",
        ),
        error.BadViewportSize => if (self.viewport_handler) |handler|
            handler.resource.postError(.bad_size, "viewport source size must be integral")
        else
            self.resource.getClient().postImplementationError("viewport object is missing"),
        error.ViewportOutOfBuffer => if (self.viewport_handler) |handler|
            handler.resource.postError(.out_of_buffer, "viewport source exceeds the buffer")
        else
            self.resource.getClient().postImplementationError("viewport object is missing"),
    }
}

fn finishApplied(self: *Self, commit_info: CommitInfo) void {
    if (self.role_handler) |handler| handler.after_commit(handler.context, commit_info);

    for (self.commit_listeners.items) |listener| listener.applied(listener.context);
}

fn commitFeedbackWithState(
    surface_state: *State,
    target_status: CommitFeedback.Status,
) ?*CommitFeedback {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == target_status) return feedback;
    }
    return null;
}

fn discardCommitFeedbacks(surface_state: *State, target_status: CommitFeedback.Status) void {
    while (commitFeedbackWithState(surface_state, target_status)) |feedback| {
        feedback.discarded(feedback.context);
    }
}

fn setCommitFeedbackState(
    surface_state: *State,
    from: CommitFeedback.Status,
    to: CommitFeedback.Status,
) void {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == from) feedback.state = to;
    }
}

fn handleDestroy(_: *wl.Surface, self: *Self) void {
    self.pending_attachment.clear();
    if (self.role_handler) |handler| handler.surface_destroyed(handler.context);
    if (self.viewport_handler) |handler| {
        self.viewport_handler = null;
        handler.surface_destroyed(handler.context);
    }
    while (self.commit_listeners.items.len > 0) {
        const previous_len = self.commit_listeners.items.len;
        self.commit_listeners.items[previous_len - 1].surface_destroyed(
            self.commit_listeners.items[previous_len - 1].context,
        );
        std.debug.assert(self.commit_listeners.items.len < previous_len);
    }
    self.commit_listeners.deinit(self.allocator);
    const surface_state = self.state();

    while (surface_state.callbacks.items.len > 0) {
        surface_state.callbacks.items[surface_state.callbacks.items.len - 1].resource.destroy();
    }
    while (surface_state.commit_feedbacks.items.len > 0) {
        const feedback = surface_state.commit_feedbacks.items[surface_state.commit_feedbacks.items.len - 1];
        feedback.discarded(feedback.context);
    }

    var removed = self.store.remove(self.id) orelse unreachable;
    removed.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn validTransform(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .normal,
        .@"90",
        .@"180",
        .@"270",
        .flipped,
        .flipped_90,
        .flipped_180,
        .flipped_270,
        => true,
        else => false,
    };
}

fn swapsAxes(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
}

fn logicalSize(
    buffer_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
) error{InvalidSize}!render_types.Size {
    if (scale <= 0 or !validTransform(transform)) return error.InvalidSize;

    const transformed: render_types.Size = if (swapsAxes(transform))
        .{ .width = buffer_size.height, .height = buffer_size.width }
    else
        buffer_size;
    const unsigned_scale: u32 = @intCast(scale);
    if (transformed.width % unsigned_scale != 0 or
        transformed.height % unsigned_scale != 0) return error.InvalidSize;

    return .{
        .width = transformed.width / unsigned_scale,
        .height = transformed.height / unsigned_scale,
    };
}

const ViewportGeometry = struct {
    logical_size: render_types.Size,
    source: ?render_types.SourceRect,
};

fn viewportGeometry(
    buffer_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
    viewport: ViewportState,
) BufferSnapshot.Error!ViewportGeometry {
    const base_size = logicalSize(buffer_size, scale, transform) catch
        return error.InvalidSize;
    const source = viewport.source orelse return .{
        .logical_size = viewport.destination orelse base_size,
        .source = null,
    };

    const right = @as(i64, source.x) + source.width;
    const bottom = @as(i64, source.y) + source.height;
    if (source.x < 0 or source.y < 0 or source.width <= 0 or source.height <= 0 or
        right > @as(i64, base_size.width) * 256 or
        bottom > @as(i64, base_size.height) * 256)
    {
        return error.ViewportOutOfBuffer;
    }

    const logical_size = viewport.destination orelse size: {
        if (@mod(source.width, 256) != 0 or @mod(source.height, 256) != 0) {
            return error.BadViewportSize;
        }
        const source_size: render_types.Size = .{
            .width = @as(u32, @intCast(@divExact(source.width, 256))),
            .height = @as(u32, @intCast(@divExact(source.height, 256))),
        };
        break :size source_size;
    };
    // Rendering currently skips transformed buffers. When transform rendering is
    // added, this post-transform source rectangle must be mapped back to buffer pixels.
    const buffer_scale: f64 = @floatFromInt(scale);
    return .{
        .logical_size = logical_size,
        .source = .{
            .x = @as(f64, @floatFromInt(source.x)) / 256.0 * buffer_scale,
            .y = @as(f64, @floatFromInt(source.y)) / 256.0 * buffer_scale,
            .width = @as(f64, @floatFromInt(source.width)) / 256.0 * buffer_scale,
            .height = @as(f64, @floatFromInt(source.height)) / 256.0 * buffer_scale,
        },
    };
}

const InputRegion = struct {
    infinite: bool,
    value: Region,

    fn init() InputRegion {
        return .{ .infinite = true, .value = Region.init() };
    }

    fn deinit(self: *InputRegion) void {
        self.value.deinit();
        self.* = undefined;
    }

    fn set(self: *InputRegion, region: *const Region) Region.Error!void {
        try self.value.copyFrom(region);
        self.infinite = false;
    }

    fn setInfinite(self: *InputRegion) void {
        self.value.clear();
        self.infinite = true;
    }

    fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }
};

const Attachment = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    const Error = error{UnsupportedBuffer};

    fn set(self: *Attachment, resource: ?*wl.Buffer) Error!void {
        self.clear();
        const buffer = resource orelse return;
        const shm_buffer = wl.shm.Buffer.get(@ptrCast(buffer)) orelse
            return error.UnsupportedBuffer;

        self.resource = buffer;
        self.shm = wl_shm_buffer_ref(shm_buffer);
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(buffer)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Attachment) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        self.resource = null;
        self.shm = null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Attachment = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
    }
};

pub const BufferSnapshot = struct {
    allocator: std.mem.Allocator,
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
    source: ?render_types.SourceRect,
    pixels: []u32,

    const Error = error{
        OutOfMemory,
        InvalidSize,
        InvalidBuffer,
        BadViewportSize,
        ViewportOutOfBuffer,
    };

    fn copyShm(
        allocator: std.mem.Allocator,
        shm_buffer: *wl.shm.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
    ) Error!BufferSnapshot {
        const width = shm_buffer.getWidth();
        const height = shm_buffer.getHeight();
        const stride = shm_buffer.getStride();
        if (width <= 0 or height <= 0 or stride <= 0) return error.InvalidBuffer;

        const buffer_size: render_types.Size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        const geometry = viewportGeometry(buffer_size, scale, transform, viewport) catch |err|
            return err;
        const row_bytes = std.math.mul(usize, buffer_size.width, @sizeOf(u32)) catch
            return error.InvalidBuffer;
        if (stride < row_bytes) return error.InvalidBuffer;

        const format = shm_buffer.getFormat();
        const argb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.argb8888));
        const xrgb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.xrgb8888));
        if (format != argb8888 and format != xrgb8888) return error.InvalidBuffer;

        const pixel_count = buffer_size.pixelCount() catch return error.InvalidBuffer;
        const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);

        shm_buffer.beginAccess();
        defer shm_buffer.endAccess();
        const data = shm_buffer.getData() orelse return error.InvalidBuffer;
        const source: [*]const u8 = @ptrCast(data);
        const destination = std.mem.sliceAsBytes(pixels);
        const source_stride: usize = @intCast(stride);
        for (0..buffer_size.height) |y| {
            const source_offset = y * source_stride;
            const destination_offset = y * row_bytes;
            @memcpy(
                destination[destination_offset..][0..row_bytes],
                source[source_offset..][0..row_bytes],
            );
        }

        if (format == xrgb8888) {
            for (pixels) |*pixel| pixel.* |= 0xff000000;
        }

        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .pixels = pixels,
        };
    }

    fn updateGeometry(
        self: *BufferSnapshot,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
    ) Error!void {
        const geometry = try viewportGeometry(self.buffer_size, scale, transform, viewport);
        self.logical_size = geometry.logical_size;
        self.scale = scale;
        self.transform = transform;
        self.source = geometry.source;
    }

    pub fn deinit(self: *BufferSnapshot) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn pixelBuffer(self: *BufferSnapshot) render_types.PixelBuffer {
        return .{
            .size = self.buffer_size,
            .stride_pixels = self.buffer_size.width,
            .pixels = self.pixels,
        };
    }
};

const FrameCallback = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    surface_id: Id,
    resource: *wl.Callback,
    state: enum { pending, cached, active, submitted },

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *FrameCallback = @ptrCast(@alignCast(resource.getUserData().?));
        removeCallback(self.store, self.surface_id, self);
        self.allocator.destroy(self);
    }
};

fn createFrameCallback(self: *Self, id: u32) error{OutOfMemory}!void {
    const resource = wl.Callback.create(self.resource.getClient(), 1, id) catch
        return error.OutOfMemory;
    errdefer resource.destroy();

    const callback = self.allocator.create(FrameCallback) catch return error.OutOfMemory;
    errdefer self.allocator.destroy(callback);
    callback.* = .{
        .allocator = self.allocator,
        .store = self.store,
        .surface_id = self.id,
        .resource = resource,
        .state = .pending,
    };
    try self.state().callbacks.append(self.allocator, callback);

    @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
        null,
        null,
        callback,
        FrameCallback.handleDestroy,
    );
}

fn removeCallback(store: *Store, surface_id: Id, callback: *FrameCallback) void {
    const surface_state = store.get(surface_id) orelse unreachable;
    for (surface_state.callbacks.items, 0..) |candidate, index| {
        if (candidate == callback) {
            _ = surface_state.callbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "logical surface size accounts for scale and transform" {
    try std.testing.expectEqual(
        render_types.Size{ .width = 100, .height = 50 },
        try logicalSize(.{ .width = 200, .height = 100 }, 2, .normal),
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 50, .height = 100 },
        try logicalSize(.{ .width = 200, .height = 100 }, 2, .@"90"),
    );
    try std.testing.expectError(
        error.InvalidSize,
        logicalSize(.{ .width = 201, .height = 100 }, 2, .normal),
    );
}

test "viewport destination defines logical surface size" {
    const geometry = try viewportGeometry(
        .{ .width = 1200, .height = 900 },
        1,
        .normal,
        .{ .destination = .{ .width = 800, .height = 600 } },
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 800, .height = 600 },
        geometry.logical_size,
    );
    try std.testing.expectEqual(@as(?render_types.SourceRect, null), geometry.source);
}

test "viewport source is validated and converted to buffer coordinates" {
    const geometry = try viewportGeometry(
        .{ .width = 8, .height = 8 },
        2,
        .normal,
        .{
            .source = .{ .x = 256, .y = 512, .width = 512, .height = 256 },
            .destination = .{ .width = 4, .height = 2 },
        },
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 4, .height = 2 },
        geometry.logical_size,
    );
    try std.testing.expectEqual(@as(f64, 2), geometry.source.?.x);
    try std.testing.expectEqual(@as(f64, 4), geometry.source.?.y);
    try std.testing.expectEqual(@as(f64, 4), geometry.source.?.width);
    try std.testing.expectEqual(@as(f64, 2), geometry.source.?.height);
    try std.testing.expectError(
        error.ViewportOutOfBuffer,
        viewportGeometry(
            .{ .width = 8, .height = 8 },
            2,
            .normal,
            .{ .source = .{ .x = 768, .y = 0, .width = 512, .height = 256 } },
        ),
    );
    try std.testing.expectError(
        error.BadViewportSize,
        viewportGeometry(
            .{ .width = 8, .height = 8 },
            2,
            .normal,
            .{ .source = .{ .x = 0, .y = 0, .width = 128, .height = 256 } },
        ),
    );
}
