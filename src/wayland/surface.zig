//! Server-side wl_surface state and compositor-owned buffer snapshots.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const render_types = @import("../render/types.zig");
const slot_map = @import("../slot_map.zig");
const WaylandRegion = @import("region.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const SinglePixelBuffer = @import("single_pixel_buffer.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.surface);

allocator: std.mem.Allocator,
store: *Store,
id: Id,
resource: *wl.Surface,
pending_attachment: Attachment,
has_pending_attachment: bool,
role_handler: ?RoleHandler,
viewport_handler: ?ViewportHandler,
content_type_handler: ?ContentTypeHandler,
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
    pending_content_type: ContentType,
    current_content_type: ContentType,
    pending_surface_damage: Region,
    pending_buffer_damage: Region,
    current_damage: Region,
    current_damage_precise: bool,
    pending_opaque: Region,
    current_opaque: Region,
    pending_input: InputRegion,
    current_input: InputRegion,
    callbacks: std.ArrayList(*FrameCallback),
    release_callbacks: std.ArrayList(*BufferReleaseCallback),
    commit_feedbacks: std.ArrayList(*CommitFeedback),
    presentation_output: ?*anyopaque,
    commit_after_submission: bool,
    preferred_buffer_scale: ?i32,
    source_cache_id: u64,
    next_source_version: u64,
    current_buffer: ?BufferSnapshot,
    cached_buffer: ?BufferSnapshot,
    cached_attachment_changed: bool,
    cached_offset_x: i32,
    cached_offset_y: i32,
    cached_scale: i32,
    cached_transform: wl.Output.Transform,
    cached_viewport: ViewportState,
    cached_content_type: ContentType,
    cached_surface_damage: Region,
    cached_buffer_damage: Region,
    cached_opaque: Region,
    cached_input: InputRegion,
    has_cached_state: bool,
    role: ?Role,
    has_committed: bool,
    has_committed_buffer: bool,

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
            .pending_content_type = .none,
            .current_content_type = .none,
            .pending_surface_damage = Region.init(),
            .pending_buffer_damage = Region.init(),
            .current_damage = Region.init(),
            .current_damage_precise = false,
            .pending_opaque = Region.init(),
            .current_opaque = Region.init(),
            .pending_input = InputRegion.init(),
            .current_input = InputRegion.init(),
            .callbacks = .empty,
            .release_callbacks = .empty,
            .commit_feedbacks = .empty,
            .presentation_output = null,
            .commit_after_submission = false,
            .preferred_buffer_scale = null,
            .source_cache_id = render_types.allocateSourceCacheId(),
            .next_source_version = 1,
            .current_buffer = null,
            .cached_buffer = null,
            .cached_attachment_changed = false,
            .cached_offset_x = 0,
            .cached_offset_y = 0,
            .cached_scale = 1,
            .cached_transform = .normal,
            .cached_viewport = .{},
            .cached_content_type = .none,
            .cached_surface_damage = Region.init(),
            .cached_buffer_damage = Region.init(),
            .cached_opaque = Region.init(),
            .cached_input = InputRegion.init(),
            .has_cached_state = false,
            .role = null,
            .has_committed = false,
            .has_committed_buffer = false,
        };
    }

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        std.debug.assert(self.callbacks.items.len == 0);
        std.debug.assert(self.release_callbacks.items.len == 0);
        std.debug.assert(self.commit_feedbacks.items.len == 0);
        self.callbacks.deinit(allocator);
        self.release_callbacks.deinit(allocator);
        self.commit_feedbacks.deinit(allocator);
        if (self.current_buffer) |*current| current.deinit();
        if (self.cached_buffer) |*cached| cached.deinit();
        self.pending_surface_damage.deinit();
        self.pending_buffer_damage.deinit();
        self.current_damage.deinit();
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
        .content_type_handler = null,
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

