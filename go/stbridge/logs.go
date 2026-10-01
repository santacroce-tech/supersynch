package stbridge

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Syncthing's own log recorders live in an internal package, so we capture
// warnings and errors by wrapping the default slog handler (which Syncthing
// logs through) — the equivalent of /rest/system/error and /rest/system/log.

type logLine struct {
	When    time.Time `json:"when"`
	Message string    `json:"message"`
	Level   int       `json:"level"`
}

type logRecorder struct {
	mu     sync.Mutex
	lines  []logLine
	errors []logLine
}

const maxLogLines = 200

var recorder = &logRecorder{}

type captureHandler struct {
	inner slog.Handler
	attrs []slog.Attr
}

func init() {
	slog.SetDefault(slog.New(&captureHandler{inner: slog.Default().Handler()}))
}

func (h *captureHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return level >= slog.LevelWarn || h.inner.Enabled(ctx, level)
}

func (h *captureHandler) Handle(ctx context.Context, r slog.Record) error {
	if r.Level >= slog.LevelWarn {
		msg := r.Message
		add := func(a slog.Attr) bool {
			if a.Key != "log.pkg" {
				msg += " " + a.Key + "=" + a.Value.String()
			}
			return true
		}
		for _, a := range h.attrs {
			add(a)
		}
		r.Attrs(add)
		recorder.add(logLine{When: r.Time, Message: msg, Level: int(r.Level)})
	}
	if h.inner.Enabled(ctx, r.Level) {
		return h.inner.Handle(ctx, r)
	}
	return nil
}

func (h *captureHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &captureHandler{inner: h.inner.WithAttrs(attrs), attrs: append(append([]slog.Attr{}, h.attrs...), attrs...)}
}

func (h *captureHandler) WithGroup(name string) slog.Handler {
	return &captureHandler{inner: h.inner.WithGroup(name), attrs: h.attrs}
}

func (r *logRecorder) add(line logLine) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, line)
	if len(r.lines) > maxLogLines {
		r.lines = r.lines[len(r.lines)-maxLogLines:]
	}
	if line.Level >= int(slog.LevelError) {
		r.errors = append(r.errors, line)
		if len(r.errors) > maxLogLines {
			r.errors = r.errors[len(r.errors)-maxLogLines:]
		}
	}
}

// ErrorsJSON mirrors GET /rest/system/error (error-level log lines).
func (n *Node) ErrorsJSON() (string, error) {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	return marshal(map[string]any{"errors": append([]logLine{}, recorder.errors...)})
}

// ClearErrors mirrors POST /rest/system/error/clear.
func (n *Node) ClearErrors() {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	recorder.errors = nil
}

// LogJSON mirrors GET /rest/system/log, limited to warnings and errors.
func (n *Node) LogJSON() (string, error) {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	return marshal(map[string]any{"messages": append([]logLine{}, recorder.lines...)})
}
