package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func staticLookup(vars map[string]string) func(string) string {
	return func(name string) string { return vars[name] }
}

// useTempRuntime points readFile, mkdirAll, and writeFile at a temp directory
// while still requiring the production constants and owner-only modes.
// template is the stand-in for /public/env.js; output is the stand-in for
// /runtime/env.js.
func useTempRuntime(t *testing.T) (template, output string) {
	t.Helper()
	root := t.TempDir()
	template = filepath.Join(root, "env.js")
	runtime := filepath.Join(root, "runtime")
	output = filepath.Join(runtime, "env.js")

	origRead, origMkdir, origWrite := readFile, mkdirAll, writeFile
	t.Cleanup(func() {
		readFile, mkdirAll, writeFile = origRead, origMkdir, origWrite
	})

	readFile = func(name string) ([]byte, error) {
		if name != envJsTemplate {
			t.Errorf("read path = %q, want %q", name, envJsTemplate)
		}
		return os.ReadFile(template)
	}
	mkdirAll = func(path string, perm os.FileMode) error {
		if path != runtimeDir {
			t.Errorf("mkdir path = %q, want %q", path, runtimeDir)
		}
		if perm != 0o750 {
			t.Errorf("mkdir perm = %#o, want 0750", perm)
		}
		return os.MkdirAll(runtime, perm)
	}
	writeFile = func(name string, data []byte, perm os.FileMode) error {
		if name != envJsOutput {
			t.Errorf("write path = %q, want %q", name, envJsOutput)
		}
		if perm != 0o600 {
			t.Errorf("write perm = %#o, want 0600", perm)
		}
		return os.WriteFile(output, data, perm)
	}
	return template, output
}

func TestRenderEnvJsSubstitutesVariables(t *testing.T) {
	template, output := useTempRuntime(t)

	if err := os.WriteFile(template, []byte(
		`window.__env = { authority: "$AUTH_AUTHORITY", clientId: "${AUTH_CLIENT_ID}" };`,
	), 0o600); err != nil {
		t.Fatalf("seed template: %v", err)
	}

	lookup := staticLookup(map[string]string{
		"AUTH_AUTHORITY": "https://login.example.com",
		"AUTH_CLIENT_ID": "spa-client",
	})

	if err := renderEnvJs(lookup); err != nil {
		t.Fatalf("renderEnvJs: %v", err)
	}

	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	want := `window.__env = { authority: "https://login.example.com", clientId: "spa-client" };`
	if string(got) != want {
		t.Errorf("rendered env.js mismatch:\n got: %s\nwant: %s", got, want)
	}

	info, err := os.Stat(output)
	if err != nil {
		t.Fatalf("stat output: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("output mode = %#o, want 0600", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(filepath.Dir(output))
	if err != nil {
		t.Fatalf("stat runtime dir: %v", err)
	}
	if dirInfo.Mode().Perm() != 0o750 {
		t.Errorf("runtime dir mode = %#o, want 0750", dirInfo.Mode().Perm())
	}
}

func TestRenderEnvJsUndefinedVarsBecomeEmpty(t *testing.T) {
	template, output := useTempRuntime(t)

	if err := os.WriteFile(template, []byte(`x=$MISSING; y=${ALSO_MISSING};`), 0o600); err != nil {
		t.Fatalf("seed template: %v", err)
	}

	if err := renderEnvJs(staticLookup(nil)); err != nil {
		t.Fatalf("renderEnvJs: %v", err)
	}

	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if want := `x=; y=;`; string(got) != want {
		t.Errorf("rendered output mismatch: got %q want %q", got, want)
	}
}

func TestRenderEnvJsTemplateMissingIsNoOp(t *testing.T) {
	_, output := useTempRuntime(t)

	if err := renderEnvJs(staticLookup(nil)); err != nil {
		t.Fatalf("renderEnvJs returned error for missing template: %v", err)
	}
	if _, err := os.Stat(output); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("output file should not exist when template is missing, stat err = %v", err)
	}
}

func TestRenderEnvJsTemplateReadErrorIsWrapped(t *testing.T) {
	template, _ := useTempRuntime(t)
	// A directory at the template path triggers an EISDIR read error that
	// is not fs.ErrNotExist, exercising the error-wrapping branch regardless
	// of the uid running the test (root can't make a regular file unreadable
	// to itself).
	if err := os.MkdirAll(template, 0o750); err != nil {
		t.Fatalf("seed template dir: %v", err)
	}

	err := renderEnvJs(staticLookup(nil))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "read env.js template") {
		t.Errorf("error %q should mention reading the template", err)
	}
}

