// Glasstunnel signaling server entrypoint.
//
// Zero-config quickstart:
//
//	go run ./cmd/server
//
// Listens on :8080 by default; override with -addr or $PORT.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/glasstunnel/glasstunnel/apps/signaling/internal/push"
	"github.com/glasstunnel/glasstunnel/apps/signaling/internal/rendezvous"
)

func main() {
	addr := flag.String("addr", defaultAddr(), "HTTP listen address")
	nonceTTL := flag.Duration("nonce-ttl", loadNonceTTL(), "Auth nonce lifetime")
	maxQueued := flag.Int("max-queued", loadMaxQueued(), "Per-device queued envelope cap")
	flag.Parse()

	pushCfg := push.ConfigFromEnv()
	pushSvc, err := push.New(pushCfg)
	if err != nil {
		log.Printf("web push disabled: %v", err)
	}

	hub := rendezvous.NewHub(rendezvous.HubOptions{
		NonceTTL:         *nonceTTL,
		MaxQueuedPerPeer: *maxQueued,
		PushService:      pushSvc,
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/signal", hub.ServeWebSocket)
	mux.HandleFunc("/push/register", pushSvc.ServeRegister)
	mux.HandleFunc("/push/vapid", pushSvc.ServeVAPIDPublicKey)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true,"version":"0.1.0-dev"}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("glasstunnel signaling. See https://github.com/glasstunnel/glasstunnel.\n"))
	})

	server := &http.Server{
		Addr:              *addr,
		Handler:           withLogging(withCORS(mux)),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("signaling listening on %s", *addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http server: %v", err)
		}
	}()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	<-ctx.Done()

	log.Println("shutdown requested, draining connections")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown: %v", err)
	}
	hub.Close()
	log.Println("bye")
}

func defaultAddr() string {
	if p := os.Getenv("PORT"); p != "" {
		return ":" + p
	}
	return ":8080"
}

func loadNonceTTL() time.Duration {
	if v := os.Getenv("GLASSTUNNEL_NONCE_TTL_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
	}
	return 30 * time.Second
}

func loadMaxQueued() int {
	if v := os.Getenv("GLASSTUNNEL_MAX_QUEUED_ENVELOPES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 256
}

func withLogging(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h.ServeHTTP(w, r)
		log.Printf("%s %s %s (%s)", r.RemoteAddr, r.Method, r.URL.Path, time.Since(start))
	})
}

func withCORS(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}
