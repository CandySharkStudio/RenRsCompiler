const std = @import("std");
const stripLuaComments = @import("parser.zig").stripLuaComments;
const print = @import("util.zig").print;
const ast = @import("ast.zig");

const Aes256 = std.crypto.core.aes.Aes256;

const CbcStreamWriter = struct {
    out_file: std.fs.File,
    aes: std.crypto.core.aes.AesEncryptCtx(Aes256),
    iv: [16]u8,
    block_buffer: [16]u8,
    block_len: usize,
    out_buffer: [256 * 1024]u8,
    out_len: usize,

    fn init(out_file: std.fs.File, key: [32]u8, iv: [16]u8) CbcStreamWriter {
        return .{
            .out_file = out_file,
            .aes = Aes256.initEnc(key),
            .iv = iv,
            .block_buffer = undefined,
            .block_len = 0,
            .out_buffer = undefined,
            .out_len = 0,
        };
    }

    fn write(self: *CbcStreamWriter, data: []const u8) !void {
        for (data) |byte| {
            self.block_buffer[self.block_len] = byte;
            self.block_len += 1;
            if (self.block_len == 16) {
                try self.encrypt_block();
            }
        }
    }

    fn encrypt_block(self: *CbcStreamWriter) !void {
        for (0..16) |j| self.block_buffer[j] ^= self.iv[j];
        self.aes.encrypt(&self.block_buffer, &self.block_buffer);
        self.iv = self.block_buffer;

        @memcpy(self.out_buffer[self.out_len .. self.out_len + 16], &self.block_buffer);
        self.out_len += 16;
        self.block_len = 0;

        if (self.out_len == self.out_buffer.len) {
            try self.flush_out();
        }
    }

    fn flush_out(self: *CbcStreamWriter) !void {
        if (self.out_len > 0) {
            try self.out_file.writeAll(self.out_buffer[0..self.out_len]);
            self.out_len = 0;
        }
    }

    fn finish(self: *CbcStreamWriter) !void {
        const pad: u8 = @intCast(16 - self.block_len);
        for (self.block_len..16) |j| self.block_buffer[j] = pad;

        for (0..16) |j| self.block_buffer[j] ^= self.iv[j];
        self.aes.encrypt(&self.block_buffer, &self.block_buffer);

        @memcpy(self.out_buffer[self.out_len .. self.out_len + 16], &self.block_buffer);
        self.out_len += 16;
        self.block_len = 0;

        try self.flush_out();
    }
};

// 修复 Base64
pub fn base64DecodeFixed(input: []const u8) ![32]u8 {
    const Decoder = std.base64.standard.Decoder;
    var result: [32]u8 = undefined;
    const size = try Decoder.calcSizeForSlice(input);
    if (size != 32) {
        return error.InvalidPadding;
    }
    try Decoder.decode(&result, input);
    if (result.len != 32) return error.InvalidPadding;
    return result;
}
// 随机生成密钥
pub fn generateKeyBase64(allocator: std.mem.Allocator) ![]const u8 {
    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);
    const Encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, Encoder.calcSize(key.len));
    return Encoder.encode(encoded, &key);
}
// 流式加密代码（流式加密采取读一点加密一点的原则，即使是面对超级大的文件也能无比从容的面对。）
// 只有二进制文件采用流式加密，文本文件的 AST 使用一次性加密。
// 完成之后将其组合成 .rrs 独特格式！随后可以给各位自由进行分发。
pub fn streamEncryptFiles(
    allocator: std.mem.Allocator,
    out_file: std.fs.File,
    key: [32]u8,
    iv1: [16]u8,
    iv2: [16]u8,
    iv3: [16]u8,
) !void {
    // 1. 将 CopywritingStruct 序列化为 JSON 字符串
    const json_buf = std.json.fmt(ast.AST, .{});
    var string_allocator: std.io.Writer.Allocating = try .initCapacity(allocator, std.math.maxInt(u8));
    defer string_allocator.deinit();
    var string_writer = string_allocator.writer;
    try json_buf.format(&string_writer);

    const text_plain = string_writer.buffered();
    const text_plain_len: u32 = @intCast(text_plain.len);

    // 2. 预先获取所有二进制文件的大小 (用于第一阶段写入长度)
    var bin_infos = try std.ArrayList(struct { name: []const u8, size: u64 }).initCapacity(allocator, std.math.maxInt(u8));
    defer bin_infos.deinit(allocator);
    for (ast.BINARY.items) |bin_path| {
        const bin_file = std.fs.cwd().openFile(bin_path, .{}) catch {
            print("无法读取文件：{s}！\n请确保你有足够的权限或者文件存在！\n", .{bin_path});
            return error.FileNotFound;
        };
        defer bin_file.close();
        const stat = try bin_file.stat();
        try bin_infos.append(allocator, .{ .name = bin_path, .size = stat.size });
    }

    // 3. 计算第一段密文长度
    const block1_plain_len: u32 = @intCast(bin_infos.items.len * 5 + 16);
    const block1_cipher_len: u32 = block1_plain_len + (16 - (block1_plain_len % 16));

    // 4. 写入明文区：[IV1][密文1长度]
    try out_file.writeAll(&iv1);
    var buf_encrypt1_len: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf_encrypt1_len, @intCast(block1_cipher_len), .little);
    try out_file.writeAll(&buf_encrypt1_len);

    // 5. 加密第一段：[名称长度(1)][数据长度(4)]...[IV2(16)]
    var stream1 = CbcStreamWriter.init(out_file, key, iv1);
    for (bin_infos.items) |info| {
        try stream1.write(&[_]u8{@intCast(info.name.len)});
        var data_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &data_len_buf, @intCast(info.size), .little);
        try stream1.write(&data_len_buf);
    }
    try stream1.write(&iv2);
    try stream1.finish();

    // 6. 加密第二段：[名称][流式读取的数据]...[IV3(16)][文本明文长度(4)]
    var stream2 = CbcStreamWriter.init(out_file, key, iv2);
    var read_buf: [256 * 1024]u8 = undefined; // 256KB 读取缓冲区，严格控制内存峰值
    for (bin_infos.items) |info| {
        try stream2.write(info.name);
        const bin_file = try std.fs.cwd().openFile(info.name, .{});
        defer bin_file.close();
        while (true) {
            const read = try bin_file.read(&read_buf);
            if (read == 0) break;
            try stream2.write(read_buf[0..read]);
        }
    }

    try stream2.write(&iv3);
    var text_plain_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &text_plain_len_buf, text_plain_len, .little);
    try stream2.write(&text_plain_len_buf);
    try stream2.finish();

    // 7. 加密第三段：[文本密文数据(JSON)]
    var stream3 = CbcStreamWriter.init(out_file, key, iv3);
    if (text_plain.len > 0) {
        try stream3.write(text_plain);
    }
    try stream3.finish();
}
