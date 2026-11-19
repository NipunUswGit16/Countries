package dto

import "errors"

type CountryCreateRequest struct {
	CountryId string `json:"countryId"`
	Name      string `json:"name"`
}

func (c CountryCreateRequest) Validate() error {
	if c.CountryId == "" {
		return errors.New("countryId is required")
	}

	if c.Name == "" {
		return errors.New("name is required")
	}

	return nil
}

type CountryUpdateRequest struct {
	Name string `json:"name"`
}

func (c CountryUpdateRequest) Validate() error {
	if c.Name == "" {
		return errors.New("name is required")
	}

	return nil
}
