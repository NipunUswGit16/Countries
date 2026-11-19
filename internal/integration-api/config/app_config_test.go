package config

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestValidateAppConfig(t *testing.T) {
	config := &AppConfig{
		DomainChangeTimeout: 10 * time.Second,
	}
	err := config.Validate()
	assert.NoError(t, err)
}

func TestGetOsMemBytes(t *testing.T) {
	config := &AppConfig{}
	config.OsMemBytes = 1024
	assert.Equal(t, int64(1024), config.GetOsMemBytes())
}

func TestGetGoMemLimit(t *testing.T) {
	config := &AppConfig{}
	config.GoMemLimit = "512MiB"
	assert.Equal(t, "512MiB", config.GetGoMemLimit())
}
