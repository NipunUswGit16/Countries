package request

import (
	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
	"bitbucket.org/ifs-pd/countries/internal/api/config"
)

type Context = apicontext.Context[ServicesFactory, config.AppConfig]
