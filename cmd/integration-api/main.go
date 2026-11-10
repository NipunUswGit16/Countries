package main

// ⚠️ WARNING: DO NOT DELETE THIS DIRECTIVE
// This directive tells kairos-gen to copy SQL files from the event-outbox library.
// Removing it will break SQL generation and migrations.
// +kairos:sql:lib:bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender

import (
	integrationapi "bitbucket.org/ifs-pd/kairos-component-common/api/integration"
	api "bitbucket.org/ifs-pd/countries/internal/integration-api"
	"bitbucket.org/ifs-pd/countries/internal/integration-api/config"
	"bitbucket.org/ifs-pd/countries/internal/integration-api/request"
)

const serviceId = "integration-api"

func main() {
	servicesFactory := &request.ServicesFactory{}

	apiInstance, _ := integrationapi.New[request.ServicesFactory, config.AppConfig](serviceId, servicesFactory)
	router := apiInstance.ApiRouter()

	// Register Loaders
	api.RegisterLoaders(apiInstance)

	//Initialize routes
	api.InitRoutes(router)

	//Block until the server is stopped
	apiInstance.Start()

	apiInstance.Logger().Info().Msg("app stopped")
}
