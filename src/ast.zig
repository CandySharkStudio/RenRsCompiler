const std = @import("std");
const zlua = @import("zlua");
const print = @import("util.zig").print;
const Lua = zlua.Lua;
pub const CopywritingStruct = struct {
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
pub var AST: CopywritingStruct = undefined;
pub var BINARY: std.ArrayList([]const u8) = undefined;
fn lua_resource(lua: *Lua) i32 {
    const allocator = lua.allocator();
    const path_ref = lua.toString(1) catch @panic("Cannot read funcname Resource first argument! please try again!");
    const mime_ref = lua.toString(2) catch @panic("Cannot read funcname Resource second argument! please try again!");
    const path = allocator.dupe(u8, path_ref) catch unreachable;
    const mime = allocator.dupe(u8, mime_ref) catch unreachable;
    // std.debug.print("{s}", .{path});
    BINARY.append(allocator, path) catch unreachable;
    AST.resource.put(path, std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, path }) catch unreachable) catch unreachable;
    _ = lua.pushString(std.fmt.allocPrint(allocator, "<g-resource>{s}</g-resource>", .{path}) catch unreachable);
    return 1;
}
pub fn ast(
    allocator: std.mem.Allocator,
    lua_content: []const u8,
) !void {
    var lua = try Lua.init(allocator);
    defer lua.deinit();
    AST = CopywritingStruct{
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
        .{ "Resource", lua_resource },
    };
    inline for (cw) |c| {
        lua.pushFunction(zlua.wrap(c[1]));
        lua.setGlobal(c[0]);
    }
    try lua.doString(c_lua_content);
}
