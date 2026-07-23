//! Stateful, protocol-neutral workspace layouts.

const std = @import("std");
const Direction = @import("../command.zig").Direction;
const types = @import("types.zig");

pub const Kind = enum {
    tiled,
};

pub const DropPosition = enum {
    center,
    top,
    right,
    bottom,
    left,
};

pub const Layout = union(enum) {
    tiled: Tiled,

    pub const Resize = union(enum) {
        tiled: Tiled.Resize,
    };

    pub fn init(kind: Kind) Layout {
        return switch (kind) {
            .tiled => .{ .tiled = .{} },
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tiled => |*layout| layout.deinit(allocator),
        }
    }

    pub fn ensureWindowCapacity(
        self: *Layout,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .tiled => |*layout| try layout.ensureWindowCapacity(allocator, additional_count),
        }
    }

    pub fn setUsableArea(self: *Layout, usable: types.Rect) void {
        switch (self.*) {
            .tiled => |*layout| layout.setUsableArea(usable),
        }
    }

    pub fn setGaps(self: *Layout, inner_gap: u32, outer_gap: u32) void {
        switch (self.*) {
            .tiled => |*layout| {
                layout.inner_gap = inner_gap;
                layout.outer_gap = outer_gap;
            },
        }
    }

    pub fn windowAdded(
        self: *Layout,
        allocator: std.mem.Allocator,
        id: types.WindowId,
        focused: ?types.WindowId,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .tiled => |*layout| try layout.windowAdded(allocator, id, focused),
        }
    }

    pub fn windowRemoved(self: *Layout, id: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.windowRemoved(id),
        }
    }

    pub fn nextWindow(
        self: *const Layout,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .tiled => |*layout| layout.nextWindow(current, reverse),
        };
    }

    /// Finds a tiled neighbor by walking split ancestors. `focus_history` is
    /// ordered least- to most-recently focused and `eligible` contains the
    /// tiled leaves that may receive focus.
    pub fn directionalWindow(
        self: *const Layout,
        current: types.WindowId,
        direction: Direction,
        eligible: []const types.WindowId,
        focus_history: []const types.WindowId,
        wrap: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .tiled => |*layout| layout.directionalWindow(
                current,
                direction,
                eligible,
                focus_history,
                wrap,
            ),
        };
    }

    pub fn relativeDirection(
        self: *const Layout,
        current: types.WindowId,
        reverse: bool,
    ) ?Direction {
        return switch (self.*) {
            .tiled => |*layout| layout.relativeDirection(current, reverse),
        };
    }

    pub fn usesTreeOrder(self: *const Layout) bool {
        return switch (self.*) {
            .tiled => true,
        };
    }

    pub fn swapWindows(self: *Layout, first: types.WindowId, second: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.swapWindows(first, second),
        }
    }

    pub fn repositionWindow(
        self: *Layout,
        source: types.WindowId,
        target: types.WindowId,
        position: DropPosition,
    ) void {
        if (position == .center) {
            self.swapWindows(source, target);
            return;
        }
        switch (self.*) {
            .tiled => |*layout| layout.repositionWindow(source, target, position),
        }
    }

    pub fn repositionWindowAtRoot(
        self: *Layout,
        source: types.WindowId,
        position: DropPosition,
    ) void {
        std.debug.assert(position == .left or position == .right);
        switch (self.*) {
            .tiled => |*layout| layout.repositionWindowAtRoot(source, position),
        }
    }

    pub fn beginResize(
        self: *const Layout,
        id: types.WindowId,
        pointer_x: f64,
        pointer_y: f64,
        edge_threshold: f64,
    ) ?Resize {
        return switch (self.*) {
            .tiled => |layout| if (layout.beginResize(
                id,
                pointer_x,
                pointer_y,
                edge_threshold,
            )) |resize|
                .{ .tiled = resize }
            else
                null,
        };
    }

    pub fn updateResize(
        self: *Layout,
        resize: Resize,
        pointer_x: f64,
        pointer_y: f64,
    ) bool {
        return switch (self.*) {
            .tiled => |*layout| switch (resize) {
                .tiled => |value| layout.updateResize(value, pointer_x, pointer_y),
            },
        };
    }

    pub fn arrange(
        self: *Layout,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        _: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        return switch (self.*) {
            .tiled => |*layout| tiled: {
                const plans = try layout.arrange(allocator, windows, usable);
                setTiledShadowClips(plans.items, usable);
                break :tiled plans;
            },
        };
    }
};

