const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const encrypt = @import("encrypt.zig");
const eq = util.eq;
const setFile = util.setFile;
const getFile = util.getFile;
const print = util.print;
const luaParser = @import("parser.zig").parseLuaFile;
const ast = @import("ast.zig");
fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    print("Error: {s}\n", .{msg});
    std.debug.defaultPanic(msg, ret_addr);
}
pub const panic = std.debug.FullPanic(panicHandler);
const default_aes_key: []const u8 = "Nim3VGmCjDBKMnaDqOX7RrsbP7/bz3zochCDuMuWMNI=";
fn showHelp() void {
    const help_msg =
        \\Ren'Rs Compiler
        \\
        \\Usage: rrc [commands]
        \\       rrc <source>.lua [options]
        \\       rrc [help option]
        \\Commands:
        \\    init    在当前目录下初始化一个 main.lua 文件！
        \\
        \\Options:
        \\    -o, --output <NAME>.<.rrs>    输出最终编译产物
        \\    -k, --key <AES_KEY>           手动指定 AES Key（手动指定后将不输出密钥！）
        \\    -q, --quiet                   静默输出（不输出命令行日志）
        \\
        \\Help Option:
        \\    -v, --version   输出当前版本
        \\    -h, --help      输出帮助
    ;
    print("{s}\n", .{help_msg});
}
pub fn main() !void {
    var original_cp: u32 = 0;
    if (builtin.os.tag == .windows) {
        original_cp = std.os.windows.kernel32.GetConsoleOutputCP();
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }
    defer if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(original_cp);
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len <= 1) {
        showHelp();
        _ = try util.input();
    } else {
        if (std.mem.eql(u8, args[1], "init")) {
            if (args.len > 2) {
                @panic("init has more than 2 parameter!");
            } else {
                try setFile("main.txt",
                    \\wait example...
                );
            }
        } else if (eq(args[1], "-h") or eq(args[1], "--help")) {
            showHelp();
        } else if (eq(args[1], "-v") or eq(args[1], "--version")) {
            print("version: \n", .{});
        } else {
            const lua_path = args[1];
            const lua_ext = std.fs.path.extension(lua_path);
            if (!eq(lua_ext, ".lua")) {
                @panic("first parameter extension must be .lua file!");
            }
            var i: usize = 2;
            var noquiet: bool = true;
            var manual_key: bool = false;
            var output: []const u8 = "main.rrs";
            var aes_key = try encrypt.generateKeyBase64(allocator);
            while (i < args.len) : (i += 1) {
                if (eq(args[i], "-q") or eq(args[i], "--quiet")) {
                    noquiet = false;
                } else if (eq(args[i], "-o") or eq(args[i], "--output")) {
                    if (i + 1 >= args.len) @panic("The -o parameter must be follow by another arguments!");
                    const op_ext = std.fs.path.extension(args[i + 1]);
                    if (eq(op_ext, ".rrs")) {
                        output = args[i + 1];
                    } else {
                        output = try std.fmt.allocPrint(allocator, "{s}.rrs", .{args[i + 1]});
                    }
                    i += 1;
                } else if (eq(args[i], "-k") or eq(args[i], "--key")) {
                    if (i + 1 >= args.len) @panic("The -k parameter must be follow by another arguments!");
                    aes_key = args[i + 1];
                    manual_key = true;
                    i += 1;
                }
            }
            if (noquiet) print("正在分析密钥......\n", .{});
            const real_key = encrypt.base64DecodeFixed(aes_key) catch {
                @panic("AES_KEY 解析失败！请检查你输入的 AES_KEY 是否正确。");
            };
            if (noquiet) print("密钥分析完毕！正在随机生成偏移...\n", .{});
            var iv1: [16]u8 = undefined;
            std.crypto.random.bytes(&iv1);
            var iv2: [16]u8 = undefined;
            std.crypto.random.bytes(&iv2);
            var iv3: [16]u8 = undefined;
            std.crypto.random.bytes(&iv3);
            if (noquiet) print("偏移生成完毕，正在提取 main.lua 文件...\n", .{});
            const lua_file = try getFile(allocator, lua_path);
            if (noquiet) print("已读取到 main.lua 文件，正在合并 Lua 文件...\n", .{});
            const lua_par: []const u8 = try luaParser(allocator, lua_file);
            if (noquiet) print("Lua 文件已合并，正在生成 AST...\n", .{});
            try ast.ast(allocator, lua_par);
            if (noquiet) print("AST 生成完毕！已找到 {} 个 Resource 资源，正在流式加密并写出文件中...\n", .{ast.BINARY.items.len});
            const out_file = try std.fs.cwd().createFile(output, .{});
            defer out_file.close();
            try encrypt.streamEncryptFiles(allocator, out_file, real_key, iv1, iv2, iv3);
            print("写出文件完成！\n", .{});
            if (!manual_key) print("你的 AES 密钥是：{s}\n请妥善保管好你的密钥。不要随意上传或者忘记了！！建议保存到本地！\n", .{aes_key});
        }
    }
}
