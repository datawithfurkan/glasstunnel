// Package push wraps Web Push (VAPID) delivery for glasstunnel.
//
// Subscriptions are registered per phone public key. When the Mac host
// emits a signed AgentStateEvent over the signaling channel, the hub
// fans it out to every subscription registered for the host's paired
// phone public keys. Payloads are intentionally tiny and non-sensitive:
// the actual content lives end-to-end-encrypted in the WebRTC channel.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

type Config struct {
	VAPIDPublicKey  string
	VAPIDPrivateKey string
	Subject         string // "mailto:ops@glasstunnel.io"
	Enabled         bool
}

func ConfigFromEnv() Config {
	c := Config{
		VAPIDPublicKey:  os.Getenv("GLASSTUNNEL_VAPID_PUBLIC"),
		VAPIDPrivateKey: os.Getenv("GLASSTUNNEL_VAPID_PRIVATE"),
		Subject:         os.Getenv("GLASSTUNNEL_VAPID_SUBJECT"),
	}
	if c.Subject == "" {
		c.Subject = "mailto:ops@glasstunnel.io"
	}
	c.Enabled = c.VAPIDPublicKey != "" && c.VAPIDPrivateKey != ""
	return c
}

type Service struct {
	cfg Config

	mu   sync.RWMutex
	subs map[string][]Subscription
}

type Subscription struct {
	Endpoint  string
	P256DH    string
	Auth      string
	DeviceID  string
	CreatedAt time.Time
}

func New(cfg Config) (*Service, error) {
	s := &Service{cfg: cfg, subs: make(map[string][]Subscription)}
	if !cfg.Enabled {
		return s, errors.New("VAPID keys not configured; /push/register still works but delivery is noop")
	}
	return s, nil
}

// Register stores a phone's Web Push subscription keyed by phone public key.
func (s *Service) Register(phoneDeviceID string, sub Subscription) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sub.DeviceID = phoneDeviceID
	sub.CreatedAt = time.Now()
	s.subs[phoneDeviceID] = append(s.subs[phoneDeviceID], sub)
}

// Unregister removes all subscriptions for a phone.
func (s *Service) Unregister(phoneDeviceID string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.subs, phoneDeviceID)
}

// Deliver sends a small payload to every subscription for the given phone.
func (s *Service) Deliver(ctx context.Context, phoneDeviceID string, payload Payload) error {
	if s == nil || !s.cfg.Enabled {
		return nil
	}
	s.mu.RLock()
	subs := append([]Subscription(nil), s.subs[phoneDeviceID]...)
	s.mu.RUnlock()
	if len(subs) == 0 {
		return nil
	}

	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	var firstErr error
	var dead []int
	for i, sub := range subs {
		sub := webpush.Subscription{
			Endpoint: sub.Endpoint,
			Keys:     webpush.Keys{P256dh: sub.P256DH, Auth: sub.Auth},
		}
		resp, err := webpush.SendNotificationWithContext(ctx, b, &sub, &webpush.Options{
			Subscriber:      s.cfg.Subject,
			VAPIDPublicKey:  s.cfg.VAPIDPublicKey,
			VAPIDPrivateKey: s.cfg.VAPIDPrivateKey,
			TTL:             30,
		})
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusGone || resp.StatusCode == http.StatusNotFound {
			dead = append(dead, i)
		}
	}

	if len(dead) > 0 {
		s.prune(phoneDeviceID, dead)
	}
	return firstErr
}

func (s *Service) prune(phoneDeviceID string, indexes []int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := s.subs[phoneDeviceID]
	keep := cur[:0]
	removed := map[int]bool{}
	for _, i := range indexes {
		removed[i] = true
	}
	for i, sub := range cur {
		if !removed[i] {
			keep = append(keep, sub)
		}
	}
	s.subs[phoneDeviceID] = keep
}

// Payload is the tiny event we fan out over Web Push. It carries no
// sensitive content; the PWA then wakes, opens WebRTC, and pulls the
// real state over the encrypted DataChannel.
type Payload struct {
	Kind       string `json:"kind"`
	AgentID    string `json:"agent_id"`
	AgentLabel string `json:"agent_label,omitempty"`
	Status     string `json:"status"`
	Summary    string `json:"summary,omitempty"`
	At         int64  `json:"at"`
}

// ServeVAPIDPublicKey is the HTTP handler for GET /push/vapid; returns the
// VAPID public key if configured, empty otherwise. The PWA uses this to
// subscribe the browser to Web Push.
func (s *Service) ServeVAPIDPublicKey(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if s == nil || !s.cfg.Enabled {
		_ = json.NewEncoder(w).Encode(map[string]any{"public_key": ""})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"public_key": s.cfg.VAPIDPublicKey})
}

// ServeRegister is the HTTP handler for POST /push/register.
func (s *Service) ServeRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		DeviceID string `json:"device_id"`
		Endpoint string `json:"endpoint"`
		P256DH   string `json:"p256dh"`
		Auth     string `json:"auth"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.DeviceID == "" || body.Endpoint == "" || body.P256DH == "" || body.Auth == "" {
		http.Error(w, "missing fields", http.StatusBadRequest)
		return
	}
	s.Register(body.DeviceID, Subscription{
		Endpoint: body.Endpoint,
		P256DH:   body.P256DH,
		Auth:     body.Auth,
	})
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

// SubscriptionCount is used by tests and health metrics.
func (s *Service) SubscriptionCount(phoneDeviceID string) int {
	if s == nil {
		return 0
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.subs[phoneDeviceID])
}

var _ = fmt.Sprintf // keep fmt imported for future error wrapping
