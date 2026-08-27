const std = @import("std");
const builtin = @import("builtin");
const full_transcript_page = @import("../../core/output/full_transcript_page.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const types = @import("../../core/shared/types.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const command_output_runtime = @import("command_output_runtime.zig");

const Allocator = std.mem.Allocator;

pub const Source = struct {
    request: full_transcript_page.Request,
    range: full_transcript_page.SourceRange,
    entries: std.ArrayList(transcript_blocks.TranscriptEntry) = .empty,
    details: std.ArrayList(transcript_blocks.ToolDetailRecord) = .empty,
    command_blocks: std.ArrayList(command_output_runtime.CommandOutputBlock) = .empty,
    styles: transcript_blocks.Styles,
    capability: ?session_child_store.SessionChildCapability = null,

    pub fn deinit(self: *Source, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        for (self.details.items) |*detail| detail.deinit(alloc);
        self.details.deinit(alloc);
        for (self.command_blocks.items) |*block| block.deinit(alloc);
        self.command_blocks.deinit(alloc);
        if (self.capability) |*capability| capability.deinit();
        self.* = undefined;
    }
};

pub const Task = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    source: Source,
    source_owned: bool = true,
    projection: ?full_transcript_screen.Projection = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Task) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.projection) |*projection| {
            projection.deinit(std.heap.c_allocator);
        }
        if (self.source_owned) self.source.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(self);
    }

    pub fn takeProjection(self: *Task) ?full_transcript_screen.Projection {
        const projection = self.projection orelse return null;
        self.projection = null;
        return projection;
    }

    pub fn takeSource(self: *Task) Source {
        std.debug.assert(self.source_owned);
        self.source_owned = false;
        return self.source;
    }

    fn cancelled(context: *anyopaque) bool {
        const self: *Task = @ptrCast(@alignCast(context));
        return self.cancel_requested.load(.acquire);
    }

    fn run(self: *Task) void {
        const alloc = std.heap.c_allocator;
        var projection = full_transcript_screen.buildProjection(
            alloc,
            self.source.entries.items,
            self.source.details.items,
            self.source.command_blocks.items,
            self.source.styles,
            self.source.request.cols,
            null,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        var projection_owned = true;
        defer if (projection_owned) projection.deinit(alloc);

        var checkpoint = build_checkpoint.BuildCheckpoint.init(
            self,
            Task.cancelled,
        );
        const measurement = full_transcript_screen.measureProjectionInterruptible(
            alloc,
            &projection,
            if (self.source.capability) |*capability| capability else null,
            self.source.request.cols,
            &checkpoint,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        debug_trace.logf(
            "full_transcript_cache",
            "page_built generation={d} entries={d} details={d} blocks={d} segments={d} rows={d}",
            .{
                self.source.request.generation,
                self.source.entries.items.len,
                self.source.details.items.len,
                self.source.command_blocks.items.len,
                projection.segments.items.len,
                measurement.total_rows,
            },
        );
        self.projection = projection;
        projection_owned = false;
        self.done.store(true, .release);
    }
};

pub fn cloneCommandBlockMetadata(
    alloc: Allocator,
    source: command_output_runtime.CommandOutputBlock,
) !command_output_runtime.CommandOutputBlock {
    const lifecycle_id: ?types.ToolLifecycleId = if (source.lifecycle_id) |id|
        .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        }
    else
        null;
    return .{
        .entry_id = source.entry_id,
        .lifecycle_id = lifecycle_id,
        .total_lines = source.total_lines,
        .retained_text_bytes = source.retained_text_bytes,
        .retention_overflow = source.retention_overflow,
        .overflow_line_index = source.overflow_line_index,
    };
}

pub const Load = struct {
    task: ?*Task = null,
    next_generation: u64 = 1,

    pub fn deinit(self: *Load) void {
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    pub fn allocateGeneration(self: *Load) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    pub fn schedule(self: *Load, source: Source) !void {
        if (self.task != null) return error.FullTranscriptPageWorkerBusy;
        try self.start(source);
    }

    pub fn busy(self: *const Load) bool {
        return self.task != null;
    }

    pub fn cancelActive(self: *Load) void {
        const task = self.task orelse return;
        task.cancel_requested.store(true, .release);
    }

    pub fn takeCompleted(self: *Load) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task;
    }

    pub fn hasRequest(self: *const Load, request: full_transcript_page.Request) bool {
        if (self.task) |task| {
            if (sameRequest(task.source.request, request) and
                !task.cancel_requested.load(.acquire)) return true;
        }
        return false;
    }

    pub fn hasCompatibleRequest(
        self: *const Load,
        request: full_transcript_page.Request,
    ) bool {
        const task = self.task orelse return false;
        return !task.cancel_requested.load(.acquire) and
            full_transcript_page.sameSurface(task.source.request, request);
    }

    fn start(self: *Load, source: Source) !void {
        const task = try std.heap.c_allocator.create(Task);
        task.* = .{ .source = source };
        if (comptime builtin.single_threaded) {
            task.run();
            self.task = task;
            return;
        }
        task.thread = std.Thread.spawn(.{}, Task.run, .{task}) catch |err| {
            task.source.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(task);
            return err;
        };
        self.task = task;
    }
};

fn sameRequest(
    lhs: full_transcript_page.Request,
    rhs: full_transcript_page.Request,
) bool {
    return lhs.generation == rhs.generation and
        lhs.content_revision == rhs.content_revision and
        lhs.cols == rhs.cols and
        std.meta.eql(lhs.anchor, rhs.anchor);
}
