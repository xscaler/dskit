package xstenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-kit/log"
	"github.com/go-kit/log/level"
	"github.com/prometheus/client_golang/prometheus"
)

// DecodeFunc turns the engine-native limits block of one tenant into the
// engine's own type.
type DecodeFunc[T any] func(tenant string, raw json.RawMessage) (T, error)

// Source holds the decoded per-tenant limits of one engine. It follows a
// Reader and swaps in a new immutable map for each applied generation.
type Source[T any] struct {
	engine  string
	decode  DecodeFunc[T]
	logger  log.Logger
	fails   prometheus.Counter
	missing prometheus.Gauge

	cur     atomic.Pointer[map[string]T]
	applied chan struct{}

	mu       sync.Mutex
	haveGen  bool
	lastGen  int64
	lastHash string

	warnedGen  int64
	haveWarned bool
}

// NewSource registers on r and applies r's snapshot at once if it already has
// one (restored from the disk cache), so Applied is true on return in that
// case. reg may be nil.
func NewSource[T any](r *Reader, engine string, decode DecodeFunc[T], logger log.Logger, reg prometheus.Registerer) *Source[T] {
	if logger == nil {
		logger = log.NewNopLogger()
	}
	s := &Source[T]{
		engine:  engine,
		decode:  decode,
		logger:  logger,
		fails:   decodeFailures(reg).WithLabelValues(engine),
		missing: limitsMissing(reg).WithLabelValues(engine),
		applied: make(chan struct{}),
	}
	r.OnUpdate(s.apply)
	if snap := r.Snapshot(); snap != nil {
		s.apply(snap)
	}
	return s
}

// decodeFailures returns the shared counter vec, reusing it when another
// Source already registered it on reg.
func decodeFailures(reg prometheus.Registerer) *prometheus.CounterVec {
	v := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "xscaler_admin_store_tenant_decode_failures_total",
		Help: "Tenant limit blocks that failed to decode, by engine. The previous value is kept.",
	}, []string{"engine"})
	if reg == nil {
		return v
	}
	if err := reg.Register(v); err != nil {
		var are prometheus.AlreadyRegisteredError
		if errors.As(err, &are) {
			return are.ExistingCollector.(*prometheus.CounterVec)
		}
	}
	return v
}

// limitsMissing returns the shared gauge vec, reusing it when another Source
// already registered it on reg.
func limitsMissing(reg prometheus.Registerer) *prometheus.GaugeVec {
	v := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "xscaler_admin_store_engine_limits_missing",
		Help: "1 when the snapshot being served has no limits object for the engine and the last decoded limits are kept, else 0.",
	}, []string{"engine"})
	if reg == nil {
		return v
	}
	if err := reg.Register(v); err != nil {
		var are prometheus.AlreadyRegisteredError
		if errors.As(err, &are) {
			return are.ExistingCollector.(*prometheus.GaugeVec)
		}
	}
	return v
}

func (s *Source[T]) apply(snap *Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !snap.HasLimits(s.engine) {
		// Nothing of ours in this snapshot: keep what we serve (retention
		// settings must not vanish) and do not count it as applied.
		s.missing.Set(1)
		if !s.haveWarned || s.warnedGen != snap.Generation() {
			s.haveWarned, s.warnedGen = true, snap.Generation()
			level.Warn(s.logger).Log("msg", "admin store snapshot has no limits object for the engine, keeping the last decoded limits", "engine", s.engine, "generation", snap.Generation())
		}
		return
	}
	s.missing.Set(0)
	hash := snap.lhash[s.engine]
	if s.haveGen && hash == s.lastHash {
		// Same limits object as before: the decoded map is still right.
		s.lastGen = snap.Generation()
		return
	}
	var prev map[string]T
	if p := s.cur.Load(); p != nil {
		prev = *p
	}
	raws := snap.Limits(s.engine)
	next := make(map[string]T, len(raws))
	for tenant, raw := range raws {
		v, err := s.decode(tenant, raw)
		if err != nil {
			s.fails.Inc()
			level.Warn(s.logger).Log("msg", "decoding tenant limits failed", "engine", s.engine, "tenant", tenant, "err", err)
			if old, ok := prev[tenant]; ok {
				next[tenant] = old
			}
			continue
		}
		next[tenant] = v
	}
	first := !s.haveGen
	s.cur.Store(&next)
	s.haveGen, s.lastGen, s.lastHash = true, snap.Generation(), hash
	if first {
		close(s.applied)
	}
}

// Get returns the tenant's decoded value.
func (s *Source[T]) Get(tenant string) (T, bool) {
	var zero T
	p := s.cur.Load()
	if p == nil {
		return zero, false
	}
	v, ok := (*p)[tenant]
	return v, ok
}

// All returns every tenant's value. The map is built once per applied
// generation and must not be modified.
func (s *Source[T]) All() map[string]T {
	if p := s.cur.Load(); p != nil {
		return *p
	}
	return nil
}

// Applied reports whether a snapshot containing this engine's limits object
// has been decoded and swapped in. A snapshot without it does not count.
func (s *Source[T]) Applied() bool {
	select {
	case <-s.applied:
		return true
	default:
		return false
	}
}

// WaitApplied blocks until a snapshot with this engine's limits is applied. A timeout of zero or
// less waits until ctx is done.
func (s *Source[T]) WaitApplied(ctx context.Context, timeout time.Duration) error {
	if s.Applied() {
		return nil
	}
	var expired <-chan time.Time
	if timeout > 0 {
		t := time.NewTimer(timeout)
		defer t.Stop()
		expired = t.C
	}
	select {
	case <-s.applied:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-expired:
		return fmt.Errorf("xstenant: %s limits not applied within %s", s.engine, timeout)
	}
}
