---
name: kairos-configure-appconfig
description: Defines or extends the typed AppConfig used by the client-API, event-handler, and integration-API runtimes — embedding BaseConfig, adding mapstructure tags and default values, implementing Validate and getter methods. Use when adding a configuration field, wiring a new environment variable, adjusting timeouts, extending AppConfig, or when the user says "add config value", "update AppConfig", or "configure environment variable".
---

# Configure Kairos AppConfig

`AppConfig` is the typed application configuration for a Kairos runtime. There is **one variant per runtime binary**, and it is obtained at runtime via `ctx.Config()`.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## File locations

| Runtime | Binary | Config directory |
|---|---|---|
| Client API | `cmd/client-api` | `internal/api/config/` |
| Event handler | `cmd/event-handler` | `internal/event-handler/config/` |
| Integration API | `cmd/integration-api` | `internal/integration-api/config/` |

The config file is the one in that directory that declares the type: `grep -l 'type AppConfig' internal/<runtime>/config/*.go`. The template names it `app_config.go`; some components use another name (e.g. `config.go`). Edit the file the grep finds.

Keys are **not** auto-shared across variants — each file is independent. Add the key to every runtime that actually reads it, and only those: a key consumed only by event handlers belongs solely in the event-handler file; one consumed only by client-API endpoints belongs solely in the API file; one read by all three goes in all three.

If `test -d internal/integration-api/config` succeeds, the component has all three runtimes. Otherwise it has only the client-API and event-handler files; don't create the integration-API one inside a config task.

## Template

The template below shows the *shape* of an extended `AppConfig`. The fields shown (`DomainChangeTimeout`, `ExternalServiceURL`) are illustrative — preserve any fields that already exist in the file and add the new one alongside them.

Use the aliased import `commonconfig` to avoid a name collision with the local `config` package:

```go
package config

import (
    "fmt"
    "time"

    commonconfig "bitbucket.org/ifs-pd/nga-common/config"
)

type AppConfig struct {
    commonconfig.BaseConfig `mapstructure:",squash"`

    DomainChangeTimeout time.Duration `mapstructure:"domain_change_timeout" default:"10s"`
    ExternalServiceURL  string        `mapstructure:"external_service_url"`
}

// Validate checks required config fields at startup. Return an error for every
// required field that is missing or invalid.
func (c *AppConfig) Validate() error {
    if c.ExternalServiceURL == "" {
        return fmt.Errorf("external_service_url is required")
    }
    return nil
}

// MemoryConfig interface methods. These two are mandatory; check the MemoryConfig
// interface for any additional methods that need to be implemented.
func (c *AppConfig) GetOsMemBytes() int64 {
    return c.OsMemBytes
}

func (c *AppConfig) GetGoMemLimit() string {
    return c.GoMemLimit
}

// Expose component-specific getters used by services/handlers.
func (c *AppConfig) GetExternalServiceURL() string {
    return c.ExternalServiceURL
}
```

## Required elements checklist

- [ ] Struct embeds `config.BaseConfig` with `mapstructure:",squash"`.
- [ ] Every new field has a `mapstructure` tag in `lower_snake_case` matching the env/config key.
- [ ] Reasonable `default:"..."` values where applicable.
- [ ] `Validate()` returns an error for every required-but-missing or invalid value.
- [ ] `MemoryConfig` interface methods present (`GetOsMemBytes`, `GetGoMemLimit`, plus any others the interface declares).
- [ ] Getter methods exposed for every field used outside the config package.
- [ ] Every runtime variant that reads the key is updated — and no variant that doesn't.

## How config is surfaced to code

- Handlers and endpoints access config via `ctx.Config()`, which returns `*AppConfig`.
- Services that need config take `*config.AppConfig` or a narrow interface.
- Timeouts, feature flags, and external endpoints must come from `ctx.Config().GetX()` — never hardcoded.

## Common patterns

### Timeouts

```go
DomainChangeTimeout time.Duration `mapstructure:"domain_change_timeout" default:"10s"`
```

Used in handler code:

```go
ctxTimeout, cancel := context.WithTimeout(ctx.Context(), ctx.Config().DomainChangeTimeout)
defer cancel()
```

### Feature flags

```go
EnableNewFlow bool `mapstructure:"enable_new_flow" default:"false"`
```

### External service endpoints

```go
ExternalServiceURL string `mapstructure:"external_service_url"`
```

## Common mistakes (RED FLAGS)

- Hardcoded timeouts, feature flags, or external URLs instead of reading from `AppConfig`.
- Missing `mapstructure` tag → environment variable won't bind.
- Missing `Validate()` check for a required key → runtime failure far from the source.
- Forgetting to mirror a config key into every runtime that reads it — a key added only to `internal/api/config/` is invisible to the event-handler and integration-API runtimes.
- Storing secrets in plaintext defaults — use Kubernetes secret env-var references instead.
