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

pub const HTTPError = error{
    MethodUnsupported,
    URLTooShort,
    URLTooLong,
    DataTooLong,
};

pub const FinishStatus = enum {
    Ok,
    Error,
    Fail,
    Cancel,
};

pub const ReqStatus = union(enum) {
    Data: []const u8,
    Finish: FinishStatus,
};

pub const HTTPHandler = *const fn (status: ReqStatus, user_data: ?*anyopaque) void;

pub const Method = enum {
    HEADER,
    GET,
    POST,
    PUT,
    DELETE,
};

pub const ContentType = enum {
    @"application/x-www-form-urlencoded",
    @"application/json",
    @"multipart/form-data",
    @"text/xml",
};

pub const TransportType = enum {
    TCP,
    SSL,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    header: []const u8,
    data: []const u8,
    handler: HTTPHandler,
    user_data: ?*anyopaque = null,
};

pub const SimpleRequest = struct {
    method: Method,
    url: []const u8,
    header: []const u8,
    content: ContentType,
    data: ?[]const u8 = null,
    transport: TransportType = .TCP,
    handler: HTTPHandler,
    user_data: ?*anyopaque = null,
};

const MethodType = union(enum) {
    GET: void,
    POST: []const u8,
    PUT: []const u8,
};

const RequestType = struct {
    handler: HTTPHandler,
    user_data: ?*anyopaque,
    method: MethodType,
};

const Package = union(enum) {
    SMALL: SimpleRequest,
    REQUEST: RequestType,
    URL: []const u8,
    HEADER: []const u8,
};

const State = enum {
    None,
    Header,
    URL,
    Data,
};

