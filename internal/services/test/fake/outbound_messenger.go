package fake

import (
	"bitbucket.org/ifs-pd/kairos-component-common/common/messaging"
	"bitbucket.org/ifs-pd/countries/internal/services"
	"github.com/rs/xid"
)

// nopMessenger discards all outbound messages. Use in tests that do not assert publishing.
type nopMessenger struct{}

func (nopMessenger) Publish(messaging.Event) error          { return nil }
func (nopMessenger) Send(messaging.Command) (string, error) { return "", nil }

// NewNopMessenger creates a new nop messenger.
func NewNopMessenger() services.OutboundMessenger {
	return nopMessenger{}
}

// Messenger records calls to OutboundMessenger.Publish / Send so a test
// can inspect what the service emitted. Reset between tests by constructing
// a new instance.
type Messenger struct {
	// Published events
	Published []messaging.Event
	// Sent commands
	Sent []messaging.Command
	// PublishErr is the error returned by Publish
	PublishErr error
	// SendErr is the error returned by Send
	SendErr error
}

func (f *Messenger) Publish(e messaging.Event) error {
	f.Published = append(f.Published, e)
	return f.PublishErr
}

func (f *Messenger) Send(c messaging.Command) (string, error) {
	id := xid.New().String()
	f.Sent = append(f.Sent, c)
	return id, f.SendErr
}

var _ services.OutboundMessenger = (*Messenger)(nil)

// NewFakeMessenger creates a new fake messenger.
func NewFakeMessenger() *Messenger {
	return &Messenger{}
}
