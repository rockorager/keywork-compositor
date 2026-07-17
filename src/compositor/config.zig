//! Declarative keywork.conf loading and validation.

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;
const Direction = command.Direction;
const Launcher = @import("launcher.zig");
const NativeInput = @import("backend/native_input.zig");

const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});
const log = std.log.scoped(.config);
const default_source = @embedFile("default-config");
const maximum_file_size = 1024 * 1024;

pub const super: u32 = 1 << 6; // xkb Mod4/Logo
pub const shift: u32 = 1 << 0;
pub const control: u32 = 1 << 2;
pub const alt: u32 = 1 << 3;

pub const Action = union(enum) {
    command: Command,
    run: []const []const u8,
};

pub const Binding = struct {
    modifiers: u32,
    keysym: u32,
    action: Action,
};

pub fn InputValue(comptime T: type) type {
    return union(enum) {
        use_default,
        value: T,

        pub fn resolve(self: @This(), default_value: T) T {
            return switch (self) {
                .use_default => default_value,
                .value => |value| value,
            };
        }
    };
}

pub const InputDeviceType = enum {
    keyboard,
    pointer,
    touchpad,
    touch,
    tablet,
    tablet_pad,
};

pub const SendEvents = enum {
    enabled,
    disabled,
    disabled_on_external_mouse,
};

pub const InputMatcher = struct {
    device_type: ?InputDeviceType = null,
    name: ?[]const u8 = null,
    vendor: ?u32 = null,
    product: ?u32 = null,

    pub fn matches(self: InputMatcher, device: InputDeviceMatch) bool {
        if (self.device_type) |expected| {
            const type_matches = switch (expected) {
                .keyboard => device.keyboard,
                .pointer => device.pointer,
                .touchpad => device.touchpad,
                .touch => device.touch,
                .tablet => device.tablet,
                .tablet_pad => device.tablet_pad,
            };
            if (!type_matches) return false;
        }
        if (self.name) |pattern| if (!globMatches(pattern, device.name)) return false;
        if (self.vendor) |vendor| if (vendor != device.vendor) return false;
        if (self.product) |product| if (product != device.product) return false;
        return true;
    }
};

pub const InputDeviceMatch = struct {
    name: []const u8,
    vendor: u32,
    product: u32,
    keyboard: bool = false,
    pointer: bool = false,
    touchpad: bool = false,
    touch: bool = false,
    tablet: bool = false,
    tablet_pad: bool = false,
};

pub const InputSettings = struct {
    send_events: ?InputValue(SendEvents) = null,
    tap: ?InputValue(NativeInput.Toggle) = null,
    tap_button_map: ?InputValue(NativeInput.TapButtonMap) = null,
    drag: ?InputValue(NativeInput.Toggle) = null,
    drag_lock: ?InputValue(NativeInput.DragLock) = null,
    three_finger_drag: ?InputValue(NativeInput.ThreeFingerDrag) = null,
    accel_profile: ?InputValue(NativeInput.AccelProfile) = null,
    accel_speed: ?InputValue(f64) = null,
    natural_scroll: ?InputValue(NativeInput.Toggle) = null,
    left_handed: ?InputValue(NativeInput.Toggle) = null,
    click_method: ?InputValue(NativeInput.ClickMethod) = null,
    clickfinger_button_map: ?InputValue(NativeInput.ClickfingerButtonMap) = null,
    middle_emulation: ?InputValue(NativeInput.Toggle) = null,
    scroll_method: ?InputValue(NativeInput.ScrollMethod) = null,
    scroll_button: ?InputValue(u32) = null,
    scroll_button_lock: ?InputValue(NativeInput.Toggle) = null,
    disable_while_typing: ?InputValue(NativeInput.Toggle) = null,
    disable_while_trackpointing: ?InputValue(NativeInput.Toggle) = null,
    rotation: ?InputValue(u32) = null,
    scroll_factor: ?InputValue(f64) = null,
    repeat_rate: ?InputValue(i32) = null,
    repeat_delay: ?InputValue(i32) = null,
};

