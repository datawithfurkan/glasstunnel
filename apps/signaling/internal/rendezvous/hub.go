// Package rendezvous implements the glasstunnel signaling hub.
//
// Connections authenticate by signing a server-issued nonce with their
// ed25519 private key. Once authenticated, the hub routes envelopes by
// from_device_id -> to_device_id. Envelopes are opaque to the hub; the
// server never reads the inner oneof payload.
//
// A small bounded queue per device handles brief disconnects: if a phone
// flaps to a new LTE cell, the Mac's envelopes sit in the queue for up
// to 60 seconds and are flushed on reconnect.
package rendezvous

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/glasstunnel/glasstunnel/apps/signaling/internal/crypto"
	"github.com/glasstunnel/glasstunnel/apps/signaling/internal/push"
	"github.com/gorilla/websocket"
)

type HubOptions struct {
	NonceTTL         time.Duration
	MaxQueuedPerPeer int
	PushService      *push.Service
}

type Hub struct {
	opts HubOptions

	mu    sync.RWMutex
	peers map[string]*peer
	// Offline envelopes queued while the destination peer is disconnected.
	// Drained into the peer's outgoing channel when it reconnects.
	offlineQueue map[string][]*envelope

	upgrader websocket.Upgrader
	done     chan struct{}
}

func NewHub(opts HubOptions) *Hub {
	if opts.NonceTTL == 0 {
		opts.NonceTTL = 30 * time.Second
	}
	if opts.MaxQueuedPerPeer == 0 {
		opts.MaxQueuedPerPeer = 256
	}
	h := &Hub{
		opts:         opts,
		peers:        make(map[string]*peer),
		offlineQueue: make(map[string][]*envelope),
		upgrader: websocket.Upgrader{
			CheckOrigin:     func(r *http.Request) bool { return true },
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
		},
		done: make(chan struct{}),
	}
	return h
}

func (h *Hub) Close() {
	close(h.done)
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.peers {
		if p.conn != nil {
			_ = p.conn.Close()
		}
	}
}

// ServeWebSocket is the HTTP handler for /signal.
func (h *Hub) ServeWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade: %v", err)
		return
	}
	p := newPeer(conn, h)
	defer p.close()

	if err := p.authenticate(h.opts.NonceTTL); err != nil {
		log.Printf("auth failed: %v", err)
		return
	}

	h.registerPeer(p)
	defer h.unregisterPeer(p)
	p.flushQueued()
	p.loop()
}

func (h *Hub) registerPeer(p *peer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if existing, ok := h.peers[p.deviceID]; ok {
		_ = existing.conn.Close()
	}
	h.peers[p.deviceID] = p

	// Drain any envelopes that arrived while this peer was offline.
	if queued, ok := h.offlineQueue[p.deviceID]; ok && len(queued) > 0 {
		sent := 0
		for _, env := range queued {
			if err := p.send(env); err != nil {
				// Peer buffer is full; re-queue remaining envelopes.
				h.offlineQueue[p.deviceID] = queued[sent:]
				log.Printf("peer %s buffer full; %d envelope(s) remain offline", p.deviceID, len(queued)-sent)
				break
			}
			sent++
		}
		if sent == len(queued) {
			delete(h.offlineQueue, p.deviceID)
		}
		log.Printf("drained %d/%d offline envelope(s) to %s", sent, len(queued), p.deviceID)
	}

	log.Printf("peer %s connected (role=%s)", p.deviceID, p.role)
}

func (h *Hub) unregisterPeer(p *peer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if cur, ok := h.peers[p.deviceID]; ok && cur == p {
		delete(h.peers, p.deviceID)
	}
	log.Printf("peer %s disconnected", p.deviceID)
}

