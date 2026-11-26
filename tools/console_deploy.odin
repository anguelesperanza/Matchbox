package console_deploy

/*
	console_deploy -- uploads hardware test builds to the New 3DS LL and the PS Vita over FTP

	The console's own FTP server has to be switched on by hand first (it shuts
	off while an app runs). This tool only ever talks to a server it was told to.

	Usage:
	  console_deploy <file> [<file> ...]
	  console_deploy -target:vita build\hardware\some_build.vpk

	The target is chosen from the extension: .3dsx goes to the 3DS, .vpk to the
	Vita. `-target:3ds` or `-target:vita` overrides that (any extension then).

	Options:
	  -target:3ds|vita   send every file to this console, whatever its extension
	  -ini:<path>        settings file (default: console_deploy.ini beside the executable)
	  -h                 this help

	Settings are read from the .ini, then from a `.local.ini` beside it if one
	exists (`console_deploy.local.ini`, gitignored: a password goes there, never
	in the committed file). See console_deploy.ini for the keys.

	Exit code: 0 if every file uploaded, 1 if an upload failed, 2 for a bad
	command line or settings file. The first failure stops the run, so nothing
	after it is attempted.

	Build:  odin build tools/console_deploy.odin -file -out:tools/console_deploy.exe
	Test:   odin test tools/console_deploy.odin -file
	(the tests use a throwaway FTP server on 127.0.0.1; they never touch a console)

	Safety: nothing is ever deleted, and the only file STOR can replace is one
	with the same name as the file being uploaded (the name is the file's own
	name with its folders cut off, so a path can never reach into another folder).
*/

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// A failure, with the sentence to show the user. nil means success, which is what `or_return` tests.
Error :: Maybe(string)

Target :: enum {
	NINTENDO_3DS,
	PS_VITA,
}

// What a console's FTP server needs. Keys in the .ini are `<target>_<field>`.
Target_Settings :: struct {
	folder_location: string, // sent to the server exactly as written: they are console paths, not Unix ones
	protocol:        string,
	encryption:      string,
	hostname:        string,
	port_number:     int,
	username:        string, // empty means anonymous
	password:        string,
}

// How long to wait before giving up. A console that is off must fail in seconds.
Timeouts :: struct {
	connect:        time.Duration, // opening a TCP connection
	reply:          time.Duration, // a server's answer to one command
	transfer_reply: time.Duration, // the "226" after the data is sent: the console is writing to its SD card
}

Upload_Result :: struct {
	bytes:        int,
	milliseconds: i64,
	folder:       string,
}

Reply :: struct {
	code: int,
	text: string,
}

Read_Status :: enum {
	NONE,
	TIMEOUT,
	CLOSED,
	FAILED,
}

Connection :: struct {
	control: net.TCP_Socket,
	pending: [dynamic]u8, // bytes already read past the end of the last reply line
	address: net.Address,
}

// A dial runs on its own thread because core:net has no connect timeout, and
// Windows waits about 20 seconds on an address nobody answers. If the wait runs
// out the thread is simply left behind: the process is about to exit anyway.
Dial_Job :: struct {
	endpoint: net.Endpoint,
	socket:   net.TCP_Socket,
	error:    net.Network_Error,
	finished: bool,
}

main :: proc() {
	code := run(os.args[1:])
	free_all(context.temp_allocator)
	os.exit(code)
}

get_target_name :: proc(target: Target) -> string {
	switch target {
	case .NINTENDO_3DS: return "3ds"
	case .PS_VITA:      return "vita"
	}
	return ""
}

get_target_from_name :: proc(name: string) -> (target: Target, ok: bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "3ds":  return .NINTENDO_3DS, true
	case "vita": return .PS_VITA, true
	}
	return {}, false
}

get_target_from_extension :: proc(path: string) -> (target: Target, error: Error) {
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	switch extension {
	case ".3dsx": return .NINTENDO_3DS, nil
	case ".vpk":  return .PS_VITA, nil
	}
	shown := extension if extension != "" else "(none)"
	return {}, fmt.tprintf(
		"cannot tell which console %q is for: extension %s is not .3dsx (3ds) or .vpk (vita). Use -target:3ds or -target:vita to choose",
		path, shown,
	)
}

// Folders are cut off so the upload can only ever name a file in the configured folder.
get_upload_name :: proc(path: string) -> string {
	last := strings.last_index_any(path, "/\\")
	return path[last + 1:] if last >= 0 else path
}

// `x.ini` -> `x.local.ini`: the gitignored override that may hold a password.
get_local_ini_path :: proc(ini_path: string) -> string {
	if strings.has_suffix(ini_path, ".ini") {
		return fmt.tprintf("%s.local.ini", ini_path[:len(ini_path) - 4])
	}
	return fmt.tprintf("%s.local", ini_path)
}

get_default_ini_path :: proc() -> string {
	executable, error := os.get_executable_path(context.temp_allocator)
	if error != nil do return "tools/console_deploy.ini"
	return fmt.tprintf("%s/console_deploy.ini", filepath.dir(executable))
}