pub const InputRule = struct {
    matcher: InputMatcher,
    settings: InputSettings = .{},
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding,
    input_rules: []const InputRule,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Problem = enum {
    invalid_section,
    unknown_section,
    directive_outside_section,
    invalid_directive,
    unknown_directive,
    empty_binding,
    unterminated_quote,
    dangling_escape,
    invalid_trigger,
    invalid_modifier,
    duplicate_modifier,
    invalid_key,
    unknown_action,
    invalid_action_arguments,
    invalid_direction,
    invalid_layout,
    invalid_workspace,
    invalid_executable,
    invalid_input_matcher,
    unknown_input_matcher,
    duplicate_input_matcher,
    invalid_input_setting,
    unknown_input_setting,
    duplicate_input_setting,
};

pub const Diagnostic = struct {
    line: usize,
    problem: Problem,
};

pub const ParseResult = union(enum) {
    snapshot: Snapshot,
    diagnostic: Diagnostic,
};

const BindingError = error{
    EmptyBinding,
    UnterminatedQuote,
    DanglingEscape,
    InvalidTrigger,
    InvalidModifier,
    DuplicateModifier,
    InvalidKey,
    UnknownAction,
    InvalidActionArguments,
    InvalidDirection,
    InvalidLayout,
    InvalidWorkspace,
    InvalidExecutable,
};

const LoadAttempt = union(enum) {
    not_found,
    snapshot: Snapshot,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_path: ?[]u8,
    snapshot: Snapshot,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        explicit_path: ?[]const u8,
    ) !Store {
        const owned_path = if (explicit_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_path) |path| allocator.free(path);
        var self: Store = .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .explicit_path = owned_path,
            .snapshot = undefined,
        };
        self.snapshot = self.loadSnapshot() catch |err| switch (err) {
            error.InvalidConfiguration, error.ConfigurationReadFailed => fallback: {
                log.warn("initial configuration failed; using built-in defaults", .{});
                break :fallback try defaultSnapshot(allocator);
            },
            else => return err,
        };
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.snapshot.deinit();
        if (self.explicit_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Returns a completely parsed replacement without changing active state.
    pub fn loadSnapshot(self: *const Store) !Snapshot {
        if (self.explicit_path) |path| return switch (try loadPath(self.allocator, self.io, path)) {
            .snapshot => |snapshot| snapshot,
            .not_found => fallback: {
                log.info("no configuration found at {s}; using built-in defaults", .{path});
                break :fallback try defaultSnapshot(self.allocator);
            },
        };

        if (self.environ_map.get("XDG_CONFIG_HOME")) |directory| {
            if (std.fs.path.isAbsolute(directory)) {
                if (try loadBelow(self.allocator, self.io, directory)) |snapshot| return snapshot;
            }
        } else if (self.environ_map.get("HOME")) |home| {
            const directory = try std.fs.path.join(self.allocator, &.{ home, ".config" });
            defer self.allocator.free(directory);
            if (try loadBelow(self.allocator, self.io, directory)) |snapshot| return snapshot;
        }

        const config_directories = self.environ_map.get("XDG_CONFIG_DIRS") orelse "/etc/xdg";
        var iterator = std.mem.splitScalar(u8, config_directories, ':');
        while (iterator.next()) |directory| {
            if (directory.len == 0 or !std.fs.path.isAbsolute(directory)) continue;
            if (try loadBelow(self.allocator, self.io, directory)) |snapshot| return snapshot;
        }
        log.info("no configuration found; using built-in defaults", .{});
        return defaultSnapshot(self.allocator);
    }
};

fn defaultSnapshot(allocator: std.mem.Allocator) !Snapshot {
    return switch (try parse(allocator, default_source)) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => |diagnostic| {
            log.err(
                "built-in configuration:{d}: {s}",
                .{ diagnostic.line, problemMessage(diagnostic.problem) },
            );
            return error.InvalidDefaultConfiguration;
        },
    };
}

