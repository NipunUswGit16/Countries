package dto

import (
	"time"

	"bitbucket.org/ifs-pd/countries/internal/domain"
)

type CountryResponse struct {
	CountryId string `json:"countryId"`
	Name      string `json:"name"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

func NewCountryResponse(country domain.Country) CountryResponse {
	return CountryResponse{
		CountryId: country.CountryId,
		Name:      country.Name,
		CreatedAt: country.CreatedAt.Format(time.RFC3339),
		UpdatedAt: country.UpdatedAt.Format(time.RFC3339),
	}
}
