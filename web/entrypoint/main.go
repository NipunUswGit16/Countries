package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"syscall"

	"go.elastic.co/ecszerolog"
)

const (
	envJsTemplate = "/public/env.js"
	envJsOutput   = "/runtime/env.js"
	runtimeDir    = "/runtime"
	swsBinary     = "/static-web-server"
	swsConfig     = "/etc/sws/config.toml"
)

// Filesystem operations used to render env.js. Tests replace them. Production
// calls pass the constants above.
var (
	readFile  = os.ReadFile
	mkdirAll  = os.MkdirAll
	writeFile = os.WriteFile
)

// execFn matches the signature of syscall.Exec. Injectable so tests can drive
// the run loop without actually replacing the test process.
type execFn func(argv0 string, argv []string, envv []string) error

func main() {
	render := func() error {
		return renderEnvJs(os.Getenv)
	}
	os.Exit(run(render, syscall.Exec, os.Stderr))
}

// run renders env.js and execs static-web-server. On a successful exec the
// process is replaced and run never returns; the explicit `return 0` is here
// only so run is unit-testable with stub functions.
//
// Logs are emitted as ECS-compliant JSON (zerolog + ecszerolog) so the web
// pod's stdout/stderr matches the format used by the rest of the component.
func run(render func() error, exec execFn, logOut io.Writer) int {
	logger := ecszerolog.New(logOut).With().
		Str("service.name", "web-entrypoint").
		Logger()

	if err := render(); err != nil {
		logger.Err(err).Msg("render env.js")
		return 1
	}
	if err := exec(swsBinary, []string{swsBinary, "--config-file", swsConfig}, os.Environ()); err != nil {
		logger.Err(err).Msg("exec static-web-server")
		return 1
	}
	return 0
}

// renderEnvJs substitutes shell-style $VAR / ${VAR} references in
// envJsTemplate and writes the result to envJsOutput. Variables are resolved
// via lookup (typically os.Getenv); undefined variables are replaced by the
// empty string, matching the behaviour of a parameterless `envsubst`. A
// missing template is not an error — env.js is optional.
func renderEnvJs(lookup func(string) string) error {
	data, err := readFile(envJsTemplate)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return fmt.Errorf("read env.js template: %w", err)
	}
	// 0750/0600: the entrypoint and static-web-server share one uid.
	if err := mkdirAll(runtimeDir, 0o750); err != nil {
		return fmt.Errorf("create %s: %w", runtimeDir, err)
	}
	if err := writeFile(envJsOutput, []byte(os.Expand(string(data), lookup)), 0o600); err != nil {
		return fmt.Errorf("write rendered env.js: %w", err)
	}
	return nil
}
