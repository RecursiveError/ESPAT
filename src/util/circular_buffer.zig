//====== Circular buffer ======
//A simple circular buffer implementation

const std = @import("std");

pub const Buffer_error = error{ BufferFull, BufferEmpty, OutOfBounds, UnknowError };

pub fn create_buffer(comptime buffer_type: type, comptime size: comptime_int) type {
    if (size <= 0) {
        @compileError("BUFFER SIZE NEED TO BE >0");
    }
    return struct {
        const Self = @This();
        const internal_size = size;
        buffer: [size]buffer_type = std.mem.zeroes([size]buffer_type),
        len: usize = size,
        begin_index: usize = 0,
        end_index: usize = 0,

        pub fn push_overwrite(self: *Self, data: buffer_type) void {
            const next_index = (self.end_index + 1) % internal_size;
            if (next_index == self.begin_index) {
                self.begin_index = (next_index + 1) % internal_size;
            }
            self.buffer[self.end_index] = data;
            self.end_index = next_index;
        }

        pub fn push(self: *Self, data: buffer_type) Buffer_error!void {
            const next_index = (self.end_index + 1) % internal_size;
            if (next_index == self.begin_index) {
                return Buffer_error.BufferFull;
            }
            self.push_overwrite(data);
        }

        pub fn push_array(self: *Self, data: []const buffer_type) Buffer_error!void {
            for (data) |value| {
                try self.push(value);
            }
        }

        pub fn rewind(self: *Self, times: usize) Buffer_error!buffer_type {
            var begin = self.begin_index;
            var to_rewind: usize = begin;
            for (0..times) |_| {
                if (begin == 0) {
                    to_rewind = internal_size;
                }
                to_rewind -= 1;
                if ((to_rewind) == self.end_index) {
                    return Buffer_error.OutOfBounds;
                }
                begin = to_rewind;
            }
            const data = self.buffer[to_rewind];
            self.begin_index = to_rewind;
            return data;
        }

        pub fn get(self: *Self) Buffer_error!buffer_type {
            const data_index = self.begin_index;
            if (data_index != self.end_index) {
                self.begin_index = (data_index + 1) % internal_size;
                return self.buffer[data_index];
            }
            return Buffer_error.BufferEmpty;
        }

        pub fn peek_at(self: *Self, index: usize) Buffer_error!buffer_type {
            if (index > internal_size) {
                return Buffer_error.OutOfBounds;
            }
            return self.buffer[index];
        }

        pub fn get_begin_index(self: *Self) usize {
            return self.begin_index;
        }

        pub fn get_end_index(self: *Self) usize {
            return self.end_index;
        }

        pub fn get_data_size(self: *Self) usize {
            const begin = self.begin_index;
            const end = self.end_index;
            if (begin > end) {
                return ((internal_size - begin) + end) - 1;
            }
            return end - begin;
        }
        pub fn isempty(self: *Self) bool {
            return self.begin_index == self.end_index;
        }

        pub fn clear(self: *Self) void {
            self.begin_index = 0;
            self.end_index = 0;
            self.buffer = std.mem.zeroes(@TypeOf(self.buffer));
        }

        pub fn raw_buffer(self: *Self) []buffer_type {
            return &self.buffer;
        }

        pub fn print(self: *Self) void {
            _ = std.debug.print("Buffer data:", .{});
            for (0..internal_size) |index| {
                var data = self.buffer[index];
                if (data == '\n' or data == '\r' or data == 0) {
                    data = '_';
                }
                if (index == self.begin_index) {
                    _ = std.debug.print("\x1b[32m", .{});
                }
                if (index == self.end_index) {
                    _ = std.debug.print("\x1b[31m", .{});
                }
                _ = std.debug.print("{c}", .{data});
                _ = std.debug.print("\x1b[0m", .{});
            }
            _ = std.debug.print("\n", .{});
        }
    };
}
