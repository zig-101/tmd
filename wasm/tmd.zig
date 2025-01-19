const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

extern fn print(addr: usize, len: usize, addr2: usize, len2: usize, extra: isize) void;

fn logMessage(msg: []const u8, extraMsg: []const u8, extraInt: isize) void {
    print(@intFromPtr(msg.ptr), msg.len, @intFromPtr(extraMsg.ptr), extraMsg.len, extraInt);
}

const maxInFileSize = 2 << 20; // 2M
const bufferSize = maxInFileSize * 7;

var buffer: []u8 = "";

export fn buffer_offset() isize {
    const bufferWithHeader = init() catch |err| {
        logMessage("init error: ", @errorName(err), @intFromError(err));
        return -@as(i32, @intFromError(err));
    };
    return @intCast(@intFromPtr(bufferWithHeader.ptr));
}

export fn get_version() isize {
    const versionWithLengthHeader = writeWersion() catch |err| {
        logMessage("write version error: ", @errorName(err), @intFromError(err));
        return -@as(i32, @intFromError(err));
    };
    return @intCast(@intFromPtr(versionWithLengthHeader.ptr));
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

fn writeWersion() ![]u8 {
    if (buffer.len == 0) {
        return error.BufferNotCreatedYet;
    }

    var fbs = std.io.fixedBufferStream(buffer);
    try fbs.writer().writeInt(u32, tmd.version.len, .little);
    const n = try fbs.writer().write(tmd.version);
    std.debug.assert(n == tmd.version.len);
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

    //logMessage(@typeName(tmd.Token), " size: ", @sizeOf(tmd.Token));
    //logMessage(@typeName(tmd.Token.PlainText), " size: ", @sizeOf(tmd.Token.PlainText));
    //logMessage(@typeName(tmd.Token.CommentText), " size: ", @sizeOf(tmd.Token.CommentText));
    //logMessage(@typeName(tmd.Token.EvenBackticks), " size: ", @sizeOf(tmd.Token.EvenBackticks));
    //logMessage(@typeName(tmd.Token.SpanMark), " size: ", @sizeOf(tmd.Token.SpanMark));
    //logMessage(@typeName(tmd.Token.LinkInfo), " size: ", @sizeOf(tmd.Token.LinkInfo));
    //logMessage(@typeName(tmd.Token.LeadingSpanMark), " size: ", @sizeOf(tmd.Token.LeadingSpanMark));
    //logMessage(@typeName(tmd.Token.ContainerMark), " size: ", @sizeOf(tmd.Token.ContainerMark));
    //logMessage(@typeName(tmd.Token.LineTypeMark), " size: ", @sizeOf(tmd.Token.LineTypeMark));
    //logMessage(@typeName(tmd.Token.Extra), " size: ", @sizeOf(tmd.Token.Extra));

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
