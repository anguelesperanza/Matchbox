// Package net wraps the Vita's networking: start-up, connection info, name
// lookup, TCP and UDP sockets, and HTTP / HTTPS requests.
//
//   net.init()                                  // once
//   if !net.connected() { ... no Wi-Fi ... }
//
//   response, ok := net.http_get("http://example.com/")
//   defer net.http_free(&response)
//
//   address, _ := net.resolve("example.com", 80)
//   socket, _  := net.tcp_connect(address)
//   net.send_all(socket, data)
//   n := net.receive(socket, buffer[:])
//   net.close(socket)
//
// Every call here blocks until it is done or times out. A game should make
// them from a worker thread (see Examples/Net-Example), or the picture
// freezes while it waits.
//
// IP addresses and ports inside an Address are in network byte order, as the
// system wants them; use the helpers here to make and print them.
//
// Link: -lSceNet_stub -lSceNetCtl_stub -lSceHttp_stub -lSceSsl_stub -lSceSysmodule_stub
package net

import sce "../sce"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
    @(link_name = "malloc")  c_malloc  :: proc(size: uint) -> rawptr ---
    @(link_name = "realloc") c_realloc :: proc(ptr: rawptr, size: uint) -> rawptr ---
    @(link_name = "free")    c_free    :: proc(ptr: rawptr) ---
}

Socket :: distinct i32
INVALID_SOCKET :: Socket(-1)

Address :: struct {
    ip:   u32, // network byte order
    port: u16, // network byte order
}

// What each step of init returned (negative is an SCE error). HTTPS needs
// all of them; plain sockets only need the first three.
Init_Results :: struct {
    load_net, net, netctl:        i32,
    load_ssl, load_http, load_https: i32,
    ssl, http:                    i32,
}
init_results: Init_Results

// The SCE error of the last call in this package that failed.
last_error: i32

@(private) net_memory: rawptr
@(private) http_template: i32 = -1
@(private) http_ready: bool

// Starts the network libraries. net_pool is the memory SceNet works in.
// With http = false only sockets and name lookup are set up.
// Returns true if sockets are usable; see init_results for the rest.
init :: proc "contextless" (http := true, net_pool: int = 1024 * 1024) -> bool {
    init_results.load_net = sce.sceSysmoduleLoadModule(.NET)
    net_memory = c_malloc(uint(net_pool))
    param := sce.NetInitParam{memory = net_memory, size = i32(net_pool), flags = 0}
    init_results.net    = sce.sceNetInit(&param)
    init_results.netctl = sce.sceNetCtlInit()
    if init_results.net < 0 {
        last_error = init_results.net
        return false
    }
    if http {
        init_results.load_ssl   = sce.sceSysmoduleLoadModule(.SSL)
        init_results.load_http  = sce.sceSysmoduleLoadModule(.HTTP)
        init_results.load_https = sce.sceSysmoduleLoadModule(.HTTPS)
        init_results.ssl  = sce.sceSslInit(300 * 1024)
        init_results.http = sce.sceHttpInit(1024 * 1024)
        if init_results.http >= 0 {
            http_template = sce.sceHttpCreateTemplate("vito/1.0", sce.HTTP_VERSION_1_1, 1)
            http_ready = http_template >= 0
        }
    }
    return true
}

shutdown :: proc "contextless" () {
    if http_template >= 0 do sce.sceHttpDeleteTemplate(http_template)
    if init_results.http >= 0 do sce.sceHttpTerm()
    if init_results.ssl >= 0 do sce.sceSslTerm()
    sce.sceNetCtlTerm()
    sce.sceNetTerm()
    c_free(net_memory)
    net_memory, http_template, http_ready = nil, -1, false
}

// ---------------------------------------------------------------
// Connection info
// ---------------------------------------------------------------

Info :: struct {
    connected:    bool,
    state:        i32, // sce.NETCTL_STATE_*
    ip:           [16]u8, // zero-terminated text, like "192.168.1.20"
    netmask:      [16]u8,
    gateway:      [16]u8,
    dns:          [16]u8,
    ssid:         [33]u8,
    signal:       int, // Wi-Fi signal strength, 0 to 100
    mac:          [6]u8,
}

// True when the console has an internet connection (Wi-Fi joined and an
// address assigned).
connected :: proc "contextless" () -> bool {
    state: i32
    return sce.sceNetCtlInetGetState(&state) >= 0 && u32(state) == sce.NETCTL_STATE_CONNECTED
}

