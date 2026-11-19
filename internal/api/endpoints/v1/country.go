package endpoints

import (
	"context"
	"errors"

	"bitbucket.org/ifs-pd/countries/internal/api/dto"
	"bitbucket.org/ifs-pd/countries/internal/api/request"
	"bitbucket.org/ifs-pd/countries/internal/domain"
	shareddto "bitbucket.org/ifs-pd/countries/internal/dto"

	"bitbucket.org/ifs-pd/kairos-component-common/common/entities"
	"github.com/gofiber/fiber/v2"
)

func CreateCountry(ctx request.Context) error {

	logger := ctx.Logger()

	db, err := ctx.DatabaseSession()
	if err != nil {
		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get database session",
			err,
		)
	}
	defer db.Close()

	req, err := ctx.ParseBody[dto.CountryCreateRequest]()
	if err != nil {
		return err
	}

	service := ctx.ServicesFactory().CreateCountryService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(
		ctx.Context(),
		ctx.Config().DomainChangeTimeout,
	)
	defer cancel()

	country := domain.Country{
		EntityBase: entities.NewEntityBase(
			entities.NewId(),
			entities.NewETag(),
		),
		CountryId: req.CountryId,
		Name:      req.Name,
	}

	createdCountry, err := service.CreateCountry(
		ctxTimeout,
		country,
	)

	if err != nil {
		logger.Error().Err(err).Msg("Failed to create country")

		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to create country",
			err,
		)
	}

	return ctx.SuccessResponse(
		dto.NewCountryResponse(createdCountry),
		"Country created successfully",
	)
}

func GetAllCountries(ctx request.Context) error {

	logger := ctx.Logger()

	db, err := ctx.DatabaseSession()
	if err != nil {
		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get database session",
			err,
		)
	}
	defer db.Close()

	page := ctx.QueryInt("page", 1)
	limit := ctx.QueryInt("limit", 10)

	if page < 1 {
		page = 1
	}

	if limit < 1 || limit > 100 {
		limit = 10
	}

	filter := domain.PaginationFilter{
		Page:  int64(page),
		Limit: int64(limit),
		Skip:  int64((page - 1) * limit),
	}

	service := ctx.ServicesFactory().CreateCountryService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(
		ctx.Context(),
		ctx.Config().DomainChangeTimeout,
	)
	defer cancel()

	countries, pagination, err := service.GetAllCountries(
		ctxTimeout,
		filter,
	)

	if err != nil {
		logger.Error().Err(err).Msg("Failed to get countries")

		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get countries",
			err,
		)
	}

	response := make(
		[]dto.CountryResponse,
		len(countries),
	)

	for i, country := range countries {
		response[i] = dto.NewCountryResponse(country)
	}

	return ctx.SuccessResponse(
		shareddto.PaginatedResponse[dto.CountryResponse]{
			Data:       response,
			Pagination: pagination,
		},
		"Countries fetched successfully",
	)
}

func GetCountryById(ctx request.Context) error {

	logger := ctx.Logger()

	id := ctx.Params("id")
	if id == "" {
		return ctx.ErrorResponse(
			fiber.StatusBadRequest,
			"id is required",
			errors.New("id is required"),
		)
	}

	db, err := ctx.DatabaseSession()
	if err != nil {
		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get database session",
			err,
		)
	}
	defer db.Close()

	service := ctx.ServicesFactory().CreateCountryService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(
		ctx.Context(),
		ctx.Config().DomainChangeTimeout,
	)
	defer cancel()

	country, err := service.GetCountryById(
		ctxTimeout,
		id,
	)

	if err != nil {
		logger.Error().Err(err).Msg("Failed to get country")

		return ctx.ErrorResponse(
			fiber.StatusNotFound,
			"Country not found",
			err,
		)
	}

	return ctx.SuccessResponse(
		dto.NewCountryResponse(country),
		"Country fetched successfully",
	)
}

func UpdateCountryById(ctx request.Context) error {

	logger := ctx.Logger()

	id := ctx.Params("id")
	if id == "" {
		return ctx.ErrorResponse(
			fiber.StatusBadRequest,
			"id is required",
			errors.New("id is required"),
		)
	}

	db, err := ctx.DatabaseSession()
	if err != nil {
		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get database session",
			err,
		)
	}
	defer db.Close()

	req, err := ctx.ParseBody[dto.CountryUpdateRequest]()
	if err != nil {
		return err
	}

	service := ctx.ServicesFactory().CreateCountryService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(
		ctx.Context(),
		ctx.Config().DomainChangeTimeout,
	)
	defer cancel()

	country := domain.Country{
		Name: req.Name,
	}

	updatedCountry, err := service.UpdateCountryById(
		ctxTimeout,
		id,
		country,
	)

	if err != nil {
		logger.Error().Err(err).Msg("Failed to update country")

		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to update country",
			err,
		)
	}

	return ctx.SuccessResponse(
		dto.NewCountryResponse(updatedCountry),
		"Country updated successfully",
	)
}

func DeleteCountryById(ctx request.Context) error {

	logger := ctx.Logger()

	id := ctx.Params("id")
	if id == "" {
		return ctx.ErrorResponse(
			fiber.StatusBadRequest,
			"id is required",
			errors.New("id is required"),
		)
	}

	db, err := ctx.DatabaseSession()
	if err != nil {
		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to get database session",
			err,
		)
	}
	defer db.Close()

	service := ctx.ServicesFactory().CreateCountryService(ctx, db)

	ctxTimeout, cancel := context.WithTimeout(
		ctx.Context(),
		ctx.Config().DomainChangeTimeout,
	)
	defer cancel()

	err = service.DeleteCountryById(
		ctxTimeout,
		id,
	)

	if err != nil {
		logger.Error().Err(err).Msg("Failed to delete country")

		return ctx.ErrorResponse(
			fiber.StatusInternalServerError,
			"Failed to delete country",
			err,
		)
	}

	return ctx.EmptySuccessResponse(
		"Country deleted successfully",
	)
}
