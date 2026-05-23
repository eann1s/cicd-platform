package http

import "net/http"

type Deps struct {
	Ready   func() bool
	Metrics http.Handler
}

type Handlers struct {
	deps Deps
}

func NewHandlers(deps Deps) *Handlers {
	return &Handlers{
		deps: deps,
	}
}

func (h *Handlers) Readyz(w http.ResponseWriter, req *http.Request) {
	if h.deps.Ready() {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
}

func (h *Handlers) Healthz(w http.ResponseWriter, req *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (h *Handlers) Metrics(w http.ResponseWriter, req *http.Request) {
	h.deps.Metrics.ServeHTTP(w, req)
}