// Everything worth showing about the current connection. Cheap enough to
// call once a second, not every frame.
info :: proc "contextless" () -> (result: Info) {
    sce.sceNetCtlInetGetState(&result.state)
    result.connected = u32(result.state) == sce.NETCTL_STATE_CONNECTED
    if !result.connected do return

    data: sce.NetCtlInfo
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_IP_ADDRESS, &data) >= 0    do result.ip = data.ip_address
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_NETMASK, &data) >= 0       do result.netmask = data.netmask
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_DEFAULT_ROUTE, &data) >= 0 do result.gateway = data.default_route
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_PRIMARY_DNS, &data) >= 0   do result.dns = data.primary_dns
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_SSID, &data) >= 0          do result.ssid = data.ssid
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_RSSI_PERCENTAGE, &data) >= 0 do result.signal = int(data.rssi_percentage)
    if sce.sceNetCtlInetGetInfo(sce.NETCTL_INFO_GET_ETHER_ADDR, &data) >= 0 {
        result.mac = (^[6]u8)(&data.ether_addr)^
    }
    return
}

// ---------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------

// Makes an address from numbers: net.address({192, 168, 1, 10}, 9999).
address :: proc "contextless" (ip: [4]u8, port: u16) -> Address {
    return {ip = transmute(u32)ip, port = sce.sceNetHtons(port)}
}

// Reads "192.168.1.10" into an address. False if the text is not an IP.
parse_ip :: proc "contextless" (text: cstring, port: u16) -> (result: Address, ok: bool) {
    if sce.sceNetInetPton(sce.NET_AF_INET, text, &result.ip) <= 0 do return {}, false
    result.port = sce.sceNetHtons(port)
    return result, true
}

// Writes the IP as text into buf (16 bytes is always enough).
ip_string :: proc "contextless" (addr: Address, buf: []u8) -> cstring {
    ip := addr.ip
    if len(buf) < 16 do return ""
    return sce.sceNetInetNtop(sce.NET_AF_INET, &ip, raw_data(buf), u32(len(buf)))
}

port_number :: proc "contextless" (addr: Address) -> u16 {
    return sce.sceNetNtohs(addr.port)
}

// Looks a host name up (DNS). A name that is already an IP address works
// too. timeout is in seconds.
resolve :: proc "contextless" (host: cstring, port: u16, timeout: int = 5) -> (result: Address, ok: bool) {
    if direct, is_ip := parse_ip(host, port); is_ip do return direct, true

    resolver := sce.sceNetResolverCreate("vito_resolver", nil, 0)
    if resolver < 0 {
        last_error = resolver
        return {}, false
    }
    in_addr: sce.NetInAddr
    r := sce.sceNetResolverStartNtoa(resolver, host, &in_addr, i32(timeout * 1_000_000), 2, 0)
    sce.sceNetResolverDestroy(resolver)
    if r < 0 {
        last_error = r
        return {}, false
    }
    return {ip = in_addr.s_addr, port = sce.sceNetHtons(port)}, true
}

@(private)
sockaddr :: proc "contextless" (addr: Address) -> sce.NetSockaddrIn {
    return {
        sin_len    = size_of(sce.NetSockaddrIn),
        sin_family = sce.NET_AF_INET,
        sin_port   = addr.port,
        sin_addr   = {s_addr = addr.ip},
    }
}

// ---------------------------------------------------------------
// Sockets
// ---------------------------------------------------------------

// Opens a TCP connection. timeout (seconds) limits each later send and
// receive, and on this system the connection attempt as well.
tcp_connect :: proc "contextless" (addr: Address, timeout: int = 10) -> (socket: Socket, ok: bool) {
    s := sce.sceNetSocket("vito_tcp", sce.NET_AF_INET, sce.NET_SOCK_STREAM, 0)
    if s < 0 {
        last_error = s
        return INVALID_SOCKET, false
    }
    set_timeout(Socket(s), timeout)
    target := sockaddr(addr)
    if r := sce.sceNetConnect(s, (^sce.NetSockaddr)(&target), size_of(target)); r < 0 {
        last_error = r
        sce.sceNetSocketClose(s)
        return INVALID_SOCKET, false
    }
    return Socket(s), true
}