pub fn currentLogicalSize(store: *Store, id: Id) ?render_types.Size {
    const surface_state = store.get(id) orelse return null;
    const buffer = surface_state.current_buffer orelse return null;
    return buffer.logical_size;
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

pub const ContentType = wp.ContentTypeV1.Type;

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

pub const ContentTypeHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setContentTypeHandler(self: *Self, handler: ContentTypeHandler) error{AlreadyExists}!void {
    if (self.content_type_handler != null) return error.AlreadyExists;
    self.content_type_handler = handler;
}

pub fn clearContentTypeHandler(self: *Self) void {
    std.debug.assert(self.content_type_handler != null);
    self.content_type_handler = null;
    self.state().pending_content_type = .none;
}

pub fn setPendingContentType(self: *Self, content_type: ContentType) void {
    std.debug.assert(self.content_type_handler != null);
    self.state().pending_content_type = content_type;
}

pub fn currentContentType(store: *Store, id: Id) ?ContentType {
    const surface_state = store.get(id) orelse return null;
    return surface_state.current_content_type;
}

pub const Role = enum {
    xdg_toplevel,
    xdg_popup,
    layer_surface,
    session_lock,
    subsurface,
    cursor,
    drag_icon,
    input_popup,
    river_decoration,
    river_shell_surface,
    xwayland,
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
    role_tag: ?RoleTag = null,
};

pub const RoleTag = enum {
    pointer_cursor,
    tablet_tool_cursor,
};

pub const RoleIdentity = struct {
    tag: RoleTag,
    context: *anyopaque,
};

pub const CommitListener = struct {
    context: *anyopaque,
    applied: *const fn (*anyopaque) void,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const CommitFeedback = struct {
    context: *anyopaque,
    sampled: *const fn (*anyopaque, *anyopaque) void,
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
    if (role == .cursor) {
        surface_state.pending_input.setEmpty();
        surface_state.current_input.setEmpty();
        surface_state.cached_input.setEmpty();
    }
}

pub fn assignedRole(self: *Self) ?Role {
    return self.state().role;
}

pub fn roleIdentity(self: *Self, role: Role) ?RoleIdentity {
    if (self.state().role != role) return null;
    const handler = self.role_handler orelse return null;
    return .{
        .tag = handler.role_tag orelse return null,
        .context = handler.context,
    };
}

pub fn hasBufferAttachedOrCommitted(self: *Self) bool {
    return self.pending_attachment.hasBuffer() or self.state().has_committed_buffer;
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

/// The returned region is borrowed until the surface's next applied commit or
/// any store insertion that reallocates its slots.
pub fn currentDamage(store: *Store, id: Id) ?*const Region {
    const surface_state = store.get(id) orelse return null;
    return &surface_state.current_damage;
}

pub fn currentDamagePrecise(store: *Store, id: Id) bool {
    const surface_state = store.get(id) orelse return false;
    return surface_state.current_damage_precise;
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

pub fn copyCurrentInputRegion(store: *Store, id: Id, destination: *Region) Region.Error!void {
    destination.clear();
    const surface_state = store.get(id) orelse return;
    const buffer = surface_state.current_buffer orelse return;
    try destination.add(
        0,
        0,
        @intCast(buffer.logical_size.width),
        @intCast(buffer.logical_size.height),
    );
    if (!surface_state.current_input.infinite) {
        try destination.intersectWith(&surface_state.current_input.value);
    }
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

pub fn setPreferredBufferScale(store: *Store, id: Id, scale: u32) void {
    std.debug.assert(scale > 0 and scale <= std.math.maxInt(i32));
    const surface_state = store.get(id) orelse return;
    const resource = surface_state.resource;
    if (resource.getVersion() < wl.Surface.preferred_buffer_scale_since_version) return;
    const scale_value: i32 = @intCast(scale);
    if (surface_state.preferred_buffer_scale == scale_value) return;
    surface_state.preferred_buffer_scale = scale_value;
    resource.sendPreferredBufferScale(scale_value);
    resource.sendPreferredBufferTransform(.normal);
}

pub fn submitPresentationFor(store: *Store, id: Id, output_context: *anyopaque) void {
    const surface_state = store.get(id) orelse return;
    if (surface_state.presentation_output != null) return;
    surface_state.presentation_output = output_context;
    surface_state.commit_after_submission = false;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .active) callback.state = .submitted;
    }
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == .active) {
            feedback.sampled(feedback.context, output_context);
            feedback.state = .submitted;
        }
    }
}

pub fn discardUnsubmittedFeedback(store: *Store) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        if (entry.value.presentation_output == null) {
            discardCommitFeedbacks(entry.value, .active);
        }
    }
}

