package domain

// PaginationFilter carries the page, sort and skip values a list query applies.
type PaginationFilter struct {
	Limit     int64
	Page      int64
	Total     int64
	Skip      int64
	Sort      string
	SortOrder string
}
