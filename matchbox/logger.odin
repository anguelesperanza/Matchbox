package matchbox

import "core:log"


get_logger :: proc() -> log.Logger {
	return mbi.logger
}
