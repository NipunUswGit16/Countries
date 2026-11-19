package schema

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestComponentName(t *testing.T) {
	assert.Equal(t, "countries", ComponentName)
	assert.NotEmpty(t, ComponentName)
}