fn loadBelow(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !?Snapshot {
    const path = try std.fs.path.join(allocator, &.{ directory, "keywork", "config" });
    defer allocator.free(path);
    return switch (try loadPath(allocator, io, path)) {
        .not_found => null,
        .snapshot => |snapshot| snapshot,
    };
}

fn loadPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadAttempt {
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(maximum_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .not_found,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.err("could not read {s}: {t}", .{ path, err });
            return error.ConfigurationReadFailed;
        },
    };
    defer allocator.free(source);
    const result = try parse(allocator, source);
    return switch (result) {
        .snapshot => |snapshot| loaded: {
            log.info("loaded configuration from {s}", .{path});
            break :loaded .{ .snapshot = snapshot };
        },
        .diagnostic => |diagnostic| {
            log.err(
                "{s}:{d}: {s}",
                .{ path, diagnostic.line, problemMessage(diagnostic.problem) },
            );
            return error.InvalidConfiguration;
        },
    };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var bindings: std.ArrayList(Binding) = .empty;
    var input_rules: std.ArrayList(InputRule) = .empty;
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') {
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = .invalid_section } };
            }
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.eql(u8, header, "bindings")) {
                section = .bindings;
                continue;
            }
            const matcher = parseInputHeader(arena_allocator, header) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                arena.deinit();
                return .{ .diagnostic = .{
                    .line = line_number,
                    .problem = problemForInputHeaderError(err),
                } };
            } orelse {
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_section } };
            };
            try input_rules.append(arena_allocator, .{ .matcher = matcher });
            section = .{ .input = input_rules.items.len - 1 };
            continue;
        }
        if (section == .none) {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .directive_outside_section } };
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .invalid_directive } };
        };
        const name = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        switch (section) {
            .none => unreachable,
            .bindings => {
                if (!std.mem.eql(u8, name, "bind")) {
                    arena.deinit();
                    return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_directive } };
                }
                const binding = parseBinding(arena_allocator, value) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    arena.deinit();
                    return .{ .diagnostic = .{
                        .line = line_number,
                        .problem = problemForError(err),
                    } };
                };
                try bindings.append(arena_allocator, binding);
            },
            .input => |index| parseInputSetting(&input_rules.items[index].settings, name, value) catch |err| {
                arena.deinit();
                return .{ .diagnostic = .{
                    .line = line_number,
                    .problem = problemForInputSettingError(err),
                } };
            },
        }
    }
    return .{ .snapshot = .{
        .arena = arena,
        .bindings = try bindings.toOwnedSlice(arena_allocator),
        .input_rules = try input_rules.toOwnedSlice(arena_allocator),
    } };
}

const Section = union(enum) {
    none,
    bindings,
    input: usize,
};

const InputHeaderError = error{
    InvalidInputMatcher,
    UnknownInputMatcher,
    DuplicateInputMatcher,
};

fn parseInputHeader(
    allocator: std.mem.Allocator,
    header: []const u8,
) (InputHeaderError || error{OutOfMemory})!?InputMatcher {
    const section_name = "input";
    if (!std.mem.startsWith(u8, header, section_name)) return null;
    if (header.len > section_name.len and header[section_name.len] != ' ' and
        header[section_name.len] != '\t') return null;
    const source = std.mem.trim(u8, header[section_name.len..], " \t");
    const words = parseWords(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedQuote, error.DanglingEscape => return error.InvalidInputMatcher,
        else => unreachable,
    };
    var matcher: InputMatcher = .{};
    for (words) |word| {
        const equals = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidInputMatcher;
        const name = word[0..equals];
        const value = word[equals + 1 ..];
        if (name.len == 0 or value.len == 0) return error.InvalidInputMatcher;
        if (std.mem.eql(u8, name, "type")) {
            if (matcher.device_type != null) return error.DuplicateInputMatcher;
            matcher.device_type = enumFromConfig(InputDeviceType, value) orelse
                return error.InvalidInputMatcher;
        } else if (std.mem.eql(u8, name, "name")) {
            if (matcher.name != null) return error.DuplicateInputMatcher;
            matcher.name = value;
        } else if (std.mem.eql(u8, name, "vendor")) {
            if (matcher.vendor != null) return error.DuplicateInputMatcher;
            matcher.vendor = std.fmt.parseInt(u32, value, 0) catch
                return error.InvalidInputMatcher;
        } else if (std.mem.eql(u8, name, "product")) {
            if (matcher.product != null) return error.DuplicateInputMatcher;
            matcher.product = std.fmt.parseInt(u32, value, 0) catch
                return error.InvalidInputMatcher;
        } else {
            return error.UnknownInputMatcher;
        }
    }
    return matcher;
}

