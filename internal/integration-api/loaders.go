package api

import (
	"bitbucket.org/ifs-pd/countries/internal/integration-api/loaders/generated"
	integrationapi "bitbucket.org/ifs-pd/kairos-component-common/api/integration"
)

// RegisterLoaders registers the loaders for the integration API
func RegisterLoaders(apiInstance integrationapi.LoaderRegistryProvider) {
	registry := apiInstance.LoaderRegistry()

	generated.RegisterLoaders(registry)
}
