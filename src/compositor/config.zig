//! Declarative keywork.conf loading and validation.

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;
const Direction = command.Direction;
const Launcher = @import("launcher.zig");

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

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding,

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
    rejected,
    snapshot: Snapshot,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_path: ?[]const u8,
) !Snapshot {
    if (explicit_path) |path| return switch (try loadPath(allocator, io, path)) {
        .snapshot => |snapshot| snapshot,
        .not_found => fallback: {
            log.info("no configuration found at {s}; using built-in defaults", .{path});
            break :fallback try defaultSnapshot(allocator);
        },
        .rejected => try defaultSnapshot(allocator),
    };

    if (environ_map.get("XDG_CONFIG_HOME")) |directory| {
        if (std.fs.path.isAbsolute(directory)) {
            if (try loadBelow(allocator, io, directory)) |attempt| return switch (attempt) {
                .snapshot => |snapshot| snapshot,
                .rejected => try defaultSnapshot(allocator),
                .not_found => unreachable,
            };
        }
    } else if (environ_map.get("HOME")) |home| {
        const directory = try std.fs.path.join(allocator, &.{ home, ".config" });
        defer allocator.free(directory);
        if (try loadBelow(allocator, io, directory)) |attempt| return switch (attempt) {
            .snapshot => |snapshot| snapshot,
            .rejected => try defaultSnapshot(allocator),
            .not_found => unreachable,
        };
    }

    const config_directories = environ_map.get("XDG_CONFIG_DIRS") orelse "/etc/xdg";
    var iterator = std.mem.splitScalar(u8, config_directories, ':');
    while (iterator.next()) |directory| {
        if (directory.len == 0 or !std.fs.path.isAbsolute(directory)) continue;
        if (try loadBelow(allocator, io, directory)) |attempt| return switch (attempt) {
            .snapshot => |snapshot| snapshot,
            .rejected => try defaultSnapshot(allocator),
            .not_found => unreachable,
        };
    }
    log.info("no configuration found; using built-in defaults", .{});
    return defaultSnapshot(allocator);
}

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

fn loadBelow(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !?LoadAttempt {
    const path = try std.fs.path.join(allocator, &.{ directory, "keywork", "config" });
    defer allocator.free(path);
    const attempt = try loadPath(allocator, io, path);
    return switch (attempt) {
        .not_found => null,
        else => attempt,
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
            log.err("could not read {s}: {t}; using built-in defaults", .{ path, err });
            return .rejected;
        },
    };
    defer allocator.free(source);
    const result = try parse(allocator, source);
    return switch (result) {
        .snapshot => |snapshot| loaded: {
            log.info("loaded configuration from {s}", .{path});
            break :loaded .{ .snapshot = snapshot };
        },
        .diagnostic => |diagnostic| rejected: {
            log.err(
                "{s}:{d}: {s}; using built-in defaults",
                .{ path, diagnostic.line, problemMessage(diagnostic.problem) },
            );
            break :rejected .rejected;
        },
    };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var bindings: std.ArrayList(Binding) = .empty;
    var in_bindings_section = false;
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
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (!std.mem.eql(u8, section, "bindings")) {
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_section } };
            }
            in_bindings_section = true;
            continue;
        }
        if (!in_bindings_section) {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .directive_outside_section } };
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .invalid_directive } };
        };
        const name = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.mem.eql(u8, name, "bind")) {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_directive } };
        }
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        const binding = parseBinding(arena_allocator, value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            arena.deinit();
            return .{ .diagnostic = .{
                .line = line_number,
                .problem = problemForError(err),
            } };
        };
        try bindings.append(arena_allocator, binding);
    }
    return .{ .snapshot = .{
        .arena = arena,
        .bindings = try bindings.toOwnedSlice(arena_allocator),
    } };
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
}

test "embedded default configuration is valid and complete" {
    var snapshot = try defaultSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 32), snapshot.bindings.len);
    try std.testing.expectEqual(Direction.left, snapshot.bindings[0].action.command.focus_direction);
    try std.testing.expectEqualStrings("monstar", snapshot.bindings[31].action.run[0]);
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