// Reads `key = value` lines into `values`, later files overriding earlier ones.
// There are no inline comments: a `#` in a password must survive. An unknown key
// is an error because a typo'd key would otherwise be silently ignored.
parse_ini_text :: proc(text: string, source: string, values: ^map[string]string) -> (error: Error) {
	field_names := [?]string{"folder_loc", "protocol", "encryption", "hostname", "port_number", "username", "password"}
	text_left := text
	line_number := 0
	for line in strings.split_lines_iterator(&text_left) {
		line_number += 1
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' || trimmed[0] == ';' do continue

		equals := strings.index_byte(trimmed, '=')
		if equals < 0 {
			return fmt.tprintf("%s line %d: expected key = value, got %q", source, line_number, trimmed)
		}
		key := strings.to_lower(strings.trim_space(trimmed[:equals]), context.temp_allocator)
		value := strings.trim_space(trimmed[equals + 1:])

		known := false
		for target in Target {
			for field in field_names {
				if key == fmt.tprintf("%s_%s", get_target_name(target), field) do known = true
			}
		}
		if !known {
			return fmt.tprintf("%s line %d: unknown key %q", source, line_number, key)
		}
		values[strings.clone(key, context.temp_allocator)] = strings.clone(value, context.temp_allocator)
	}
	return nil
}

// Reads the main .ini (required) and the `.local.ini` beside it (optional).
load_ini_values :: proc(ini_path: string) -> (values: map[string]string, error: Error) {
	values = make(map[string]string, context.temp_allocator)
	main_bytes, read_error := os.read_entire_file(ini_path, context.temp_allocator)
	if read_error != nil {
		return values, fmt.tprintf("cannot read settings file %s (%v); pass -ini:<path> to use another", ini_path, read_error)
	}
	error = parse_ini_text(string(main_bytes), ini_path, &values)
	if error != nil do return

	local_path := get_local_ini_path(ini_path)
	if os.exists(local_path) {
		local_bytes, local_error := os.read_entire_file(local_path, context.temp_allocator)
		if local_error != nil {
			return values, fmt.tprintf("cannot read %s (%v)", local_path, local_error)
		}
		error = parse_ini_text(string(local_bytes), local_path, &values)
	}
	return
}

get_target_settings :: proc(values: map[string]string, target: Target, ini_path: string) -> (settings: Target_Settings, error: Error) {
	name := get_target_name(target)
	required :: proc(values: map[string]string, name, field, ini_path: string) -> (value: string, error: Error) {
		key := fmt.tprintf("%s_%s", name, field)
		found: bool
		value, found = values[key]
		if !found || value == "" {
			return "", fmt.tprintf("missing key %s in %s", key, ini_path)
		}
		return value, nil
	}

	settings.folder_location = required(values, name, "folder_loc", ini_path) or_return
	settings.protocol = required(values, name, "protocol", ini_path) or_return
	settings.encryption = required(values, name, "encryption", ini_path) or_return
	settings.hostname = required(values, name, "hostname", ini_path) or_return
	port_text := required(values, name, "port_number", ini_path) or_return
	settings.username = values[fmt.tprintf("%s_username", name)] or_else ""
	settings.password = values[fmt.tprintf("%s_password", name)] or_else ""

	// Refuse rather than quietly fall back to plain FTP: an encrypted setting
	// that is not honoured would be a false sense of safety.
	if !strings.equal_fold(settings.protocol, "ftp") {
		return {}, fmt.tprintf(
			"%s_protocol = %q is not supported yet (only \"ftp\" works)", name, settings.protocol)
	}
	if !strings.equal_fold(settings.encryption, "none") {
		return {}, fmt.tprintf(
			"%s_encryption = %q is not supported yet (only \"none\" works)", name, settings.encryption)
	}

	port, port_ok := strconv.parse_int(port_text)
	if !port_ok || port < 1 || port > 65535 {
		return {}, fmt.tprintf("%s_port_number = %q is not a port number (1 to 65535)", name, port_text)
	}
	settings.port_number = port
	return settings, nil
}

// ---------------------------------------------------------------------------
// FTP over core:net

dial_endpoint_thread :: proc(job: ^Dial_Job) {
	job.socket, job.error = net.dial_tcp_from_endpoint(job.endpoint)
	sync.atomic_store(&job.finished, true)
}

dial_with_timeout :: proc(endpoint: net.Endpoint, timeout: time.Duration) -> (socket: net.TCP_Socket, error: Error) {
	job := new(Dial_Job) // never freed on a timeout: the thread may still be using it
	job.endpoint = endpoint
	worker := thread.create_and_start_with_poly_data(job, dial_endpoint_thread)
	started := time.tick_now()
	for !sync.atomic_load(&job.finished) {
		if time.tick_since(started) > timeout {
			return {}, fmt.tprintf("no answer from %s within %v", net.endpoint_to_string(endpoint, context.temp_allocator), timeout)
		}
		time.sleep(2 * time.Millisecond)
	}
	thread.join(worker)
	thread.destroy(worker)
	socket = job.socket
	if job.error != nil {
		error = fmt.tprintf("%v", job.error)
	}
	free(job)
	return
}

// Reads one line (CRLF or LF ended) from the socket, keeping any extra bytes for the next call.
read_line :: proc(socket: net.TCP_Socket, pending: ^[dynamic]u8, timeout: time.Duration) -> (line: string, status: Read_Status) {
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	buffer: [1024]u8
	for {
		for byte, index in pending[:] {
			if byte == '\n' {
				text := strings.clone(string(pending[:index]), context.temp_allocator)
				remove_range(pending, 0, index + 1)
				return strings.trim_right(text, "\r"), .NONE
			}
		}
		count, error := net.recv_tcp(socket, buffer[:])
		if error == .Timeout || error == .Would_Block do return "", .TIMEOUT
		if error != nil do return "", .FAILED
		if count == 0 do return "", .CLOSED
		append(pending, ..buffer[:count])
	}
}