pub const Tiled = struct {
    nodes: std.ArrayList(Node) = .empty,
    free_nodes: std.ArrayList(NodeIndex) = .empty,
    root: ?NodeIndex = null,
    last_usable: ?types.Rect = null,
    split_ratio_percent: u8 = 50,
    outer_gap: u32 = 16,
    inner_gap: u32 = 16,

    pub const NodeIndex = u32;
    pub const Axis = enum { horizontal, vertical };
    pub const Resize = struct {
        window: types.WindowId,
        split_index: NodeIndex,
        first: NodeIndex,
        second: NodeIndex,
        axis: Axis,
        initial_ratio_percent: u8,
        initial_pointer: f64,
        available_length: u32,
    };
    const Split = struct {
        axis: Axis,
        ratio_percent: u8,
        first: NodeIndex,
        second: NodeIndex,
    };
    const Node = struct {
        parent: ?NodeIndex = null,
        rect: ?types.Rect = null,
        content: union(enum) {
            leaf: types.WindowId,
            split: Split,
        },
    };

    pub fn deinit(self: *Tiled, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.free_nodes.deinit(allocator);
        self.* = .{};
    }

    fn ensureWindowCapacity(
        self: *Tiled,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        const additional_nodes = std.math.mul(usize, additional_count, 2) catch
            return error.OutOfMemory;
        const total_nodes = std.math.add(usize, self.nodes.items.len, additional_nodes) catch
            return error.OutOfMemory;
        try self.nodes.ensureUnusedCapacity(allocator, additional_nodes);
        try self.free_nodes.ensureTotalCapacity(allocator, total_nodes);
    }

    fn windowAdded(
        self: *Tiled,
        allocator: std.mem.Allocator,
        id: types.WindowId,
        focused: ?types.WindowId,
    ) error{OutOfMemory}!void {
        std.debug.assert(self.findLeaf(id) == null);
        try self.ensureWindowCapacity(allocator, 1);
        if (self.root == null) {
            self.root = self.allocateNode(.{ .content = .{ .leaf = id } });
            self.refreshRects();
            return;
        }

        const target_index = if (focused) |focused_id|
            self.findLeaf(focused_id) orelse unreachable
        else
            self.extremeLeaf(self.root.?, true);
        const target_rect = self.nodes.items[target_index].rect orelse self.last_usable;
        const axis: Axis = if (target_rect) |rect|
            if (rect.size.width >= rect.size.height) .horizontal else .vertical
        else
            .horizontal;
        self.splitLeaf(target_index, id, axis, false);
    }

    fn splitLeaf(
        self: *Tiled,
        target_index: NodeIndex,
        id: types.WindowId,
        axis: Axis,
        before: bool,
    ) void {
        const old_id = switch (self.nodes.items[target_index].content) {
            .leaf => |value| value,
            .split => unreachable,
        };
        const old_rect = self.nodes.items[target_index].rect;
        const first = self.allocateNode(.{
            .parent = target_index,
            .rect = if (before) null else old_rect,
            .content = .{ .leaf = if (before) id else old_id },
        });
        const second = self.allocateNode(.{
            .parent = target_index,
            .rect = if (before) old_rect else null,
            .content = .{ .leaf = if (before) old_id else id },
        });
        const target = &self.nodes.items[target_index];
        target.rect = null;
        target.content = .{ .split = .{
            .axis = axis,
            .ratio_percent = self.split_ratio_percent,
            .first = first,
            .second = second,
        } };
        self.refreshRects();
    }

    fn windowRemoved(self: *Tiled, id: types.WindowId) void {
        const target_index = self.findLeaf(id) orelse unreachable;
        const parent_index = self.nodes.items[target_index].parent orelse {
            std.debug.assert(self.root.? == target_index);
            self.releaseNode(target_index);
            self.root = null;
            return;
        };
        const parent = &self.nodes.items[parent_index];
        const split = switch (parent.content) {
            .leaf => unreachable,
            .split => |split| split,
        };
        const sibling_index = if (split.first == target_index) split.second else split.first;
        const grandparent_index = parent.parent;
        self.nodes.items[sibling_index].parent = grandparent_index;
        if (grandparent_index) |grandparent| {
            const grandparent_split = &self.nodes.items[grandparent].content.split;
            if (grandparent_split.first == parent_index) {
                grandparent_split.first = sibling_index;
            } else {
                std.debug.assert(grandparent_split.second == parent_index);
                grandparent_split.second = sibling_index;
            }
        } else {
            std.debug.assert(self.root.? == parent_index);
            self.root = sibling_index;
        }
        self.releaseNode(target_index);
        self.releaseNode(parent_index);
        self.refreshRects();
    }

    fn nextWindow(
        self: *const Tiled,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        var node_index = self.findLeaf(current) orelse return null;
        while (self.nodes.items[node_index].parent) |parent_index| {
            const split = self.nodes.items[parent_index].content.split;
            if (reverse and split.second == node_index)
                return self.leafId(self.extremeLeaf(split.first, true));
            if (!reverse and split.first == node_index)
                return self.leafId(self.extremeLeaf(split.second, false));
            node_index = parent_index;
        }
        const root = self.root orelse return null;
        return self.leafId(self.extremeLeaf(root, reverse));
    }

    fn directionalWindow(
        self: *const Tiled,
        current: types.WindowId,
        direction: Direction,
        eligible: []const types.WindowId,
        focus_history: []const types.WindowId,
        wrap: bool,
    ) ?types.WindowId {
        const desired_axis: Axis = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const forward = direction == .right or direction == .down;
        var node_index = self.findLeaf(current) orelse return null;
        var wrap_candidate: ?types.WindowId = null;
        while (self.nodes.items[node_index].parent) |parent_index| {
            const split = self.nodes.items[parent_index].content.split;
            if (split.axis == desired_axis) {
                const in_first = split.first == node_index;
                std.debug.assert(in_first or split.second == node_index);
                const adjacent: ?NodeIndex = if (forward and in_first)
                    split.second
                else if (!forward and !in_first)
                    split.first
                else
                    null;
                if (adjacent) |subtree| {
                    if (self.mostRecentLeaf(subtree, eligible, focus_history)) |id| return id;
                } else if (wrap) {
                    const opposite = if (forward) split.first else split.second;
                    if (self.mostRecentLeaf(opposite, eligible, focus_history)) |id| {
                        // Keep climbing so wrapping uses the workspace's
                        // outermost matching split rather than a nested edge.
                        wrap_candidate = id;
                    }
                }
            }
            node_index = parent_index;
        }
        return wrap_candidate;
    }

    fn relativeDirection(
        self: *const Tiled,
        current: types.WindowId,
        reverse: bool,
    ) ?Direction {
        const leaf_index = self.findLeaf(current) orelse return null;
        const parent_index = self.nodes.items[leaf_index].parent orelse return null;
        const axis = self.nodes.items[parent_index].content.split.axis;
        return switch (axis) {
            .horizontal => if (reverse) .left else .right,
            .vertical => if (reverse) .up else .down,
        };
    }

    fn mostRecentLeaf(
        self: *const Tiled,
        subtree: NodeIndex,
        eligible: []const types.WindowId,
        focus_history: []const types.WindowId,
    ) ?types.WindowId {
        var index = focus_history.len;
        while (index > 0) {
            index -= 1;
            const id = focus_history[index];
            if (!containsId(eligible, id)) continue;
            if (self.findLeafFrom(subtree, id) != null) return id;
        }
        return null;
    }

    fn swapWindows(self: *Tiled, first: types.WindowId, second: types.WindowId) void {
        const first_index = self.findLeaf(first) orelse unreachable;
        const second_index = self.findLeaf(second) orelse unreachable;
        self.nodes.items[first_index].content.leaf = second;
        self.nodes.items[second_index].content.leaf = first;
    }

    fn repositionWindow(
        self: *Tiled,
        source: types.WindowId,
        target: types.WindowId,
        position: DropPosition,
    ) void {
        std.debug.assert(!source.eql(target));
        std.debug.assert(position != .center);
        self.windowRemoved(source);
        const target_index = self.findLeaf(target) orelse unreachable;
        const axis: Axis = switch (position) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
            .center => unreachable,
        };
        const before = position == .left or position == .top;
        self.splitLeaf(target_index, source, axis, before);
    }

    fn repositionWindowAtRoot(
        self: *Tiled,
        source: types.WindowId,
        position: DropPosition,
    ) void {
        std.debug.assert(position == .left or position == .right);
        self.windowRemoved(source);
        const previous_root = self.root orelse unreachable;
        const source_index = self.allocateNode(.{ .content = .{ .leaf = source } });
        const root_index = self.allocateNode(.{ .content = .{ .split = .{
            .axis = .horizontal,
            .ratio_percent = self.split_ratio_percent,
            .first = if (position == .left) source_index else previous_root,
            .second = if (position == .left) previous_root else source_index,
        } } });
        self.nodes.items[source_index].parent = root_index;
        self.nodes.items[previous_root].parent = root_index;
        self.root = root_index;
        self.refreshRects();
    }

    fn beginResize(
        self: *const Tiled,
        id: types.WindowId,
        pointer_x: f64,
        pointer_y: f64,
        edge_threshold: f64,
    ) ?Resize {
        std.debug.assert(edge_threshold >= 0);
        const leaf_index = self.findLeaf(id) orelse return null;
        const leaf_rect = self.nodes.items[leaf_index].rect orelse return null;
        var child_index = leaf_index;
        var best: ?Resize = null;
        var best_distance = std.math.inf(f64);
        while (self.nodes.items[child_index].parent) |parent_index| {
            const parent = self.nodes.items[parent_index];
            const split = switch (parent.content) {
                .leaf => unreachable,
                .split => |value| value,
            };
            const division = divide(
                parent.rect orelse break,
                split.axis,
                split.ratio_percent,
                self.inner_gap,
            ) orelse {
                child_index = parent_index;
                continue;
            };
            const first_end = if (split.axis == .horizontal)
                @as(i64, division.first.x) + division.first.size.width
            else
                @as(i64, division.first.y) + division.first.size.height;
            const second_start = if (split.axis == .horizontal)
                @as(i64, division.second.x)
            else
                @as(i64, division.second.y);
            const leaf_start = if (split.axis == .horizontal)
                @as(i64, leaf_rect.x)
            else
                @as(i64, leaf_rect.y);
            const leaf_end = leaf_start + if (split.axis == .horizontal)
                leaf_rect.size.width
            else
                leaf_rect.size.height;
            const touches_boundary = if (split.first == child_index)
                leaf_end == first_end
            else blk: {
                std.debug.assert(split.second == child_index);
                break :blk leaf_start == second_start;
            };
            const cross_pointer = if (split.axis == .horizontal) pointer_y else pointer_x;
            const cross_start = if (split.axis == .horizontal)
                @as(i64, leaf_rect.y)
            else
                @as(i64, leaf_rect.x);
            const cross_end = cross_start + if (split.axis == .horizontal)
                leaf_rect.size.height
            else
                leaf_rect.size.width;
            const within_leaf = cross_pointer >= @as(f64, @floatFromInt(cross_start)) and
                cross_pointer < @as(f64, @floatFromInt(cross_end));
            if (touches_boundary and within_leaf) {
                const pointer = if (split.axis == .horizontal) pointer_x else pointer_y;
                const first_boundary: f64 = @floatFromInt(first_end);
                const second_boundary: f64 = @floatFromInt(second_start);
                const distance = if (pointer < first_boundary)
                    first_boundary - pointer
                else if (pointer > second_boundary)
                    pointer - second_boundary
                else
                    0;
                if (distance < best_distance) {
                    best_distance = distance;
                    best = .{
                        .window = id,
                        .split_index = parent_index,
                        .first = split.first,
                        .second = split.second,
                        .axis = split.axis,
                        .initial_ratio_percent = split.ratio_percent,
                        .initial_pointer = pointer,
                        .available_length = if (split.axis == .horizontal)
                            division.first.size.width + division.second.size.width
                        else
                            division.first.size.height + division.second.size.height,
                    };
                }
            }
            child_index = parent_index;
        }
        return if (best_distance <= edge_threshold) best else null;
    }

    fn updateResize(
        self: *Tiled,
        resize: Resize,
        pointer_x: f64,
        pointer_y: f64,
    ) bool {
        var node_index = self.findLeaf(resize.window) orelse return false;
        while (node_index != resize.split_index) {
            node_index = self.nodes.items[node_index].parent orelse return false;
        }
        const node = &self.nodes.items[resize.split_index];
        const split = switch (node.content) {
            .leaf => return false,
            .split => &node.content.split,
        };
        if (split.first != resize.first or split.second != resize.second or
            split.axis != resize.axis) return false;
        const pointer = if (resize.axis == .horizontal) pointer_x else pointer_y;
        const ratio = resizedRatio(
            resize.initial_ratio_percent,
            resize.initial_pointer,
            pointer,
            resize.available_length,
        );
        if (ratio == split.ratio_percent) return false;
        split.ratio_percent = ratio;
        self.refreshRects();
        return true;
    }

    fn arrange(
        self: *Tiled,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
    ) !std.ArrayList(types.LayoutPlan) {
        var plans: std.ArrayList(types.LayoutPlan) = .empty;
        errdefer plans.deinit(allocator);
        try plans.ensureTotalCapacity(allocator, windows.len);
        const area = inset(usable, self.outer_gap);
        self.last_usable = area;
        self.refreshRects();
        if (self.root) |root| {
            if (self.nodeVisible(root, windows))
                self.arrangeNode(root, windows, area, &plans);
        }
        std.debug.assert(plans.items.len == windows.len);
        return plans;
    }

    fn setUsableArea(self: *Tiled, usable: types.Rect) void {
        self.last_usable = inset(usable, self.outer_gap);
        self.refreshRects();
    }

    fn refreshRects(self: *Tiled) void {
        const root = self.root orelse return;
        self.refreshNode(root, self.last_usable orelse return);
    }

    fn refreshNode(self: *Tiled, node_index: NodeIndex, area: types.Rect) void {
        const node = &self.nodes.items[node_index];
        node.rect = area;
        switch (node.content) {
            .leaf => {},
            .split => |split| {
                if (divide(area, split.axis, split.ratio_percent, self.inner_gap)) |division| {
                    self.refreshNode(split.first, division.first);
                    self.refreshNode(split.second, division.second);
                } else {
                    self.refreshNode(split.first, area);
                    self.refreshNode(split.second, area);
                }
            },
        }
    }

    fn arrangeNode(
        self: *Tiled,
        node_index: NodeIndex,
        windows: []const types.WindowInput,
        area: types.Rect,
        plans: *std.ArrayList(types.LayoutPlan),
    ) void {
        const node = &self.nodes.items[node_index];
        node.rect = area;
        switch (node.content) {
            .leaf => |id| {
                std.debug.assert(inputFor(windows, id) != null);
                plans.appendAssumeCapacity(.{
                    .id = id,
                    .rect = area,
                    .visible = true,
                    .tiled_edges = .{ .top = true, .right = true, .bottom = true, .left = true },
                });
            },
            .split => |split| {
                const first_visible = self.nodeVisible(split.first, windows);
                const second_visible = self.nodeVisible(split.second, windows);
                if (first_visible and second_visible) {
                    if (divide(area, split.axis, split.ratio_percent, self.inner_gap)) |division| {
                        self.arrangeNode(split.first, windows, division.first, plans);
                        self.arrangeNode(split.second, windows, division.second, plans);
                    } else {
                        self.arrangeNode(split.first, windows, area, plans);
                        self.arrangeNode(split.second, windows, area, plans);
                    }
                } else if (first_visible) {
                    self.arrangeNode(split.first, windows, area, plans);
                } else if (second_visible) {
                    self.arrangeNode(split.second, windows, area, plans);
                } else unreachable;
            },
        }
    }

    fn nodeVisible(
        self: *const Tiled,
        node_index: NodeIndex,
        windows: []const types.WindowInput,
    ) bool {
        return switch (self.nodes.items[node_index].content) {
            .leaf => |id| inputFor(windows, id) != null,
            .split => |split| self.nodeVisible(split.first, windows) or
                self.nodeVisible(split.second, windows),
        };
    }

    fn findLeaf(self: *const Tiled, id: types.WindowId) ?NodeIndex {
        return self.findLeafFrom(self.root orelse return null, id);
    }

    fn findLeafFrom(
        self: *const Tiled,
        node_index: NodeIndex,
        id: types.WindowId,
    ) ?NodeIndex {
        return switch (self.nodes.items[node_index].content) {
            .leaf => |candidate| if (candidate.eql(id)) node_index else null,
            .split => |split| self.findLeafFrom(split.first, id) orelse
                self.findLeafFrom(split.second, id),
        };
    }

    fn extremeLeaf(self: *const Tiled, start: NodeIndex, reverse: bool) NodeIndex {
        var node_index = start;
        while (true) switch (self.nodes.items[node_index].content) {
            .leaf => return node_index,
            .split => |split| node_index = if (reverse) split.second else split.first,
        };
    }

    fn leafId(self: *const Tiled, node_index: NodeIndex) types.WindowId {
        return self.nodes.items[node_index].content.leaf;
    }

    fn allocateNode(self: *Tiled, node: Node) NodeIndex {
        if (self.free_nodes.items.len != 0) {
            const index = self.free_nodes.items[self.free_nodes.items.len - 1];
            self.free_nodes.items.len -= 1;
            self.nodes.items[index] = node;
            return index;
        }
        const index: NodeIndex = @intCast(self.nodes.items.len);
        self.nodes.appendAssumeCapacity(node);
        return index;
    }

    fn releaseNode(self: *Tiled, node_index: NodeIndex) void {
        self.free_nodes.appendAssumeCapacity(node_index);
    }
};

