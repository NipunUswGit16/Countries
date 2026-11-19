package request

import (
	"bitbucket.org/ifs-pd/countries/internal/event-handler/config"
	ehcontext "bitbucket.org/ifs-pd/kairos-component-common/event-handler/context"
)

// Context is an alias to the event handler request contex.
type Context = ehcontext.Context[ServicesFactory, config.AppConfig]
