const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

// ToDo: how to remove the content of example.css from the output wasm file?

extern fn print(addr: usize, len: usize, addr2: usize, len2: usize, extra: isize) void;

fn logMessage(msg: []const u8, extraMsg: []const u8, extraInt: isize) void {
    print(@intFromPtr(msg.ptr), msg.len, @intFromPtr(extraMsg.ptr), extraMsg.len, extraInt);
}

const maxInFileSize = 1 << 20; // 1M
const bufferSize = maxInFileSize * 10;

var buffer: []u8 = "";

export fn buffer_offset() isize {
    const bufferWithHeader = init() catch |err| {
        logMessage("init error: ", @errorName(err), @intFromError(err));
        return -@as(i32, @intFromError(err));
    };
    return @intCast(@intFromPtr(bufferWithHeader.ptr));
}

export fn tmd_to_html(fullHtmlPage: bool, supportCustomBlocks: bool) isize {
    const htmlWithLengthHeader = render(fullHtmlPage, supportCustomBlocks) catch |err| {
        logMessage("render error: ", @errorName(err), @intFromError(err));
        return -@as(i32, @intFromError(err));
    };
    return @intCast(@intFromPtr(htmlWithLengthHeader.ptr));
}

fn init() ![]u8 {
    if (buffer.len == 0) {
        buffer = try std.heap.wasm_allocator.alloc(u8, bufferSize);
    }

    var fbs = std.io.fixedBufferStream(buffer);
    try fbs.writer().writeInt(u32, maxInFileSize, .little);

    return buffer;
}

fn render(fullHtmlPage: bool, supportCustomBlocks: bool) ![]u8 {
    if (buffer.len == 0) {
        return error.BufferNotCreatedYet;
    }

    var fbs = std.io.fixedBufferStream(buffer);
    const suffixForIdsAndNames: []const u8 = blk: {
        const suffixLen = try fbs.reader().readByte();
        break :blk buffer[1 .. 1 + suffixLen];
    };
    fbs = std.io.fixedBufferStream(buffer[1 + suffixForIdsAndNames.len ..]);
    const tmdDataLength = try fbs.reader().readInt(u32, .little);
    if (tmdDataLength > maxInFileSize) {
        return error.DataSizeTooLarge;
    }

    const tmdDataStart = 1 + 4 + suffixForIdsAndNames.len;
    const tmdDataEnd = tmdDataStart + tmdDataLength;

    const tmdContent = buffer[tmdDataStart..tmdDataEnd];
    const remainingBuffer = buffer[tmdDataEnd..];

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    const fbaAllocator = fba.allocator();

    // parse file

    var tmdDoc = try tmd.parser.parse_tmd_doc(tmdContent, fbaAllocator);

    // render file

    //logMessage("", "tmdDataLength: ", @intCast(tmdDataLength));
    //logMessage("", "fba.end_index: ", @intCast(fba.end_index));

    const renderBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
    fbs = std.io.fixedBufferStream(renderBuffer);
    try fbs.writer().writeInt(u32, 0, .little);
    try tmd.render.tmd_to_html(&tmdDoc, fbs.writer(), fullHtmlPage, supportCustomBlocks, suffixForIdsAndNames, std.heap.wasm_allocator);
    const htmlWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    try fbs.writer().writeInt(u32, htmlWithLengthHeader.len - 4, .little);

    //logMessage("", "htmlWithLengthHeader.len: ", @intCast(htmlWithLengthHeader.len));

    return htmlWithLengthHeader;
}
