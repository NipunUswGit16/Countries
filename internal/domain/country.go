package domain

import "bitbucket.org/ifs-pd/kairos-component-common/common/entities"

// Country is a simple aggregate: a named country stored for the current tenant.
type Country struct {
	entities.EntityBase[entities.EntityId] `json:",inline"`

	CountryId string `json:"countryId"`
	Name      string `json:"name"`
}