// A reply is `NNN text`; `NNN-text` starts a multi-line reply that ends at `NNN text`.
read_reply :: proc(connection: ^Connection, waiting_for: string, timeout: time.Duration) -> (reply: Reply, error: Error) {
	first_code := ""
	text: [dynamic]string
	text.allocator = context.temp_allocator
	for {
		line, status := read_line(connection.control, &connection.pending, timeout)
		switch status {
		case .NONE:
		case .TIMEOUT:
			return {}, fmt.tprintf("timed out after %v waiting for the server's reply to %s", timeout, waiting_for)
		case .CLOSED:
			return {}, fmt.tprintf("the server closed the connection while waiting for its reply to %s", waiting_for)
		case .FAILED:
			return {}, fmt.tprintf("network error while waiting for the server's reply to %s", waiting_for)
		}
		// The code is reported on its own, so keep only the words in `text`.
		append(&text, line[4:] if len(line) > 4 else line)
		if len(line) < 3 do continue
		code_text := line[:3]
		if _, is_number := strconv.parse_int(code_text); !is_number do continue
		if first_code == "" do first_code = code_text
		if code_text == first_code && (len(line) == 3 || line[3] == ' ') {
			reply.code, _ = strconv.parse_int(first_code)
			reply.text = strings.join(text[:], " | ", context.temp_allocator)
			return
		}
	}
}

send_command :: proc(connection: ^Connection, command: string, timeouts: Timeouts) -> (error: Error) {
	_ = net.set_option(connection.control, .Send_Timeout, timeouts.reply)
	line := fmt.tprintf("%s\r\n", command)
	_, send_error := net.send_tcp(connection.control, transmute([]u8)line)
	if send_error != nil {
		// The command's verb only: a PASS line would put the password in the message.
		verb, _, _ := strings.partition(command, " ")
		return fmt.tprintf("could not send %s to the server (%v)", verb, send_error)
	}
	return nil
}

// Sends a command and checks the reply code. `accepted` lists the codes that mean success.
command_expect :: proc(connection: ^Connection, command: string, accepted: []int, timeouts: Timeouts) -> (reply: Reply, error: Error) {
	verb, _, _ := strings.partition(command, " ")
	send_command(connection, command, timeouts) or_return
	reply = read_reply(connection, verb, timeouts.reply) or_return
	return reply, check_reply(reply, verb, accepted)
}

check_reply :: proc(reply: Reply, verb: string, accepted: []int) -> Error {
	for code in accepted {
		if reply.code == code do return nil
	}
	expected := make([dynamic]string, context.temp_allocator)
	for code in accepted do append(&expected, fmt.tprintf("%d", code))
	return fmt.tprintf("unexpected reply to %s: %d %s (expected %s)",
		verb, reply.code, reply.text, strings.join(expected[:], " or ", context.temp_allocator))
}

log_in :: proc(connection: ^Connection, settings: Target_Settings, timeouts: Timeouts) -> (error: Error) {
	username := settings.username if settings.username != "" else "anonymous"
	user_reply := command_expect(connection, fmt.tprintf("USER %s", username), {230, 331, 530}, timeouts) or_return
	if user_reply.code == 230 do return nil
	if user_reply.code == 530 {
		return fmt.tprintf("login refused for user %q: %d %s", username, user_reply.code, user_reply.text)
	}
	// Anonymous servers want an e-mail-like password; an empty one is what the config means by "no login".
	password := settings.password if settings.username != "" else "anonymous@"
	send_command(connection, fmt.tprintf("PASS %s", password), timeouts) or_return
	pass_reply := read_reply(connection, "PASS", timeouts.reply) or_return
	if pass_reply.code == 530 || pass_reply.code == 430 {
		return fmt.tprintf("login refused for user %q: %d %s", username, pass_reply.code, pass_reply.text)
	}
	return check_reply(pass_reply, "PASS", {230, 202})
}

// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`: only the port is used. The
// address the server reports is often wrong behind a router, and the console
// is the host that was dialled anyway.
parse_pasv_port :: proc(text: string) -> (port: int, ok: bool) {
	open := strings.index_byte(text, '(')
	close := strings.index_byte(text, ')')
	if open < 0 || close < open do return 0, false
	parts := strings.split(text[open + 1:close], ",", context.temp_allocator)
	if len(parts) != 6 do return 0, false
	high, high_ok := strconv.parse_int(strings.trim_space(parts[4]))
	low, low_ok := strconv.parse_int(strings.trim_space(parts[5]))
	if !high_ok || !low_ok || high < 0 || high > 255 || low < 0 || low > 255 do return 0, false
	port = high * 256 + low
	return port, port > 0
}

// `229 Entering Extended Passive Mode (|||port|)`
parse_epsv_port :: proc(text: string) -> (port: int, ok: bool) {
	open := strings.index(text, "(|||")
	close := strings.index_byte(text, ')')
	if open < 0 || close < open do return 0, false
	number := strings.trim_right(text[open + 4:close], "|")
	port, ok = strconv.parse_int(number)
	return port, ok && port > 0
}

