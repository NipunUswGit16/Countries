package eventhandler

import (
	"bitbucket.org/ifs-pd/countries/internal/event-handler/config"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/request"
	eventhandler "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
)

func InitHandlers(eh eventhandler.GenericEventHandler[request.ServicesFactory, config.AppConfig, *config.AppConfig]) {
	_ = eh
}
