package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/eann1s/cicd-platform/consumers/go-service/internal/app"
	"github.com/eann1s/cicd-platform/consumers/go-service/internal/logger"
	"github.com/eann1s/cicd-platform/consumers/go-service/internal/middleware"
	"github.com/eann1s/cicd-platform/consumers/go-service/internal/obs"
	"github.com/eann1s/cicd-platform/consumers/go-service/internal/readiness"
	transporthttp "github.com/eann1s/cicd-platform/consumers/go-service/internal/transport/http"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rs/zerolog"
)

var (
	addr = ":8080"
)

func main() {
	err := run()
	if err != nil {
		_ = fmt.Errorf("%+v", err)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log, err := logger.NewLogger("info", "1.0.0")
	if err != nil {
		return err
	}

	ready := &readiness.AtomicReadiness{}

	reg := prometheus.NewRegistry()
	m := obs.NewMetrics()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		m.RequestsTotal,
		m.RequestDuration,
	)

	srv := newServer(log, ready, reg, m, addr)

	app := app.NewApp(srv, ready, log, addr)

	if err = app.Run(ctx); err != nil {
		return err
	}

	return nil
}

func newServer(log zerolog.Logger, ready readiness.Readiness, reg *prometheus.Registry, m *obs.Metrics, addr string) *http.Server {
	deps := transporthttp.Deps{
		Ready: func() bool {
			return ready.IsReady()
		},
		Metrics: promhttp.HandlerFor(reg, promhttp.HandlerOpts{}),
	}
	h := transporthttp.NewHandlers(deps)
	mux := transporthttp.NewMux(h)
	handler := middleware.Chain(mux, middleware.HttpMetrics(m))
	return &http.Server{
		Addr:    addr,
		Handler: handler,
	}
}