// PASV first (what these consoles' servers speak), EPSV if the server will not do it.
open_data_connection :: proc(connection: ^Connection, timeouts: Timeouts) -> (socket: net.TCP_Socket, error: Error) {
	port := 0
	pasv_reply, pasv_error := command_expect(connection, "PASV", {227}, timeouts)
	if pasv_error == nil {
		pasv_port, pasv_ok := parse_pasv_port(pasv_reply.text)
		if pasv_ok {
			port = pasv_port
		} else {
			pasv_error = fmt.tprintf("could not read a port from the PASV reply %q", pasv_reply.text)
		}
	}
	if port == 0 {
		epsv_reply, epsv_error := command_expect(connection, "EPSV", {229}, timeouts)
		epsv_port, epsv_ok := parse_epsv_port(epsv_reply.text)
		if epsv_error != nil || !epsv_ok {
			return {}, fmt.tprintf("the server accepts neither PASV (%s) nor EPSV (%s)",
				pasv_error, epsv_error.? or_else "unreadable reply")
		}
		port = epsv_port
	}
	endpoint := net.Endpoint{address = connection.address, port = port}
	data, dial_error := dial_with_timeout(endpoint, timeouts.connect)
	if dial_error != nil {
		return {}, fmt.tprintf("could not open the data connection to port %d: %s", port, dial_error)
	}
	return data, nil
}

get_endpoint :: proc(settings: Target_Settings) -> (endpoint: net.Endpoint, error: Error) {
	address, address_ok := net.parse_ip4_address(settings.hostname)
	if address_ok {
		return net.Endpoint{address = address, port = settings.port_number}, nil
	}
	resolved, resolve_error := net.resolve_ip4(settings.hostname)
	if resolve_error != nil {
		return {}, fmt.tprintf("cannot find host %q (%v)", settings.hostname, resolve_error)
	}
	resolved.port = settings.port_number
	return resolved, nil
}

// Connects, logs in, sets binary mode, changes into the target folder and STORs one file.
upload_file :: proc(
	settings: Target_Settings,
	target: Target,
	name: string,
	data: []byte,
	timeouts: Timeouts,
) -> (result: Upload_Result, error: Error) {
	started := time.tick_now()
	endpoint := get_endpoint(settings) or_return

	control, dial_error := dial_with_timeout(endpoint, timeouts.connect)
	if dial_error != nil {
		return {}, fmt.tprintf(
			"cannot connect to the %s's FTP server at %s:%d (%s). Switch the console's FTP server on first (it shuts off while an app runs)",
			get_target_name(target), settings.hostname, settings.port_number, dial_error,
		)
	}
	connection := Connection{control = control, address = endpoint.address}
	connection.pending.allocator = context.temp_allocator
	defer net.close(control)

	greeting := read_reply(&connection, "the connection greeting", timeouts.reply) or_return
	check_reply(greeting, "the connection greeting", {220}) or_return

	log_in(&connection, settings, timeouts) or_return
	command_expect(&connection, "TYPE I", {200}, timeouts) or_return
	folder := settings.folder_location
	_, cwd_error := command_expect(&connection, fmt.tprintf("CWD %s", folder), {250, 200}, timeouts)
	if cwd_error != nil {
		// The 3DS server (ftpd) roots its tree at the SD card, so `sdmc:/3ds` is "No such device" there and `/3ds` is
		// the same folder; the Vita server takes `ux0:downloads/` as written. Retry once without a `device:` prefix
		// instead of making the ini differ per server: the ini keeps the console's own name for the folder.
		colon := strings.index_byte(folder, ':')
		slash := strings.index_byte(folder, '/')
		has_device_prefix := colon > 0 && (slash < 0 || colon < slash)
		if !has_device_prefix do return {}, cwd_error
		rooted := folder[colon + 1:]
		if !strings.has_prefix(rooted, "/") do rooted = fmt.tprintf("/%s", rooted)
		command_expect(&connection, fmt.tprintf("CWD %s", rooted), {250, 200}, timeouts) or_return
		folder = rooted
	}

	data_socket := open_data_connection(&connection, timeouts) or_return
	data_open := true
	defer if data_open do net.close(data_socket)

	// 125 and 150 both mean "going ahead"; only the wording differs between servers.
	command_expect(&connection, fmt.tprintf("STOR %s", name), {150, 125}, timeouts) or_return

	_ = net.set_option(data_socket, .Send_Timeout, timeouts.transfer_reply)
	sent, send_error := net.send_tcp(data_socket, data)
	if send_error != nil || sent != len(data) {
		return {}, fmt.tprintf("the upload stopped after %d of %d bytes (%v)", sent, len(data), send_error)
	}
	// Closing the data connection is how FTP says "that was the whole file".
	net.close(data_socket)
	data_open = false

	done := read_reply(&connection, "the end of the upload", timeouts.transfer_reply) or_return
	check_reply(done, "the end of the upload", {226, 250}) or_return

	// The reply to QUIT does not matter: the file is already stored.
	if send_command(&connection, "QUIT", timeouts) == nil {
		_, _ = read_reply(&connection, "QUIT", timeouts.reply)
	}

	result.bytes = len(data)
	result.milliseconds = i64(time.duration_milliseconds(time.tick_since(started)))
	result.folder = folder
	return result, nil
}

// ---------------------------------------------------------------------------
// Command line