fn inset(rect: types.Rect, requested: u32) types.Rect {
    const gap = @min(requested, @min((rect.size.width - 1) / 2, (rect.size.height - 1) / 2));
    return .{
        .x = rect.x + @as(i32, @intCast(gap)),
        .y = rect.y + @as(i32, @intCast(gap)),
        .size = types.Size.init(rect.size.width - 2 * gap, rect.size.height - 2 * gap),
    };
}

fn setTiledShadowClips(plans: []types.LayoutPlan, usable: types.Rect) void {
    for (plans) |*plan| plan.shadow_clip = usable;
}

fn inputFor(windows: []const types.WindowInput, id: types.WindowId) ?types.WindowInput {
    for (windows) |window| if (window.id.eql(id)) return window;
    return null;
}

fn containsId(ids: []const types.WindowId, id: types.WindowId) bool {
    for (ids) |candidate| if (candidate.eql(id)) return true;
    return false;
}

fn divide(
    rect: types.Rect,
    axis: Tiled.Axis,
    ratio_percent: u8,
    requested_gap: u32,
) ?struct { first: types.Rect, second: types.Rect } {
    const length = if (axis == .horizontal) rect.size.width else rect.size.height;
    if (length < 2) return null;
    const gap = @min(requested_gap, length - 2);
    const available = length - gap;
    var first_length: u32 = @intCast((@as(u64, available) * ratio_percent) / 100);
    first_length = std.math.clamp(first_length, 1, available - 1);
    const second_length = available - first_length;
    return if (axis == .horizontal) .{
        .first = .{
            .x = rect.x,
            .y = rect.y,
            .size = types.Size.init(first_length, rect.size.height),
        },
        .second = .{
            .x = rect.x + @as(i32, @intCast(first_length + gap)),
            .y = rect.y,
            .size = types.Size.init(second_length, rect.size.height),
        },
    } else .{
        .first = .{
            .x = rect.x,
            .y = rect.y,
            .size = types.Size.init(rect.size.width, first_length),
        },
        .second = .{
            .x = rect.x,
            .y = rect.y + @as(i32, @intCast(first_length + gap)),
            .size = types.Size.init(rect.size.width, second_length),
        },
    };
}

