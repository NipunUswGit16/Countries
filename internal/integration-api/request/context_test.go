package request

import (
	"testing"

	"bitbucket.org/ifs-pd/countries/internal/integration-api/config"
	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
)

func TestContext(t *testing.T) {
	var _ apicontext.Context[ServicesFactory, config.AppConfig]
}