const InputSettingError = error{
    InvalidInputSetting,
    UnknownInputSetting,
    DuplicateInputSetting,
};

fn parseInputSetting(settings: *InputSettings, name: []const u8, value: []const u8) InputSettingError!void {
    if (std.mem.eql(u8, name, "send-events")) {
        try assignInputSetting(InputValue(SendEvents), &settings.send_events, try parseEnumInputValue(SendEvents, value));
    } else if (std.mem.eql(u8, name, "tap")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.tap, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "tap-button-map")) {
        try assignInputSetting(InputValue(NativeInput.TapButtonMap), &settings.tap_button_map, try parseEnumInputValue(NativeInput.TapButtonMap, value));
    } else if (std.mem.eql(u8, name, "drag")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.drag, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "drag-lock")) {
        try assignInputSetting(InputValue(NativeInput.DragLock), &settings.drag_lock, try parseEnumInputValue(NativeInput.DragLock, value));
    } else if (std.mem.eql(u8, name, "three-finger-drag")) {
        try assignInputSetting(InputValue(NativeInput.ThreeFingerDrag), &settings.three_finger_drag, try parseEnumInputValue(NativeInput.ThreeFingerDrag, value));
    } else if (std.mem.eql(u8, name, "accel-profile")) {
        const parsed = try parseEnumInputValue(NativeInput.AccelProfile, value);
        if (parsed == .value and (parsed.value == .none or parsed.value == .custom)) return error.InvalidInputSetting;
        try assignInputSetting(InputValue(NativeInput.AccelProfile), &settings.accel_profile, parsed);
    } else if (std.mem.eql(u8, name, "accel-speed")) {
        try assignInputSetting(InputValue(f64), &settings.accel_speed, try parseFloatInputValue(value, -1, 1));
    } else if (std.mem.eql(u8, name, "natural-scroll")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.natural_scroll, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "left-handed")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.left_handed, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "click-method")) {
        try assignInputSetting(InputValue(NativeInput.ClickMethod), &settings.click_method, try parseEnumInputValue(NativeInput.ClickMethod, value));
    } else if (std.mem.eql(u8, name, "clickfinger-button-map")) {
        try assignInputSetting(InputValue(NativeInput.ClickfingerButtonMap), &settings.clickfinger_button_map, try parseEnumInputValue(NativeInput.ClickfingerButtonMap, value));
    } else if (std.mem.eql(u8, name, "middle-emulation")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.middle_emulation, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "scroll-method")) {
        try assignInputSetting(InputValue(NativeInput.ScrollMethod), &settings.scroll_method, try parseEnumInputValue(NativeInput.ScrollMethod, value));
    } else if (std.mem.eql(u8, name, "scroll-button")) {
        try assignInputSetting(InputValue(u32), &settings.scroll_button, try parseUnsignedInputValue(value));
    } else if (std.mem.eql(u8, name, "scroll-button-lock")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.scroll_button_lock, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "disable-while-typing")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.disable_while_typing, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "disable-while-trackpointing")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.disable_while_trackpointing, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "rotation")) {
        const parsed = try parseUnsignedInputValue(value);
        if (parsed == .value and parsed.value >= 360) return error.InvalidInputSetting;
        try assignInputSetting(InputValue(u32), &settings.rotation, parsed);
    } else if (std.mem.eql(u8, name, "scroll-factor")) {
        try assignInputSetting(InputValue(f64), &settings.scroll_factor, try parseFloatInputValue(value, 0, std.math.inf(f64)));
    } else if (std.mem.eql(u8, name, "repeat-rate")) {
        try assignInputSetting(InputValue(i32), &settings.repeat_rate, try parseNonnegativeInputValue(value));
    } else if (std.mem.eql(u8, name, "repeat-delay")) {
        try assignInputSetting(InputValue(i32), &settings.repeat_delay, try parseNonnegativeInputValue(value));
    } else {
        return error.UnknownInputSetting;
    }
}

fn assignInputSetting(comptime T: type, target: *?T, value: T) InputSettingError!void {
    if (target.* != null) return error.DuplicateInputSetting;
    target.* = value;
}

