package services

import (
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
)

// OutboundMessenger is the outbound-bus contract services depend on.
// ServicesFactory adapts the runtime ctx.Sender() to this interface so the
// same service works identically under the API runtime and the event-handler
// runtime.
//
// SendCommandResponse is intentionally NOT here — replying to a specific
// inbound command is correlation-bound and lives in the command handler.
type OutboundMessenger interface {
	// Publish an event to the outbound-bus.
	Publish(event messaging.Event) error
	// Send a command to a component. Returns the message ID (Ce-Id) for correlation.
	Send(cmd messaging.Command) (string, error)
}

// senderAdapter adapts the runtime ctx.Sender() to the OutboundMessenger interface.
type senderAdapter struct {
	inner messaging.Sender
}

// NewSenderAdapter creates a new senderAdapter.
func NewSenderAdapter(s messaging.Sender) OutboundMessenger {
	return senderAdapter{inner: s}
}

func (a senderAdapter) Publish(e messaging.Event) error {
	return a.inner.Publish(e)
}

func (a senderAdapter) Send(c messaging.Command) (string, error) {
	return a.inner.Send(c)
}
