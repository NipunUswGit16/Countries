package request

import (
	"testing"

	apicontext "bitbucket.org/ifs-pd/kairos-component-common/api/context"
	"bitbucket.org/ifs-pd/countries/internal/integration-api/config"
)

func TestContext(t *testing.T) {
	var _ apicontext.Context[ServicesFactory, config.AppConfig]
}
