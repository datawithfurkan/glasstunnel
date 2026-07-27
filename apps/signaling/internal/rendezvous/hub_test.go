package rendezvous

import (
	"encoding/json"
	"testing"
)

func TestEnvelopePayloadKind(t *testing.T) {
	e := envelope{Payload: json.RawMessage(`{"sdpOffer":{"sessionId":"s1"}}`)}
	if got := e.PayloadKind(); got != "sdpOffer" {
		t.Fatalf("PayloadKind = %q, want sdpOffer", got)
	}

	empty := envelope{Payload: json.RawMessage(`{}`)}
	if got := empty.PayloadKind(); got != "empty" {
		t.Fatalf("PayloadKind = %q, want empty", got)
	}

	bad := envelope{Payload: json.RawMessage(`not json`)}
	if got := bad.PayloadKind(); got != "unknown" {
		t.Fatalf("PayloadKind = %q, want unknown", got)
	}
}

func TestHubOptionsDefaults(t *testing.T) {
	h := NewHub(HubOptions{})
	defer h.Close()
	if h.opts.NonceTTL == 0 {
		t.Fatal("NonceTTL default not applied")
	}
	if h.opts.MaxQueuedPerPeer == 0 {
		t.Fatal("MaxQueuedPerPeer default not applied")
	}
}

func TestQueueForOfflineStoresEnvelope(t *testing.T) {
	h := NewHub(HubOptions{MaxQueuedPerPeer: 10})
	defer h.Close()

	env := &envelope{ToDeviceID: "gt-phone", Payload: json.RawMessage(`{"test":1}`), Raw: []byte(`{"test":1}`)}
	if err := h.queueForOffline(env); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	h.mu.Lock()
	queued := h.offlineQueue["gt-phone"]
	h.mu.Unlock()

	if len(queued) != 1 {
		t.Fatalf("expected 1 queued envelope, got %d", len(queued))
	}
}

func TestQueueForOfflineCap(t *testing.T) {
	h := NewHub(HubOptions{MaxQueuedPerPeer: 3})
	defer h.Close()

	for i := 0; i < 5; i++ {
		env := &envelope{ToDeviceID: "gt-phone", Payload: json.RawMessage(`{"test":1}`), Raw: []byte(`{"test":1}`)}
		_ = h.queueForOffline(env)
	}

	h.mu.Lock()
	queued := h.offlineQueue["gt-phone"]
	h.mu.Unlock()

	if len(queued) != 3 {
		t.Fatalf("expected cap of 3, got %d", len(queued))
	}
}

func TestOfflineQueueDrainsOnRegister(t *testing.T) {
	h := NewHub(HubOptions{MaxQueuedPerPeer: 10})
	defer h.Close()

	for i := 0; i < 3; i++ {
		env := &envelope{ToDeviceID: "gt-phone", Payload: json.RawMessage(`{"test":1}`), Raw: []byte(`{"test":1}`)}
		_ = h.queueForOffline(env)
	}

	p := newPeer(nil, h)
	p.deviceID = "gt-phone"

	h.registerPeer(p)
	defer h.unregisterPeer(p)

	h.mu.Lock()
	queued := h.offlineQueue["gt-phone"]
	h.mu.Unlock()
	if len(queued) != 0 {
		t.Fatalf("expected offline queue to be drained, got %d", len(queued))
	}

	count := 0
	done := false
	for !done {
		select {
		case <-p.outgoing:
			count++
		case <-p.queue:
			count++
		default:
			done = true
		}
	}
	if count != 3 {
		t.Fatalf("expected 3 drained messages, got %d", count)
	}
}

func TestOfflineQueueNotDrainedForDifferentDevice(t *testing.T) {
	h := NewHub(HubOptions{MaxQueuedPerPeer: 10})
	defer h.Close()

	env := &envelope{ToDeviceID: "gt-phone", Payload: json.RawMessage(`{"test":1}`), Raw: []byte(`{"test":1}`)}
	_ = h.queueForOffline(env)

	p := newPeer(nil, h)
	p.deviceID = "gt-other"
	h.registerPeer(p)

	h.mu.Lock()
	queued := h.offlineQueue["gt-phone"]
	h.mu.Unlock()
	if len(queued) != 1 {
		t.Fatalf("expected offline queue to remain for gt-phone, got %d", len(queued))
	}
}
