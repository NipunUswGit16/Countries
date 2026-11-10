package main

// ⚠️ WARNING: DO NOT DELETE THIS DIRECTIVE
// This directive tells kairos-gen to copy SQL files from the event-handler library.
// Removing it will break SQL generation and loaders.
// +kairos:sql:lib:bitbucket.org/ifs-pd/kairos-component-common/event-handler

import (
	"bitbucket.org/ifs-pd/kairos-component-common/common"
	eventhandlerCommon "bitbucket.org/ifs-pd/kairos-component-common/event-handler"
	"bitbucket.org/ifs-pd/kairos-component-common/event-handler/config"
	eventhandler "bitbucket.org/ifs-pd/countries/internal/event-handler"
	ehconfig "bitbucket.org/ifs-pd/countries/internal/event-handler/config"
	"bitbucket.org/ifs-pd/countries/internal/event-handler/request"
)

const serviceId = "event-handler"

func main() {
	servicesFactory := &request.ServicesFactory{}

	deps, err := common.CreateDefaultDependencies[
		request.ServicesFactory,
		config.Config,
		*config.Config,
		ehconfig.AppConfig,
	](serviceId, servicesFactory)
	if err != nil {
		panic(err)
	}

	eh := eventhandlerCommon.NewWithDependencies(deps)
	defer eh.Close()

	eventhandler.InitHandlers(eh)

	eh.Start()

	eh.Logger().Info().Msg("event handler stopped")
}
