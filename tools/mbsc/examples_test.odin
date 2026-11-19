package mbsc

import "core:strings"
import "core:testing"

// The shaders that ship with the engine and its examples must always check cleanly, on every target.

@(private = "file")
Example :: struct {
	name:   string,
	source: string,
}

@(private = "file")
examples := [?]Example {
	{"matchbox/shaders/mesh.mbs", #load("../../matchbox/shaders/mesh.mbs", string)},
	{"examples/shader-language/hit_flash.mbs", #load("../../examples/shader-language/hit_flash.mbs", string)},
}

@(test)
the_shipped_shaders_check_cleanly_on_every_target :: proc(t: ^testing.T) {
	for example in examples {
		for target in Target {
			defer free_all(context.temp_allocator)

			source, _ := strings.replace_all(example.source, "\r\n", "\n", context.temp_allocator)
			parsed := parse_shader(example.name, source)
			defer destroy_parsed(parsed)
			if parsed.has_syntax_errors == false {
				check_subset(parsed)
				if len(parsed.diagnostics) == 0 {
					module := build_module(parsed, target)
					if len(parsed.diagnostics) == 0 {
						lower_module(module)
					}
				}
			}

			if len(parsed.diagnostics) > 0 {
				text := render_errors(parsed, example.name)
				defer delete(text)
				testing.expectf(t, false, "%s for %v:\n%s", example.name, target, text)
			}
		}
	}
}
