package gpu

/*
	report_vk.odin
	--------------

	Why this machine could not start the renderer, written down.

	When a game fails to open on somebody else's computer, the only evidence is
	whatever it manages to say before it stops. A person who has been handed a
	copy is not going to run it from a terminal, read a log level, or know what
	an extension is -- so everything worth knowing is collected here and handed
	to the caller as one block of text to put in a file they can send back.

	Collected as the checks happen rather than gathered afterwards, because by
	the time init has failed the Vulkan objects needed to ask again may be gone.
*/

import "core:fmt"
import "core:log"
import "core:strings"

import vk "vendor:vulkan"

@(private)
report: strings.Builder

@(private)
report_started: bool

@(private)
report_line :: proc(format:string, args:..any) {
	if !report_started {
		report = strings.builder_make()
		report_started = true
	}
	fmt.sbprintfln(&report, format, ..args)
}

/*
	Everything noticed while starting up, as text.

	Empty when nothing had anything to say, which is the normal case on a
	machine where the renderer came up.
*/
startup_report :: proc() -> string {
	if !report_started do return ""
	return strings.to_string(report)
}

/*
	What a device has to support before it is worth considering.

	One list, asked by both the "can this device serve" check and the device
	creation that follows it. Two lists would eventually disagree, and the
	symptom of that is a device passing selection and then failing to be
	created, which reads as a driver bug rather than as ours.
*/
@(private)
required_device_extensions :: proc(allocator := context.allocator) -> []cstring {
	out := make([dynamic]cstring, allocator = allocator)

	append(&out, cstring(vk.KHR_SWAPCHAIN_EXTENSION_NAME))
	append(&out, cstring(vk.EXT_SHADER_OBJECT_EXTENSION_NAME))
	for extra in EXTRA_DEVICE_EXTENSIONS do append(&out, extra)

	return out[:]
}

@(private)
device_has_extension :: proc(device:vk.PhysicalDevice, name:cstring) -> bool {
	scratch, _ := acquire_scratch()

	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	available := make([]vk.ExtensionProperties, count, allocator = scratch)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available))

	for &one in available {
		if name == cstring(&one.extensionName[0]) do return true
	}
	return false
}

/*Whether this device can serve, asked before it is scored against the others*/
@(private)
device_meets_requirements :: proc(device:vk.PhysicalDevice) -> bool {
	scratch, _ := acquire_scratch()

	for required in required_device_extensions(scratch) {
		if !device_has_extension(device, required) do return false
	}
	return true
}

/*
	Writes down every device on the machine and what each is missing.

	Runs whether or not startup goes on to succeed: the cost is one enumeration
	of extensions per device, and having the note already written is what makes
	a failure further along explainable.
*/
@(private)
record_devices :: proc(devices:[]vk.PhysicalDevice) {
	scratch, _ := acquire_scratch()
	required := required_device_extensions(scratch)

	report_line("graphics devices found: %d", len(devices))

	for device, i in devices {
		properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
		vk.GetPhysicalDeviceProperties2(device, &properties)
		p := properties.properties

		report_line("")
		report_line("  [%d] %s", i, cstring(&p.deviceName[0]))
		report_line("      type            %v", p.deviceType)
		report_line("      vendor id       0x%04x", p.vendorID)
		report_line("      device id       0x%04x", p.deviceID)
		report_line("      driver version  %d.%d.%d",
			(p.driverVersion >> 22) & 0x3ff, (p.driverVersion >> 12) & 0x3ff, p.driverVersion & 0xfff)
		report_line("      vulkan          %d.%d.%d",
			p.apiVersion >> 22, (p.apiVersion >> 12) & 0x3ff, p.apiVersion & 0xfff)

		missing := 0
		for name in required {
			if device_has_extension(device, name) do continue

			report_line("      MISSING         %s", name)
			missing += 1
		}

		if missing == 0 {
			report_line("      has everything this renderer requires")
		} else {
			report_line("      cannot run the game: %d required extension(s) absent", missing)
		}
	}
}

/*
	The last word when nothing on the machine could serve.

	Says what to do about it as well as what happened, because the person
	reading this file is more likely to be the one who was sent the game than
	the one who wrote it.
*/
@(private)
report_no_usable_device :: proc(loc := #caller_location) {
	report_line("")
	report_line("None of the devices above can run this renderer.")
	report_line("")
	report_line("Most often this is a graphics driver that is out of date -- installing the")
	report_line("newest one from the GPU maker's own site, rather than through Windows Update,")
	report_line("fixes the majority of these.")
	report_line("")
	report_line("If a MISSING line above names VK_EXT_shader_object, that extension is fairly")
	report_line("new and some drivers still do not provide it. A current driver usually does.")
	report_line("Installing the Vulkan SDK also supplies an emulation layer that stands in for")
	report_line("it, which is worth trying to confirm the diagnosis.")

	log_report(loc)
}

/*Also to the log, for anybody who did start the game from a terminal*/
@(private)
log_report :: proc(loc := #caller_location) {
	rest := startup_report()
	for line in strings.split_lines_iterator(&rest) {
		log.error(line, location = loc)
	}
}
