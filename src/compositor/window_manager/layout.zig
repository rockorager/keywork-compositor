//! Stateful, protocol-neutral workspace layouts.

const std = @import("std");
const types = @import("types.zig");

pub const Kind = enum {
    master_stack,
    dwindle,
    scrolling,
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
    scrolling: Scrolling,

    pub const Resize = union(enum) {
        dwindle: Dwindle.Resize,
    };

    pub fn init(kind: Kind) Layout {
        return switch (kind) {
            .master_stack => .{ .tiled = .{ .master_stack = .{} } },
            .dwindle => .{ .tiled = .{ .dwindle = .{} } },
            .scrolling => .{ .scrolling = .{} },
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tiled => |*layout| layout.deinit(allocator),
            .scrolling => {},
        }
    }

    pub fn ensureWindowCapacity(
        self: *Layout,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .tiled => |*layout| try layout.ensureWindowCapacity(allocator, additional_count),
            .scrolling => {},
        }
    }

    pub fn setUsableArea(self: *Layout, usable: types.Rect) void {
        switch (self.*) {
            .tiled => |*layout| layout.setUsableArea(usable),
            .scrolling => {},
        }
    }

    pub fn setGaps(self: *Layout, inner_gap: u32, outer_gap: u32) void {
        switch (self.*) {
            .tiled => |*layout| layout.setGaps(inner_gap, outer_gap),
            .scrolling => |*layout| {
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
            .scrolling => {},
        }
    }

    pub fn windowRemoved(self: *Layout, id: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.windowRemoved(id),
            .scrolling => {},
        }
    }

    pub fn nextWindow(
        self: *const Layout,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .tiled => |*layout| layout.nextWindow(current, reverse),
            .scrolling => null,
        };
    }

    pub fn usesTreeOrder(self: *const Layout) bool {
        return switch (self.*) {
            .tiled => |layout| layout == .dwindle,
            .scrolling => false,
        };
    }

    pub fn swapWindows(self: *Layout, first: types.WindowId, second: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.swapWindows(first, second),
            .scrolling => {},
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
            .scrolling => {},
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
            .tiled => |layout| switch (layout) {
                .master_stack => null,
                .dwindle => |policy| if (policy.beginResize(
                    id,
                    pointer_x,
                    pointer_y,
                    edge_threshold,
                )) |resize|
                    .{ .dwindle = resize }
                else
                    null,
            },
            .scrolling => null,
        };
    }

    pub fn updateResize(
        self: *Layout,
        resize: Resize,
        pointer_x: f64,
        pointer_y: f64,
    ) bool {
        return switch (self.*) {
            .tiled => |*layout| switch (layout.*) {
                .master_stack => false,
                .dwindle => |*policy| switch (resize) {
                    .dwindle => |value| policy.updateResize(value, pointer_x, pointer_y),
                },
            },
            .scrolling => false,
        };
    }

    pub fn arrange(
        self: *Layout,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        focused: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        return switch (self.*) {
            .tiled => |*layout| layout.arrange(allocator, windows, usable),
            .scrolling => |*layout| layout.arrange(allocator, windows, usable, focused),
        };
    }
};

