package http

import "net/http"


func NewMux(h *Handlers) *http.ServeMux {
	m := http.NewServeMux()
	m.HandleFunc("/healthz", h.Healthz)
	m.HandleFunc("/readyz", h.Readyz)
	return m
}