pub fn finishPresentation(
    store: *Store,
    output_context: *anyopaque,
    info: presentation.Info,
) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (surface_state.presentation_output != output_context) continue;
        surface_state.presentation_output = null;
        surface_state.commit_after_submission = false;
        sendFrameDoneFor(store, entry.id, info.timestamp.milliseconds());
        while (commitFeedbackWithState(surface_state, .submitted)) |feedback| {
            feedback.presented(feedback.context, info);
        }
    }
}

pub fn discardPresentation(store: *Store, output_context: *anyopaque) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (surface_state.presentation_output != output_context) continue;
        surface_state.presentation_output = null;
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
            if (surface_state.role == .cursor) return;
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
        .get_release => |release| createBufferReleaseCallback(self, release.callback) catch
            resource.postNoMemory(),
    }
}

fn commit(self: *Self) void {
    const surface_state = self.state();
    if (surface_state.release_callbacks.items.len > 0 and
        (!self.has_pending_attachment or !self.pending_attachment.hasBuffer()))
    {
        self.resource.postError(
            .no_buffer,
            "wl_surface.get_release requires a non-null buffer attachment",
        );
        return;
    }

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
            self.pending_attachment.hasBuffer()
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
    var applied_info = commit_info;
    const previous_geometry = currentBufferGeometry(surface_state);
    const offset_changed = surface_state.pending_offset_x != 0 or
        surface_state.pending_offset_y != 0;

    surface_state.current_opaque.copyFrom(&surface_state.pending_opaque) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_input.copyFrom(&surface_state.pending_input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (self.has_pending_attachment) {
        const reusable = if (surface_state.current_buffer) |*current| current else null;
        const snapshot = snapshotPendingAttachment(self, reusable) catch |err| switch (err) {
            error.ImportFailed => failed: {
                log.warn("DMA-BUF became unavailable after successful import", .{});
                applied_info.has_buffer = false;
                break :failed null;
            },
            else => {
                postBufferError(self, err);
                return;
            },
        };

        if (surface_state.current_buffer) |*current| current.deinit();
        surface_state.current_buffer = snapshot;

        releasePendingAttachment(self);
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
    surface_state.current_content_type = surface_state.pending_content_type;
    surface_state.current_offset_x = surface_state.pending_offset_x;
    surface_state.current_offset_y = surface_state.pending_offset_y;
    updateCurrentDamage(
        surface_state,
        previous_geometry,
        &surface_state.pending_surface_damage,
        &surface_state.pending_buffer_damage,
        offset_changed,
    );
    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_committed = true;
    if (applied_info.has_buffer) surface_state.has_committed_buffer = true;
    if (surface_state.presentation_output != null) surface_state.commit_after_submission = true;
    discardCommitFeedbacks(surface_state, .active);
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) callback.state = .active;
    }
    if (applied_info.has_buffer) {
        setCommitFeedbackState(surface_state, .pending, .active);
    } else {
        discardCommitFeedbacks(surface_state, .pending);
    }

    finishApplied(self, applied_info);
}

fn cachePending(self: *Self) bool {
    const surface_state = self.state();
    var snapshot: ?BufferSnapshot = null;
    defer if (snapshot) |*buffer| buffer.deinit();

    if (self.has_pending_attachment) {
        snapshot = snapshotPendingAttachment(self, null) catch |err| switch (err) {
            error.ImportFailed => failed: {
                log.warn("DMA-BUF became unavailable after successful import", .{});
                break :failed null;
            },
            else => {
                postBufferError(self, err);
                return false;
            },
        };
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

        releasePendingAttachment(self);
    }

    surface_state.cached_scale = surface_state.pending_scale;
    surface_state.cached_transform = surface_state.pending_transform;
    surface_state.cached_viewport = surface_state.pending_viewport;
    surface_state.cached_content_type = surface_state.pending_content_type;
    surface_state.cached_offset_x +|= surface_state.pending_offset_x;
    surface_state.cached_offset_y +|= surface_state.pending_offset_y;
    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_cached_state = true;
    surface_state.has_committed = true;
    const cached_has_buffer = if (surface_state.cached_attachment_changed)
        surface_state.cached_buffer != null
    else
        surface_state.current_buffer != null;
    if (cached_has_buffer) surface_state.has_committed_buffer = true;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) callback.state = .cached;
    }
    setCommitFeedbackState(surface_state, .pending, .cached);
    return true;
}

