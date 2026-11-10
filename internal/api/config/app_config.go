package config

import (
	"time"

	commonconfig "bitbucket.org/ifs-pd/nga-common/config"
)

type AppConfig struct {
	commonconfig.BaseConfig `mapstructure:",squash"`
	DomainChangeTimeout     time.Duration `mapstructure:"domain_change_timeout" default:"10s"`
}

func (c *AppConfig) Validate() error {
	return nil
}

func (c *AppConfig) GetOsMemBytes() int64 {
	return c.OsMemBytes
}

func (c *AppConfig) GetGoMemLimit() string {
	return c.GoMemLimit
}