fn parseEnumInputValue(comptime T: type, value: []const u8) InputSettingError!InputValue(T) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    return .{ .value = enumFromConfig(T, value) orelse return error.InvalidInputSetting };
}

fn parseFloatInputValue(value: []const u8, minimum: f64, maximum: f64) InputSettingError!InputValue(f64) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidInputSetting;
    if (!std.math.isFinite(parsed) or parsed < minimum or parsed > maximum) return error.InvalidInputSetting;
    return .{ .value = parsed };
}

fn parseUnsignedInputValue(value: []const u8) InputSettingError!InputValue(u32) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    return .{ .value = std.fmt.parseInt(u32, value, 0) catch return error.InvalidInputSetting };
}

fn parseNonnegativeInputValue(value: []const u8) InputSettingError!InputValue(i32) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    const parsed = std.fmt.parseInt(i32, value, 0) catch return error.InvalidInputSetting;
    if (parsed < 0) return error.InvalidInputSetting;
    return .{ .value = parsed };
}

fn enumFromConfig(comptime T: type, value: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (configNameEquals(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn configNameEquals(value: []const u8, field_name: []const u8) bool {
    if (value.len != field_name.len) return false;
    for (value, field_name) |actual, field| {
        if (actual != if (field == '_') '-' else field) return false;
    }
    return true;
}

fn globMatches(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == value[value_index]))
        {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (star_index) |star| {
            star_value_index += 1;
            value_index = star_value_index;
            pattern_index = star + 1;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn parseBinding(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})!Binding {
    const words = try parseWords(allocator, value);
    if (words.len < 2) return error.EmptyBinding;
    const trigger = try parseTrigger(allocator, words[0]);
    const action_name = words[1];
    const arguments = words[2..];
    const action: Action = if (std.mem.eql(u8, action_name, "focus"))
        .{ .command = try parseDirectionalCommand(arguments, false) }
    else if (std.mem.eql(u8, action_name, "move-focused"))
        .{ .command = try parseDirectionalCommand(arguments, true) }
    else if (std.mem.eql(u8, action_name, "set-layout"))
        .{ .command = try parseLayout(arguments) }
    else if (std.mem.eql(u8, action_name, "switch-workspace"))
        .{ .command = .{ .switch_workspace = try parseWorkspace(arguments) } }
    else if (std.mem.eql(u8, action_name, "move-focused-to-workspace"))
        .{ .command = .{ .move_to_workspace = try parseWorkspace(arguments) } }
    else if (std.mem.eql(u8, action_name, "run")) run: {
        if (arguments.len == 0) return error.InvalidActionArguments;
        Launcher.validateArgv(arguments) catch return error.InvalidExecutable;
        break :run .{ .run = arguments };
    } else return error.UnknownAction;
    return .{ .modifiers = trigger.modifiers, .keysym = trigger.keysym, .action = action };
}

fn parseWords(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (true) {
        while (index < value.len and (value[index] == ' ' or value[index] == '\t')) index += 1;
        if (index == value.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        var started = false;
        while (index < value.len) {
            const byte = value[index];
            if (quote) |delimiter| {
                if (byte == delimiter) {
                    quote = null;
                    started = true;
                    index += 1;
                } else if (byte == '\\') {
                    index += 1;
                    if (index == value.len) return error.DanglingEscape;
                    try word.append(allocator, value[index]);
                    started = true;
                    index += 1;
                } else {
                    try word.append(allocator, byte);
                    started = true;
                    index += 1;
                }
                continue;
            }
            if (byte == ' ' or byte == '\t') break;
            if (byte == '\'' or byte == '"') {
                quote = byte;
                started = true;
                index += 1;
            } else if (byte == '\\') {
                index += 1;
                if (index == value.len) return error.DanglingEscape;
                try word.append(allocator, value[index]);
                started = true;
                index += 1;
            } else {
                try word.append(allocator, byte);
                started = true;
                index += 1;
            }
        }
        if (quote != null) return error.UnterminatedQuote;
        std.debug.assert(started);
        try words.append(allocator, try word.toOwnedSlice(allocator));
    }
    return words.toOwnedSlice(allocator);
}

const Trigger = struct { modifiers: u32, keysym: u32 };

fn parseTrigger(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})!Trigger {
    if (value.len == 0 or value[0] == '+' or value[value.len - 1] == '+' or
        std.mem.indexOf(u8, value, "++") != null)
    {
        return error.InvalidTrigger;
    }
    const last_plus = std.mem.lastIndexOfScalar(u8, value, '+');
    const key_name = if (last_plus) |index| value[index + 1 ..] else value;
    var modifiers: u32 = 0;
    if (last_plus) |end| {
        var parts = std.mem.splitScalar(u8, value[0..end], '+');
        while (parts.next()) |name| {
            const modifier: u32 = if (std.mem.eql(u8, name, "super"))
                super
            else if (std.mem.eql(u8, name, "shift"))
                shift
            else if (std.mem.eql(u8, name, "ctrl") or std.mem.eql(u8, name, "control"))
                control
            else if (std.mem.eql(u8, name, "alt"))
                alt
            else
                return error.InvalidModifier;
            if (modifiers & modifier != 0) return error.DuplicateModifier;
            modifiers |= modifier;
        }
    }
    const key_name_z = try allocator.dupeZ(u8, key_name);
    const keysym = c.xkb_keysym_from_name(key_name_z, c.XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) return error.InvalidKey;
    return .{ .modifiers = modifiers, .keysym = keysym };
}

fn parseDirectionalCommand(arguments: []const []const u8, move: bool) BindingError!Command {
    if (arguments.len != 1) return error.InvalidActionArguments;
    const direction = arguments[0];
    if (std.mem.eql(u8, direction, "next")) return if (move) .move_focused_next else .focus_next;
    if (std.mem.eql(u8, direction, "previous")) return if (move) .move_focused_previous else .focus_previous;
    const parsed: Direction = std.meta.stringToEnum(Direction, direction) orelse
        return error.InvalidDirection;
    return if (move) .{ .move_focused_direction = parsed } else .{ .focus_direction = parsed };
}

fn parseLayout(arguments: []const []const u8) BindingError!Command {
    if (arguments.len != 1) return error.InvalidActionArguments;
    if (std.mem.eql(u8, arguments[0], "master-stack")) return .layout_master_stack;
    if (std.mem.eql(u8, arguments[0], "dwindle")) return .layout_dwindle;
    if (std.mem.eql(u8, arguments[0], "scrolling")) return .layout_scrolling;
    return error.InvalidLayout;
}

fn parseWorkspace(arguments: []const []const u8) BindingError!u8 {
    if (arguments.len != 1) return error.InvalidActionArguments;
    const workspace = std.fmt.parseInt(u8, arguments[0], 10) catch return error.InvalidWorkspace;
    if (workspace < 1 or workspace > 10) return error.InvalidWorkspace;
    return workspace;
}

fn problemForError(err: anyerror) Problem {
    return switch (err) {
        error.EmptyBinding => .empty_binding,
        error.UnterminatedQuote => .unterminated_quote,
        error.DanglingEscape => .dangling_escape,
        error.InvalidTrigger => .invalid_trigger,
        error.InvalidModifier => .invalid_modifier,
        error.DuplicateModifier => .duplicate_modifier,
        error.InvalidKey => .invalid_key,
        error.UnknownAction => .unknown_action,
        error.InvalidActionArguments => .invalid_action_arguments,
        error.InvalidDirection => .invalid_direction,
        error.InvalidLayout => .invalid_layout,
        error.InvalidWorkspace => .invalid_workspace,
        error.InvalidExecutable => .invalid_executable,
        else => unreachable,
    };
}

fn problemForInputHeaderError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidInputMatcher => .invalid_input_matcher,
        error.UnknownInputMatcher => .unknown_input_matcher,
        error.DuplicateInputMatcher => .duplicate_input_matcher,
        else => unreachable,
    };
}

fn problemForInputSettingError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidInputSetting => .invalid_input_setting,
        error.UnknownInputSetting => .unknown_input_setting,
        error.DuplicateInputSetting => .duplicate_input_setting,
        else => unreachable,
    };
}

