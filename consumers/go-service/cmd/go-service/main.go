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
	"github.com/eann1s/cicd-platform/consumers/go-service/internal/readiness"
	transporthttp "github.com/eann1s/cicd-platform/consumers/go-service/internal/transport/http"
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

	srv := newServer(log, ready, addr)

	app := app.NewApp(srv, ready, log, addr)

	if err = app.Run(ctx); err != nil {
		return err
	}

	return nil
}

func newServer(log zerolog.Logger, ready readiness.Readiness, addr string) *http.Server {
	deps := transporthttp.Deps{
		Ready: func() bool {
			return ready.IsReady()
		},
	}
	h := transporthttp.NewHandlers(deps)
	m := transporthttp.NewMux(h)
	return &http.Server{
		Addr:    addr,
		Handler: m,
	}
}