fn resizedRatio(initial: u8, initial_pointer: f64, pointer: f64, available: u32) u8 {
    std.debug.assert(available > 0);
    const delta_percent = (pointer - initial_pointer) * 100 /
        @as(f64, @floatFromInt(available));
    const ratio = std.math.clamp(
        @as(f64, @floatFromInt(initial)) + delta_percent,
        10,
        90,
    );
    return @intFromFloat(@round(ratio));
}

fn input(index: u32, width: u32) types.WindowInput {
    return .{ .id = types.id(index), .current = types.Size.init(width, 40) };
}

test "gap configuration applies to tiled layout" {
    var layout: Layout = .init(.tiled);
    defer layout.deinit(std.testing.allocator);
    layout.setGaps(20, 24);
    try std.testing.expectEqual(@as(u32, 20), layout.tiled.inner_gap);
    try std.testing.expectEqual(@as(u32, 24), layout.tiled.outer_gap);
}

test "tiled shadows share the usable area without neighbor clipping" {
    var layout: Layout = .{ .tiled = .{ .outer_gap = 8, .inner_gap = 8 } };
    defer layout.deinit(std.testing.allocator);
    const usable: types.Rect = .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 100),
    };
    try layout.windowAdded(std.testing.allocator, types.id(0), null);
    try layout.windowAdded(std.testing.allocator, types.id(1), types.id(0));
    var plans = try layout.arrange(
        std.testing.allocator,
        &.{ input(0, 10), input(1, 10) },
        usable,
        null,
    );
    defer plans.deinit(std.testing.allocator);

    try std.testing.expectEqual(usable, plans.items[0].shadow_clip.?);
    try std.testing.expectEqual(usable, plans.items[1].shadow_clip.?);
}