pub fn problemMessage(problem: Problem) []const u8 {
    return switch (problem) {
        .invalid_section => "invalid section header",
        .unknown_section => "unknown section",
        .directive_outside_section => "directive appears outside a section",
        .invalid_directive => "directive must contain '='",
        .unknown_directive => "unknown directive",
        .empty_binding => "binding requires a trigger and action",
        .unterminated_quote => "unterminated quoted argument",
        .dangling_escape => "unfinished argument escape",
        .invalid_trigger => "invalid binding trigger",
        .invalid_modifier => "unknown binding modifier",
        .duplicate_modifier => "duplicate binding modifier",
        .invalid_key => "unknown key name",
        .unknown_action => "unknown binding action",
        .invalid_action_arguments => "invalid arguments for binding action",
        .invalid_direction => "invalid direction",
        .invalid_layout => "invalid layout",
        .invalid_workspace => "workspace must be between 1 and 10",
        .invalid_executable => "executable must be an absolute path or a bare filename",
        .invalid_input_matcher => "invalid input matcher",
        .unknown_input_matcher => "unknown input matcher",
        .duplicate_input_matcher => "duplicate input matcher",
        .invalid_input_setting => "invalid input setting",
        .unknown_input_setting => "unknown input setting",
        .duplicate_input_setting => "duplicate input setting",
    };
}

