package request

import (
	"bitbucket.org/ifs-pd/countries/internal/repositories"
	"bitbucket.org/ifs-pd/countries/internal/services"
	countryservice "bitbucket.org/ifs-pd/countries/internal/services/country"
	"bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
)

type ServicesFactory struct{}

func (f ServicesFactory) CreateCountryService(
	ctx Context,
	session interfaces.Session,
) *countryservice.CountryService {

	repo := repositories.NewCountryRepository(session)

	return countryservice.NewCountryService(
		repo,
		services.NewSenderAdapter(ctx.Sender()),
		ctx.Logger(),
	)
}