test "tiled layout splits the focused leaf along its longest dimension" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);

    try layout.windowAdded(std.testing.allocator, first.id, null);
    var plans = try layout.arrange(std.testing.allocator, &.{first}, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, first.id);
    plans.deinit(std.testing.allocator);

    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    plans = try layout.arrange(std.testing.allocator, &.{ first, second }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, second.id);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .size = types.Size.init(60, 80) }, plans.items[0].rect);
    try std.testing.expectEqual(types.Rect{ .x = 60, .y = 0, .size = types.Size.init(60, 80) }, plans.items[1].rect);
    plans.deinit(std.testing.allocator);

    try layout.windowAdded(std.testing.allocator, third.id, second.id);
    plans = try layout.arrange(std.testing.allocator, &.{ first, second, third }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, third.id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .size = types.Size.init(60, 80) }, plans.items[0].rect);
    try std.testing.expectEqual(types.Rect{ .x = 60, .y = 0, .size = types.Size.init(60, 40) }, plans.items[1].rect);
    try std.testing.expectEqual(types.Rect{ .x = 60, .y = 40, .size = types.Size.init(60, 40) }, plans.items[2].rect);
}

test "tiled tree traversal swaps leaves and collapses removed branches" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    const fourth = input(3, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, first.id, null);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    try layout.windowAdded(std.testing.allocator, third.id, second.id);
    try layout.windowAdded(std.testing.allocator, fourth.id, first.id);

    try std.testing.expectEqual(fourth.id, layout.nextWindow(first.id, false).?);
    try std.testing.expectEqual(second.id, layout.nextWindow(fourth.id, false).?);
    try std.testing.expectEqual(third.id, layout.nextWindow(second.id, false).?);
    try std.testing.expectEqual(first.id, layout.nextWindow(third.id, false).?);
    try std.testing.expectEqual(third.id, layout.nextWindow(first.id, true).?);

    layout.swapWindows(first.id, second.id);
    try std.testing.expectEqual(fourth.id, layout.nextWindow(second.id, false).?);
    layout.windowRemoved(fourth.id);
    try std.testing.expectEqual(first.id, layout.nextWindow(second.id, false).?);

    var plans = try layout.arrange(std.testing.allocator, &.{ first, second, third }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(100, 100),
    }, first.id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), plans.items.len);
}