print_usage :: proc() {
	fmt.eprintln("usage: console_deploy [-target:3ds|vita] [-ini:<path>] <file> [<file> ...]")
	fmt.eprintln("  .3dsx files go to the New 3DS LL, .vpk files to the Vita. Switch the console's FTP server on first.")
}

fail :: proc(code: int, format: string, arguments: ..any) -> int {
	fmt.eprintf("console_deploy: ")
	fmt.eprintfln(format, ..arguments)
	return code
}

run :: proc(args: []string, timeouts := Timeouts{connect = 3 * time.Second, reply = 5 * time.Second, transfer_reply = 30 * time.Second}) -> int {
	ini_path := ""
	target_override: Maybe(Target)
	files: [dynamic]string
	files.allocator = context.temp_allocator

	for arg in args {
		switch {
		case arg == "-h" || arg == "-help" || arg == "--help":
			print_usage()
			return 0
		case strings.has_prefix(arg, "-ini:"):
			ini_path = arg[len("-ini:"):]
		case strings.has_prefix(arg, "-target:"):
			target, target_ok := get_target_from_name(arg[len("-target:"):])
			if !target_ok do return fail(2, "unknown target %q: use -target:3ds or -target:vita", arg[len("-target:"):])
			target_override = target
		case strings.has_prefix(arg, "-"):
			return fail(2, "unknown option %q (see -h)", arg)
		case:
			append(&files, arg)
		}
	}
	if len(files) == 0 {
		print_usage()
		return 2
	}
	if ini_path == "" do ini_path = get_default_ini_path()

	// Check every file before connecting to anything, so a typo in the last
	// name does not leave a half-finished deploy.
	targets := make([dynamic]Target, context.temp_allocator)
	contents := make([dynamic][]byte, context.temp_allocator)
	for path in files {
		target: Target
		if override, has_override := target_override.?; has_override {
			target = override
		} else {
			target_error: Error
			target, target_error = get_target_from_extension(path)
			if target_error != nil do return fail(2, "%s", target_error.?)
		}
		if !os.exists(path) do return fail(1, "file does not exist: %s", path)
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil do return fail(1, "cannot read %s (%v)", path, read_error)
		append(&targets, target)
		append(&contents, bytes)
	}

	values, ini_error := load_ini_values(ini_path)
	if ini_error != nil do return fail(2, "%s", ini_error.?)

	// Settings for every target in use are checked up front for the same reason.
	settings_for := [Target]Target_Settings{}
	for target in targets {
		settings, settings_error := get_target_settings(values, target, ini_path)
		if settings_error != nil do return fail(2, "%s", settings_error.?)
		settings_for[target] = settings
	}

	for path, index in files {
		target := targets[index]
		settings := settings_for[target]
		name := get_upload_name(path)
		result, upload_error := upload_file(settings, target, name, contents[index], timeouts)
		if upload_error != nil {
			skipped := len(files) - index - 1
			fmt.eprintfln("console_deploy: %s: %s", path, upload_error)
			if skipped > 0 do fmt.eprintfln("console_deploy: stopped; %d file(s) after it were not uploaded", skipped)
			return 1
		}
		folder := strings.trim_right(result.folder, "/")
		fmt.printfln("uploaded %s -> %s %s/%s (%d bytes, %d ms)",
			name, get_target_name(target), folder, name, result.bytes, result.milliseconds)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Tests. A throwaway FTP server on 127.0.0.1 stands in for the console, so
// nothing here ever reaches 10.0.0.126 or 10.0.0.209.

@(require) import "core:testing"
@(require) import "base:runtime"

when ODIN_TEST {

Fake_Server :: struct {
	listener:        net.TCP_Socket,
	port:            int,
	sessions:        int,  // connections to serve before the thread ends
	reject_login:    bool, // PASS answers 530
	refuse_pasv:     bool, // PASV answers 502
	refuse_epsv:     bool, // EPSV answers 502
	refuse_cwd:      bool, // CWD answers 550
	silent_greeting: bool, // accepts the connection and says nothing
	commands:        [dynamic]string,
	received:        [dynamic]u8,
}

start_fake_server :: proc(server: ^Fake_Server) -> ^thread.Thread {
	listener, error := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	assert(error == nil)
	endpoint, _ := net.bound_endpoint(listener)
	server.listener = listener
	server.port = endpoint.port
	return thread.create_and_start_with_poly_data(server, serve_fake_sessions)
}

stop_fake_server :: proc(server: ^Fake_Server, worker: ^thread.Thread) {
	thread.join(worker)
	thread.destroy(worker)
	net.close(server.listener)
}

free_fake_server :: proc(server: ^Fake_Server) {
	for command in server.commands do delete(command)
	delete(server.commands)
	delete(server.received)
}

fake_send :: proc(socket: net.TCP_Socket, line: string) {
	text := fmt.tprintf("%s\r\n", line)
	_, _ = net.send_tcp(socket, transmute([]u8)text)
}

serve_fake_sessions :: proc(server: ^Fake_Server) {
	context.allocator = runtime.heap_allocator()
	for _ in 0 ..< server.sessions {
		control, _, accept_error := net.accept_tcp(server.listener)
		if accept_error != nil do return
		serve_fake_session(server, control)
		net.close(control)
	}
}

serve_fake_session :: proc(server: ^Fake_Server, control: net.TCP_Socket) {
	pending: [dynamic]u8
	defer delete(pending)
	data_listener: net.TCP_Socket
	has_listener := false
	defer if has_listener do net.close(data_listener)

	if server.silent_greeting {
		time.sleep(2 * time.Second)
		return
	}
	fake_send(control, "220 fake ftp ready")
	for {
		line, status := read_line(control, &pending, 5 * time.Second)
		if status != .NONE do return
		append(&server.commands, strings.clone(line))
		verb, _, _ := strings.partition(line, " ")
		switch verb {
		case "USER":
			fake_send(control, "331 password please")
		case "PASS":
			fake_send(control, "530 login incorrect" if server.reject_login else "230 welcome")
		case "TYPE":
			fake_send(control, "200 type set")
		case "CWD":
			fake_send(control, "550 no such folder" if server.refuse_cwd else "250 ok")
		case "PASV", "EPSV":
			refused := server.refuse_pasv if verb == "PASV" else server.refuse_epsv
			if refused {
				fake_send(control, "502 not implemented")
				continue
			}
			if has_listener do net.close(data_listener)
			listener, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
			data_listener, has_listener = listener, true
			endpoint, _ := net.bound_endpoint(listener)
			if verb == "PASV" {
				fake_send(control, fmt.tprintf("227 Entering Passive Mode (127,0,0,1,%d,%d)", endpoint.port / 256, endpoint.port % 256))
			} else {
				fake_send(control, fmt.tprintf("229 Entering Extended Passive Mode (|||%d|)", endpoint.port))
			}
		case "STOR":
			data, _, _ := net.accept_tcp(data_listener)
			fake_send(control, "150 opening data connection")
			buffer: [4096]u8
			for {
				count, error := net.recv_tcp(data, buffer[:])
				if error != nil || count == 0 do break
				append(&server.received, ..buffer[:count])
			}
			net.close(data)
			fake_send(control, "226 transfer complete")
		case "QUIT":
			fake_send(control, "221 bye")
			return
		case:
			fake_send(control, "502 not implemented")
		}
	}
}

// Writes a settings file pointing both targets at the loopback server and returns its path.
write_test_ini :: proc(directory, file_name: string, port: int, extra: string = "") -> string {
	text := fmt.tprintf(
		"3ds_folder_loc = sdmc:/3ds\n3ds_protocol = ftp\n3ds_encryption = none\n3ds_hostname = 127.0.0.1\n3ds_port_number = %d\n" +
		"vita_folder_loc = ux0:downloads/\nvita_protocol = ftp\nvita_encryption = none\nvita_hostname = 127.0.0.1\nvita_port_number = %d\n%s",
		port, port, extra,
	)
	path := fmt.tprintf("%s/%s", directory, file_name)
	assert(os.write_entire_file(path, text) == nil)
	return path
}

make_test_directory :: proc(label: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	path, error := os.make_directory_temp(base, fmt.tprintf("console_deploy_%s_*", label), context.temp_allocator)
	assert(error == nil)
	return path
}

write_test_file :: proc(directory, name: string, count: int) -> (path: string, payload: []byte) {
	// Every byte value occurs, so a text-mode or truncated transfer would show.
	payload = make([]byte, count, context.temp_allocator)
	for index in 0 ..< count do payload[index] = u8((index * 31 + index / 251) % 256)
	path = fmt.tprintf("%s/%s", directory, name)
	assert(os.write_entire_file(path, payload) == nil)
	return
}

text_of :: proc(error: Error) -> string {
	return error.? or_else ""
}

slice_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for value, index in a {
		if value != b[index] do return false
	}
	return true
}

@(test)
test_ini_both_targets_comments_whitespace :: proc(t: ^testing.T) {
	text := "# a comment\n; another\n\n  3ds_hostname =  10.0.0.126  \r\n3DS_Port_Number=5000\nvita_hostname = h\n3ds_password = pa#ss\n"
	values := make(map[string]string, context.temp_allocator)
	error := parse_ini_text(text, "test.ini", &values)
	testing.expect(t, error == nil, text_of(error))
	testing.expect_value(t, values["3ds_hostname"], "10.0.0.126")
	testing.expect_value(t, values["3ds_port_number"], "5000")
	testing.expect_value(t, values["vita_hostname"], "h")
	testing.expect_value(t, values["3ds_password"], "pa#ss")
}

@(test)
test_ini_unknown_key_and_bad_line :: proc(t: ^testing.T) {
	values := make(map[string]string, context.temp_allocator)
	error := parse_ini_text("3ds_hostnme = x\n", "test.ini", &values)
	testing.expect(t, strings.contains(text_of(error), "unknown key"), text_of(error))
	testing.expect(t, strings.contains(text_of(error), "line 1"), text_of(error))
	error = parse_ini_text("\n\njust words\n", "test.ini", &values)
	testing.expect(t, strings.contains(text_of(error), "line 3"), text_of(error))
}

@(test)
test_shipped_ini_has_both_targets :: proc(t: ^testing.T) {
	// `odin test` runs from the folder it was started in; try the repo root, then tools/.
	values, error := load_ini_values("tools/console_deploy.ini")
	if error != nil do values, error = load_ini_values("console_deploy.ini")
	testing.expect(t, error == nil, text_of(error))
	three_ds, three_error := get_target_settings(values, .NINTENDO_3DS, "console_deploy.ini")
	testing.expect(t, three_error == nil, text_of(three_error))
	testing.expect_value(t, three_ds.hostname, "10.0.0.126")
	testing.expect_value(t, three_ds.port_number, 5000)
	testing.expect_value(t, three_ds.folder_location, "sdmc:/3ds")
	testing.expect_value(t, three_ds.username, "")
	vita, vita_error := get_target_settings(values, .PS_VITA, "console_deploy.ini")
	testing.expect(t, vita_error == nil, text_of(vita_error))
	testing.expect_value(t, vita.hostname, "10.0.0.209")
	testing.expect_value(t, vita.port_number, 1337)
	testing.expect_value(t, vita.folder_location, "ux0:downloads/")
}

@(test)
test_missing_key_and_unsupported_settings :: proc(t: ^testing.T) {
	values := make(map[string]string, context.temp_allocator)
	_ = parse_ini_text("vita_folder_loc = f\nvita_protocol = ftp\nvita_encryption = none\nvita_port_number = 1337\n", "x.ini", &values)
	_, error := get_target_settings(values, .PS_VITA, "x.ini")
	testing.expect_value(t, text_of(error), "missing key vita_hostname in x.ini")

	values["vita_hostname"] = "h"
	values["vita_protocol"] = "sftp"
	_, error = get_target_settings(values, .PS_VITA, "x.ini")
	testing.expect(t, strings.contains(text_of(error), "not supported yet"), text_of(error))
	values["vita_protocol"] = "ftp"
	values["vita_encryption"] = "tls"
	_, error = get_target_settings(values, .PS_VITA, "x.ini")
	testing.expect(t, strings.contains(text_of(error), "not supported yet"), text_of(error))
	values["vita_encryption"] = "none"
	values["vita_port_number"] = "70000"
	_, error = get_target_settings(values, .PS_VITA, "x.ini")
	testing.expect(t, strings.contains(text_of(error), "not a port number"), text_of(error))
}

@(test)
test_target_from_extension :: proc(t: ^testing.T) {
	target, error := get_target_from_extension("build/hardware/a.3dsx")
	testing.expect(t, target == .NINTENDO_3DS && error == nil)
	target, error = get_target_from_extension("C:\\x\\A.VPK")
	testing.expect(t, target == .PS_VITA && error == nil)
	_, error = get_target_from_extension("a.elf")
	testing.expect(t, strings.contains(text_of(error), ".elf"), text_of(error))
	_, error = get_target_from_extension("noextension")
	testing.expect(t, strings.contains(text_of(error), "(none)"), text_of(error))
}

@(test)
test_upload_name_cannot_leave_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, get_upload_name("build\\hardware\\a.vpk"), "a.vpk")
	testing.expect_value(t, get_upload_name("../../x/a.3dsx"), "a.3dsx")
	testing.expect_value(t, get_upload_name("a.vpk"), "a.vpk")
}

