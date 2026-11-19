package repositories

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"bitbucket.org/ifs-pd/countries/internal/domain"
	"bitbucket.org/ifs-pd/nga-common/postgres/client/interfaces"
	"github.com/jackc/pgx/v5"
)

const (
	countriesTableName    = "countries"
	ErrMsgCountryNotFound = "country not found"
)

type CountryRepositoryInterface interface {
	GetAll(ctx context.Context, filter domain.PaginationFilter) ([]domain.Country, int64, error)
	GetByCountryID(ctx context.Context, countryId string) (domain.Country, error)
	Create(ctx context.Context, country domain.Country) (domain.Country, error)
	Update(ctx context.Context, countryId string, country domain.Country) (domain.Country, error)
	Delete(ctx context.Context, countryId string) error
}

var _ CountryRepositoryInterface = (*CountryRepository)(nil)

type CountryRepository struct {
	session interfaces.Session
}

func NewCountryRepository(session interfaces.Session) *CountryRepository {
	return &CountryRepository{
		session: session,
	}
}

func (r *CountryRepository) GetAll(ctx context.Context, filter domain.PaginationFilter) ([]domain.Country, int64, error) {

	countQuery := fmt.Sprintf(
		"SELECT COUNT(*) FROM %s",
		pgx.Identifier{countriesTableName}.Sanitize(),
	)

	var total int64
	err := r.session.QueryRow(ctx, countQuery).Scan(&total)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to count countries: %w", err)
	}

	query := fmt.Sprintf(`
		SELECT id, data::text
		FROM %s
		ORDER BY (data->>'createdAt')::timestamp DESC
		LIMIT $1 OFFSET $2
	`, pgx.Identifier{countriesTableName}.Sanitize())

	rows, err := r.session.Query(ctx, query, filter.Limit, filter.Skip)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to query countries: %w", err)
	}
	defer rows.Close()

	var results []domain.Country

	for rows.Next() {
		var id string
		var jsonData string

		if err := rows.Scan(&id, &jsonData); err != nil {
			return nil, 0, err
		}

		var country domain.Country

		if err := json.Unmarshal([]byte(jsonData), &country); err != nil {
			return nil, 0, err
		}

		results = append(results, country)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return results, total, nil
}

func (r *CountryRepository) GetByCountryID(ctx context.Context, countryId string) (domain.Country, error) {

	query := fmt.Sprintf(`
		SELECT id, data::text
		FROM %s
		WHERE data->>'countryId' = $1
	`, pgx.Identifier{countriesTableName}.Sanitize())

	var id string
	var jsonData string

	err := r.session.QueryRow(ctx, query, countryId).Scan(&id, &jsonData)
	if err != nil {

		if err == pgx.ErrNoRows {
			return domain.Country{}, errors.New(ErrMsgCountryNotFound)
		}

		return domain.Country{}, err
	}

	var country domain.Country

	if err := json.Unmarshal([]byte(jsonData), &country); err != nil {
		return domain.Country{}, err
	}

	return country, nil
}

func (r *CountryRepository) Create(ctx context.Context, country domain.Country) (domain.Country, error) {

	jsonData, err := json.Marshal(country)
	if err != nil {
		return domain.Country{}, err
	}

	query := fmt.Sprintf(`
		INSERT INTO %s (id, data)
		VALUES ($1, $2::jsonb)
	`, pgx.Identifier{countriesTableName}.Sanitize())

	_, err = r.session.Exec(
		ctx,
		query,
		country.Id.String(),
		string(jsonData),
	)

	if err != nil {
		return domain.Country{}, err
	}

	return country, nil
}

func (r *CountryRepository) Update(ctx context.Context, countryId string, country domain.Country) (domain.Country, error) {

	existing, err := r.GetByCountryID(ctx, countryId)
	if err != nil {
		return domain.Country{}, err
	}

	country.Id = existing.Id
	country.CountryId = existing.CountryId
	country.CreatedAt = existing.CreatedAt

	jsonData, err := json.Marshal(country)
	if err != nil {
		return domain.Country{}, err
	}

	query := fmt.Sprintf(`
		UPDATE %s
		SET data = $1::jsonb
		WHERE id = $2
	`, pgx.Identifier{countriesTableName}.Sanitize())

	_, err = r.session.Exec(
		ctx,
		query,
		string(jsonData),
		country.Id.String(),
	)

	if err != nil {
		return domain.Country{}, err
	}

	return country, nil
}

func (r *CountryRepository) Delete(ctx context.Context, countryId string) error {

	country, err := r.GetByCountryID(ctx, countryId)
	if err != nil {
		return err
	}

	query := fmt.Sprintf(
		"DELETE FROM %s WHERE id = $1",
		pgx.Identifier{countriesTableName}.Sanitize(),
	)

	result, err := r.session.Exec(
		ctx,
		query,
		country.Id.String(),
	)

	if err != nil {
		return err
	}

	if result.RowsAffected() == 0 {
		return errors.New(ErrMsgCountryNotFound)
	}

	return nil
}