fn applyCached(self: *Self) void {
    const surface_state = self.state();
    std.debug.assert(surface_state.has_cached_state);
    const previous_geometry = currentBufferGeometry(surface_state);
    const offset_changed = surface_state.cached_offset_x != 0 or
        surface_state.cached_offset_y != 0;
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
    surface_state.current_content_type = surface_state.cached_content_type;
    surface_state.current_offset_x = surface_state.cached_offset_x;
    surface_state.current_offset_y = surface_state.cached_offset_y;
    updateCurrentDamage(
        surface_state,
        previous_geometry,
        &surface_state.cached_surface_damage,
        &surface_state.cached_buffer_damage,
        offset_changed,
    );
    surface_state.cached_offset_x = 0;
    surface_state.cached_offset_y = 0;
    surface_state.cached_surface_damage.clear();
    surface_state.cached_buffer_damage.clear();
    surface_state.has_cached_state = false;
    if (surface_state.presentation_output != null) surface_state.commit_after_submission = true;
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
        error.ImportFailed => unreachable,
    }
}

fn snapshotPendingAttachment(
    self: *Self,
    reusable: ?*BufferSnapshot,
) BufferSnapshot.Error!?BufferSnapshot {
    const surface_state = self.state();
    const source_cache: render_types.SourceCache = .{
        .id = surface_state.source_cache_id,
        .version = surface_state.next_source_version,
    };
    const snapshot = if (self.pending_attachment.shm) |shm_buffer|
        try BufferSnapshot.copyShm(
            self.allocator,
            shm_buffer,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            reusable,
            &surface_state.pending_surface_damage,
            &surface_state.pending_buffer_damage,
            source_cache,
        )
    else if (self.pending_attachment.dmabuf) |dmabuf_buffer|
        try BufferSnapshot.copyDmabuf(
            self.allocator,
            dmabuf_buffer,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            source_cache,
        )
    else if (self.pending_attachment.single_pixel) |pixel|
        try BufferSnapshot.copySinglePixel(
            self.allocator,
            pixel,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            reusable,
            source_cache,
        )
    else
        return null;
    surface_state.next_source_version +%= 1;
    return snapshot;
}

fn finishApplied(self: *Self, commit_info: CommitInfo) void {
    if (self.role_handler) |handler| handler.after_commit(handler.context, commit_info);

    for (self.commit_listeners.items) |listener| listener.applied(listener.context);
}

