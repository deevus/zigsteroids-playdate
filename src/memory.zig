const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");

const Allocator = std.mem.Allocator;

pub const PlaydateAllocator = struct {
    api: *pdapi.PlaydateAPI,

    pub fn init(api: *pdapi.PlaydateAPI) PlaydateAllocator {
        return .{
            .api = api,
        };
    }

    pub fn allocator(self: *PlaydateAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = Allocator.noResize,
                .free = free,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        n: usize,
        log2_ptr_align: u8,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address; // Typically ignored in custom implementations
        _ = log2_ptr_align; // Typically ignored in custom implementations

        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        // No need for manual alignment calculation as playdate.system.realloc handles it.
        const ptr = self.api.system.realloc(null, n); // Allocating new memory
        return @as([*]u8, @ptrCast(ptr));
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        new_size: usize,
        return_address: usize,
    ) bool {
        _ = log2_buf_align;
        _ = return_address; // These are typically ignored in custom implementations.

        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        _ = self.api.system.realloc(buf.ptr, new_size);
        // It's assumed that the consumer of this API will handle the returned pointer correctly.
        return true; // Return true on successful resize.
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        return_address: usize,
    ) void {
        _ = log2_buf_align;
        _ = return_address; // `buf` is used, others are typically ignored.
        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        _ = self.api.system.realloc(buf.ptr, 0); // Intentionally ignore the return value as we're freeing memory.
    }
};