// Opens a TCP socket that waits for connections on a port of this console.
tcp_listen :: proc "contextless" (port: u16, backlog: int = 4) -> (socket: Socket, ok: bool) {
    s := sce.sceNetSocket("vito_listen", sce.NET_AF_INET, sce.NET_SOCK_STREAM, 0)
    if s < 0 {
        last_error = s
        return INVALID_SOCKET, false
    }
    yes: i32 = 1
    sce.sceNetSetsockopt(s, sce.NET_SOL_SOCKET, sce.NET_SO_REUSEADDR, &yes, size_of(yes))
    local := sockaddr({ip = sce.NET_INADDR_ANY, port = sce.sceNetHtons(port)})
    r := sce.sceNetBind(s, (^sce.NetSockaddr)(&local), size_of(local))
    if r >= 0 do r = sce.sceNetListen(s, i32(backlog))
    if r < 0 {
        last_error = r
        sce.sceNetSocketClose(s)
        return INVALID_SOCKET, false
    }
    return Socket(s), true
}

// Waits for someone to connect to a listening socket. Give the listener a
// timeout with set_timeout first, or this waits for ever.
tcp_accept :: proc "contextless" (listener: Socket) -> (socket: Socket, from: Address, ok: bool) {
    peer: sce.NetSockaddrIn
    length := u32(size_of(peer))
    s := sce.sceNetAccept(i32(listener), (^sce.NetSockaddr)(&peer), &length)
    if s < 0 {
        last_error = s
        return INVALID_SOCKET, {}, false
    }
    return Socket(s), {ip = peer.sin_addr.s_addr, port = peer.sin_port}, true
}

// Opens a UDP socket. port 0 lets the system pick one (enough for a client);
// a number makes it receive packets sent to that port of this console.
udp_open :: proc "contextless" (port: u16 = 0, broadcast := false) -> (socket: Socket, ok: bool) {
    s := sce.sceNetSocket("vito_udp", sce.NET_AF_INET, sce.NET_SOCK_DGRAM, 0)
    if s < 0 {
        last_error = s
        return INVALID_SOCKET, false
    }
    if broadcast {
        yes: i32 = 1
        sce.sceNetSetsockopt(s, sce.NET_SOL_SOCKET, sce.NET_SO_BROADCAST, &yes, size_of(yes))
    }
    if port != 0 {
        local := sockaddr({ip = sce.NET_INADDR_ANY, port = sce.sceNetHtons(port)})
        if r := sce.sceNetBind(s, (^sce.NetSockaddr)(&local), size_of(local)); r < 0 {
            last_error = r
            sce.sceNetSocketClose(s)
            return INVALID_SOCKET, false
        }
    }
    return Socket(s), true
}

// Sends one UDP packet. Returns the bytes sent, or a negative SCE error.
udp_send :: proc "contextless" (socket: Socket, to: Address, data: []u8) -> int {
    target := sockaddr(to)
    r := sce.sceNetSendto(i32(socket), raw_data(data), u32(len(data)), 0, (^sce.NetSockaddr)(&target), size_of(target))
    if r < 0 do last_error = r
    return int(r)
}

// Waits for one UDP packet. Returns its size and sender; a negative size is
// an SCE error (a timeout among them, see timed_out).
udp_receive :: proc "contextless" (socket: Socket, buf: []u8) -> (size: int, from: Address) {
    peer: sce.NetSockaddrIn
    length := u32(size_of(peer))
    r := sce.sceNetRecvfrom(i32(socket), raw_data(buf), u32(len(buf)), 0, (^sce.NetSockaddr)(&peer), &length)
    if r < 0 do last_error = r
    return int(r), {ip = peer.sin_addr.s_addr, port = peer.sin_port}
}

// Sends all of data on a TCP socket, however many pieces that takes.
send_all :: proc "contextless" (socket: Socket, data: []u8) -> bool {
    sent := 0
    for sent < len(data) {
        r := sce.sceNetSend(i32(socket), raw_data(data[sent:]), u32(len(data) - sent), 0)
        if r <= 0 {
            last_error = r
            return false
        }
        sent += int(r)
    }
    return true
}

// Receives what is available on a TCP socket, up to len(buf). Returns the
// byte count; 0 means the other side closed the connection; negative is an
// SCE error (see timed_out).
receive :: proc "contextless" (socket: Socket, buf: []u8) -> int {
    r := sce.sceNetRecv(i32(socket), raw_data(buf), u32(len(buf)), 0)
    if r < 0 do last_error = r
    return int(r)
}