@(test)
test_passive_reply_parsing :: proc(t: ^testing.T) {
	port, ok := parse_pasv_port("227 Entering Passive Mode (10,0,0,126,19,136)")
	testing.expect(t, ok && port == 5000)
	_, ok = parse_pasv_port("227 nonsense")
	testing.expect(t, !ok)
	port, ok = parse_epsv_port("229 Entering Extended Passive Mode (|||6446|)")
	testing.expect(t, ok && port == 6446)
}

@(test)
test_upload_bytes_arrive_identical :: proc(t: ^testing.T) {
	directory := make_test_directory("ok")
	defer os.remove_all(directory)
	file_path, payload := write_test_file(directory, "game.3dsx", 300_001)

	server := Fake_Server{sessions = 1}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 0)
	testing.expect_value(t, len(server.received), len(payload))
	testing.expect(t, slice_equal(server.received[:], payload), "received bytes differ from the file")
	// anonymous login, binary mode, then the configured folder, then the bare name
	testing.expect_value(t, len(server.commands), 7)
	if len(server.commands) == 7 {
		testing.expect_value(t, server.commands[0], "USER anonymous")
		testing.expect_value(t, server.commands[1], "PASS anonymous@")
		testing.expect_value(t, server.commands[2], "TYPE I")
		testing.expect_value(t, server.commands[3], "CWD sdmc:/3ds")
		testing.expect_value(t, server.commands[4], "PASV")
		testing.expect_value(t, server.commands[5], "STOR game.3dsx")
		testing.expect_value(t, server.commands[6], "QUIT")
	}
	for command in server.commands {
		testing.expect(t, !strings.has_prefix(command, "DELE") && !strings.has_prefix(command, "RMD"), command)
	}
}