test "tiled directional navigation enters sibling branch through recent focus" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);

    try layout.windowAdded(std.testing.allocator, first.id, null);
    var plans = try layout.arrange(std.testing.allocator, &.{first}, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, first.id);
    plans.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    plans = try layout.arrange(std.testing.allocator, &.{ first, second }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, second.id);
    plans.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, third.id, second.id);

    const eligible = &.{ first.id, second.id, third.id };
    const focus_history = &.{ first.id, second.id, third.id };
    try std.testing.expectEqual(
        third.id,
        layout.directionalWindow(first.id, .right, eligible, focus_history, true).?,
    );
    try std.testing.expectEqual(
        second.id,
        layout.directionalWindow(third.id, .up, eligible, focus_history, true).?,
    );
    try std.testing.expectEqual(
        first.id,
        layout.directionalWindow(third.id, .right, eligible, focus_history, true).?,
    );
    try std.testing.expect(layout.directionalWindow(third.id, .right, eligible, focus_history, false) == null);
    try std.testing.expectEqual(Direction.down, layout.relativeDirection(third.id, false).?);

    try std.testing.expectEqual(
        second.id,
        layout.directionalWindow(first.id, .right, &.{ first.id, second.id }, focus_history, true).?,
    );
}

test "tiled directional navigation wraps at the outermost matching split" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, first.id, null);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    try layout.windowAdded(std.testing.allocator, third.id, second.id);

    const windows = &.{ first.id, second.id, third.id };
    try std.testing.expectEqual(
        first.id,
        layout.directionalWindow(third.id, .right, windows, windows, true).?,
    );
    try std.testing.expectEqual(
        third.id,
        layout.directionalWindow(first.id, .left, windows, windows, true).?,
    );
}

