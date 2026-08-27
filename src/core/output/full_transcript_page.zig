const std = @import("std");

pub const max_source_entries: usize = 256;
pub const live_refresh_revision_stride: u64 = 8;

pub const Anchor = union(enum) {
    tail,
    entry_index: usize,
};

pub const Request = struct {
    generation: u64,
    content_revision: u64,
    cols: u16,
    anchor: Anchor,
};

pub const Key = struct {
    generation: u64,
    content_revision: u64,
    cols: u16,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: SourceRange) usize {
        return self.end - self.start;
    }
};

pub fn sourceRange(request: Request, total_entries: usize) SourceRange {
    if (total_entries <= max_source_entries) {
        return .{ .start = 0, .end = total_entries };
    }

    const latest_start = total_entries - max_source_entries;
    const start = switch (request.anchor) {
        .tail => latest_start,
        .entry_index => |requested_index| blk: {
            const anchor_index = @min(requested_index, total_entries - 1);
            break :blk @min(anchor_index -| max_source_entries / 2, latest_start);
        },
    };
    return .{ .start = start, .end = start + max_source_entries };
}

pub fn accepts(request: Request, key: Key) bool {
    return request.generation == key.generation and
        request.content_revision == key.content_revision and
        request.cols == key.cols;
}

pub fn sameSurface(lhs: Request, rhs: Request) bool {
    return lhs.cols == rhs.cols and std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn reusable(
    installed: Request,
    key: Key,
    content_revision: u64,
    cols: u16,
    anchor: Anchor,
) bool {
    return installed.content_revision == content_revision and
        installed.cols == cols and
        std.meta.eql(installed.anchor, anchor) and
        accepts(installed, key);
}

pub fn liveRefreshDue(installed_revision: u64, current_revision: u64) bool {
    return current_revision -% installed_revision >= live_refresh_revision_stride;
}

pub fn coalesce(current: ?Request, next: Request) Request {
    const existing = current orelse return next;
    return if (next.generation >= existing.generation) next else existing;
}

pub fn previousAnchor(range: SourceRange) ?Anchor {
    if (range.start == 0) return null;
    return .{ .entry_index = range.start - 1 };
}

pub fn nextAnchor(range: SourceRange, total_entries: usize) ?Anchor {
    if (range.end >= total_entries) return null;
    return .{ .entry_index = range.end };
}

test "full transcript page range stays bounded at the tail" {
    const request = Request{
        .generation = 7,
        .content_revision = 41,
        .cols = 80,
        .anchor = .tail,
    };
    const range = sourceRange(request, 10_000);

    try std.testing.expectEqual(@as(usize, 10_000), range.end);
    try std.testing.expectEqual(max_source_entries, range.len());
}

test "full transcript page range centers an entry without crossing bounds" {
    const middle = sourceRange(.{
        .generation = 8,
        .content_revision = 42,
        .cols = 120,
        .anchor = .{ .entry_index = 5_000 },
    }, 10_000);
    try std.testing.expect(middle.start <= 5_000);
    try std.testing.expect(middle.end > 5_000);
    try std.testing.expectEqual(max_source_entries, middle.len());

    const head = sourceRange(.{
        .generation = 9,
        .content_revision = 42,
        .cols = 120,
        .anchor = .{ .entry_index = 0 },
    }, 3);
    try std.testing.expectEqual(SourceRange{ .start = 0, .end = 3 }, head);
}

test "full transcript page accepts only the exact generation revision and width" {
    const request = Request{
        .generation = 11,
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    };
    try std.testing.expect(accepts(request, .{
        .generation = 11,
        .content_revision = 73,
        .cols = 96,
    }));
    try std.testing.expect(!accepts(request, .{
        .generation = 10,
        .content_revision = 73,
        .cols = 96,
    }));
    try std.testing.expect(!accepts(request, .{
        .generation = 11,
        .content_revision = 72,
        .cols = 96,
    }));
    try std.testing.expect(!accepts(request, .{
        .generation = 11,
        .content_revision = 73,
        .cols = 80,
    }));
}

test "full transcript page surface ignores revisions but not width or anchor" {
    const original = Request{
        .generation = 11,
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    };
    var changed = original;
    changed.generation = 12;
    changed.content_revision = 74;
    try std.testing.expect(sameSurface(original, changed));

    changed.cols = 80;
    try std.testing.expect(!sameSurface(original, changed));
    changed.cols = original.cols;
    changed.anchor = .{ .entry_index = 42 };
    try std.testing.expect(!sameSurface(original, changed));
}

test "full transcript page reuse requires exact installed content and surface" {
    const installed = Request{
        .generation = 11,
        .content_revision = 73,
        .cols = 96,
        .anchor = .tail,
    };
    const key = Key{ .generation = 11, .content_revision = 73, .cols = 96 };
    try std.testing.expect(reusable(installed, key, 73, 96, .tail));
    try std.testing.expect(!reusable(installed, key, 74, 96, .tail));
    try std.testing.expect(!reusable(installed, key, 73, 80, .tail));
    try std.testing.expect(!reusable(
        installed,
        key,
        73,
        96,
        .{ .entry_index = 1 },
    ));
}

test "live full transcript refresh is bounded by revision stride" {
    try std.testing.expect(!liveRefreshDue(40, 47));
    try std.testing.expect(liveRefreshDue(40, 48));
    try std.testing.expect(liveRefreshDue(std.math.maxInt(u64) - 3, 4));
}

test "full transcript page coalescing keeps the newest generation" {
    const older = Request{
        .generation = 20,
        .content_revision = 90,
        .cols = 80,
        .anchor = .tail,
    };
    const newer = Request{
        .generation = 21,
        .content_revision = 91,
        .cols = 120,
        .anchor = .{ .entry_index = 500 },
    };

    try std.testing.expectEqual(newer, coalesce(older, newer));
    try std.testing.expectEqual(newer, coalesce(newer, older));
    try std.testing.expectEqual(newer, coalesce(null, newer));
}

test "full transcript page navigation stops at document boundaries" {
    const previous = previousAnchor(.{ .start = 256, .end = 512 });
    try std.testing.expect(previous != null);
    try std.testing.expectEqual(
        Anchor{ .entry_index = 255 },
        previous.?,
    );
    try std.testing.expect(previousAnchor(.{ .start = 0, .end = 256 }) == null);

    const next = nextAnchor(.{ .start = 256, .end = 512 }, 1_000);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(
        Anchor{ .entry_index = 512 },
        next.?,
    );
    try std.testing.expect(nextAnchor(.{ .start = 744, .end = 1_000 }, 1_000) == null);
}