func TestRenderEnvJsMkdirAllError(t *testing.T) {
	template, output := useTempRuntime(t)
	if err := os.WriteFile(template, []byte("ok"), 0o600); err != nil {
		t.Fatalf("seed template: %v", err)
	}
	// A regular file occupies the path the runtime directory would live
	// under; MkdirAll then refuses to descend into a non-directory.
	runtime := filepath.Dir(output)
	if err := os.WriteFile(runtime, nil, 0o600); err != nil {
		t.Fatalf("seed blocker file: %v", err)
	}

	err := renderEnvJs(staticLookup(nil))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "create ") {
		t.Errorf("error %q should mention creating the runtime directory", err)
	}
}

func TestRenderEnvJsWriteFileError(t *testing.T) {
	template, output := useTempRuntime(t)
	if err := os.WriteFile(template, []byte("ok"), 0o600); err != nil {
		t.Fatalf("seed template: %v", err)
	}
	// Output path already exists as a directory; WriteFile fails to open it.
	if err := os.MkdirAll(output, 0o750); err != nil {
		t.Fatalf("seed output dir: %v", err)
	}

	err := renderEnvJs(staticLookup(nil))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "write rendered env.js") {
		t.Errorf("error %q should mention writing env.js", err)
	}
}

func TestRunHappyPath(t *testing.T) {
	render := func() error { return nil }
	exec := func(argv0 string, argv []string, envv []string) error {
		if argv0 != swsBinary {
			t.Errorf("argv0 = %q, want %q", argv0, swsBinary)
		}
		want := []string{swsBinary, "--config-file", swsConfig}
		if len(argv) != len(want) {
			t.Fatalf("argv = %v, want %v", argv, want)
		}
		for i := range argv {
			if argv[i] != want[i] {
				t.Errorf("argv[%d] = %q, want %q", i, argv[i], want[i])
			}
		}
		return nil
	}

	var logOut bytes.Buffer
	if got := run(render, exec, &logOut); got != 0 {
		t.Errorf("run returned %d, want 0; log=%q", got, logOut.String())
	}
	if logOut.Len() != 0 {
		t.Errorf("logOut should be empty on the happy path, got %q", logOut.String())
	}
}

func TestRunRenderErrorReturnsOneAndLogs(t *testing.T) {
	render := func() error { return errors.New("render boom") }
	exec := func(string, []string, []string) error {
		t.Fatal("exec should not be called when render fails")
		return nil
	}

	var logOut bytes.Buffer
	if got := run(render, exec, &logOut); got != 1 {
		t.Errorf("run returned %d, want 1", got)
	}
	assertJSONLog(t, logOut.Bytes(), map[string]string{
		"log.level":     "error",
		"message":       "render env.js",
		"service.name":  "web-entrypoint",
		"error.message": "render boom",
	})
}

func TestRunExecErrorReturnsOneAndLogs(t *testing.T) {
	render := func() error { return nil }
	exec := func(string, []string, []string) error {
		return errors.New("exec boom")
	}

	var logOut bytes.Buffer
	if got := run(render, exec, &logOut); got != 1 {
		t.Errorf("run returned %d, want 1", got)
	}
	assertJSONLog(t, logOut.Bytes(), map[string]string{
		"log.level":     "error",
		"message":       "exec static-web-server",
		"service.name":  "web-entrypoint",
		"error.message": "exec boom",
	})
}

// assertJSONLog parses the first line of out as JSON and asserts each wanted
// key/value pair is present. Keeps the test resilient to additional ECS
// fields the logging library may attach (timestamp, ecs.version, etc.).
func assertJSONLog(t *testing.T, out []byte, want map[string]string) {
	t.Helper()
	line := out
	if i := bytes.IndexByte(out, '\n'); i >= 0 {
		line = out[:i]
	}
	if len(line) == 0 {
		t.Fatalf("expected a JSON log line, got %q", out)
	}
	var got map[string]any
	if err := json.Unmarshal(line, &got); err != nil {
		t.Fatalf("log line is not valid JSON: %v\nline: %s", err, line)
	}
	for k, v := range want {
		actual, ok := got[k]
		if !ok {
			t.Errorf("missing field %q in log line: %s", k, line)
			continue
		}
		if s, _ := actual.(string); s != v {
			t.Errorf("field %q = %v, want %q (line: %s)", k, actual, v, line)
		}
	}
}