test "tiled layout repositions a window on each side of the drop target" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    const area: types.Rect = .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    };
    const Case = struct {
        position: DropPosition,
        ids: [3]types.WindowId,
        rects: [3]types.Rect,
    };
    const cases = [_]Case{
        .{
            .position = .left,
            .ids = .{ second.id, first.id, third.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(120, 40) },
                .{ .x = 0, .y = 40, .size = types.Size.init(60, 40) },
                .{ .x = 60, .y = 40, .size = types.Size.init(60, 40) },
            },
        },
        .{
            .position = .right,
            .ids = .{ second.id, third.id, first.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(120, 40) },
                .{ .x = 0, .y = 40, .size = types.Size.init(60, 40) },
                .{ .x = 60, .y = 40, .size = types.Size.init(60, 40) },
            },
        },
        .{
            .position = .top,
            .ids = .{ second.id, first.id, third.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(120, 40) },
                .{ .x = 0, .y = 40, .size = types.Size.init(120, 20) },
                .{ .x = 0, .y = 60, .size = types.Size.init(120, 20) },
            },
        },
        .{
            .position = .bottom,
            .ids = .{ second.id, third.id, first.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(120, 40) },
                .{ .x = 0, .y = 40, .size = types.Size.init(120, 20) },
                .{ .x = 0, .y = 60, .size = types.Size.init(120, 20) },
            },
        },
    };

    for (cases) |case| {
        var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
        defer layout.deinit(std.testing.allocator);
        layout.setUsableArea(area);
        try layout.windowAdded(std.testing.allocator, first.id, null);
        try layout.windowAdded(std.testing.allocator, second.id, first.id);
        try layout.windowAdded(std.testing.allocator, third.id, second.id);
        layout.repositionWindow(first.id, third.id, case.position);

        var plans = try layout.arrange(
            std.testing.allocator,
            &.{ first, second, third },
            area,
            first.id,
        );
        defer plans.deinit(std.testing.allocator);
        for (plans.items, case.ids, case.rects) |plan, id, rect| {
            try std.testing.expectEqual(id, plan.id);
            try std.testing.expectEqual(rect, plan.rect);
        }
    }
}

