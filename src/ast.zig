const std = @import("std");
const zlua = @import("zlua");
const util = @import("util.zig");
const Lua = zlua.Lua;

pub const ASTStruct = struct {
    // 全局定义
    define: std.StringHashMap(std.json.Value),
    // 部分二进制资源
    resource: std.StringHashMap([]const u8),
    // 当前翻译
    translate: std.StringHashMap(std.StringHashMap([]const u8)),
    // 当前样式表
    style: std.StringHashMap([]const u8),
    // 当前控件表
    components: std.ArrayList(std.StringHashMap(std.json.Value)),
    // 最终的文案代码
    copywriting: std.json.Value,
    // 自定义 JSON 解析器
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        // 1. 序列化 define
        try jw.objectField("define");
        try jw.beginObject();
        var def_iter = self.define.iterator();
        while (def_iter.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }
        try jw.endObject();

        // 2. 序列化 resource
        try jw.objectField("resource");
        try jw.beginObject();
        var res_iter = self.resource.iterator();
        while (res_iter.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }
        try jw.endObject();

        // 3. 序列化 translate (嵌套 HashMap)
        try jw.objectField("translate");
        try jw.beginObject();
        var trans_iter = self.translate.iterator();
        while (trans_iter.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            // 内层 HashMap
            try jw.beginObject();
            var inner_iter = entry.value_ptr.*.iterator();
            while (inner_iter.next()) |inner_entry| {
                try jw.objectField(inner_entry.key_ptr.*);
                try jw.write(inner_entry.value_ptr.*);
            }
            try jw.endObject();
        }
        try jw.endObject();

        // 4. 序列化 style
        try jw.objectField("style");
        try jw.beginObject();
        var style_iter = self.style.iterator();
        while (style_iter.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }
        try jw.endObject();

        // 5. 序列化 components (ArrayList)
        try jw.objectField("components");
        try jw.beginArray();
        for (self.components.items) |comp_map| {
            try jw.beginObject();
            var comp_iter = comp_map.iterator();
            while (comp_iter.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }
        try jw.endArray();

        // 6. 序列化 copywriting
        try jw.objectField("copywriting");
        try jw.write(self.copywriting);

        try jw.endObject();
    }
};
pub var AST: ASTStruct = undefined;
pub var BINARY: std.ArrayList([]const u8) = undefined;

fn gen_random_uuid() [36]u8 {
    var raw_uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&raw_uuid);
    raw_uuid[6] = (raw_uuid[6] & 0x0F) | 0x40;
    raw_uuid[8] = (raw_uuid[8] & 0x3F) | 0x80;
    var result: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var out: usize = 0;
    for (raw_uuid, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            result[out] = '-';
            out += 1;
        }
        result[out] = hex[byte >> 4];
        result[out + 1] = hex[byte & 0x0F];
        out += 2;
    }
    return result;
}

const ASTError = error{
    InvalidArgumentCount,
    UnsupportedTypeError,
    MixedTableKeys,
};