@(test)
test_vita_target_and_username_login :: proc(t: ^testing.T) {
	directory := make_test_directory("vita")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "game.vpk", 1000)

	server := Fake_Server{sessions = 1}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port, "vita_username = me\nvita_password = s3cret\n")
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 0)
	testing.expect_value(t, len(server.received), 1000)
	if len(server.commands) >= 4 {
		testing.expect_value(t, server.commands[0], "USER me")
		testing.expect_value(t, server.commands[1], "PASS s3cret")
		testing.expect_value(t, server.commands[3], "CWD ux0:downloads/")
	}
}

@(test)
test_target_override_beats_extension :: proc(t: ^testing.T) {
	directory := make_test_directory("override")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "thing.bin", 50)

	server := Fake_Server{sessions = 1}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), "-target:vita", file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 0)
	testing.expect_value(t, len(server.received), 50)
	if len(server.commands) >= 4 do testing.expect_value(t, server.commands[3], "CWD ux0:downloads/")
}

@(test)
test_local_ini_overrides_main :: proc(t: ^testing.T) {
	directory := make_test_directory("local")
	defer os.remove_all(directory)
	main_path := write_test_ini(directory, "c.ini", 1)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", directory, "c.local.ini"), "3ds_password = secret\n3ds_port_number = 2\n")
	values, error := load_ini_values(main_path)
	testing.expect(t, error == nil, text_of(error))
	testing.expect_value(t, values["3ds_password"], "secret")
	testing.expect_value(t, values["3ds_port_number"], "2")
	testing.expect_value(t, values["vita_port_number"], "1")
}

