package country

import (
	"context"

	"bitbucket.org/ifs-pd/countries/internal/domain"
	"bitbucket.org/ifs-pd/countries/internal/dto"
	"bitbucket.org/ifs-pd/countries/internal/repositories"
	"bitbucket.org/ifs-pd/countries/internal/services"
	"bitbucket.org/ifs-pd/nga-common/logging"
)

type CountryService struct {
	repo      repositories.CountryRepositoryInterface
	messenger services.OutboundMessenger
	logger    logging.Logger
}

func NewCountryService(
	repo repositories.CountryRepositoryInterface,
	messenger services.OutboundMessenger,
	logger logging.Logger,
) *CountryService {
	return &CountryService{
		repo:      repo,
		messenger: messenger,
		logger:    logger,
	}
}

func (s *CountryService) GetAllCountries(
	ctx context.Context,
	filter domain.PaginationFilter,
) ([]domain.Country, dto.Pagination, error) {

	results, total, err := s.repo.GetAll(ctx, filter)
	if err != nil {
		return nil, dto.Pagination{}, err
	}

	return results, dto.Pagination{
		Page:  filter.Page,
		Limit: filter.Limit,
		Total: total,
	}, nil
}

func (s *CountryService) GetCountryById(
	ctx context.Context,
	id string,
) (domain.Country, error) {
	return s.repo.GetByCountryID(ctx, id)
}

func (s *CountryService) CreateCountry(
	ctx context.Context,
	country domain.Country,
) (domain.Country, error) {
	return s.repo.Create(ctx, country)
}

func (s *CountryService) UpdateCountryById(
	ctx context.Context,
	id string,
	country domain.Country,
) (domain.Country, error) {
	return s.repo.Update(ctx, id, country)
}

func (s *CountryService) DeleteCountryById(
	ctx context.Context,
	id string,
) error {
	return s.repo.Delete(ctx, id)
}
