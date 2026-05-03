package http

import "net/http"


type Deps struct {
	Ready func() bool
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