@(test)
test_epsv_fallback_when_pasv_refused :: proc(t: ^testing.T) {
	directory := make_test_directory("epsv")
	defer os.remove_all(directory)
	file_path, payload := write_test_file(directory, "a.vpk", 5000)

	server := Fake_Server{sessions = 1, refuse_pasv = true}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 0)
	testing.expect(t, slice_equal(server.received[:], payload), "received bytes differ from the file")
	if len(server.commands) >= 6 {
		testing.expect_value(t, server.commands[4], "PASV")
		testing.expect_value(t, server.commands[5], "EPSV")
	}
}

@(test)
test_failure_when_neither_pasv_nor_epsv :: proc(t: ^testing.T) {
	directory := make_test_directory("nopasv")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.vpk", 10)

	server := Fake_Server{sessions = 1, refuse_pasv = true, refuse_epsv = true}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 1)
	testing.expect_value(t, len(server.received), 0)
}

@(test)
test_refused_login :: proc(t: ^testing.T) {
	directory := make_test_directory("login")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.3dsx", 10)

	server := Fake_Server{sessions = 1, reject_login = true}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 1)
	testing.expect_value(t, len(server.received), 0)
	for command in server.commands {
		testing.expect(t, !strings.has_prefix(command, "STOR"), command)
	}
}

@(test)
test_refused_folder_stores_nothing :: proc(t: ^testing.T) {
	directory := make_test_directory("cwd")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.3dsx", 10)

	server := Fake_Server{sessions = 1, refuse_cwd = true}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 1)
	testing.expect_value(t, len(server.received), 0)
}

@(test)
test_server_down_fails_fast :: proc(t: ^testing.T) {
	directory := make_test_directory("down")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.3dsx", 10)

	// Bind to learn a free port, then close it so nothing listens there.
	listener, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	endpoint, _ := net.bound_endpoint(listener)
	net.close(listener)
	ini := write_test_ini(directory, "c.ini", endpoint.port)

	started := time.tick_now()
	code := run({fmt.tprintf("-ini:%s", ini), file_path})
	elapsed := time.tick_since(started)
	testing.expect_value(t, code, 1)
	testing.expectf(t, elapsed < 5 * time.Second, "took %v", elapsed)
}

@(test)
test_silent_server_times_out :: proc(t: ^testing.T) {
	directory := make_test_directory("silent")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.3dsx", 10)

	server := Fake_Server{sessions = 1, silent_greeting = true}
	worker := start_fake_server(&server)
	ini := write_test_ini(directory, "c.ini", server.port)
	started := time.tick_now()
	code := run({fmt.tprintf("-ini:%s", ini), file_path}, Timeouts{connect = time.Second, reply = 300 * time.Millisecond, transfer_reply = time.Second})
	elapsed := time.tick_since(started)
	stop_fake_server(&server, worker)
	defer free_fake_server(&server)

	testing.expect_value(t, code, 1)
	testing.expectf(t, elapsed < 1500 * time.Millisecond, "took %v", elapsed)
}

@(test)
test_non_ftp_protocol_refused_before_connecting :: proc(t: ^testing.T) {
	directory := make_test_directory("sftp")
	defer os.remove_all(directory)
	file_path, _ := write_test_file(directory, "a.3dsx", 10)
	// the main ini says ftp; the local override flips one key
	ini := write_test_ini(directory, "c.ini", 1)
	local := fmt.tprintf("%s/%s", directory, "c.local.ini")
	_ = os.write_entire_file(local, "3ds_protocol = sftp\n")
	testing.expect_value(t, run({fmt.tprintf("-ini:%s", ini), file_path}), 2)
	_ = os.write_entire_file(local, "3ds_encryption = tls\n")
	testing.expect_value(t, run({fmt.tprintf("-ini:%s", ini), file_path}), 2)
}

@(test)
test_command_line_errors :: proc(t: ^testing.T) {
	directory := make_test_directory("args")
	defer os.remove_all(directory)
	ini := write_test_ini(directory, "c.ini", 1)
	ini_argument := fmt.tprintf("-ini:%s", ini)
	elf_path, _ := write_test_file(directory, "a.elf", 10)
	missing := fmt.tprintf("%s/%s", directory, "missing.3dsx")

	testing.expect_value(t, run({}), 2)                                        // no files
	testing.expect_value(t, run({ini_argument, elf_path}), 2)                  // unknown extension
	testing.expect_value(t, run({ini_argument, "-target:psp", elf_path}), 2)   // unknown target
	testing.expect_value(t, run({ini_argument, "-wat"}), 2)                    // unknown option
	testing.expect_value(t, run({ini_argument, missing}), 1)                   // file does not exist
	testing.expect_value(t, run({"-ini:nowhere.ini", "-target:vita", elf_path}), 2) // no settings file
}

}
