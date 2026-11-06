package xstenant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-kit/log"
	"github.com/go-kit/log/level"
	"github.com/prometheus/client_golang/prometheus"
)

// maxAttempts bounds how often one poll restarts after a torn publish.
const maxAttempts = 3

// Failure reasons used in xscaler_admin_store_fetch_failures_total.
const (
	reasonFetch      = "fetch"
	reasonNotFound   = "not_found"
	reasonOversize   = "oversize"
	reasonHash       = "hash_mismatch"
	reasonDecode     = "decode"
	reasonSchema     = "schema"
	reasonGeneration = "generation_backwards"
	reasonName       = "invalid_name"
)

type pollError struct {
	object string
	reason string
	err    error
}

func (e *pollError) Error() string { return fmt.Sprintf("%s: %s: %v", e.object, e.reason, e.err) }
func (e *pollError) Unwrap() error { return e.err }

// Reader polls the admin store and serves the latest verified Snapshot.
type Reader struct {
	cfg    Config
	bucket Bucket
	logger log.Logger
	m      *metrics
	now    func() time.Time

	snap atomic.Pointer[Snapshot]
	// fromBucket is set once this process has fetched a manifest from the
	// bucket. Until then snap may come from the disk cache and is not a
	// reference for the generation-backwards check.
	fromBucket atomic.Bool

	mu        sync.Mutex
	callbacks []func(*Snapshot)
}

// New returns a Reader. A valid disk cache, if configured, is loaded here so
// Snapshot is available before the first poll. reg may be nil.
func New(cfg Config, bucket Bucket, logger log.Logger, reg prometheus.Registerer) (*Reader, error) {
	if bucket == nil {
		return nil, errors.New("xstenant: bucket is required")
	}
	if logger == nil {
		logger = log.NewNopLogger()
	}
	cfg.applyDefaults()
	r := &Reader{
		cfg:    cfg,
		bucket: bucket,
		logger: logger,
		m:      newMetrics(reg),
		now:    time.Now,
	}
	if cfg.CacheDir != "" {
		r.loadCache()
	}
	return r, nil
}

// Ready reports whether a snapshot is available, from the bucket or the disk
// cache. It says nothing about whether an engine has applied that snapshot;
// engines gate on Source.Applied instead.
func (r *Reader) Ready() bool { return r.snap.Load() != nil }

// Snapshot returns the current snapshot, or nil before any state exists.
func (r *Reader) Snapshot() *Snapshot { return r.snap.Load() }

// OnUpdate registers f to run after each snapshot swap, including the swap of
// a snapshot restored from the disk cache (run at the start of Run).
func (r *Reader) OnUpdate(f func(*Snapshot)) {
	r.mu.Lock()
	r.callbacks = append(r.callbacks, f)
	r.mu.Unlock()
}

