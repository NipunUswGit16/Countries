package request

import (
	"bitbucket.org/ifs-pd/countries/internal/integration-api/config"
	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
)

// Context is the request context type for integration API handlers
type Context = apicontext.Context[ServicesFactory, config.AppConfig]
