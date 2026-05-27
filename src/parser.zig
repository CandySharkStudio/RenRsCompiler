const std = @import("std");
const util = @import("util.zig");

const EMBED_FUNCTION: []const u8 = "embedLuaFile";
// 查找该字符是否为字母或下划线
fn isIdentChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

// 查找一个完整的单词
fn findWord(s: []const u8, word: []const u8) anyerror!usize {
    var i: usize = 0;
    while (i + word.len <= s.len) {
        if (std.mem.eql(u8, s[i .. i + word.len], word)) {
            const prev_ok = i == 0 or !isIdentChar(s[i - 1]);
            const next_ok = i + word.len >= s.len or !isIdentChar(s[i + word.len]);
            if (prev_ok and next_ok) {
                return i;
            }
        }
        i += 1;
    }
    return error.CannotFindAnyWord;
}

// 跳过空白字符 2
fn skipWs2(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) {
        i += 1;
    }
    return i;
}

// 简单字符串解析
fn readStringLiteral(chars: []const u8, idx: *usize) anyerror![]const u8 {
    var c = chars;
    const bracketType = c[0];
    c = c[1..];
    idx.* += 1;
    if (bracketType != '"' and bracketType != '\'') {
        return error.MyError;
    }
    var idx2: u8 = 0;
    while (true) {
        if (idx2 < c.len) {
            if (c[idx2] == bracketType) {
                break;
            }
            idx2 += 1;
        } else {
            return error.CannotReadStringLiteral;
        }
    }
    idx.* += idx2 + 1;
    return c[0..idx2];
}
// 获取 embedLuaFile 的参数
fn getEmbedArg(line: []const u8) anyerror![]const u8 {
    const pos = try findWord(line, EMBED_FUNCTION);
    var chars = line[pos + EMBED_FUNCTION.len ..];
    const idx1 = skipWs2(chars, 0);
    chars = chars[idx1..];
    if (chars[0] != '(') {
        return error.CannotParseEmbedArgs;
    }
    chars = chars[1..];
    const idx2 = skipWs2(chars, 0);
    chars = chars[idx2..];
    var idx: usize = 0;
    const filename = try readStringLiteral(chars, &idx);
    chars = chars[idx..];
    const idx3 = skipWs2(chars, 0);
    chars = chars[idx3..];
    if (chars[0] != ')') {
        return error.CannotParseEmbedArgs;
    }
    return filename;
}

// 将 main.lua 里面的所有 embedLuaFile 全部转换成原本的代码，最终返回字符串！
pub fn parseLuaFile(
    allocator: std.mem.Allocator,
    lua_content: []const u8,
) ![]const u8 {
    var lua_array = try std.ArrayList([]const u8).initCapacity(allocator, std.math.maxInt(u8));
    var line_iter = std.mem.splitScalar(u8, lua_content, '\n');
    while (line_iter.next()) |line| {
        const rerr = getEmbedArg(line);
        if (rerr) |res| {
            const g = try util.getFile(allocator, res);
            try lua_array.append(allocator, g);
        } else |_| {
            try lua_array.append(allocator, line);
        }
    }
    const lua_file = try std.mem.join(allocator, "\n", lua_array.items);
    return lua_file;
}
