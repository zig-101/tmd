const std = @import("std");
const unicode = std.unicode;

pub fn begins_with_CJK_rune(utf8: []const u8) bool {
    return is_CJK_rune(read_rune(utf8));
}

pub fn ends_with_CJK_rune(utf8: []const u8) bool {
    return is_CJK_rune(read_last_rune(utf8));
}

test "begins/ends with CJK runes" {
    try std.testing.expect(!begins_with_CJK_rune(""));
    try std.testing.expect(!ends_with_CJK_rune(""));

    try std.testing.expect(!begins_with_CJK_rune("αé"));
    try std.testing.expect(!ends_with_CJK_rune("αé"));

    try std.testing.expect(!begins_with_CJK_rune("a森"));
    try std.testing.expect(begins_with_CJK_rune("森a"));
    try std.testing.expect(!ends_with_CJK_rune("森a"));
    try std.testing.expect(ends_with_CJK_rune("a森"));
}

pub const BadRune: u21 = 0xFFFD;

pub fn is_rune_start(b: u8) bool {
    return b & 0xC0 != 0x80;
}

pub fn read_last_rune(p: []const u8) u21 {
    if (p.len == 0) return BadRune;

    var start = p.len - 1;
    const r: u21 = @intCast(p[start]);
    if (r < 0x80) return r;
    if (start == 0) return BadRune;

    start -= 1;
    std.debug.assert(start + 2 == p.len);
    if (is_rune_start(p[start])) {
        const len = unicode.utf8ByteSequenceLength(p[start]) catch return BadRune;
        if (len != 2) return BadRune;
        return unicode.utf8Decode2(p[start..][0..2].*) catch BadRune;
    }
    if (start == 0) return BadRune;

    start -= 1;
    std.debug.assert(start + 3 == p.len);
    if (is_rune_start(p[start])) {
        const len = unicode.utf8ByteSequenceLength(p[start]) catch return BadRune;
        if (len != 3) return BadRune;
        return unicode.utf8Decode3(p[start..][0..3].*) catch BadRune;
    }
    if (start == 0) return BadRune;

    start -= 1;
    std.debug.assert(start + 4 == p.len);
    if (is_rune_start(p[start])) {
        const len = unicode.utf8ByteSequenceLength(p[start]) catch return BadRune;
        if (len != 4) return BadRune;
        return unicode.utf8Decode4(p[start..][0..4].*) catch BadRune;
    }
    return BadRune;
}

pub fn read_rune(p: []const u8) u21 {
    if (p.len == 0) return BadRune;

    const len = unicode.utf8ByteSequenceLength(p[0]) catch return BadRune;
    if (len == 1) return @intCast(p[0]);
    if (p.len < len) return BadRune;

    const data = p[0..len];
    return switch (len) {
        2 => unicode.utf8Decode2(data[0..2].*) catch BadRune,
        3 => unicode.utf8Decode3(data[0..3].*) catch BadRune,
        4 => unicode.utf8Decode4(data[0..4].*) catch BadRune,
        else => unreachable,
    };
}

test "read runes" {
    try std.testing.expect(read_rune("") == BadRune);
    try std.testing.expect(read_last_rune("") == BadRune);

    try std.testing.expect(read_rune("abc") == 'a');
    try std.testing.expect(read_last_rune("abc") == 'c');

    try std.testing.expect(read_rune("αé") == 0x03B1);
    try std.testing.expect(read_last_rune("αé") == 0x00E9);

    try std.testing.expect(read_rune("木林森") == 0x6728);
    try std.testing.expect(read_last_rune("木林森") == 0x68EE);

    try std.testing.expect(read_rune("\xE6\x9C\xE6\x9E\xE6\xA3") == BadRune);
    try std.testing.expect(read_last_rune("\xE6\x9C\xE6\x9E\xE6\xA3") == BadRune);

    try std.testing.expect(read_rune("\xE6\x9C") == BadRune);
    try std.testing.expect(read_last_rune("\xE6\xA3") == BadRune);
}

const rrange = struct {
    start: u21,
    end: u21,
};

const CJK_rune_ranges = [_]rrange{
    // Ref and tools:
    //   http://www.unicode.org/charts/
    //   https://en.wikipedia.org/wiki/CJK_Unified_Ideographs
    //   https://unicodeplus.com/
    //   https://www.unicode.org/charts/unihan.html

    .{ .start = 0x2000, .end = 0x206F }, // 2000–206F   General Punctuation
    .{ .start = 0x2E80, .end = 0x303F }, // 2E80–2EFF CJK Radicals Supplement
    // 2F00–2FDF CJK Radicals / Kangxi Radicals
    // 2FF0–2FFF Ideographic Description Characters
    // 3000–303F CJK Symbols and Punctuation
    .{ .start = 0x31C0, .end = 0x31EF }, // 31C0–31EF CJK Strokes
    .{ .start = 0x3400, .end = 0x4DBF }, // 3400–4DBF CJK Unified Ideographs Extension A
    .{ .start = 0x4E00, .end = 0x9FFF }, // 4E00–9FFF CJK Unified Ideographs
    .{ .start = 0xF900, .end = 0xFAFF }, // F900–FAFF CJK Compatibility Ideographs
    .{ .start = 0xFE50, .end = 0xFE6F }, // FE50–FE6F CJK Compatibility Forms - Small Form Variants
    .{ .start = 0xFF00, .end = 0xFFEF }, // FF00–FFEF CJK Compatibility Forms - Halfwidth and Fullwidth Forms
    .{ .start = 0x20000, .end = 0x2EE5F }, // 20000–2A6DF CJK Unified Ideographs Extension B
    // ... here is a reserved gap: 2A6E0-2A6FF
    // 2A700–2B73F CJK Unified Ideographs Extension C
    // 2B740–2B81F CJK Unified Ideographs Extension D
    // 2B820–2CEAF CJK Unified Ideographs Extension E
    // 2CEB0–2EBEF CJK Unified Ideographs Extension F
    // 2EBF0–2EE5F CJK Unified Ideographs Extension I
    .{ .start = 0x2F800, .end = 0x2FA1F }, // 2F800–2FA1F CJK Compatibility Ideographs Supplement
    .{ .start = 0x30000, .end = 0x323AF }, // 30000–3134F CJK Unified Ideographs Extension G
    // 31350–323AF CJK Unified Ideographs Extension H
};

pub fn is_CJK_rune(r: u21) bool {
    var x: usize = 0;
    var y: usize = CJK_rune_ranges.len;
    while (x < y) {
        const z = x + (y - x) / 2;
        const rr = CJK_rune_ranges[z];
        if (r < rr.start) {
            y = z;
        } else if (r > rr.end) {
            x = z + 1;
        } else {
            return true;
        }
    }
    return false;
}

test "is_CJK_rune" {
    for (&CJK_rune_ranges) |rr| {
        for (rr.start..rr.end + 1) |r| {
            try std.testing.expect(is_CJK_rune(@intCast(r)));
        }
    }
    const N: u21 = 100;
    {
        const rune = CJK_rune_ranges[0].start - N;
        for (rune..rune + N) |r| {
            try std.testing.expect(!is_CJK_rune(@intCast(r)));
        }
    }
    {
        const rune = CJK_rune_ranges[CJK_rune_ranges.len - 1].end + 1;
        for (rune..rune + N) |r| {
            try std.testing.expect(!is_CJK_rune(@intCast(r)));
        }
    }
    {
        for (0..256) |r| {
            try std.testing.expect(!is_CJK_rune(@intCast(r)));
        }
    }
}
