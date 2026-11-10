package eventhandler

import (
	eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/config"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/request"
)

func InitHandlers(eh eventhandler.GenericEventHandler[request.ServicesFactory, config.AppConfig, *config.AppConfig]) {
	_ = eh
}
