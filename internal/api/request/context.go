package request

import (
	"bitbucket.org/ifs-pd/countries/internal/api/config"
	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
)

type Context = apicontext.Context[ServicesFactory, config.AppConfig]
