package eventhandler

import (
	"testing"

	eventhandlertest "bitbucket.org/ifs-pd/kairos-component-common/event-handler/test"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/config"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/request"
	"github.com/stretchr/testify/assert"
)

func TestInitHandlers(t *testing.T) {
	testEh := eventhandlertest.New("test-component", &request.ServicesFactory{}, &config.AppConfig{})
	defer testEh.Close()

	assert.NotPanics(t, func() {
		InitHandlers(testEh)
	})
}