fn releasePendingAttachment(self: *Self) void {
    std.debug.assert(self.has_pending_attachment);
    // SHM storage is no longer used once its pixels have been copied, even
    // when the resulting content update remains cached by a synchronized role.
    if (self.pending_attachment.resource) |buffer| buffer.sendRelease();
    self.pending_attachment.clear();
    self.has_pending_attachment = false;

    const surface_state = self.state();
    while (surface_state.release_callbacks.items.len > 0) {
        surface_state.release_callbacks.items[0].resource.destroySendDone(0);
    }
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
    if (self.content_type_handler) |handler| {
        self.content_type_handler = null;
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
    while (surface_state.release_callbacks.items.len > 0) {
        surface_state.release_callbacks.items[surface_state.release_callbacks.items.len - 1]
            .resource.destroy();
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

    fn setEmpty(self: *InputRegion) void {
        self.value.clear();
        self.infinite = false;
    }

    fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }
};

const Attachment = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    dmabuf: ?*LinuxDmabuf.Buffer = null,
    single_pixel: ?u32 = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    const Error = error{UnsupportedBuffer};

    fn set(self: *Attachment, resource: ?*wl.Buffer) Error!void {
        self.clear();
        const buffer = resource orelse return;
        const shm_buffer = wl.shm.Buffer.get(@ptrCast(buffer));
        const dmabuf_buffer = if (shm_buffer == null)
            LinuxDmabuf.Buffer.fromResource(buffer)
        else
            null;
        const single_pixel_buffer = if (shm_buffer == null and dmabuf_buffer == null)
            SinglePixelBuffer.Buffer.fromResource(buffer)
        else
            null;
        if (shm_buffer == null and dmabuf_buffer == null and single_pixel_buffer == null) {
            return error.UnsupportedBuffer;
        }

        self.resource = buffer;
        self.shm = if (shm_buffer) |shm| wl_shm_buffer_ref(shm) else null;
        self.dmabuf = dmabuf_buffer;
        self.single_pixel = if (single_pixel_buffer) |single| single.pixel else null;
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(buffer)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Attachment) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        self.resource = null;
        self.shm = null;
        self.dmabuf = null;
        self.single_pixel = null;
    }

    fn hasBuffer(self: *const Attachment) bool {
        return self.shm != null or self.dmabuf != null or self.single_pixel != null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Attachment = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
        self.dmabuf = null;
    }
};

const BufferGeometry = struct {
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    transform: wl.Output.Transform,
    source: ?render_types.SourceRect,
};

fn currentBufferGeometry(surface_state: *const State) ?BufferGeometry {
    const buffer = surface_state.current_buffer orelse return null;
    return .{
        .buffer_size = buffer.buffer_size,
        .logical_size = buffer.logical_size,
        .transform = buffer.transform,
        .source = buffer.source,
    };
}

fn updateCurrentDamage(
    surface_state: *State,
    previous_geometry: ?BufferGeometry,
    surface_damage: *const Region,
    buffer_damage: *const Region,
    offset_changed: bool,
) void {
    surface_state.current_damage.clear();
    surface_state.current_damage_precise = !offset_changed;
    const current_geometry = currentBufferGeometry(surface_state);
    if (!std.meta.eql(previous_geometry, current_geometry)) {
        const previous_size = if (previous_geometry) |geometry|
            geometry.logical_size
        else
            render_types.Size{ .width = 0, .height = 0 };
        const current_size = if (current_geometry) |geometry|
            geometry.logical_size
        else
            render_types.Size{ .width = 0, .height = 0 };
        surface_state.current_damage.setRectangle(
            0,
            0,
            @max(previous_size.width, current_size.width),
            @max(previous_size.height, current_size.height),
        );
        return;
    }

    surface_state.current_damage.copyFrom(surface_damage) catch {
        return setFullCurrentDamage(surface_state);
    };
    const buffer = if (surface_state.current_buffer) |*current| current else return;
    if (!addBufferDamage(&surface_state.current_damage, buffer_damage, buffer)) {
        setFullCurrentDamage(surface_state);
    }
}

fn setFullCurrentDamage(surface_state: *State) void {
    const size = if (surface_state.current_buffer) |buffer|
        buffer.logical_size
    else
        render_types.Size{ .width = 0, .height = 0 };
    surface_state.current_damage.setRectangle(0, 0, size.width, size.height);
}

