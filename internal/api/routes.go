package api

import (
	"github.com/gofiber/fiber/v2"
)

// InitRoutes initializes the routes for the API
func InitRoutes(router fiber.Router) {
	v1Group := router.Group("/v1")
	_ = v1Group
}
