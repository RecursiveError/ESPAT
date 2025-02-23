const std = @import("std");

const Types = @import("Types.zig");
const commands = @import("util/commands.zig");

const Runner = Types.Runner;
const Device = Types.Device;
const DriverError = Types.DriverError;
const TXPkg = Types.TXPkg;

const PREFIX = commands.prefix;
const POSTFIX = commands.postfix;
const get_cmd_string = commands.get_cmd_string;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    header: []const u8,
    data: []const u8,
};

const Package = union(enum) {
    URL: []const u8,
    HEADER: []const u8,
    GET: void,
};

pub const HttpDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *HttpDevice, buffer: []const u8) DriverError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "SET", HttpDevice.set_state },
    });

    runner_loop: *Runner = undefined,
    device: Device = .{
        .pool_data = pool_data,
        .check_cmd = check_cmd,
        .apply_cmd = apply_cmd,
        .ok_handler = ok_handler,
        .err_handler = err_handler,
        .send_handler = send_event,
        .deinit = deinit,
    },

    to_send: ?[]const u8 = null,
    //header set does not send "SET OK" in full like URL does, instead it sends "OK" twice
    header_count: u8 = 0,
    header_check: bool = false,

    fn pool_data(inst: *anyopaque) DriverError![]const u8 {
        const self: *HttpDevice = @alignCast(@ptrCast(inst));
        if (self.to_send) |data| {
            return data;
        }
        return DriverError.NO_POOL_DATA;
    }

    fn check_cmd(cmd: []const u8, buffer: []const u8, inst: *anyopaque) DriverError!void {
        const self: *HttpDevice = @alignCast(@ptrCast(inst));
        const response_callback = cmd_response_map.get(cmd);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, buffer });
        }
    }

    fn apply_cmd(pkg: TXPkg, out_buffer: []u8, inst: *anyopaque) DriverError![]const u8 {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;
        const data = std.mem.bytesAsValue(Package, &pkg.buffer);
        switch (data.*) {
            .URL => |url| {
                self.to_send = url;
                self.runner_loop.set_busy_flag(1, runner_inst);
                return std.fmt.bufPrint(out_buffer, "{s}{s}={d}{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPURLCFG),
                    url.len,
                    POSTFIX,
                }) catch unreachable;
            },
            .HEADER => |header| {
                self.to_send = header;
                self.runner_loop.set_busy_flag(1, runner_inst);
                self.header_check = true;
                self.header_count = 1;
                return std.fmt.bufPrint(out_buffer, "{s}{s}={d}{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCHEAD),
                    header.len,
                    POSTFIX,
                }) catch return DriverError.INVALID_ARGS;
            },
            .GET => {
                return std.fmt.bufPrint(out_buffer, "{s}{s}=\"\"{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCGET),
                    POSTFIX,
                }) catch return DriverError.INVALID_ARGS;
            },
        }
        return DriverError.INVALID_PKG;
    }

    fn ok_handler(inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;
        if (self.header_check) {
            if (self.header_count == 0) {
                self.runner_loop.set_busy_flag(0, runner_inst);
                return;
            }
            self.header_count -= 1;
        }
        return;
    }

    fn err_handler(inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;

        if (self.header_check) {
            self.runner_loop.set_busy_flag(0, runner_inst);
            self.header_count = 0;
            self.header_check = false;
        }
    }

    fn send_event(_: *anyopaque, _: bool) void {
        return;
    }

    fn deinit(_: *anyopaque) void {
        return;
    }

    fn set_state(self: *HttpDevice, _: []const u8) DriverError!void {
        const runner_inst = self.runner_loop.runner_instance;
        self.to_send = null;
        self.runner_loop.set_busy_flag(0, runner_inst);
    }

    pub fn request(self: *HttpDevice, req: Request) !void {
        const runner_inst = self.runner_loop.runner_instance;
        //TODO: add error checks

        var header_clear: commands.Package = .{};
        const clear_slice = std.fmt.bufPrint(&header_clear.str, "{s}{s}=0{s}", .{
            PREFIX,
            get_cmd_string(.HTTPCHEAD),
            POSTFIX,
        }) catch unreachable;

        header_clear.len = clear_slice.len;

        self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, header_clear), runner_inst) catch return error.TX_BUFFER_FULL;
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .URL = req.url }), runner_inst) catch return error.TX_BUFFER_FULL;
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .HEADER = req.header }), runner_inst) catch return error.TX_BUFFER_FULL;
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .GET = {} }), runner_inst) catch return error.TX_BUFFER_FULL;
    }
};