fn addBufferDamage(
    destination: *Region,
    damage: *const Region,
    buffer: *const BufferSnapshot,
) bool {
    if (buffer.transform != .normal) return damage.isEmpty();
    const source = buffer.source orelse render_types.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(buffer.buffer_size.width),
        .height = @floatFromInt(buffer.buffer_size.height),
    };
    const logical_width: f64 = @floatFromInt(buffer.logical_size.width);
    const logical_height: f64 = @floatFromInt(buffer.logical_size.height);
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        const rectangle_left: f64 = @floatFromInt(rectangle.x);
        const rectangle_top: f64 = @floatFromInt(rectangle.y);
        const rectangle_right = rectangle_left + @as(f64, @floatFromInt(rectangle.width));
        const rectangle_bottom = rectangle_top + @as(f64, @floatFromInt(rectangle.height));
        const left = @max(rectangle_left, source.x);
        const top = @max(rectangle_top, source.y);
        const right = @min(rectangle_right, source.x + source.width);
        const bottom = @min(rectangle_bottom, source.y + source.height);
        if (right <= left or bottom <= top) continue;

        const logical_left = std.math.clamp(
            @floor((left - source.x) * logical_width / source.width),
            0,
            logical_width,
        );
        const logical_top = std.math.clamp(
            @floor((top - source.y) * logical_height / source.height),
            0,
            logical_height,
        );
        const logical_right = std.math.clamp(
            @ceil((right - source.x) * logical_width / source.width),
            0,
            logical_width,
        );
        const logical_bottom = std.math.clamp(
            @ceil((bottom - source.y) * logical_height / source.height),
            0,
            logical_height,
        );
        const x: i32 = @intFromFloat(logical_left);
        const y: i32 = @intFromFloat(logical_top);
        const width: i32 = @intFromFloat(logical_right - logical_left);
        const height: i32 = @intFromFloat(logical_bottom - logical_top);
        destination.add(x, y, width, height) catch return false;
    }
    return true;
}

pub const BufferSnapshot = struct {
    allocator: std.mem.Allocator,
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
    source: ?render_types.SourceRect,
    pixels: []u32,
    source_cache: render_types.SourceCache,
    source_damage: ?[]const render_types.Rect,

    const Error = error{
        OutOfMemory,
        InvalidSize,
        InvalidBuffer,
        BadViewportSize,
        ViewportOutOfBuffer,
        ImportFailed,
    };

    fn copyShm(
        allocator: std.mem.Allocator,
        shm_buffer: *wl.shm.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        reusable: ?*BufferSnapshot,
        surface_damage: *const Region,
        buffer_damage: *const Region,
        source_cache: render_types.SourceCache,
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
        shm_buffer.beginAccess();
        defer shm_buffer.endAccess();
        const data = shm_buffer.getData() orelse return error.InvalidBuffer;
        const can_update_partially = if (reusable) |snapshot|
            snapshot.pixels.len == pixel_count and
                std.meta.eql(snapshot.buffer_size, buffer_size) and
                std.meta.eql(snapshot.logical_size, geometry.logical_size) and
                snapshot.transform == transform and
                std.meta.eql(snapshot.source, geometry.source) and
                surface_damage.isEmpty()
        else
            false;
        const source_damage = if (can_update_partially)
            try copyBufferDamage(allocator, buffer_damage, buffer_size)
        else
            null;
        errdefer if (source_damage) |damage| {
            if (damage.len > 0) allocator.free(damage);
        };
        const pixels = if (reusable) |snapshot|
            snapshot.takePixels(pixel_count) orelse
                allocator.alloc(u32, pixel_count) catch return error.OutOfMemory
        else
            allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
        const source: [*]const u8 = @ptrCast(data);
        const source_stride: usize = @intCast(stride);
        copyShmPixels(
            pixels,
            source,
            source_stride,
            buffer_size,
            format == xrgb8888,
            if (can_update_partially) buffer_damage else null,
        );

        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .pixels = pixels,
            .source_cache = source_cache,
            .source_damage = source_damage,
        };
    }

    fn copyDmabuf(
        allocator: std.mem.Allocator,
        buffer: *LinuxDmabuf.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        source_cache: render_types.SourceCache,
    ) Error!BufferSnapshot {
        const buffer_size = buffer.size();
        const geometry = try viewportGeometry(buffer_size, scale, transform, viewport);
        const pixels = buffer.copyPixels(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ImportFailed => return error.ImportFailed,
        };

        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .pixels = pixels,
            .source_cache = source_cache,
            .source_damage = null,
        };
    }

    fn copySinglePixel(
        allocator: std.mem.Allocator,
        pixel: u32,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        reusable: ?*BufferSnapshot,
        source_cache: render_types.SourceCache,
    ) Error!BufferSnapshot {
        const buffer_size: render_types.Size = .{ .width = 1, .height = 1 };
        const geometry = try viewportGeometry(buffer_size, scale, transform, viewport);
        const pixels = if (reusable) |snapshot|
            snapshot.takePixels(1) orelse
                allocator.alloc(u32, 1) catch return error.OutOfMemory
        else
            allocator.alloc(u32, 1) catch return error.OutOfMemory;
        pixels[0] = pixel;
        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .pixels = pixels,
            .source_cache = source_cache,
            .source_damage = null,
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

    fn takePixels(self: *BufferSnapshot, pixel_count: usize) ?[]u32 {
        if (self.pixels.len != pixel_count) return null;
        const pixels = self.pixels;
        self.pixels = &.{};
        return pixels;
    }

    pub fn deinit(self: *BufferSnapshot) void {
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        if (self.source_damage) |damage| {
            if (damage.len > 0) self.allocator.free(damage);
        }
        self.* = undefined;
    }

    pub fn pixelBuffer(self: *BufferSnapshot) render_types.PixelBuffer {
        return .{
            .size = self.buffer_size,
            .stride_pixels = self.buffer_size.width,
            .pixels = self.pixels,
            .source_cache = self.source_cache,
            .source_damage = self.source_damage,
        };
    }
};