test "tiled layout repositions a window at the workspace root edge" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    const area: types.Rect = .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    };
    const cases = [_]struct {
        position: DropPosition,
        ids: [3]types.WindowId,
        rects: [3]types.Rect,
    }{
        .{
            .position = .left,
            .ids = .{ third.id, first.id, second.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(60, 80) },
                .{ .x = 60, .y = 0, .size = types.Size.init(30, 80) },
                .{ .x = 90, .y = 0, .size = types.Size.init(30, 80) },
            },
        },
        .{
            .position = .right,
            .ids = .{ first.id, second.id, third.id },
            .rects = .{
                .{ .x = 0, .y = 0, .size = types.Size.init(30, 80) },
                .{ .x = 30, .y = 0, .size = types.Size.init(30, 80) },
                .{ .x = 60, .y = 0, .size = types.Size.init(60, 80) },
            },
        },
    };

    for (cases) |case| {
        var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
        defer layout.deinit(std.testing.allocator);
        layout.setUsableArea(area);
        try layout.windowAdded(std.testing.allocator, first.id, null);
        try layout.windowAdded(std.testing.allocator, second.id, first.id);
        try layout.windowAdded(std.testing.allocator, third.id, second.id);
        layout.repositionWindowAtRoot(third.id, case.position);

        var plans = try layout.arrange(
            std.testing.allocator,
            &.{ first, second, third },
            area,
            third.id,
        );
        defer plans.deinit(std.testing.allocator);
        for (plans.items, case.ids, case.rects) |plan, id, rect| {
            try std.testing.expectEqual(id, plan.id);
            try std.testing.expectEqual(rect, plan.rect);
        }
    }
}

test "tiled pointer resize adjusts the nearest bordering split" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, first.id, null);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    var plans = try layout.arrange(std.testing.allocator, &.{ first, second }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, second.id);
    plans.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, third.id, second.id);

    plans = try layout.arrange(std.testing.allocator, &.{ first, second, third }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, third.id);
    plans.deinit(std.testing.allocator);

    const resize = layout.beginResize(second.id, 100, 35, 8).?;
    try std.testing.expect(layout.updateResize(resize, 100, 55));
    try std.testing.expect(!layout.updateResize(resize, 100, 55));
    plans = try layout.arrange(std.testing.allocator, &.{ first, second, third }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    }, third.id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.Rect{
        .x = 60,
        .y = 0,
        .size = types.Size.init(60, 60),
    }, plans.items[1].rect);
    try std.testing.expectEqual(types.Rect{
        .x = 60,
        .y = 60,
        .size = types.Size.init(60, 20),
    }, plans.items[2].rect);
    try std.testing.expect(layout.beginResize(second.id, 100, 20, 8) == null);
}

test "tiled pointer resize rejects a split removed during the grab" {
    const first = input(0, 10);
    const second = input(1, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 0 } };
    defer layout.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, first.id, null);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    var plans = try layout.arrange(std.testing.allocator, &.{ first, second }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(100, 100),
    }, second.id);
    plans.deinit(std.testing.allocator);

    const resize = layout.beginResize(first.id, 45, 50, 8).?;
    layout.windowRemoved(second.id);
    try std.testing.expect(!layout.updateResize(resize, 60, 50));
}

test "tiled pointer resize accepts a window edge across a wide gap" {
    const first = input(0, 10);
    const second = input(1, 10);
    var layout: Layout = .{ .tiled = .{ .outer_gap = 0, .inner_gap = 20 } };
    defer layout.deinit(std.testing.allocator);
    try layout.windowAdded(std.testing.allocator, first.id, null);
    try layout.windowAdded(std.testing.allocator, second.id, first.id);
    var plans = try layout.arrange(std.testing.allocator, &.{ first, second }, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(100, 100),
    }, second.id);
    plans.deinit(std.testing.allocator);

    try std.testing.expect(layout.beginResize(first.id, 39, 50, 8) != null);
    try std.testing.expect(layout.beginResize(first.id, 25, 50, 8) == null);
}
