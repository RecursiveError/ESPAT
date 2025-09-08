const std = @import("std");

const Types = @import("Types.zig");
const commands = @import("util/commands.zig");

const Runner = Types.Runner;
const Device = Types.Device;
const DeviceError = Types.DeviceError;
const RunnerError = Types.RunnerError;

const PREFIX = commands.prefix;
const POSTFIX = commands.postfix;
const get_cmd_string = commands.get_cmd_string;

pub const HTTPError = error{
    MethodUnsupported,
    URLTooShort,
    URLTooLong,
    DataTooLong,
} || DeviceError;

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

const State = enum {
    None,
    Header,
    URL,
    Send,
    Data,
};

pub const Package = union(enum) {
    HEADER_CLEAR: void,
    SMALL: SimpleRequest,
    REQUEST: RequestType,
    URL: []const u8,
    HEADER: []const u8,
};

pub const Config = struct {
    cmd_buf: []Package,
    data_buf: []u8,
    runner: *const Runner,
};

pub const HttpDevice = struct {
    const CMD_CALLBACK_TYPE = *const fn (self: *HttpDevice, buffer: []const u8) DeviceError!void;
    const cmd_response_map = std.StaticStringMap(CMD_CALLBACK_TYPE).initComptime(.{
        .{ "SET", HttpDevice.set_state },
        .{ "+HTTPCGET", HttpDevice.get_response },
        .{ "+HTTPCPOST", HttpDevice.get_response },
        .{ "+HTTPCPUT", HttpDevice.get_response },
        .{ "+HTTPCLIENT", HttpDevice.get_response },
    });

    runner_dev: *const Runner,
    device: Device = .{
        .send_data_fn = pool_data,
        .check_cmd_fn = check_cmd,
        .get_cmd_fn = apply_cmd,
        .ok_handler_fn = ok_handler,
        .err_handler_fn = err_handler,
        .send_handler_fn = send_event,
        .reset_fn = reset,
    },

    data_buf: []u8,
    cmd_queue: std.ArrayList(Package),
    id: u32 = std.math.maxInt(u32), //invalid id
    to_send: ?[]const u8 = null,
    corrent_state: State = .None,
    //header set does not send "SET OK" like URL does, instead it sends "OK" twice
    header_check: bool = false,
    recv_check: bool = false,
    corrent_handler: ?HTTPHandler = null,
    corrent_user_data: ?*anyopaque = null,

    fn pool_data(device: *const Device, writer: *std.io.Writer) DeviceError!void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));
        if (self.to_send) |data| {
            writer.writeAll(data) catch unreachable;
            writer.flush() catch unreachable;
            return;
        }
        return DeviceError.NO_SEND_DATA;
    }

    fn check_cmd(device: *const Device, cmd: []const u8, all: []const u8) DeviceError!void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));
        const response_callback = cmd_response_map.get(cmd);
        if (response_callback) |callback| {
            try @call(.auto, callback, .{ self, all });
        }
    }

    fn apply_cmd(device: *const Device, writer: *std.io.Writer) DeviceError!void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));

        const pkg = self.cmd_queue.pop() orelse return DeviceError.QUEUE_EMPTY;
        switch (pkg) {
            .URL => |url| {
                self.corrent_state = .URL;
                self.to_send = url;
                self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                writer.print("{s}{s}={d}{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPURLCFG),
                    url.len,
                    POSTFIX,
                }) catch unreachable;
            },
            .HEADER_CLEAR => {
                writer.print("{s}{s}=0{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCHEAD),
                    POSTFIX,
                }) catch unreachable;
            },
            .HEADER => |header| {
                self.corrent_state = .Header;
                self.to_send = header;

                self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                self.header_check = true;
                writer.print("{s}{s}={d}{s}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCHEAD),
                    header.len,
                    POSTFIX,
                }) catch unreachable;
            },
            .REQUEST => |req| {
                self.corrent_state = .Send;
                self.corrent_handler = req.handler;
                self.corrent_user_data = req.user_data;
                switch (req.method) {
                    .GET => {
                        writer.print("{s}{s}=\"\"{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCGET),
                            POSTFIX,
                        }) catch unreachable;
                    },
                    .POST => |post| {
                        self.to_send = post;

                        self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                        writer.print("{s}{s}=\"\",{d}{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCPOST),
                            post.len,
                            POSTFIX,
                        }) catch unreachable;
                    },
                    .PUT => |put| {
                        self.to_send = put;
                        self.runner_dev.set_busy_flag(true, self.id) catch unreachable;
                        writer.print("{s}{s}=\"\",{d}{s}", .{
                            PREFIX,
                            get_cmd_string(.HTTPCPUT),
                            put.len,
                            POSTFIX,
                        }) catch unreachable;
                    },
                }
            },
            .SMALL => |req| {
                const method: usize = @intFromEnum(req.method) + 1;
                const content: usize = @intFromEnum(req.content);
                const transport: usize = @as(usize, @intFromEnum(req.transport)) + 1;

                self.corrent_state = .Data;
                self.corrent_handler = req.handler;
                self.corrent_user_data = req.user_data;

                writer.print("{s}{s}={d},{d},\"\",,,{d}", .{
                    PREFIX,
                    get_cmd_string(.HTTPCLIENT),
                    method,
                    content,
                    transport,
                }) catch unreachable;

                if (req.method == .POST) {
                    if (req.data) |to_send| {
                        writer.print(",{s}", .{to_send}) catch unreachable;
                    }
                }
                writer.print("{s}", .{POSTFIX}) catch unreachable;
            },
        }
        writer.flush() catch unreachable;
    }

    fn ok_handler(device: *const Device) void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));
        switch (self.corrent_state) {
            .Header => {
                if (self.header_check) {
                    self.header_check = false;
                    return;
                }

                self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
            },
            .Data => {
                if (self.corrent_handler) |callback| {
                    callback(.{ .Finish = .Ok }, self.corrent_user_data);
                }
                self.corrent_state = .None;
            },
            .Send => self.corrent_state = .Data,
            else => {},
        }
        return;
    }

    fn err_handler(device: *const Device) void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));

        switch (self.corrent_state) {
            .Header => {
                self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
                self.header_check = false;
                self.clear_request();
            },
            .URL => {
                self.clear_request();
            },
            .Data, .Send => {
                if (self.corrent_handler) |callback| {
                    const failevent = if (self.recv_check) ReqStatus{ .Finish = .Error } else ReqStatus{ .Finish = .Fail };
                    self.recv_check = false;
                    callback(failevent, self.corrent_user_data);
                }
            },
            else => {},
        }
    }

    fn send_event(device: *const Device, state: bool) void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));
        if (self.corrent_state == .Data) {
            if (self.corrent_handler) |callback| {
                if (state) {
                    callback(.{ .Finish = .Ok }, self.corrent_user_data);
                } else {
                    const failevent = if (self.recv_check) ReqStatus{ .Finish = .Error } else ReqStatus{ .Finish = .Fail };
                    callback(failevent, self.corrent_user_data);
                    self.recv_check = false;
                }
            }
            self.corrent_state = .None;
        }

        self.to_send = null;
        self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
        return;
    }

    fn reset(device: *const Device) DeviceError!void {
        const self: *HttpDevice = @alignCast(@constCast(@fieldParentPtr("device", device)));
        while (true) {
            const pkg = self.cmd_queue.pop() orelse break;

            switch (pkg) {
                .REQUEST => |req| {
                    req.handler(.{ .Finish = .Cancel }, req.user_data);
                },
                .SMALL => |req| {
                    req.handler(.{ .Finish = .Cancel }, req.user_data);
                },
                else => continue,
            }
        }
        self.corrent_state = .None;
        self.corrent_handler = null;
        self.corrent_user_data = null;
        self.recv_check = false;
        self.header_check = false;
    }

    fn set_state(self: *HttpDevice, _: []const u8) DeviceError!void {
        self.to_send = null;
        self.runner_dev.set_busy_flag(false, self.id) catch unreachable;
    }

    fn get_response(self: *HttpDevice, buffer: []const u8) DeviceError!void {
        const has_start = std.mem.indexOf(u8, buffer, ",");
        if (has_start) |index| {
            const data = commands.get_cmd_slice(buffer, ":", ",");
            const len = std.fmt.parseInt(usize, data[1..], 10) catch return DeviceError.INVALID_RESPONSE;

            if (self.corrent_handler) |callback| {
                const reader: *std.io.Reader = self.runner_dev.take_reader() catch return DeviceError.CMD_FAIL;
                const data_size = len;
                const start_index = index + 1;
                const rev = buffer[start_index..];
                var to_read = data_size - rev.len;
                var read_size = @min(to_read, (self.data_buf.len - rev.len));
                const end_index = (read_size + rev.len);

                std.mem.copyForwards(u8, self.data_buf, rev);
                reader.readSliceAll(self.data_buf[rev.len..end_index]) catch return DeviceError.FATAL_ERROR;
                callback(.{ .Data = self.data_buf[0..end_index] }, self.corrent_user_data);
                to_read -= read_size;
                //read revice data
                while (to_read > 0) {
                    read_size = @min(to_read, self.data_buf.len);
                    reader.readSliceAll(self.data_buf[0..read_size]) catch return DeviceError.FATAL_ERROR;
                    callback(.{ .Data = self.data_buf[0..read_size] }, self.corrent_user_data);
                    to_read -= read_size;
                }
            }

            return;
        }
        return DeviceError.INVALID_RESPONSE;
    }

    //clear the next request on queue
    pub fn clear_request(self: *HttpDevice) void {
        while (true) {
            const pkg = self.cmd_queue.pop() orelse return;
            self.runner_dev.queue_cancel(self.id, 1);
            switch (pkg) {
                .REQUEST => |req| {
                    req.handler(.{ .Finish = .Cancel }, req.user_data);
                    break;
                },
                .SMALL => |req| {
                    req.handler(.{ .Finish = .Cancel }, req.user_data);
                    break;
                },
                else => {},
            }
        }
        return;
    }

    pub fn request(self: *HttpDevice, req: Request) HTTPError!void {
        const free = self.runner_dev.queue_free_size();
        const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
        if ((free < 4) or (cmd_free < 4)) return HTTPError.QUEUE_FULL;
        try check_request(&req);

        self.runner_dev.queue_multi(self.id, 3) catch unreachable;
        self.cmd_queue.insertAssumeCapacity(0, .{ .HEADER_CLEAR = {} });
        self.cmd_queue.insertAssumeCapacity(0, .{ .URL = req.url });
        if (req.header.len > 0) {
            self.runner_dev.queue(self.id) catch unreachable;
            self.cmd_queue.insertAssumeCapacity(0, .{ .HEADER = req.header });
        }
        const method: MethodType = switch (req.method) {
            .GET => MethodType{ .GET = {} },
            .POST => MethodType{ .POST = req.data },
            .PUT => MethodType{ .PUT = req.data },
            else => unreachable,
        };

        self.cmd_queue.insertAssumeCapacity(0, .{
            .REQUEST = .{
                .handler = req.handler,
                .user_data = req.user_data,
                .method = method,
            },
        });
    }

    pub fn simple_request(self: *HttpDevice, req: SimpleRequest) !void {
        const free = self.runner_dev.queue_free_size();
        const cmd_free = self.cmd_queue.capacity - self.cmd_queue.items.len;
        if ((free < 4) or (cmd_free < 4)) return HTTPError.QUEUE_FULL;

        if (req.data) |has_data| {
            if (has_data.len > 230) return HTTPError.DataTooLong;
        }
        self.runner_dev.queue_multi(self.id, 3) catch unreachable;
        self.cmd_queue.insertAssumeCapacity(0, .{ .HEADER_CLEAR = {} });
        self.cmd_queue.insertAssumeCapacity(0, .{ .URL = req.url });
        if (req.header.len > 0) {
            self.runner_dev.queue(self.id) catch unreachable;
            self.cmd_queue.insertAssumeCapacity(0, .{ .HEADER = req.header });
        }
        self.cmd_queue.insertAssumeCapacity(0, .{ .SMALL = req });
    }

    pub fn init(config: Config) HttpDevice {
        return HttpDevice{
            .cmd_queue = std.ArrayList(Package).initBuffer(config.cmd_buf),
            .data_buf = config.data_buf,
            .runner_dev = config.runner,
        };
    }

    pub fn link_device(self: *HttpDevice) !void {
        self.id = try self.runner_dev.link_device(&self.device);
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
