#+build windows

package matchbox

import "core:testing"

@(test)
log_levels_are_tagged_by_how_serious_they_are :: proc(t: ^testing.T) {
	testing.expect_value(t, get_log_level_tag(.Debug), "[DEBUG]")
	testing.expect_value(t, get_log_level_tag(.Info), "[INFO]")
	testing.expect_value(t, get_log_level_tag(.Warning), "[WARN]")
	testing.expect_value(t, get_log_level_tag(.Error), "[ERROR]")
	testing.expect_value(t, get_log_level_tag(.Fatal), "[FATAL]")
}
