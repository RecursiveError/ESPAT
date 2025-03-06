In addition to the TCP/IP APIs, ESP-AT also provides APIs for a build-in HTTP/HTTPS client, allowing a simpler means for web communication, however, it is much more limited than the use of the TCP/IP APIs.


# Basic HTTP

To use the HTTP feature it is necessary to create a device: `Http.Device.init();`
link this device to the Runner with: `Http_device.link_device(&my_drive);`

## Request


> WARNING: ESP-AT will ignore the data field if the method is different from POST.
>
>ESP-AT does not support redirects, and all requests with 3xx will be interpreted as errors.

To send a request, you first need to pass some information to the struct `Request`, this struct contains the following fields:  

- `method`: request method  
- `url`: request url  
- `header`: a slice for the text that should be sent as a header (this driver does not do automatic formatting)    
- `data`: data to send for the request
- `handler`: callback to receive HTTP events (each request has its own callback) [events](#events)
- `user_data`: optional user data

Once this is done, just call `http_device.request(Request)`, passing the struct and that's it, now just wait!


## Events
To receive data from a request you need to create a handler.

An HTTP handler has the following signature: `fn (status: Status, user_data: ?*anyopaque) void;`

Status is a tagged enum with the following fields:
|**Field**|**Type**|**info**|
|---------|--------|--------|
| Data    | []const u8| data received from the connection may come in several packets, so it is recommended to wait until the request completion event|
| Finish | FinishStatus | request completion [status](#finishstatus) |

### FinishStatus:
**Ok**: request went through without problems.  
**Error**: request received data but with a code other than 2xx.  
**Fail**: Request did not receive data and received a code other than 2xx.  
**Cancel**:request canceled due to some internal error

## Example
```zig
const Driver = @import("ESPAT");
const Http = Driver.HttpDevice;
const Runner = Driver.StandartRunner;
...


var api_buffer: [API_BUFFER_SIZE]u8 = undefined;
var api_buf_index: usize = 0;
fn api_response(event: Http.Status, _: ?*anyopaque) void {
    switch (event) {
        .Data => |rev| {
            std.mem.copyForwards(u8, api_buffer[api_buf_index..], rev);
            api_buf_index += rev.len;
        },
        .Finish => |status| {
            switch (status) {
                .Ok => {
                    std.log.info("|API| {s}", .{api_buffer[0..api_buf_index]});
                },
                else => {
                    std.log.info("|API| {any}", .{status});
                },
            }
            api_buf_index = 0;
        },
    }
}

...

fn main() !void {
    ...
    var http_dev = Http.Device.init();
    ...
    http_dev.link_device(&my_drive);
    try http_dev.request(.{
        .url = "https://httpbin.org/post",
        .header = "User-Agent: ESPAT\r\n",
        .data = "blablabla",
        .method = .POST,
        .handler = HTTP_callback,
        .user_data = null,
    });

    try http_dev.simple_request(.{
        .url = "https://httpbin.org/get",
        .header = "User-Agent: ESPAT\r\n",
        .data = "blablabla", //not send
        .method = .GET,
        .content = .@"text/xml",
        .transport = .SSL,
        .handler = HTTP_callback,
        .user_data = null,
    });

    while (true) {
        my_drive.process() catch |err| {
            _ = std.log.err("Driver got error: {}", .{err});
            while (true) {}
        };
    }


}

```