const std = @import("std");

pub const network_handler_state = enum {
    None,
    Connected,
    Closed,
};

pub const network_handler_type = enum { NONE, TCP, UDP, SSL };

pub const network_handler = struct { descriptor_id: u8 = 255, state: network_handler_state = .None, network_handler_type: network_handler_type = .NONE };
pub const NetworkPackage = struct { descriptor_id: u8 = 255, data: ?[]u8 = null };
