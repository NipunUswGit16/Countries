package main

// ⚠️ WARNING: DO NOT DELETE THIS DIRECTIVE
// This directive tells kairos-gen to copy SQL files from the event-outbox library.
// Removing it will break SQL generation and loaders.
// +kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender

import (
	commonapi "bitbucket.org/ifs-pd/kairos-component-common/api"
	"bitbucket.org/ifs-pd/countries/internal/api"
	"bitbucket.org/ifs-pd/countries/internal/api/config"
	"bitbucket.org/ifs-pd/countries/internal/api/request"
)

const serviceId = "client-api"

func main() {
	servicesFactory := &request.ServicesFactory{}

	apiInstance, _ := commonapi.New[request.ServicesFactory, config.AppConfig](serviceId, servicesFactory)
	router := apiInstance.ApiRouter()

	//Initialize routes
	api.InitRoutes(router)

	//Block until the server is stopped
	apiInstance.Start()

	apiInstance.Logger().Info().Msg("app stopped")
}
