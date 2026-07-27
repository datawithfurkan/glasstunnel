package rendezvous

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/glasstunnel/glasstunnel/apps/signaling/internal/crypto"
	"github.com/gorilla/websocket"
)

type peer struct {
	hub      *Hub
	conn     *websocket.Conn
	deviceID string
	pubKey   []byte
	role     string
	outgoing chan []byte
	queue    chan []byte
	ctx      context.Context
	cancel   context.CancelFunc
}

func newPeer(conn *websocket.Conn, hub *Hub) *peer {
	ctx, cancel := context.WithCancel(context.Background())
	return &peer{
		hub:      hub,
		conn:     conn,
		outgoing: make(chan []byte, 64),
		queue:    make(chan []byte, hub.opts.MaxQueuedPerPeer),
		ctx:      ctx,
		cancel:   cancel,
	}
}

func (p *peer) close() {
	p.cancel()
	_ = p.conn.Close()
}

// authenticate performs the handshake: we issue a nonce, peer signs it
// with their ed25519 private key, we verify against their presented public key.
func (p *peer) authenticate(ttl time.Duration) error {
	_ = p.conn.SetReadDeadline(time.Now().Add(ttl + 5*time.Second))
	nonce, err := crypto.NewNonce()
	if err != nil {
		return fmt.Errorf("nonce: %w", err)
	}
	hello := map[string]any{
		"type":      "server_hello",
		"nonce":     base64.StdEncoding.EncodeToString(nonce),
		"ttl_ms":    ttl.Milliseconds(),
		"version":   "0.1.0",
		"issued_at": time.Now().UnixMilli(),
	}
	if err := p.conn.WriteJSON(hello); err != nil {
		return fmt.Errorf("server_hello: %w", err)
	}

	_, raw, err := p.conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("client_auth read: %w", err)
	}

	var auth struct {
		Type       string `json:"type"`
		DeviceID   string `json:"device_id"`
		PublicKey  string `json:"public_key"`
		Signature  string `json:"signature"`
		Role       string `json:"role"`
		DeviceInfo string `json:"device_info"`
	}
	if err := json.Unmarshal(raw, &auth); err != nil {
		return fmt.Errorf("client_auth parse: %w", err)
	}
	if auth.Type != "client_auth" {
		return fmt.Errorf("expected client_auth, got %q", auth.Type)
	}
	if auth.DeviceID == "" || auth.PublicKey == "" || auth.Signature == "" {
		return errors.New("client_auth missing fields")
	}

	pub, err := base64.StdEncoding.DecodeString(auth.PublicKey)
	if err != nil {
		return fmt.Errorf("public_key decode: %w", err)
	}
	sig, err := base64.StdEncoding.DecodeString(auth.Signature)
	if err != nil {
		return fmt.Errorf("signature decode: %w", err)
	}
	if !crypto.Verify(pub, nonce, sig) {
		return errors.New("signature verification failed")
	}
	if crypto.DeviceIDFromPublicKey(pub) != auth.DeviceID {
		return errors.New("device_id does not match public_key")
	}

	p.deviceID = auth.DeviceID
	p.pubKey = pub
	p.role = auth.Role
	if p.role == "" {
		p.role = "unknown"
	}

	ack := map[string]any{
		"type":      "auth_ok",
		"device_id": p.deviceID,
		"at":        time.Now().UnixMilli(),
	}
	if err := p.conn.WriteJSON(ack); err != nil {
		return fmt.Errorf("auth_ok: %w", err)
	}

	_ = p.conn.SetReadDeadline(time.Time{})
	return nil
}

func (p *peer) send(env *envelope) error {
	raw := env.Raw
	if raw == nil {
		b, err := json.Marshal(env)
		if err != nil {
			return err
		}
		raw = b
	}
	select {
	case p.outgoing <- raw:
		return nil
	default:
		// Backpressure: try the bounded queue channel instead so we drop
		// the oldest buffered message rather than the newest.
		select {
		case p.queue <- raw:
			return nil
		default:
			return errors.New("peer send buffer full")
		}
	}
}

func (p *peer) flushQueued() {
	for {
		select {
		case msg := <-p.queue:
			select {
			case p.outgoing <- msg:
			default:
				return
			}
		default:
			return
		}
	}
}

func (p *peer) loop() {
	go p.writer()
	p.reader()
}

func (p *peer) writer() {
	pingTicker := time.NewTicker(25 * time.Second)
	defer pingTicker.Stop()
	for {
		select {
		case <-p.ctx.Done():
			return
		case msg := <-p.outgoing:
			_ = p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := p.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				log.Printf("write to %s: %v", p.deviceID, err)
				return
			}
		case <-pingTicker.C:
			_ = p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := p.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (p *peer) reader() {
	p.conn.SetReadLimit(1 << 20)
	_ = p.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	p.conn.SetPongHandler(func(string) error {
		_ = p.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})
	for {
		_, raw, err := p.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = p.conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		var peek struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &peek); err == nil && peek.Type != "" {
			p.handleControl(raw, peek.Type)
			continue
		}

		var env envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			log.Printf("bad envelope from %s: %v", p.deviceID, err)
			continue
		}
		if env.FromDeviceID != p.deviceID {
			log.Printf("peer %s tried to spoof from=%s", p.deviceID, env.FromDeviceID)
			continue
		}
		env.Raw = raw
		if err := p.hub.RouteEnvelope(&env); err != nil {
			log.Printf("route: %v", err)
		}
	}
}

func (p *peer) handleControl(raw []byte, kind string) {
	switch kind {
	case "ping":
		_ = p.conn.WriteJSON(map[string]any{"type": "pong", "at": time.Now().UnixMilli()})
	default:
		// Unknown control type, ignore silently.
	}
}