// Limits how long a send or receive on this socket may wait, in seconds.
// 0 means for ever.
set_timeout :: proc "contextless" (socket: Socket, seconds: int) {
    microseconds := i32(seconds * 1_000_000)
    sce.sceNetSetsockopt(i32(socket), sce.NET_SOL_SOCKET, sce.NET_SO_RCVTIMEO, &microseconds, size_of(microseconds))
    sce.sceNetSetsockopt(i32(socket), sce.NET_SOL_SOCKET, sce.NET_SO_SNDTIMEO, &microseconds, size_of(microseconds))
}

// Makes send and receive return at once instead of waiting; when there is
// nothing to do they fail with an error for which would_block is true.
set_non_blocking :: proc "contextless" (socket: Socket, on := true) {
    value: i32 = 1 if on else 0
    sce.sceNetSetsockopt(i32(socket), sce.NET_SOL_SOCKET, sce.NET_SO_NBIO, &value, size_of(value))
}

// Turns off the small delay TCP adds to group writes; for game traffic.
set_no_delay :: proc "contextless" (socket: Socket, on := true) {
    value: i32 = 1 if on else 0
    sce.sceNetSetsockopt(i32(socket), sce.NET_IPPROTO_TCP, sce.NET_TCP_NODELAY, &value, size_of(value))
}

close :: proc "contextless" (socket: Socket) {
    if socket != INVALID_SOCKET do sce.sceNetSocketClose(i32(socket))
}

// True if a negative result from receive / udp_receive / a send means "no
// data yet" on a non-blocking socket.
would_block :: proc "contextless" (result: int) -> bool {
    return i32(result) == sce.NET_ERROR_EAGAIN
}

// True if a negative result means the wait ran out. On this system a
// timed-out receive reports the same error as would_block.
timed_out :: proc "contextless" (result: int) -> bool {
    return i32(result) == sce.NET_ERROR_ETIMEDOUT || i32(result) == sce.NET_ERROR_EAGAIN
}

// ---------------------------------------------------------------
// HTTP and HTTPS
// ---------------------------------------------------------------

Http_Response :: struct {
    status: int,   // 200, 404, ...
    body:   []u8,  // release with http_free
}

// Where an HTTP request failed, for error messages.
Http_Step :: enum {
    None,
    Not_Initialised,
    Connection,
    Request,
    Send,
    Status,
    Read,
    Too_Large,
    Out_Of_Memory,
}
last_http_step: Http_Step
// For a failed HTTPS request: the SSL error and detail flags.
last_ssl_error:  i32
last_ssl_detail: u32

// GET a URL ("http://..." or "https://..."). Redirects are followed.
// max_size limits the body; a larger one fails with .Too_Large.
http_get :: proc "contextless" (url: cstring, max_size: int = 8 * 1024 * 1024) -> (response: Http_Response, ok: bool) {
    return http_request(sce.HTTP_METHOD_GET, url, nil, nil, max_size)
}

// POST a body to a URL. content_type is for example "application/json".
http_post :: proc "contextless" (url: cstring, body: []u8, content_type: cstring = "application/octet-stream",
                                 max_size: int = 8 * 1024 * 1024) -> (response: Http_Response, ok: bool) {
    return http_request(sce.HTTP_METHOD_POST, url, body, content_type, max_size)
}

http_request :: proc "contextless" (method: i32, url: cstring, body: []u8, content_type: cstring,
                                    max_size: int) -> (response: Http_Response, ok: bool) {
    fail :: proc "contextless" (step: Http_Step, error: i32) -> (Http_Response, bool) {
        last_http_step, last_error = step, error
        return {}, false
    }
    if !http_ready do return fail(.Not_Initialised, init_results.http)

    connection := sce.sceHttpCreateConnectionWithURL(http_template, url, 0)
    if connection < 0 do return fail(.Connection, connection)
    defer sce.sceHttpDeleteConnection(connection)

    request := sce.sceHttpCreateRequestWithURL(connection, method, url, u64(len(body)))
    if request < 0 do return fail(.Request, request)
    defer sce.sceHttpDeleteRequest(request)
    if content_type != nil && len(body) > 0 {
        sce.sceHttpAddRequestHeader(request, "Content-Type", content_type, sce.HTTP_HEADER_OVERWRITE)
    }

    if r := sce.sceHttpSendRequest(request, raw_data(body), u32(len(body))); r < 0 {
        last_ssl_error, last_ssl_detail = 0, 0
        sce.sceHttpsGetSslError(request, &last_ssl_error, &last_ssl_detail)
        return fail(.Send, r)
    }
    status: i32
    if r := sce.sceHttpGetStatusCode(request, &status); r < 0 do return fail(.Status, r)
    response.status = int(status)

    // The length is not always announced, so read until the end, growing.
    capacity := 16 * 1024
    data := ([^]u8)(c_malloc(uint(capacity)))
    if data == nil do return fail(.Out_Of_Memory, 0)
    size := 0
    for {
        if size == capacity {
            if capacity >= max_size {
                c_free(data)
                return fail(.Too_Large, 0)
            }
            capacity = min(capacity * 2, max_size)
            grown := ([^]u8)(c_realloc(data, uint(capacity)))
            if grown == nil {
                c_free(data)
                return fail(.Out_Of_Memory, 0)
            }
            data = grown
        }
        r := sce.sceHttpReadData(request, &data[size], u32(capacity - size))
        if r < 0 {
            c_free(data)
            return fail(.Read, r)
        }
        if r == 0 do break
        size += int(r)
    }
    response.body = data[:size]
    last_http_step = .None
    return response, true
}

