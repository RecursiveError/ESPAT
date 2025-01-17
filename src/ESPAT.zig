//re-exports

pub const StandartRunner = struct {
    pub const RunnerRoot = @import("Runner.zig");
    pub const Runner = RunnerRoot.StdRunner;
    pub const Config = RunnerRoot.Config;
    pub const ResponseCallback = RunnerRoot.ResponseCallback;
    pub const TXcallback = RunnerRoot.TXcallback;
    pub const RXcallback = RunnerRoot.RXcallback;
    pub const ReponseEvent = RunnerRoot.ReponseEvent;
};

pub const Network = struct {
    pub const NetworkRoot = @import("Network_device.zig");

    pub const PackageType = NetworkRoot.PackageType;
    pub const Event = NetworkRoot.Event;
    pub const HandlerState = NetworkRoot.HandlerState;
    pub const ConnectConfig = NetworkRoot.ConnectConfig;
    pub const ServerConfig = NetworkRoot.ServerConfig;
    pub const TCPConn = NetworkRoot.TCPConn;
    pub const UDPConn = NetworkRoot.UDPConn;
    pub const HandlerType = NetworkRoot.HandlerType;
    pub const Handler = NetworkRoot.Handler;
    pub const Client = NetworkRoot.Client;
    pub const ClientCallback = NetworkRoot.ClientCallback;
    pub const DriveMode = NetworkRoot.DriverMode;
    pub const Device = NetworkRoot.NetworkDevice;
};

pub const WiFi = struct {
    pub const WiFiRoot = @import("WiFi_device.zig");

    pub const APConfig = WiFiRoot.APConfig;
    pub const STAConfig = WiFiRoot.STAConfig;
    pub const Event = WiFiRoot.Event;
    pub const Encryption = WiFiRoot.Encryption;

    pub const DriverMode = WiFiRoot.DriverMode;

    pub const state = WiFiRoot.state;

    pub const WIFICallbackType = WiFiRoot.WIFICallbackType;

    pub const Device = WiFiRoot.WiFiDevice;
};

pub const CommandsUtil = struct {
    pub const CommandsRoot = @import("util/commands.zig");
    pub const CommandEnum = CommandsRoot.Commands;
    pub const get_cmd_string = CommandsRoot.get_cmd_string;
    pub const get_cmd_slice = CommandsRoot.get_cmd_slice;
    pub const infix = CommandsRoot.infix;
    pub const prefix = CommandsRoot.prefix;
    pub const postfix = CommandsRoot.postfix;
};

pub const Types = struct {
    const TypesRoot = @import("Types.zig");
    pub const DriverError = TypesRoot.DriverError;

    pub const TXExtraData = TypesRoot.TXExtraData;

    pub const TXEventPkg = TypesRoot.TXEventPkg;

    pub const ToRead = TypesRoot.ToRead;

    pub const Runner = TypesRoot.Runner;

    pub const Device = TypesRoot.Device;
};