fn copyBufferDamage(
    allocator: std.mem.Allocator,
    damage: *const Region,
    size: render_types.Size,
) error{OutOfMemory}![]const render_types.Rect {
    var rectangles: std.ArrayList(render_types.Rect) = .empty;
    defer rectangles.deinit(allocator);
    var iterator = damage.rectangleIterator();
    while (iterator.next()) |rectangle| {
        const clipped = (render_types.Rect{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        }).clipTo(size) orelse continue;
        rectangles.append(allocator, clipped) catch return error.OutOfMemory;
    }
    return rectangles.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn copyShmPixels(
    destination: []u32,
    source: [*]const u8,
    source_stride: usize,
    size: render_types.Size,
    force_opaque: bool,
    damage: ?*const Region,
) void {
    const row_bytes = @as(usize, size.width) * @sizeOf(u32);
    std.debug.assert(source_stride >= row_bytes);
    std.debug.assert(destination.len >= @as(usize, size.width) * size.height);
    if (damage) |region| {
        var rectangles = region.rectangleIterator();
        while (rectangles.next()) |rectangle| {
            const clipped = (render_types.Rect{
                .x = rectangle.x,
                .y = rectangle.y,
                .width = rectangle.width,
                .height = rectangle.height,
            }).clipTo(size) orelse continue;
            copyShmRectangle(
                destination,
                source,
                source_stride,
                size.width,
                clipped,
                force_opaque,
            );
        }
        return;
    }
    copyShmRectangle(
        destination,
        source,
        source_stride,
        size.width,
        .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
        force_opaque,
    );
}

fn copyShmRectangle(
    destination: []u32,
    source: [*]const u8,
    source_stride: usize,
    destination_stride: u32,
    rectangle: render_types.Rect,
    force_opaque: bool,
) void {
    std.debug.assert(rectangle.x >= 0 and rectangle.y >= 0);
    const x: usize = @intCast(rectangle.x);
    const y: usize = @intCast(rectangle.y);
    const copy_bytes = @as(usize, rectangle.width) * @sizeOf(u32);
    for (0..rectangle.height) |row| {
        const source_offset = (y + row) * source_stride + x * @sizeOf(u32);
        const destination_offset = (y + row) * destination_stride + x;
        @memcpy(
            std.mem.sliceAsBytes(destination[destination_offset..][0..rectangle.width]),
            source[source_offset..][0..copy_bytes],
        );
        if (force_opaque) {
            for (destination[destination_offset..][0..rectangle.width]) |*pixel| {
                pixel.* |= 0xff000000;
            }
        }
    }
}

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

const BufferReleaseCallback = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    surface_id: Id,
    resource: *wl.Callback,

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *BufferReleaseCallback = @ptrCast(@alignCast(resource.getUserData().?));
        removeBufferReleaseCallback(self.store, self.surface_id, self);
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

fn createBufferReleaseCallback(self: *Self, id: u32) error{OutOfMemory}!void {
    const resource = wl.Callback.create(self.resource.getClient(), 1, id) catch
        return error.OutOfMemory;
    errdefer resource.destroy();

    const callback = self.allocator.create(BufferReleaseCallback) catch
        return error.OutOfMemory;
    errdefer self.allocator.destroy(callback);
    callback.* = .{
        .allocator = self.allocator,
        .store = self.store,
        .surface_id = self.id,
        .resource = resource,
    };
    try self.state().release_callbacks.append(self.allocator, callback);

    @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
        null,
        null,
        callback,
        BufferReleaseCallback.handleDestroy,
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

fn removeBufferReleaseCallback(
    store: *Store,
    surface_id: Id,
    callback: *BufferReleaseCallback,
) void {
    const surface_state = store.get(surface_id) orelse unreachable;
    for (surface_state.release_callbacks.items, 0..) |candidate, index| {
        if (candidate == callback) {
            _ = surface_state.release_callbacks.orderedRemove(index);
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

test "single pixel snapshots use viewporter destination without changing color" {
    var snapshot = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x8040_2000,
        1,
        .normal,
        .{ .destination = .{ .width = 320, .height = 180 } },
        null,
        .{ .id = 1, .version = 1 },
    );
    defer snapshot.deinit();

    try std.testing.expectEqual(
        render_types.Size{ .width = 1, .height = 1 },
        snapshot.buffer_size,
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 320, .height = 180 },
        snapshot.logical_size,
    );
    try std.testing.expectEqualSlices(u32, &.{0x8040_2000}, snapshot.pixels);
}

test "same-size snapshots recycle pixel storage" {
    var first = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x1122_3344,
        1,
        .normal,
        .{},
        null,
        .{ .id = 1, .version = 1 },
    );
    defer first.deinit();
    const original_pointer = first.pixels.ptr;

    var second = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x5566_7788,
        1,
        .normal,
        .{},
        &first,
        .{ .id = 1, .version = 2 },
    );
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 0), first.pixels.len);
    try std.testing.expectEqual(original_pointer, second.pixels.ptr);
    try std.testing.expectEqualSlices(u32, &.{0x5566_7788}, second.pixels);
}