// Run polls until ctx is done. The first poll happens immediately.
func (r *Reader) Run(ctx context.Context) error {
	if s := r.snap.Load(); s != nil {
		r.notify(s)
	}
	t := time.NewTicker(r.cfg.PollInterval)
	defer t.Stop()
	for {
		r.poll(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// Start runs Run in a goroutine with a context derived from parent. The
// returned stop cancels that context and waits for the goroutine to exit. It
// is safe to call more than once and from several goroutines.
func (r *Reader) Start(parent context.Context) (stop func()) {
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = r.Run(ctx)
	}()
	return func() {
		cancel()
		<-done
	}
}

func (r *Reader) poll(ctx context.Context) {
	err := r.pollOnce(ctx)
	if err == nil {
		return
	}
	var pe *pollError
	if errors.As(err, &pe) {
		if pe.reason == reasonNotFound {
			level.Debug(r.logger).Log("msg", "admin store object not found", "object", pe.object)
		} else {
			level.Warn(r.logger).Log("msg", "admin store update failed, keeping current snapshot", "object", pe.object, "reason", pe.reason, "err", pe.err)
		}
		r.m.fetchFailures.WithLabelValues(pe.object, pe.reason).Inc()
		return
	}
	if ctx.Err() == nil {
		level.Warn(r.logger).Log("msg", "admin store update failed, keeping current snapshot", "err", err)
	}
}

func (r *Reader) pollOnce(ctx context.Context) error {
	var err error
	for range maxAttempts {
		var retry bool
		retry, err = r.attempt(ctx)
		if !retry {
			return err
		}
	}
	return err
}

// attempt runs one pass. retry is true when the pass saw a torn publish and
// the manifest should be fetched again.
func (r *Reader) attempt(ctx context.Context) (retry bool, err error) {
	rawMan, err := r.get(ctx, r.cfg.Prefix+manifestName)
	if err != nil {
		return false, wrapErr(manifestName, err)
	}
	man, err := r.decodeManifest(rawMan)
	if err != nil {
		return false, err
	}
	cur := r.snap.Load()
	if cur != nil {
		if r.fromBucket.Load() {
			if man.Generation < cur.man.Generation {
				return false, &pollError{manifestName, reasonGeneration, fmt.Errorf("generation %d is lower than %d", man.Generation, cur.man.Generation)}
			}
		} else if man.Generation < cur.man.Generation {
			level.Info(r.logger).Log("msg", "bucket generation is lower than the cached one, accepting it", "bucket", man.Generation, "cache", cur.man.Generation)
		}
		// An equal generation is only taken as current when the snapshot
		// was already confirmed by the bucket, or when every object hash
		// matches. A restored cache can hold different bytes under the same
		// generation number (for example after a bucket restore).
		if man.Generation == cur.man.Generation && (r.fromBucket.Load() || sameHashes(man.Objects, cur.hashes)) {
			r.fromBucket.Store(true)
			r.m.lastSuccess.Set(float64(r.now().Unix()))
			return false, nil
		}
	}

	fetched := map[string][]byte{}
	for name, want := range man.Objects {
		if cur != nil && cur.hashes[name] == want {
			continue
		}
		b, err := r.get(ctx, name)
		if err != nil {
			return false, wrapErr(r.short(name), err)
		}
		if got := hashHex(b); got != want {
			// The object belongs to a newer generation than the manifest.
			return true, &pollError{r.short(name), reasonHash, fmt.Errorf("sha256 %s, manifest has %s", got, want)}
		}
		fetched[name] = b
	}

	next, err := r.assemble(man, rawMan, fetched, cur)
	if err != nil {
		return false, err
	}
	r.swap(next)
	return false, nil
}

func sameHashes(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func (r *Reader) swap(next *Snapshot) {
	r.fromBucket.Store(true)
	r.snap.Store(next)
	r.m.generation.Set(float64(next.man.Generation))
	r.m.published.Set(float64(next.man.PublishedAt.Unix()))
	r.m.lastSuccess.Set(float64(r.now().Unix()))
	if r.cfg.CacheDir != "" {
		if err := r.writeCache(next); err != nil {
			level.Warn(r.logger).Log("msg", "writing admin store cache failed", "err", err)
		}
	}
	r.notify(next)
}

func (r *Reader) notify(s *Snapshot) {
	r.mu.Lock()
	cbs := append([]func(*Snapshot){}, r.callbacks...)
	r.mu.Unlock()
	for _, f := range cbs {
		f(s)
	}
}

func (r *Reader) decodeManifest(b []byte) (manifest, error) {
	var man manifest
	if err := json.Unmarshal(b, &man); err != nil {
		return man, &pollError{manifestName, reasonDecode, err}
	}
	if man.Schema > schemaVersion || man.Schema < 1 {
		return man, &pollError{manifestName, reasonSchema, fmt.Errorf("unsupported schema %d", man.Schema)}
	}
	for name := range man.Objects {
		if !strings.HasPrefix(name, r.cfg.Prefix) || path.Clean(name) != name || strings.HasSuffix(name, "/") {
			return man, &pollError{manifestName, reasonName, fmt.Errorf("invalid object name %q", name)}
		}
	}
	return man, nil
}

// assemble decodes the fetched objects and reuses the decoded form of the
// unchanged ones from cur.
func (r *Reader) assemble(man manifest, rawMan []byte, fetched map[string][]byte, cur *Snapshot) (*Snapshot, error) {
	s := &Snapshot{
		man:     man,
		tenants: map[string]TenantState{},
		keys:    map[string]keyRecord{},
		limits:  map[string]map[string]json.RawMessage{},
		hashes:  man.Objects,
		lhash:   map[string]string{},
		now:     r.now,
	}
	keepRaw := r.cfg.CacheDir != ""
	if keepRaw {
		s.raw = map[string][]byte{}
		s.rawMan = rawMan
	}
	tenantsPath := r.cfg.Prefix + tenantsName
	keysPath := r.cfg.Prefix + keysName
	limitsPrefix := r.cfg.Prefix + limitsDir

	for name := range man.Objects {
		b, isNew := fetched[name]
		if keepRaw {
			if isNew {
				s.raw[name] = b
			} else if cur != nil {
				s.raw[name] = cur.raw[name]
			}
		}
		switch {
		case name == tenantsPath:
			if !isNew {
				s.tenants = cur.tenants
				continue
			}
			var d tenantsDoc
			if err := decodeDoc(b, &d, &d.Schema); err != nil {
				return nil, wrapDecode(r.short(name), err)
			}
			s.tenants = d.Tenants
		case name == keysPath:
			if !isNew {
				s.keys = cur.keys
				continue
			}
			var d keysDoc
			if err := decodeDoc(b, &d, &d.Schema); err != nil {
				return nil, wrapDecode(r.short(name), err)
			}
			s.keys = d.Keys
		case strings.HasPrefix(name, limitsPrefix) && strings.HasSuffix(name, ".json"):
			engine := strings.TrimSuffix(strings.TrimPrefix(name, limitsPrefix), ".json")
			s.lhash[engine] = man.Objects[name]
			if !isNew {
				s.limits[engine] = cur.limits[engine]
				continue
			}
			var d limitsDoc
			if err := decodeDoc(b, &d, &d.Schema); err != nil {
				return nil, wrapDecode(r.short(name), err)
			}
			s.limits[engine] = d.Tenants
		}
	}
	return s, nil
}

func decodeDoc(b []byte, v any, schema *int) error {
	if err := json.Unmarshal(b, v); err != nil {
		return err
	}
	if *schema > schemaVersion || *schema < 1 {
		return errSchema{*schema}
	}
	return nil
}

type errSchema struct{ v int }

func (e errSchema) Error() string { return fmt.Sprintf("unsupported schema %d", e.v) }

func wrapDecode(object string, err error) error {
	var es errSchema
	if errors.As(err, &es) {
		return &pollError{object, reasonSchema, err}
	}
	return &pollError{object, reasonDecode, err}
}

func wrapErr(object string, err error) error {
	var pe *pollError
	if errors.As(err, &pe) {
		pe.object = object
		return pe
	}
	return &pollError{object, reasonFetch, err}
}

// get reads one object, enforcing the size cap.
func (r *Reader) get(ctx context.Context, name string) ([]byte, error) {
	rc, err := r.bucket.Get(ctx, name)
	if err != nil {
		if r.bucket.IsObjNotFoundErr(err) {
			return nil, &pollError{reason: reasonNotFound, err: err}
		}
		return nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, r.cfg.MaxObjectBytes+1))
	if err != nil {
		if r.bucket.IsObjNotFoundErr(err) {
			return nil, &pollError{reason: reasonNotFound, err: err}
		}
		return nil, err
	}
	if int64(len(b)) > r.cfg.MaxObjectBytes {
		return nil, &pollError{reason: reasonOversize, err: fmt.Errorf("larger than %d bytes", r.cfg.MaxObjectBytes)}
	}
	return b, nil
}

func (r *Reader) short(name string) string { return strings.TrimPrefix(name, r.cfg.Prefix) }

func hashHex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
