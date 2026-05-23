package readiness

import "sync/atomic"

type Readiness interface {
	IsReady() bool
	SetReady(bool)
}

type AtomicReadiness struct {
	ready atomic.Bool
}

func (r *AtomicReadiness) IsReady() bool {
	return r.ready.Load()
}

func (r *AtomicReadiness) SetReady(ready bool) {
	r.ready.Store(ready)
}
