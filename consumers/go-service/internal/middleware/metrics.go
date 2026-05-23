package middleware

import (
	"net/http"
	"time"

	"github.com/eann1s/cicd-platform/consumers/go-service/internal/obs"
)

type Middleware func(http.Handler) http.Handler

func Chain(h http.Handler, mws ...Middleware) http.Handler {
	for i := len(mws) - 1; i >= 0; i-- {
		h = mws[i](h)
	}
	return h
}

func HttpMetrics(m *obs.Metrics) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/metrics" || r.URL.Path == "metrics" {
				next.ServeHTTP(w, r)
				return
			}
			startTime := time.Now()
			wrapper := &responseWrapper{ResponseWriter: w, status: http.StatusOK}

			next.ServeHTTP(wrapper, r)

			route := getRoute(r)
			method := r.Method
			statusClass := getStatusClass(wrapper.status)

			duration := time.Now().Sub(startTime)

			m.RequestsTotal.WithLabelValues(route, method, statusClass).Inc()
			m.RequestDuration.WithLabelValues(route, method, statusClass).Observe(float64(duration.Seconds()))
		})
	}
}

func getRoute(r *http.Request) string {
	route := r.Pattern
	if route == "" {
		route = r.URL.Path
		if route == "" {
			route = "unknown"
		}
	}
	return route
}

func getStatusClass(status int) string {
	if status < 200 {
		return "1xx"
	} else if status >= 200 && status < 300 {
		return "2xx"
	} else if status >= 300 && status < 400 {
		return "3xx"
	} else if status >= 400 && status < 500 {
		return "4xx"
	} else {
		return "5xx"
	}
}
