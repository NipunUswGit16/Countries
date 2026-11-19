// Package masterdata holds the master-data entity definitions for this
// component. Any struct here that embeds entities.MasterDataEntityBase is
// automatically picked up by `make generate` (kairos-gen) and wired for
// change-data-capture (CDC) via Debezium; `make generate` then refreshes
// chart/resources/masterdata-entities.json and sql/1.gen/<table>.sql.
//
// kairos-gen scans this directory unconditionally, so keep it even while the
// component has no master-data entities.
package masterdata
