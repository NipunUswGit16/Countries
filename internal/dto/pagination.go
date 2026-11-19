// Package dto holds response types shared by the entry layers (api,
// integration-api) and the services. It imports nothing from internal/.
package dto

type Pagination struct {
	Page  int64 `json:"page"`
	Limit int64 `json:"limit"`
	Total int64 `json:"total"`
}

type PaginatedResponse[T any] struct {
	Data       []T        `json:"data"`
	Pagination Pagination `json:"pagination"`
}