// RouteEnvelope delivers an envelope to the destination peer or briefly
// queues it if the destination is offline. Signature verification is
// intentionally done by the sender; the hub only trusts the sender's
// authenticated public key to stamp `from_device_id`.
//
// Special case: AgentStateEvent envelopes also fan out to Web Push so the
// phone gets a notification even when the PWA is backgrounded. The envelope
// payload never leaves the tunnel; we only push a tiny {kind, status}
// metadata blob.
func (h *Hub) RouteEnvelope(env *envelope) error {
	if h.opts.PushService != nil && env.PayloadKind() == "agentStateEvent" {
		h.tryPushFromEnvelope(env)
	}
	h.mu.RLock()
	dest, ok := h.peers[env.ToDeviceID]
	h.mu.RUnlock()
	if !ok {
		return h.queueForOffline(env)
	}
	return dest.send(env)
}

func (h *Hub) tryPushFromEnvelope(env *envelope) {
	var probe struct {
		Event struct {
			AgentID string `json:"agentId"`
			Status  int    `json:"status"`
			Summary string `json:"summary"`
			AtMs    int64  `json:"atUnixMs"`
		} `json:"agentStateEvent"`
	}
	if err := json.Unmarshal(env.Payload, &probe); err != nil {
		return
	}
	if probe.Event.Status < 3 {
		// Only fan out "needs attention" states: waitingInput/awaitingApproval/done/error.
		// AgentStatus < 3 is idle/working and would spam.
		if probe.Event.Status != 5 {
			return
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = h.opts.PushService.Deliver(ctx, env.ToDeviceID, push.Payload{
		Kind:       "agent-state",
		AgentID:    probe.Event.AgentID,
		Status:     statusLabel(probe.Event.Status),
		Summary:    probe.Event.Summary,
		At:         probe.Event.AtMs,
		AgentLabel: "",
	})
}

func statusLabel(s int) string {
	switch s {
	case 1:
		return "idle"
	case 2:
		return "working"
	case 3:
		return "waiting-input"
	case 4:
		return "awaiting-approval"
	case 5:
		return "done"
	case 6:
		return "error"
	case 7:
		return "disconnected"
	default:
		return "unknown"
	}
}

func (h *Hub) queueForOffline(env *envelope) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	q, ok := h.peers[env.ToDeviceID]
	if ok {
		return q.send(env)
	}
	// Peer is offline: store in hub-level offline queue for delivery on reconnect.
	if len(h.offlineQueue[env.ToDeviceID]) >= h.opts.MaxQueuedPerPeer {
		log.Printf("offline queue overflow for %s (type=%s)", env.ToDeviceID, env.PayloadKind())
		return nil
	}
	h.offlineQueue[env.ToDeviceID] = append(h.offlineQueue[env.ToDeviceID], env)
	log.Printf("queued envelope for offline %s (type=%s)", env.ToDeviceID, env.PayloadKind())
	return nil
}

// -------------------------------------------------------------------
// Envelope wire format
// -------------------------------------------------------------------
// The hub only needs to read three fields: from_device_id, to_device_id,
// and the payload discriminator. Everything else stays in the raw JSON
// bytes and is forwarded verbatim.
// -------------------------------------------------------------------

// The wire format is camelCase across Swift, TypeScript, and Go. The
// .proto schema is snake_case but we do not use proto JSON mapping yet;
// each language hand-serializes using its natural field casing, which
// Swift keeps as camelCase by default and TS's hand-written types also
// emit as camelCase. Go matches by tagging its struct camelCase too.
type envelope struct {
	EnvelopeID   string          `json:"envelopeId"`
	FromDeviceID string          `json:"fromDeviceId"`
	ToDeviceID   string          `json:"toDeviceId"`
	SentAtUnixMs int64           `json:"sentAtUnixMs"`
	Signature    string          `json:"signature"`
	Payload      json.RawMessage `json:"payload"`
	Raw          []byte          `json:"-"`
}

// PayloadKind extracts the oneof discriminator for logging. If the JSON
// is malformed we return "unknown" rather than crashing.
func (e *envelope) PayloadKind() string {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(e.Payload, &probe); err != nil {
		return "unknown"
	}
	for k := range probe {
		return k
	}
	return "empty"
}

var _ = crypto.NonceLength
