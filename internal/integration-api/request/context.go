package request

import (
	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
	"bitbucket.org/ifs-pd/countries/internal/integration-api/config"
)

// Context is the request context type for integration API handlers
type Context = apicontext.Context[ServicesFactory, config.AppConfig]