test "configuration parses typed commands and explicit run argv" {
    const source =
        \\[bindings]
        \\bind=super+h focus left
        \\bind=super+shift+j move-focused down
        \\bind=super+t set-layout master-stack
        \\bind=super+1 switch-workspace 1
        \\bind=super+shift+0 move-focused-to-workspace 10
        \\bind=super+return run foot --title "Keywork Terminal" 'empty='
    ;
    const result = try parse(std.testing.allocator, source);
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 6), snapshot.bindings.len);
    try std.testing.expectEqual(Direction.left, snapshot.bindings[0].action.command.focus_direction);
    try std.testing.expectEqual(Direction.down, snapshot.bindings[1].action.command.move_focused_direction);
    try std.testing.expectEqual(Command.layout_master_stack, snapshot.bindings[2].action.command);
    try std.testing.expectEqual(@as(u8, 10), snapshot.bindings[4].action.command.move_to_workspace);
    try std.testing.expectEqualStrings("foot", snapshot.bindings[5].action.run[0]);
    try std.testing.expectEqualStrings("Keywork Terminal", snapshot.bindings[5].action.run[2]);
    try std.testing.expectEqualStrings("empty=", snapshot.bindings[5].action.run[3]);
}

test "valid empty configuration disables configured bindings" {
    const result = try parse(std.testing.allocator, "# intentionally empty\n[bindings]\n");
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.bindings.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.input_rules.len);
}

test "embedded default configuration is valid and complete" {
    var snapshot = try defaultSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 32), snapshot.bindings.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.input_rules.len);
    try std.testing.expectEqual(Direction.left, snapshot.bindings[0].action.command.focus_direction);
    try std.testing.expectEqualStrings("monstar", snapshot.bindings[31].action.run[0]);
}

test "input rules parse matchers and typed settings" {
    const source =
        \\[input type=pointer]
        \\natural-scroll=disabled
        \\[input type=touchpad name="ELAN *" vendor=0x04f3 product=0x1234]
        \\send-events=disabled-on-external-mouse
        \\tap=enabled
        \\tap-button-map=lmr
        \\drag=enabled
        \\drag-lock=sticky
        \\three-finger-drag=four-fingers
        \\accel-profile=adaptive
        \\accel-speed=-0.25
        \\natural-scroll=enabled
        \\left-handed=disabled
        \\click-method=clickfinger
        \\clickfinger-button-map=lrm
        \\middle-emulation=enabled
        \\scroll-method=two-finger
        \\scroll-button=0x112
        \\scroll-button-lock=enabled
        \\disable-while-typing=enabled
        \\disable-while-trackpointing=disabled
        \\rotation=180
        \\scroll-factor=0.75
        \\repeat-rate=30
        \\repeat-delay=400
    ;
    const result = try parse(std.testing.allocator, source);
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.input_rules.len);
    try std.testing.expectEqual(InputDeviceType.pointer, snapshot.input_rules[0].matcher.device_type.?);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, snapshot.input_rules[0].settings.natural_scroll.?.value);

    const rule = snapshot.input_rules[1];
    try std.testing.expectEqual(InputDeviceType.touchpad, rule.matcher.device_type.?);
    try std.testing.expectEqualStrings("ELAN *", rule.matcher.name.?);
    try std.testing.expectEqual(@as(u32, 0x04f3), rule.matcher.vendor.?);
    try std.testing.expectEqual(@as(u32, 0x1234), rule.matcher.product.?);
    try std.testing.expectEqual(SendEvents.disabled_on_external_mouse, rule.settings.send_events.?.value);
    try std.testing.expectEqual(NativeInput.ThreeFingerDrag.four_fingers, rule.settings.three_finger_drag.?.value);
    try std.testing.expectEqual(NativeInput.AccelProfile.adaptive, rule.settings.accel_profile.?.value);
    try std.testing.expectEqual(@as(f64, -0.25), rule.settings.accel_speed.?.value);
    try std.testing.expectEqual(@as(u32, 0x112), rule.settings.scroll_button.?.value);
    try std.testing.expectEqual(@as(i32, 400), rule.settings.repeat_delay.?.value);
    try std.testing.expect(rule.matcher.matches(.{
        .name = "ELAN Touchpad",
        .vendor = 0x04f3,
        .product = 0x1234,
        .pointer = true,
        .touchpad = true,
    }));
    try std.testing.expect(!rule.matcher.matches(.{
        .name = "ELAN Touchpad",
        .vendor = 0x04f3,
        .product = 1,
        .pointer = true,
        .touchpad = true,
    }));
}

