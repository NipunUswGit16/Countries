module bitbucket.org/ifs-pd/countries

go 1.27.3

replace bitbucket.org/ifs-pd/countries/pkg/schema => ./pkg/schema

tool (
	bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen
	github.com/swaggo/swag/cmd/swag
)

require (
	bitbucket.org/ifs-pd/kairos-component-common/api v1.2.37
	bitbucket.org/ifs-pd/kairos-component-common/common v1.5.3
	bitbucket.org/ifs-pd/kairos-component-common/event-handler v1.2.49
	// Toolkit depedency which imports scripts as a
	// go module
	bitbucket.org/ifs-pd/kairos-component-common/toolkit v1.0.60
	bitbucket.org/ifs-pd/nga-common/config v1.1.6
	github.com/gofiber/fiber/v2 v2.52.16
	github.com/rs/xid v1.6.0
	github.com/stretchr/testify v1.12.1
)

require (
	bitbucket.org/ifs-pd/access-management/pkg/schema v0.0.1 // indirect
	bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen v0.1.11 // indirect
	bitbucket.org/ifs-pd/nga-common/auth/middleware/fiber/v2 v2.0.10 // indirect
	bitbucket.org/ifs-pd/nga-common/auth/v2 v2.1.6 // indirect
	bitbucket.org/ifs-pd/nga-common/idempotency/postgres/v2 v2.0.14 // indirect
	bitbucket.org/ifs-pd/nga-common/idempotency/v2 v2.0.2 // indirect
	bitbucket.org/ifs-pd/nga-common/logging v1.1.7 // indirect
	bitbucket.org/ifs-pd/nga-common/logging/logrus v1.1.7 // indirect
	bitbucket.org/ifs-pd/nga-common/metrics/middleware/common v0.0.12 // indirect
	bitbucket.org/ifs-pd/nga-common/metrics/middleware/fiber v1.0.19 // indirect
	bitbucket.org/ifs-pd/nga-common/metrics/postgres v0.0.1 // indirect
	bitbucket.org/ifs-pd/nga-common/postgres v1.1.0 // indirect
	bitbucket.org/ifs-pd/nga-common/tenantinfo v1.1.3 // indirect
	bitbucket.org/ifs-pd/nga-common/typederrors v1.0.22 // indirect
	bitbucket.org/ifs-pd/nga-common/validation v0.0.10 // indirect
	bitbucket.org/ifs-pd/nga-event-outbox/pkg/eventsender v0.1.2 // indirect
	github.com/KyleBanks/depth v1.2.1 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/cilium/ebpf v0.22.0 // indirect
	github.com/clipperhouse/uax29/v2 v2.7.0 // indirect
	github.com/cloudevents/sdk-go/observability/opentelemetry/v2 v2.16.2 // indirect
	github.com/cloudevents/sdk-go/v2 v2.16.2 // indirect
	github.com/containerd/cgroups/v3 v3.1.3 // indirect
	github.com/containerd/log v0.2.0 // indirect
	github.com/coreos/go-systemd/v22 v22.7.0 // indirect
	github.com/cpuguy83/go-md2man/v2 v2.0.0-20190314233015-f79a8a8ca69d // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.4.1 // indirect
	github.com/dgraph-io/ristretto/v2 v2.4.2 // indirect
	github.com/docker/go-units v0.5.0 // indirect
	github.com/dustin/go-humanize v1.1.0 // indirect
	github.com/ebitengine/purego v0.11.2 // indirect
	github.com/expr-lang/expr v1.17.8 // indirect
	github.com/felixge/httpsnoop v1.1.0 // indirect
	github.com/fsnotify/fsnotify v1.10.1 // indirect
	github.com/gertd/go-pluralize v0.2.1 // indirect
	github.com/go-logr/logr v1.4.4 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/go-openapi/jsonpointer v1.0.2 // indirect
	github.com/go-openapi/jsonreference v1.0.3 // indirect
	github.com/go-openapi/spec v1.0.1 // indirect
	github.com/go-openapi/swag/conv v0.29.2 // indirect
	github.com/go-openapi/swag/jsonutils v0.29.2 // indirect
	github.com/go-openapi/swag/loading v0.29.2 // indirect
	github.com/go-openapi/swag/pools v0.29.2 // indirect
	github.com/go-openapi/swag/stringutils v0.29.2 // indirect
	github.com/go-openapi/swag/typeutils v0.29.2 // indirect
	github.com/go-openapi/swag/yamlutils v0.29.2 // indirect
	github.com/go-viper/mapstructure/v2 v2.5.0 // indirect
	github.com/goccy/go-json v0.12.0 // indirect
	github.com/godbus/dbus/v5 v5.2.4 // indirect
	github.com/gofiber/contrib/otelfiber v1.0.10 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.33.0 // indirect
	github.com/hashicorp/go-cleanhttp v0.5.2 // indirect
	github.com/hashicorp/go-retryablehttp v0.7.8 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/pgx/v5 v5.12.0 // indirect
	github.com/jackc/puddle/v2 v2.2.3 // indirect
	github.com/json-iterator/go v1.1.12 // indirect
	github.com/klauspost/compress v1.20.3 // indirect
	github.com/lestrrat-go/blackmagic v1.0.4 // indirect
	github.com/lestrrat-go/dsig v1.4.0 // indirect
	github.com/lestrrat-go/dsig-secp256k1 v1.0.0 // indirect
	github.com/lestrrat-go/httpcc v1.0.1 // indirect
	github.com/lestrrat-go/httprc/v3 v3.0.6 // indirect
	github.com/lestrrat-go/jwx/v3 v3.4.0 // indirect
	github.com/lestrrat-go/option/v2 v2.0.0 // indirect
	github.com/lufia/plan9stats v0.0.0-20261101121723-be84dd9509a0 // indirect
	github.com/mattn/go-colorable v0.1.16 // indirect
	github.com/mattn/go-isatty v0.0.24 // indirect
	github.com/mattn/go-runewidth v0.0.31 // indirect
	github.com/moby/sys/userns v0.2.1 // indirect
	github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd // indirect
	github.com/modern-go/reflect2 v1.0.2 // indirect
	github.com/molecule-man/go-brrr v1.3.1 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/opencontainers/runtime-spec v1.3.0 // indirect
	github.com/pandatix/go-abnf v0.5.5 // indirect
	github.com/pelletier/go-toml/v2 v2.4.3 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/power-devops/perfstat v0.0.0-20260916203055-22a1a467d9f0 // indirect
	github.com/prometheus/client_golang v1.25.0 // indirect
	github.com/prometheus/client_model v0.6.3 // indirect
	github.com/prometheus/common v0.73.1 // indirect
	github.com/prometheus/procfs v0.23.0 // indirect
	github.com/rs/zerolog v1.35.1 // indirect
	github.com/russross/blackfriday/v2 v2.0.1 // indirect
	github.com/sagikazarmark/locafero v0.12.0 // indirect
	github.com/segmentio/asm v1.2.1 // indirect
	github.com/shirou/gopsutil/v4 v4.26.10 // indirect
	github.com/shurcooL/sanitized_anchor_name v1.0.0 // indirect
	github.com/sirupsen/logrus v1.10.2 // indirect
	github.com/spf13/afero v1.15.0 // indirect
	github.com/spf13/cast v1.10.0 // indirect
	github.com/spf13/pflag v1.0.10 // indirect
	github.com/spf13/viper v1.21.0 // indirect
	github.com/stretchr/objx v0.8.0 // indirect
	github.com/subosito/gotenv v1.6.0 // indirect
	github.com/swaggo/swag v1.16.6 // indirect
	github.com/tklauser/go-sysconf v0.4.0 // indirect
	github.com/tklauser/numcpus v0.12.0 // indirect
	github.com/urfave/cli/v2 v2.3.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasthttp v1.77.0 // indirect
	github.com/valyala/fastjson v1.6.10 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	go.opentelemetry.io/auto/sdk v1.2.1 // indirect
	go.opentelemetry.io/contrib v1.47.0 // indirect
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.72.0 // indirect
	go.opentelemetry.io/otel v1.47.0 // indirect
	go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.47.0 // indirect
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.47.0 // indirect
	go.opentelemetry.io/otel/exporters/stdout/stdouttrace v1.47.0 // indirect
	go.opentelemetry.io/otel/log v1.47.0 // indirect
	go.opentelemetry.io/otel/metric v1.47.0 // indirect
	go.opentelemetry.io/otel/sdk v1.47.0 // indirect
	go.opentelemetry.io/otel/trace v1.47.0 // indirect
	go.opentelemetry.io/proto/otlp v1.11.1 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	go.uber.org/zap v1.28.0 // indirect
	go.yaml.in/yaml/v3 v3.0.6 // indirect
	golang.org/x/mod v0.42.0 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	golang.org/x/tools v0.52.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20261026165753-2ffab32bce7e // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261026165753-2ffab32bce7e // indirect
	google.golang.org/grpc v1.85.0 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
	gopkg.in/yaml.v2 v2.4.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
	sigs.k8s.io/yaml v1.3.0 // indirect
)
