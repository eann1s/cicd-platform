package app

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"

	"github.com/eann1s/cicd-platform/consumers/go-service/internal/readiness"
	"github.com/rs/zerolog"
)


var (
	shutdownTimeout = 5 * time.Second
)

type App struct {
	server *http.Server
	ready readiness.Readiness
	log zerolog.Logger
	addr string
}

func NewApp(server *http.Server, ready readiness.Readiness, log zerolog.Logger, addr string) *App {
	return &App{
		server: server,
		ready: ready,
		log: log,
		addr: addr,
	}
}

func (a *App) Run(ctx context.Context) error {
	a.log.Info().Msg("starting app...")
	errCh := make(chan error, 1)

	ln, err := net.Listen("tcp", a.addr)
	if err != nil {
		a.log.Error().Err(err).Str("addr", a.addr).Msg("failed to start listener")
		return err
	}

	a.ready.SetReady(true)
	a.log.Info().Str("addr", a.addr).Msg("app is ready")

	go func() {
		err := a.server.Serve(ln)
		if err != nil && err != http.ErrServerClosed {
			a.log.Error().Err(err).Msg("failed to start server")
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		a.log.Error().Err(err).Msg("error received")
		if errr := a.ShutdownWithTimeout(shutdownTimeout); errr != nil {
			return errors.Join(err, errr)
		}
	case <-ctx.Done():
		a.log.Info().Msg("shutdown requested")
		if err := a.ShutdownWithTimeout(shutdownTimeout); err != nil {
			return err
		}
	}

	a.log.Info().Msg("app exited")
	return nil
}

func (a *App) ShutdownWithTimeout(timeout time.Duration) error {
	shutdownCtx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return a.server.Shutdown(shutdownCtx)
}

func (a *App) Shutdown(ctx context.Context) error {
	a.ready.SetReady(false)
	a.log.Info().Msg("app is shutting down")

	if err := a.server.Shutdown(ctx); err != nil {
		a.log.Error().Err(err).Msg("failed to shutdown server")
		return err
	}
	
	a.log.Info().Msg("app is shut down")
	return nil
}