test "input name matchers support star and question wildcards" {
    try std.testing.expect(globMatches("Logitech * 3S", "Logitech MX Master 3S"));
    try std.testing.expect(globMatches("event?", "event7"));
    try std.testing.expect(!globMatches("event?", "event12"));
    try std.testing.expect(!globMatches("ELAN*", "Logitech MX Master 3S"));
}

test "input rules reject malformed matchers and settings" {
    const duplicate_matcher = try parse(std.testing.allocator, "[input type=pointer type=touchpad]\n");
    try std.testing.expectEqual(Problem.duplicate_input_matcher, duplicate_matcher.diagnostic.problem);
    const unknown_matcher = try parse(std.testing.allocator, "[input path=/dev/input/event0]\n");
    try std.testing.expectEqual(Problem.unknown_input_matcher, unknown_matcher.diagnostic.problem);
    const invalid_matcher = try parse(std.testing.allocator, "[input type=mouse]\n");
    try std.testing.expectEqual(Problem.invalid_input_matcher, invalid_matcher.diagnostic.problem);
    const duplicate_setting = try parse(std.testing.allocator, "[input]\ntap=enabled\ntap=disabled\n");
    try std.testing.expectEqual(Problem.duplicate_input_setting, duplicate_setting.diagnostic.problem);
    const unknown_setting = try parse(std.testing.allocator, "[input]\nsensitivity=1\n");
    try std.testing.expectEqual(Problem.unknown_input_setting, unknown_setting.diagnostic.problem);
    const invalid_setting = try parse(std.testing.allocator, "[input]\naccel-speed=2\n");
    try std.testing.expectEqual(Problem.invalid_input_setting, invalid_setting.diagnostic.problem);
}

test "configuration rejects the complete snapshot at the failing line" {
    var result = try parse(std.testing.allocator,
        \\[bindings]
        \\bind=super+h focus left
        \\bind=super+x run ./relative-command
    );
    const diagnostic = switch (result) {
        .snapshot => |*snapshot| {
            snapshot.deinit();
            return error.ExpectedDiagnostic;
        },
        .diagnostic => |diagnostic| diagnostic,
    };
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(Problem.invalid_executable, diagnostic.problem);
}

test "configuration rejects malformed syntax and unknown sections" {
    const quoted = try parse(std.testing.allocator, "[bindings]\nbind=super+x run foot \\");
    try std.testing.expectEqual(Problem.dangling_escape, quoted.diagnostic.problem);
    const section = try parse(std.testing.allocator, "[outputs]\n");
    try std.testing.expectEqual(Problem.unknown_section, section.diagnostic.problem);
    const modifier = try parse(std.testing.allocator, "[bindings]\nbind=super+super+x focus left\n");
    try std.testing.expectEqual(Problem.duplicate_modifier, modifier.diagnostic.problem);
}