pub const Tiled = union(enum) {
    master_stack: MasterStack,
    dwindle: Dwindle,

    fn deinit(self: *Tiled, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| policy.deinit(allocator),
        }
    }

    fn ensureWindowCapacity(
        self: *Tiled,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| try policy.ensureWindowCapacity(allocator, additional_count),
        }
    }

    fn setUsableArea(self: *Tiled, usable: types.Rect) void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| policy.setUsableArea(usable),
        }
    }

    fn setGaps(self: *Tiled, inner_gap: u32, outer_gap: u32) void {
        switch (self.*) {
            .master_stack => |*policy| {
                policy.inner_gap = inner_gap;
                policy.outer_gap = outer_gap;
            },
            .dwindle => |*policy| {
                policy.inner_gap = inner_gap;
                policy.outer_gap = outer_gap;
            },
        }
    }

    fn windowAdded(
        self: *Tiled,
        allocator: std.mem.Allocator,
        id: types.WindowId,
        focused: ?types.WindowId,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| try policy.windowAdded(allocator, id, focused),
        }
    }

    fn windowRemoved(self: *Tiled, id: types.WindowId) void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| policy.windowRemoved(id),
        }
    }

    fn nextWindow(
        self: *const Tiled,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .master_stack => null,
            .dwindle => |*policy| policy.nextWindow(current, reverse),
        };
    }

    fn swapWindows(self: *Tiled, first: types.WindowId, second: types.WindowId) void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| policy.swapWindows(first, second),
        }
    }

    fn repositionWindow(
        self: *Tiled,
        source: types.WindowId,
        target: types.WindowId,
        position: DropPosition,
    ) void {
        switch (self.*) {
            .master_stack => {},
            .dwindle => |*policy| policy.repositionWindow(source, target, position),
        }
    }

    pub fn arrange(
        self: *Tiled,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
    ) !std.ArrayList(types.LayoutPlan) {
        const plans = try switch (self.*) {
            .master_stack => |*policy| policy.arrange(allocator, windows, usable),
            .dwindle => |*policy| policy.arrange(allocator, windows, usable),
        };
        setTiledShadowClips(plans.items, usable);
        return plans;
    }
};

pub const MasterStack = struct {
    master_count: u32 = 1,
    master_ratio_percent: u8 = 60,
    outer_gap: u32 = 16,
    inner_gap: u32 = 16,

    pub fn setMasterCount(self: *MasterStack, count: u32) void {
        self.master_count = count;
    }

    pub fn setMasterRatio(self: *MasterStack, percent: u8) void {
        std.debug.assert(percent >= 10 and percent <= 90);
        self.master_ratio_percent = percent;
    }

    fn arrange(
        self: *const MasterStack,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
    ) !std.ArrayList(types.LayoutPlan) {
        var plans: std.ArrayList(types.LayoutPlan) = .empty;
        errdefer plans.deinit(allocator);
        try plans.ensureTotalCapacity(allocator, windows.len);
        if (windows.len == 0) return plans;

        const area = inset(usable, self.outer_gap);
        const master_len = @min(windows.len, @max(@as(usize, 1), self.master_count));
        if (master_len == windows.len) {
            appendColumn(&plans, windows, area, self.inner_gap);
            return plans;
        }
        if (area.size.width < 2) {
            appendColumn(&plans, windows, area, self.inner_gap);
            return plans;
        }

        const gap = @min(self.inner_gap, area.size.width - 2);
        const available_width = area.size.width - gap;
        var master_width: u32 = @intCast((@as(u64, available_width) * self.master_ratio_percent) / 100);
        master_width = std.math.clamp(master_width, 1, available_width - 1);
        const stack_width = available_width - master_width;
        appendColumn(&plans, windows[0..master_len], .{
            .x = area.x,
            .y = area.y,
            .size = types.Size.init(master_width, area.size.height),
        }, self.inner_gap);
        appendColumn(&plans, windows[master_len..], .{
            .x = area.x + @as(i32, @intCast(master_width + gap)),
            .y = area.y,
            .size = types.Size.init(stack_width, area.size.height),
        }, self.inner_gap);
        return plans;
    }
};

