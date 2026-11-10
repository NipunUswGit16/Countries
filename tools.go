//go:build tools

package main

import (
	_ "bitbucket.org/ifs-pd/kairos-component-common/toolkit"
)

// This file pins the toolkit *file bundle* (Makefiles, scripts, chart helpers)
// via a blank import so `go mod tidy` keeps the module in go.mod.
//
// Generator executables (`kairos-gen`, `swag`) are NOT imported here. They are
// pinned as `tool` directives in go.mod and invoked with `go tool`.
//
// See: https://bitbucket.org/ifs-pd/kairos-component-common/src/main/toolkit/