pub const HttpDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *HttpDevice, buffer: []const u8) DriverError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "SET", HttpDevice.set_state },
        .{ "+HTTPCGET", HttpDevice.get_response },
        .{ "+HTTPCPOST", HttpDevice.get_response },
        .{ "+HTTPCPUT", HttpDevice.get_response },
        .{ "+HTTPCLIENT", HttpDevice.get_response },
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
    corrent_state: State = .None,
    //header set does not send "SET OK" like URL does, instead it sends "OK" twice
    header_check: bool = false,
    recv_check: bool = false,
    corrent_handler: ?HTTPHandler = null,
    corrent_user_data: ?*anyopaque = null,

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
        const data: *align(1) const Package = std.mem.bytesAsValue(Package, &pkg.buffer);
        switch (data.*) {
            .URL => |url| {
                self.corrent_state = .URL;
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
                self.corrent_state = .Header;
                self.to_send = header;
                self.runner_loop.set_busy_flag(1, runner_inst);
                self.header_check = true;
                return std.fmt.bufPrint(out_buffer, "{s}{s}={d}{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCHEAD),
                    header.len,
                    POSTFIX,
                }) catch return DriverError.INVALID_ARGS;
            },
            .REQUEST => |req| {
                self.corrent_state = .Data;
                self.corrent_handler = req.handler;
                self.corrent_user_data = req.user_data;
                switch (req.method) {
                    .GET => {
                        return std.fmt.bufPrint(out_buffer, "{s}{s}=\"\"{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCGET),
                            POSTFIX,
                        }) catch return DriverError.INVALID_ARGS;
                    },
                    .POST => |post| {
                        self.to_send = post;
                        self.runner_loop.set_busy_flag(1, runner_inst);
                        return std.fmt.bufPrint(out_buffer, "{s}{s}=\"\",{d}{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCPOST),
                            post.len,
                            POSTFIX,
                        }) catch return DriverError.INVALID_ARGS;
                    },
                    .PUT => |put| {
                        self.to_send = put;
                        self.runner_loop.set_busy_flag(1, runner_inst);
                        return std.fmt.bufPrint(out_buffer, "{s}{s}=\"\",{d}{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCPUT),
                            put.len,
                            POSTFIX,
                        }) catch return DriverError.INVALID_ARGS;
                    },
                }
            },
            .SMALL => |req| {
                const method: usize = @intFromEnum(req.method) + 1;
                const content: usize = @intFromEnum(req.content);
                const transport: usize = @as(usize, @intFromEnum(req.transport)) + 1;
                var end: usize = 0;

                self.corrent_state = .Data;
                self.corrent_handler = req.handler;
                self.corrent_user_data = req.user_data;

                var pre = std.fmt.bufPrint(out_buffer, "{s}{s}={d},{d},\"\",,,{d}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCLIENT),
                    method,
                    content,
                    transport,
                }) catch return DriverError.INVALID_ARGS;

                end += pre.len;

                if (req.method == .POST) {
                    if (req.data) |to_send| {
                        pre = std.fmt.bufPrint(out_buffer[end..], ",{s}", .{to_send}) catch return DriverError.INVALID_ARGS;
                        end += pre.len;
                    }
                }
                pre = std.fmt.bufPrint(out_buffer[end..], "{s}", .{POSTFIX}) catch unreachable;
                end += pre.len;
                return out_buffer[0..end];
            },
        }
        return DriverError.INVALID_PKG;
    }

    fn ok_handler(inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;
        switch (self.corrent_state) {
            .Header => {
                if (self.header_check) {
                    self.header_check = false;
                    return;
                }
                self.runner_loop.set_busy_flag(0, runner_inst);
            },
            .Data => {
                if (self.corrent_handler) |callback| {
                    callback(.{ .Finish = .Ok }, self.corrent_user_data);
                }
            },
            else => {},
        }
        return;
    }

    fn err_handler(inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;

        switch (self.corrent_state) {
            .Header => {
                self.runner_loop.set_busy_flag(0, runner_inst);
                self.header_check = false;
                self.clear_request();
            },
            .URL => {
                self.clear_request();
            },
            .Data => {
                if (self.corrent_handler) |callback| {
                    const failevent = if (self.recv_check) ReqStatus{ .Finish = .Error } else ReqStatus{ .Finish = .Fail };
                    self.recv_check = false;
                    callback(failevent, self.corrent_user_data);
                }
            },
            else => {},
        }
    }

    fn send_event(inst: *anyopaque, _: bool) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        const runner_inst = self.runner_loop.runner_instance;
        self.to_send = null;
        self.runner_loop.set_busy_flag(0, runner_inst);
        return;
    }

    fn deinit(inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));

        const runner_inst = self.runner_loop.runner_instance;
        const TX_size = self.runner_loop.get_tx_len(runner_inst);
        for (0..TX_size) |_| {
            const data = self.runner_loop.get_tx_data(runner_inst).?;
            switch (data.device) {
                .HTTP => {
                    const pkg: *align(1) const Package = @alignCast(std.mem.bytesAsValue(Package, &data.buffer));
                    switch (pkg.*) {
                        .REQUEST => |req| {
                            req.handler(.{ .Finish = .Cancel }, req.user_data);
                        },
                        .SMALL => |req| {
                            req.handler(.{ .Finish = .Cancel }, req.user_data);
                        },
                        else => continue,
                    }
                },
                else => {
                    self.runner_loop.store_tx_data(data, runner_inst) catch return;
                },
            }
        }
        self.corrent_state = .None;
        self.corrent_handler = null;
        self.corrent_user_data = null;
        self.recv_check = false;
        self.header_check = false;
    }

    fn set_state(self: *HttpDevice, _: []const u8) DriverError!void {
        const runner_inst = self.runner_loop.runner_instance;
        self.to_send = null;
        self.runner_loop.set_busy_flag(0, runner_inst);
    }

    fn get_response(self: *HttpDevice, buffer: []const u8) DriverError!void {
        const runner_inst = self.runner_loop.runner_instance;
        const start_index = std.mem.indexOf(u8, buffer, ",");
        if (start_index) |index| {
            const data = commands.get_cmd_slice(buffer, ":", ",");
            const len = std.fmt.parseInt(usize, data[1..], 10) catch return DriverError.INVALID_RESPONSE;
            const long_request = Types.ToRead{
                .to_read = len,
                .data_offset = buffer.len,
                .start_index = index + 1,
                .notify = HttpDevice.recive_data,
                .user_data = self,
            };

            self.runner_loop.set_long_data(long_request, runner_inst);
            return;
        }
        return DriverError.INVALID_RESPONSE;
    }

    fn recive_data(data: []const u8, inst: *anyopaque) void {
        var self: *HttpDevice = @alignCast(@ptrCast(inst));
        self.recv_check = true;
        if (self.corrent_handler) |callback| {
            callback(.{ .Data = data }, self.corrent_user_data);
        }
    }

    pub fn init() HttpDevice {
        return HttpDevice{};
    }

    pub fn request(self: *HttpDevice, req: Request) !void {
        const runner_inst = self.runner_loop.runner_instance;
        if (self.runner_loop.get_tx_free_space(runner_inst) < 4) return DriverError.TX_BUFFER_FULL;
        try check_request(&req);

        var header_clear: commands.Package = .{};
        const clear_slice = std.fmt.bufPrint(&header_clear.str, "{s}{s}=0{s}", .{
            PREFIX,
            get_cmd_string(.HTTPCHEAD),
            POSTFIX,
        }) catch unreachable;

        header_clear.len = clear_slice.len;

        self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, header_clear), runner_inst) catch unreachable;
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .URL = req.url }), runner_inst) catch unreachable;
        if (req.header.len > 0) {
            self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .HEADER = req.header }), runner_inst) catch unreachable;
        }
        const method: MethodType = switch (req.method) {
            .GET => MethodType{ .GET = {} },
            .POST => MethodType{ .POST = req.data },
            .PUT => MethodType{ .PUT = req.data },
            else => unreachable,
        };

        const pkg = Package{
            .REQUEST = .{
                .handler = req.handler,
                .user_data = req.user_data,
                .method = method,
            },
        };

        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, pkg), runner_inst) catch unreachable;
    }

    ///Clear the next HTTP request on the event buffer
    pub fn clear_request(self: *HttpDevice) void {
        const runner_inst = self.runner_loop.runner_instance;
        const TX_size = self.runner_loop.get_tx_len(runner_inst);
        var end: bool = false;
        for (0..TX_size) |_| {
            const data = self.runner_loop.get_tx_data(runner_inst).?;
            //keep the buffer event order
            if (!end) {
                switch (data.device) {
                    .HTTP => {
                        const pkg: *align(1) const Package = @alignCast(std.mem.bytesAsValue(Package, &data.buffer));
                        switch (pkg.*) {
                            .REQUEST => |req| {
                                req.handler(.{ .Finish = .Cancel }, req.user_data);
                                end = true;
                                continue;
                            },
                            .SMALL => |req| {
                                req.handler(.{ .Finish = .Cancel }, req.user_data);
                                end = true;
                                continue;
                            },
                            else => continue,
                        }
                    },
                    else => {},
                }
            }
            self.runner_loop.store_tx_data(data, runner_inst) catch return;
        }
    }

    pub fn simple_request(self: *HttpDevice, req: SimpleRequest) !void {
        const runner_inst = self.runner_loop.runner_instance;
        if (self.runner_loop.get_tx_free_space(runner_inst) < 4) return DriverError.TX_BUFFER_FULL;
        if (req.data) |has_data| {
            if (has_data.len > 230) return HTTPError.DataTooLong;
        }
        var header_clear: commands.Package = .{};
        const clear_slice = std.fmt.bufPrint(&header_clear.str, "{s}{s}=0{s}", .{
            PREFIX,
            get_cmd_string(.HTTPCHEAD),
            POSTFIX,
        }) catch unreachable;

        header_clear.len = clear_slice.len;

        self.runner_loop.store_tx_data(TXPkg.convert_type(.Command, header_clear), runner_inst) catch unreachable;
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .URL = req.url }), runner_inst) catch unreachable;
        if (req.header.len > 0) {
            self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .HEADER = req.header }), runner_inst) catch unreachable;
        }
        self.runner_loop.store_tx_data(TXPkg.convert_type(.HTTP, Package{ .SMALL = req }), runner_inst) catch unreachable;
    }

    pub fn link_device(self: *HttpDevice, runner: anytype) void {
        const info = @typeInfo(@TypeOf(runner));
        switch (info) {
            .pointer => |ptr| {
                const child_type = ptr.child;
                if (@hasField(child_type, "HTTP_device")) {
                    const HTTP_device = &runner.HTTP_device;
                    if (@TypeOf(HTTP_device.*) == ?*Device) {
                        self.device.device_instance = @ptrCast(self);
                        HTTP_device.* = &self.device;
                    } else {
                        @compileError("HTTP_device need to be a Device pointer");
                    }
                } else {
                    @compileError(std.fmt.comptimePrint("type {s} does not have field \"HTTP_device\"", .{@typeName(runner)}));
                }

                if (@hasField(child_type, "runner_dev")) {
                    if (@TypeOf(runner.runner_dev) == Runner) {
                        self.runner_loop = &(runner.*.runner_dev);
                    } else {
                        @compileError("runner_dev need to be a Runner type");
                    }
                } else {
                    @compileError(std.fmt.comptimePrint("type {s} does not have field \"runner_dev\"", .{@typeName(runner)}));
                }
            },
            else => {
                @compileError("\"runner\" need to be a Pointer");
            },
        }
    }
};

fn check_request(req: *const Request) HTTPError!void {
    const url_len = req.url.len;

    if (url_len < 8) {
        return HTTPError.URLTooShort;
    } else if (url_len > 8192) {
        return HTTPError.URLTooLong;
    }

    switch (req.method) {
        .DELETE => return HTTPError.MethodUnsupported,
        .HEADER => return HTTPError.MethodUnsupported,
        else => {},
    }
}