fn luaValueToJson(allocator: std.mem.Allocator, lua: *Lua, index: i32) ASTError!std.json.Value {
    switch (lua.typeOf(index)) {
        .boolean => {
            return .{ .bool = lua.toBoolean(index) };
        },
        .number => {
            if (lua.isInteger(index)) {
                return .{ .integer = lua.toInteger(index) catch return error.UnsupportedTypeError };
            } else {
                return .{ .float = lua.toNumber(index) catch return error.UnsupportedTypeError };
            }
        },
        .nil, .none => {
            return .null;
        },
        .string => {
            const str_ref = lua.toString(index) catch return error.UnsupportedTypeError;
            const str = allocator.dupe(u8, str_ref) catch unreachable;
            if (util.eq(str, "nil") or util.eq(str, "null")) {
                allocator.free(str);
                return .null;
            } else {
                return .{ .string = str };
            }
        },
        .table => {
            return try luaTableToJson(allocator, lua, index);
        },
        else => return error.UnsupportedTypeError,
    }
}
fn luaTableToJson(allocator: std.mem.Allocator, lua: *Lua, index: i32) ASTError!std.json.Value {
    var is_array = false;
    var is_object = false;
    var json_object = std.json.ObjectMap.init(allocator);
    errdefer json_object.deinit();
    var json_array = std.json.Array.init(allocator);
    errdefer json_array.deinit();

    lua.pushNil();
    while (lua.next(index)) {
        const key = lua.typeOf(-2);
        if (key == .number and lua.isInteger(-2)) {
            is_array = true;
            json_array.append(try luaValueToJson(allocator, lua, -1)) catch unreachable;
        } else if (key == .string) {
            is_object = true;
            const str_ref = lua.toString(-2) catch return error.UnsupportedTypeError;
            const str = allocator.dupe(u8, str_ref) catch unreachable;
            const val = try luaValueToJson(allocator, lua, -1);
            json_object.put(str, val) catch unreachable;
        } else {
            lua.pop(1);
            return error.UnsupportedTypeError;
        }
        if (is_array and is_object) {
            return error.MixedTableKeys;
        }
        lua.pop(1);
    }
    if (!is_array and !is_object) {
        is_object = true;
    }
    if (is_array) {
        json_object.deinit();
        return .{ .array = json_array };
    } else {
        json_array.deinit();
        return .{ .object = json_object };
    }
}
fn luaJsonToTable(lua: *Lua, json: std.json.Value) void {
    switch (json) {
        .null => _ = lua.pushString("null"),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(i),
        .float => |f| lua.pushNumber(f),
        .number_string => |ns| {
            if (std.fmt.parseInt(i64, ns, 10) catch null) |int_val| {
                lua.pushInteger(int_val);
            } else if (std.fmt.parseFloat(f64, ns) catch null) |float_val| {
                lua.pushNumber(float_val);
            } else {
                lua.pushNil();
            }
        },
        .string => |s| _ = lua.pushString(s),
        .array => |arr| {
            lua.createTable(0, @intCast(arr.items.len));
            const table_idx = lua.absIndex(-1);
            for (arr.items, 0..) |item, i| {
                luaJsonToTable(lua, item);
                lua.rawSetIndex(table_idx, @as(i64, @intCast(i)) + 1);
            }
        },
        .object => |obj| {
            lua.createTable(0, @intCast(obj.count()));
            const table_idx = lua.absIndex(-1);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                _ = lua.pushString(entry.key_ptr.*);
                luaJsonToTable(lua, entry.value_ptr.*);
                lua.rawSetTable(table_idx);
            }
        },
    }
}
fn luaResource(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const path_ref = lua.toString(1) catch @panic("Cannot read funcname \"Resource\" first argument to String! please try again!");
    const path = allocator.dupe(u8, path_ref) catch unreachable;
    const mime_ref = lua.toString(2) catch @panic(util.fmt(allocator, "Cannot read funcname \"Resource\" second argument to String by \"{s}\"! please try again!", .{path}));
    const mime = allocator.dupe(u8, mime_ref) catch unreachable;
    BINARY.append(allocator, path) catch unreachable;
    AST.resource.put(path, std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, path }) catch unreachable) catch unreachable;
    _ = lua.pushString(std.fmt.allocPrint(allocator, "<g-resource>{s}</g-resource>", .{path}) catch unreachable);
    return 1;
}
fn luaBase64Resource(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const uuid_ref = gen_random_uuid();
    const uuid = allocator.dupe(u8, &uuid_ref) catch unreachable;
    const base_ref = lua.toString(1) catch @panic("Cannot read funcname \"Base64Resource\" first argument to String! please try again!");
    const base = allocator.dupe(u8, base_ref) catch unreachable;
    AST.resource.put(uuid, base) catch unreachable;
    _ = lua.pushString(std.fmt.allocPrint(allocator, "<g-resource>{s}</g-resource>", .{uuid}) catch unreachable);
    return 1;
}
fn luaSetDefine(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const key_ref = lua.toString(1) catch @panic("Cannot read funcname \"SetDefine\" first argument to String! please try again!");
    const key = allocator.dupe(u8, key_ref) catch unreachable;
    const value = luaValueToJson(allocator, lua, 2) catch |err| {
        @panic(util.fmt(allocator, "Cannot read funcname \"SetDefine\" second argument to Allow Type by \"{s}\"! error message: \"{}\"", .{ key, err }));
    };
    AST.define.put(key, value) catch unreachable;
    return 0;
}
fn luaSetTranslate(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const key_ref = lua.toString(1) catch @panic("Cannot read funcname \"SetTranslate\" first argument to String! please try again!");
    const key = allocator.dupe(u8, key_ref) catch unreachable;
    var mv = std.StringHashMap([]const u8).init(allocator);
    const lv = luaValueToJson(allocator, lua, 2) catch |err| {
        @panic(util.fmt(allocator, "Cannot read funcname \"SetTranslate\" second argument to Allow Type by \"{s}\"! error message: \"{}\"", .{ key, err }));
    };
    if (lv != .object) {
        @panic(util.fmt(allocator, "Cannot read funcname \"SetTranslate\" second argument to Allow Type by \"{s}\"! error message: CannotConvertToObject", .{key}));
    }
    var it = lv.object.iterator();
    while (it.next()) |en| {
        const v = en.value_ptr.*;
        if (v != .string) {
            @panic(util.fmt(allocator, "Cannot read funcname \"SetTranslate\" second argument to Allow Type by \"{s}\" in \"{s}\"! error message: CannotConvertToString", .{ key, en.key_ptr.* }));
        }
        mv.put(en.key_ptr.*, v.string) catch unreachable;
    }
    AST.translate.put(key, mv) catch unreachable;
    return 0;
}
fn luaGetDefine(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const key_ref = lua.toString(1) catch @panic("Cannot read funcname \"SetTranslate\" first argument to String! please try again!");
    const key = allocator.dupe(u8, key_ref) catch unreachable;
    const c = AST.define.get(key);
    if (c) |v| {
        luaJsonToTable(lua, v);
        return 1;
    } else {
        @panic(util.fmt(allocator, "Cannot find any value in key: \"{s}\", please check your code and make sure the key is exists!", .{key}));
    }
}
fn luaPrint(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const value = luaValueToJson(allocator, lua, 1) catch |err| {
        @panic(util.fmt(allocator, "Cannot read funcname \"print\" first argument to Allow Type! error message: \"{}\"", .{err}));
    };
    util.printJson(value);
    return 0;
}
pub fn ast(
    allocator: std.mem.Allocator,
    lua_content: []const u8,
) !void {
    var lua = try Lua.init(allocator);
    defer lua.deinit();
    AST = ASTStruct{
        .define = std.StringHashMap(std.json.Value).init(allocator),
        .resource = std.StringHashMap([]const u8).init(allocator),
        .translate = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
        .style = std.StringHashMap([]const u8).init(allocator),
        .components = try std.ArrayList(std.StringHashMap(std.json.Value)).initCapacity(allocator, std.math.maxInt(u8)),
        .copywriting = .null,
    };
    BINARY = try std.ArrayList([]const u8).initCapacity(allocator, std.math.maxInt(u8));
    const c_lua_content = try allocator.dupeZ(u8, lua_content);
    defer allocator.free(c_lua_content);
    const cw = .{
        .{ "Resource", luaResource },
        .{ "Base64Resource", luaBase64Resource },
        .{ "SetDefine", luaSetDefine },
        .{ "SetTranslate", luaSetTranslate },
        .{ "GetDefine", luaGetDefine },
        .{ "print", luaPrint },
    };
    inline for (cw) |c| {
        lua.pushFunction(zlua.wrap(c[1]));
        lua.setGlobal(c[0]);
    }
    try lua.doString(c_lua_content);
}
