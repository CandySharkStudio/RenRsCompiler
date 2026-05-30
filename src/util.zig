const std = @import("std");
// 判断俩字符串是否相等
pub fn eq(a: []const u8, b: []const u8) bool {
    return a.len == b.len and std.mem.eql(u8, a, b);
}

pub fn fmt(allocator: std.mem.Allocator, comptime msg: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, msg, args) catch unreachable;
}
// 写出文件
pub fn setFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}
// 打印输出
pub fn print(comptime msg: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    writer.interface.print(msg, args) catch unreachable;
    writer.interface.flush() catch unreachable;
}
// 输入
pub fn input() ![]u8 {
    var buffer: [1024]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&buffer);
    const output = try reader.interface.takeDelimiterExclusive('\n');
    return output;
}
// 读取文件
pub fn getFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

pub fn printJson(v: anytype) void {
    const json_buf = std.json.fmt(v, .{});
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer).interface;
    json_buf.format(&writer) catch unreachable;
    const text_plain = writer.buffered();

    print("{s}\n", .{text_plain});
}