test "buffer damage maps into logical surface coordinates" {
    const buffer: BufferSnapshot = .{
        .allocator = std.testing.allocator,
        .buffer_size = .{ .width = 200, .height = 100 },
        .logical_size = .{ .width = 100, .height = 50 },
        .scale = 2,
        .transform = .normal,
        .source = null,
        .pixels = &.{},
        .source_cache = .{ .id = 1, .version = 1 },
        .source_damage = null,
    };
    var buffer_damage = Region.init();
    defer buffer_damage.deinit();
    try buffer_damage.add(20, 10, 40, 20);
    var surface_damage = Region.init();
    defer surface_damage.deinit();

    try std.testing.expect(addBufferDamage(&surface_damage, &buffer_damage, &buffer));
    var rectangles = surface_damage.rectangleIterator();
    try std.testing.expectEqual(
        Region.Rectangle{ .x = 10, .y = 5, .width = 20, .height = 10 },
        rectangles.next().?,
    );
    try std.testing.expectEqual(@as(?Region.Rectangle, null), rectangles.next());
}

test "SHM snapshot copying updates only damaged rows" {
    const source = [_]u32{
        0x0011_2233, 0x0044_5566, 0x0077_8899,
        0x00aa_bbcc, 0x00dd_eeff, 0x0001_0203,
    };
    const untouched = 0x1234_5678;
    var destination = [_]u32{untouched} ** source.len;
    var damage = Region.init();
    defer damage.deinit();
    try damage.add(1, 0, 1, 2);

    copyShmPixels(
        &destination,
        @ptrCast(&source),
        3 * @sizeOf(u32),
        .{ .width = 3, .height = 2 },
        true,
        &damage,
    );

    try std.testing.expectEqualSlices(
        u32,
        &.{
            untouched, 0xff44_5566, untouched,
            untouched, 0xffdd_eeff, untouched,
        },
        &destination,
    );
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