http_free :: proc "contextless" (response: ^Http_Response) {
    c_free(raw_data(response.body))
    response^ = {}
}

// HTTPS checks the server's certificate against the console's own list of
// certificate authorities. That list stopped being updated years ago, so
// many current sites fail the check. Passing false turns the check off:
// the connection is still encrypted, but the server is no longer proven to
// be who it says it is. Use it only for data that does not need that proof.
//
// Turning the check off cannot help when the failure is not about the
// certificate: a server that only accepts newer TLS versions or ciphers than
// the console's firmware has fails the handshake itself (HTTPS_ERROR_HANDSHAKE
// from http_error_name). The way round that is a TLS library shipped with
// the game, which this package does not include.
https_set_verify :: proc "contextless" (verify: bool) -> i32 {
    flags := u32(sce.HTTPS_FLAG_SERVER_VERIFY | sce.HTTPS_FLAG_CN_CHECK | sce.HTTPS_FLAG_NOT_AFTER_CHECK |
                 sce.HTTPS_FLAG_NOT_BEFORE_CHECK | sce.HTTPS_FLAG_KNOWN_CA_CHECK)
    https_verify = verify
    // Belt and braces: the option flags, and a callback that gets the last
    // word on each certificate. The callback is installed the first time the
    // check is turned off and from then on follows https_verify.
    if !verify && !https_callback_set && http_template >= 0 {
        https_callback_result = sce.sceHttpsSetSslCallback(http_template, https_callback, nil)
        https_callback_set = https_callback_result >= 0
    }
    return sce.sceHttpsEnableOption(flags) if verify else sce.sceHttpsDisableOption(flags)
}

@(private) https_verify: bool = true
@(private) https_callback_set: bool
// What installing the certificate callback returned, and how often and with
// what it was last called; for diagnosing HTTPS failures.
https_callback_result: i32
https_callback_calls:  int
https_callback_error:  u32

@(private)
https_callback :: proc "c" (verify_error: u32, certificates: [^]rawptr, count: i32, user: rawptr) -> i32 {
    https_callback_calls += 1
    https_callback_error = verify_error
    if !https_verify do return 0 // accept whatever was presented
    return 0 if verify_error == 0 else -1
}

// A name for the SCE error codes HTTP and HTTPS requests fail with most.
// "" for anything else.
http_error_name :: proc "contextless" (code: i32) -> string {
    switch code {
    case sce.HTTPS_ERROR_CERT:           return "HTTPS_ERROR_CERT (certificate rejected)"
    case sce.HTTPS_ERROR_HANDSHAKE:      return "HTTPS_ERROR_HANDSHAKE (TLS version or cipher not shared)"
    case sce.HTTPS_ERROR_IO:             return "HTTPS_ERROR_IO"
    case sce.HTTPS_ERROR_INTERNAL:       return "HTTPS_ERROR_INTERNAL"
    case sce.HTTPS_ERROR_PROXY:          return "HTTPS_ERROR_PROXY"
    case sce.HTTP_ERROR_SSL:             return "HTTP_ERROR_SSL"
    case sce.HTTP_ERROR_NETWORK:         return "HTTP_ERROR_NETWORK"
    case sce.HTTP_ERROR_TIMEOUT:         return "HTTP_ERROR_TIMEOUT"
    case sce.HTTP_ERROR_RESOLVER_ENOHOST: return "HTTP_ERROR_RESOLVER_ENOHOST (name not found)"
    case sce.HTTP_ERROR_BEFORE_INIT:     return "HTTP_ERROR_BEFORE_INIT"
    }
    return ""
}