pub const Dwindle = struct {
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

    pub fn deinit(self: *Dwindle, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.free_nodes.deinit(allocator);
        self.* = .{};
    }

    fn ensureWindowCapacity(
        self: *Dwindle,
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
        self: *Dwindle,
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
        self: *Dwindle,
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

    fn windowRemoved(self: *Dwindle, id: types.WindowId) void {
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
        self: *const Dwindle,
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

    fn swapWindows(self: *Dwindle, first: types.WindowId, second: types.WindowId) void {
        const first_index = self.findLeaf(first) orelse unreachable;
        const second_index = self.findLeaf(second) orelse unreachable;
        self.nodes.items[first_index].content.leaf = second;
        self.nodes.items[second_index].content.leaf = first;
    }

    fn repositionWindow(
        self: *Dwindle,
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

    fn beginResize(
        self: *const Dwindle,
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
        self: *Dwindle,
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
        self: *Dwindle,
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

    fn setUsableArea(self: *Dwindle, usable: types.Rect) void {
        self.last_usable = inset(usable, self.outer_gap);
        self.refreshRects();
    }

    fn refreshRects(self: *Dwindle) void {
        const root = self.root orelse return;
        self.refreshNode(root, self.last_usable orelse return);
    }

    fn refreshNode(self: *Dwindle, node_index: NodeIndex, area: types.Rect) void {
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
        self: *Dwindle,
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
        self: *const Dwindle,
        node_index: NodeIndex,
        windows: []const types.WindowInput,
    ) bool {
        return switch (self.nodes.items[node_index].content) {
            .leaf => |id| inputFor(windows, id) != null,
            .split => |split| self.nodeVisible(split.first, windows) or
                self.nodeVisible(split.second, windows),
        };
    }

    fn findLeaf(self: *const Dwindle, id: types.WindowId) ?NodeIndex {
        return self.findLeafFrom(self.root orelse return null, id);
    }

    fn findLeafFrom(
        self: *const Dwindle,
        node_index: NodeIndex,
        id: types.WindowId,
    ) ?NodeIndex {
        return switch (self.nodes.items[node_index].content) {
            .leaf => |candidate| if (candidate.eql(id)) node_index else null,
            .split => |split| self.findLeafFrom(split.first, id) orelse
                self.findLeafFrom(split.second, id),
        };
    }

    fn extremeLeaf(self: *const Dwindle, start: NodeIndex, reverse: bool) NodeIndex {
        var node_index = start;
        while (true) switch (self.nodes.items[node_index].content) {
            .leaf => return node_index,
            .split => |split| node_index = if (reverse) split.second else split.first,
        };
    }

    fn leafId(self: *const Dwindle, node_index: NodeIndex) types.WindowId {
        return self.nodes.items[node_index].content.leaf;
    }

    fn allocateNode(self: *Dwindle, node: Node) NodeIndex {
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

    fn releaseNode(self: *Dwindle, node_index: NodeIndex) void {
        self.free_nodes.appendAssumeCapacity(node_index);
    }
};

pub const Scrolling = struct {
    offset: u32 = 0,
    outer_gap: u32 = 16,
    inner_gap: u32 = 16,

    fn arrange(
        self: *Scrolling,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        focused: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        var plans: std.ArrayList(types.LayoutPlan) = .empty;
        errdefer plans.deinit(allocator);
        try plans.ensureTotalCapacity(allocator, windows.len);
        const area = inset(usable, self.outer_gap);
        var focus_start: ?u32 = null;
        var focus_end: u32 = 0;
        var cursor: u32 = 0;
        for (windows) |window| {
            const width = @max(@as(u32, 1), window.current.width);
            if (focused != null and window.id.eql(focused.?)) {
                focus_start = cursor;
                focus_end = cursor + width;
            }
            cursor +|= width +| self.inner_gap;
        }
        if (focus_start) |start| {
            if (start < self.offset) self.offset = start;
            if (focus_end > self.offset +| area.size.width)
                self.offset = focus_end - area.size.width;
        }

        cursor = 0;
        for (windows) |window| {
            const width = @max(@as(u32, 1), window.current.width);
            const x64 = @as(i64, area.x) + @as(i64, cursor) - @as(i64, self.offset);
            const rect: types.Rect = .{
                .x = @intCast(std.math.clamp(x64, std.math.minInt(i32), std.math.maxInt(i32))),
                .y = area.y,
                .size = types.Size.init(width, area.size.height),
            };
            const clip = intersection(rect, area);
            plans.appendAssumeCapacity(.{
                .id = window.id,
                .rect = rect,
                .visible = clip != null,
                .clip = clip,
                .shadow_clip = area,
            });
            cursor +|= width +| self.inner_gap;
        }
        return plans;
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

fn appendColumn(
    plans: *std.ArrayList(types.LayoutPlan),
    windows: []const types.WindowInput,
    area: types.Rect,
    requested_gap: u32,
) void {
    const count: u32 = @intCast(windows.len);
    if (area.size.height < count) {
        for (windows) |window| plans.appendAssumeCapacity(.{
            .id = window.id,
            .rect = area,
            .visible = true,
            .tiled_edges = .{ .top = true, .right = true, .bottom = true, .left = true },
        });
        return;
    }
    const gap = if (count > 1) @min(requested_gap, (area.size.height - count) / (count - 1)) else 0;
    const height = area.size.height - gap * (count - 1);
    const base = height / count;
    const remainder = height % count;
    var y = area.y;
    for (windows, 0..) |window, i| {
        const item_height = base + @intFromBool(i < remainder);
        plans.appendAssumeCapacity(.{
            .id = window.id,
            .rect = .{ .x = area.x, .y = y, .size = types.Size.init(area.size.width, item_height) },
            .visible = true,
            .tiled_edges = .{ .top = true, .right = true, .bottom = true, .left = true },
        });
        y += @intCast(item_height + gap);
    }
}

fn intersection(a: types.Rect, b: types.Rect) ?types.Rect {
    const left = @max(@as(i64, a.x), b.x);
    const top = @max(@as(i64, a.y), b.y);
    const right = @min(@as(i64, a.x) + a.size.width, @as(i64, b.x) + b.size.width);
    const bottom = @min(@as(i64, a.y) + a.size.height, @as(i64, b.y) + b.size.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .size = types.Size.init(@intCast(right - left), @intCast(bottom - top)),
    };
}

fn setTiledShadowClips(plans: []types.LayoutPlan, usable: types.Rect) void {
    for (plans) |*plan| plan.shadow_clip = usable;
}

fn inputFor(windows: []const types.WindowInput, id: types.WindowId) ?types.WindowInput {
    for (windows) |window| if (window.id.eql(id)) return window;
    return null;
}

fn divide(
    rect: types.Rect,
    axis: Dwindle.Axis,
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

test "master stack geometry is deterministic with offsets gaps and remainders" {
    const area: types.Rect = .{ .x = 100, .y = 50, .size = types.Size.init(103, 65) };
    var layout: Layout = .{ .tiled = .{ .master_stack = .{ .outer_gap = 2, .inner_gap = 3 } } };
    const cases = [_][]const types.WindowInput{
        &.{},
        &.{input(0, 10)},
        &.{ input(0, 10), input(1, 10) },
        &.{ input(0, 10), input(1, 10), input(2, 10), input(3, 10) },
    };
    const expected = [_][]const types.Rect{
        &.{},
        &.{.{ .x = 102, .y = 52, .size = types.Size.init(99, 61) }},
        &.{
            .{ .x = 102, .y = 52, .size = types.Size.init(57, 61) },
            .{ .x = 162, .y = 52, .size = types.Size.init(39, 61) },
        },
        &.{
            .{ .x = 102, .y = 52, .size = types.Size.init(57, 61) },
            .{ .x = 162, .y = 52, .size = types.Size.init(39, 19) },
            .{ .x = 162, .y = 74, .size = types.Size.init(39, 18) },
            .{ .x = 162, .y = 95, .size = types.Size.init(39, 18) },
        },
    };
    for (cases, expected) |windows, rects| {
        var plans = try layout.arrange(std.testing.allocator, windows, area, null);
        defer plans.deinit(std.testing.allocator);
        try std.testing.expectEqual(rects.len, plans.items.len);
        for (plans.items, rects) |plan, rect| try std.testing.expectEqual(rect, plan.rect);
    }
}

test "gap configuration applies to every layout" {
    var master_stack: Layout = .init(.master_stack);
    master_stack.setGaps(12, 16);
    try std.testing.expectEqual(@as(u32, 12), master_stack.tiled.master_stack.inner_gap);
    try std.testing.expectEqual(@as(u32, 16), master_stack.tiled.master_stack.outer_gap);

    var dwindle: Layout = .init(.dwindle);
    defer dwindle.deinit(std.testing.allocator);
    dwindle.setGaps(20, 24);
    try std.testing.expectEqual(@as(u32, 20), dwindle.tiled.dwindle.inner_gap);
    try std.testing.expectEqual(@as(u32, 24), dwindle.tiled.dwindle.outer_gap);

    var scrolling: Layout = .init(.scrolling);
    scrolling.setGaps(28, 32);
    try std.testing.expectEqual(@as(u32, 28), scrolling.scrolling.inner_gap);
    try std.testing.expectEqual(@as(u32, 32), scrolling.scrolling.outer_gap);
}

test "tiled shadows share the usable area without neighbor clipping" {
    var layout: Layout = .{ .tiled = .{ .master_stack = .{ .outer_gap = 8, .inner_gap = 8 } } };
    const usable: types.Rect = .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 100),
    };
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

test "tiny areas emit every window once without zero sizes" {
    const windows = [_]types.WindowInput{ input(0, 1), input(1, 1), input(2, 1) };
    var layout: Layout = .{ .tiled = .{ .master_stack = .{ .outer_gap = 99, .inner_gap = 99 } } };
    var plans = try layout.arrange(std.testing.allocator, &windows, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(3, 3),
    }, null);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(windows.len, plans.items.len);
    for (plans.items, 0..) |plan, i| {
        try std.testing.expectEqual(windows[i].id, plan.id);
        try std.testing.expect(plan.rect.size.width > 0 and plan.rect.size.height > 0);
    }
}

test "dwindle splits the focused leaf along its longest dimension" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 0 } } };
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

test "dwindle tree traversal swaps leaves and collapses removed branches" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    const fourth = input(3, 10);
    var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 0 } } };
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

