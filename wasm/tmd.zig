const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

// ToDo: how to remove the content of example.css from the output wasm file?

extern fn print(addr: usize, len: usize, addr2: usize, len2: usize, extra: isize) void;

fn logMessage(msg: []const u8, extraMsg: []const u8, extraInt: isize) void {
    print(@intFromPtr(msg.ptr), msg.len, @intFromPtr(extraMsg.ptr), extraMsg.len, extraInt);
}

const maxInFileSize = 1 << 20;
const maxDocDataSize = 1 << 20;
const maxOutFileSize = (1 << 23); // + (1 << 22); // it looks it is okay with 4M more.

const bufferSize = maxInFileSize + maxDocDataSize + maxOutFileSize;

var buffer: []u8 = "";

export fn buffer_offset() isize {
    const bufferWithHeader = init() catch |err| {
        logMessage("init error: ", @errorName(err), @intFromError(err));
        return -@as(i32, @intFromError(err));
    };
    return @intCast(@intFromPtr(bufferWithHeader.ptr));
}

export fn tmd_to_html() isize {
    const htmlWithLengthHeader = render() catch |err| {
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

fn render() ![]u8 {
    var fbs = std.io.fixedBufferStream(buffer);
    const tmdDataLength = try fbs.reader().readInt(u32, .little);
    if (tmdDataLength > maxInFileSize)
        return error.DataSizeTooLarge;

    const tmdDataEnd = 4 + tmdDataLength;

    const tmdContent = buffer[4..tmdDataEnd];
    const fixedBuffer = buffer[tmdDataEnd..];

    // ToDo: it is best to use a top-to-down allocator to parse tmd doc, so that
    //       the input tmd data and output html data can start at the same memory address.
    //       Two benefits:
    //       1. more memory space for output html.
    //       2. the tmd_to_html function doesn't need to return an address.

    var fba = std.heap.FixedBufferAllocator.init(fixedBuffer);
    const fbaAllocator = fba.allocator();

    // parse file

    var tmdDoc = try tmd.parser.parse_tmd_doc(tmdContent, fbaAllocator);

    // render file

    const renderBuffer = try fbaAllocator.alloc(u8, maxOutFileSize);
    fbs = std.io.fixedBufferStream(renderBuffer);
    try fbs.writer().writeInt(u32, 0, .little);
    try tmd.render.tmd_to_html(&tmdDoc, fbs.writer(), false, std.heap.wasm_allocator);
    const htmlWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    try fbs.writer().writeInt(u32, htmlWithLengthHeader.len - 4, .little);

    return htmlWithLengthHeader;
}
