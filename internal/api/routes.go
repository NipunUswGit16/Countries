package api

import (
	endpoints "bitbucket.org/ifs-pd/countries/internal/api/endpoints/v1"
	"bitbucket.org/ifs-pd/kairos-component-common/api"

	"github.com/gofiber/fiber/v2"
)

// InitRoutes initializes the routes for the API
func InitRoutes(router fiber.Router) {

	v1 := router.Group("/v1")

	countryRoutes := v1.Group("/countries")
	{
		countryRoutes.Get("/", api.Handler(endpoints.GetAllCountries))
		countryRoutes.Post("/", api.Handler(endpoints.CreateCountry))
		countryRoutes.Get("/:id", api.Handler(endpoints.GetCountryById))
		countryRoutes.Put("/:id", api.Handler(endpoints.UpdateCountryById))
		countryRoutes.Delete("/:id", api.Handler(endpoints.DeleteCountryById))
	}
}