test "dwindle repositions a window on each side of the drop target" {
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
        var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 0 } } };
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

test "dwindle pointer resize adjusts the nearest bordering split" {
    const first = input(0, 10);
    const second = input(1, 10);
    const third = input(2, 10);
    var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 0 } } };
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

test "dwindle pointer resize rejects a split removed during the grab" {
    const first = input(0, 10);
    const second = input(1, 10);
    var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 0 } } };
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

test "dwindle pointer resize accepts a window edge across a wide gap" {
    const first = input(0, 10);
    const second = input(1, 10);
    var layout: Layout = .{ .tiled = .{ .dwindle = .{ .outer_gap = 0, .inner_gap = 20 } } };
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

test "scrolling keeps focus visible and clips viewport edges" {
    const windows = [_]types.WindowInput{ input(0, 60), input(1, 60), input(2, 60) };
    var layout: Layout = .{ .scrolling = .{ .outer_gap = 0, .inner_gap = 5 } };
    var plans = try layout.arrange(std.testing.allocator, &windows, .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 50),
    }, windows[2].id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 90), layout.scrolling.offset);
    try std.testing.expect(!plans.items[0].visible);
    try std.testing.expectEqual(@as(u32, 35), plans.items[1].clip.?.size.width);
    try std.testing.expectEqual(@as(u32, 60), plans.items[2].clip.?.size.width);
}

test "scrolling outer gap insets its viewport" {
    const window = input(0, 60);
    var layout: Layout = .{ .scrolling = .{ .outer_gap = 5, .inner_gap = 2 } };
    var plans = try layout.arrange(std.testing.allocator, &.{window}, .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 50),
    }, window.id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.Rect{
        .x = 15,
        .y = 25,
        .size = types.Size.init(60, 40),
    }, plans.items[0].rect);
    try std.testing.expectEqual(plans.items[0].rect, plans.items[0].clip.?);
    try std.testing.expectEqual(types.Rect{
        .x = 15,
        .y = 25,
        .size = types.Size.init(90, 40),
    }, plans.items[0].shadow_clip.?);
}
