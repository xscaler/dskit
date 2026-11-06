package xstenant

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

const pfx = "admin/v1/"

var errNotFound = errors.New("not found")

// fakeBucket is an in-memory Bucket that counts Get calls per object.
type fakeBucket struct {
	mu    sync.Mutex
	objs  map[string][]byte
	gets  map[string]int
	down  bool
	order []string
}

func newFakeBucket() *fakeBucket {
	return &fakeBucket{objs: map[string][]byte{}, gets: map[string]int{}}
}

func (b *fakeBucket) Get(_ context.Context, name string) (io.ReadCloser, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.gets[name]++
	b.order = append(b.order, name)
	if b.down {
		return nil, errors.New("bucket down")
	}
	o, ok := b.objs[name]
	if !ok {
		return nil, errNotFound
	}
	return io.NopCloser(bytes.NewReader(o)), nil
}

func (b *fakeBucket) IsObjNotFoundErr(err error) bool { return errors.Is(err, errNotFound) }

func (b *fakeBucket) set(name string, data []byte) {
	b.mu.Lock()
	b.objs[name] = data
	b.mu.Unlock()
}

func (b *fakeBucket) resetGets() {
	b.mu.Lock()
	b.gets = map[string]int{}
	b.mu.Unlock()
}

func (b *fakeBucket) getCount(name string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.gets[name]
}

func (b *fakeBucket) totalGets() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for _, c := range b.gets {
		n += c
	}
	return n
}

func sha(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func golden(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// publish writes the objects and a manifest for the generation to the bucket.
// Objects are overwritten before the manifest, as the publisher does.
func publish(t *testing.T, b *fakeBucket, gen int64, objs map[string][]byte) {
	t.Helper()
	man := manifest{Schema: 1, Generation: gen, PublishedAt: time.Unix(1_800_000_000+gen, 0).UTC(), Objects: map[string]string{}}
	for name, data := range objs {
		b.set(pfx+name, data)
		man.Objects[pfx+name] = sha(data)
	}
	raw, err := json.MarshalIndent(man, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	b.set(pfx+manifestName, raw)
}

func goldenObjects(t *testing.T) map[string][]byte {
	return map[string][]byte{
		"tenants.json":       golden(t, "tenants.json"),
		"keys.json":          golden(t, "keys.json"),
		"limits/mimir.json":  golden(t, "limits/mimir.json"),
		"limits/loki.json":   golden(t, "limits/loki.json"),
		"limits/tempo.json":  golden(t, "limits/tempo.json"),
		"unknown/other.json": []byte(`{"schema": 7}`),
	}
}

func newReader(t *testing.T, b Bucket, cacheDir string) (*Reader, *prometheus.Registry) {
	t.Helper()
	reg := prometheus.NewRegistry()
	r, err := New(Config{CacheDir: cacheDir, MaxObjectBytes: 1 << 20}, b, nil, reg)
	if err != nil {
		t.Fatal(err)
	}
	return r, reg
}

func failures(r *Reader, object, reason string) float64 {
	return testutil.ToFloat64(r.m.fetchFailures.WithLabelValues(object, reason))
}

func TestHappyPath(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, reg := newReader(t, b, "")

	if r.Ready() || r.Snapshot() != nil {
		t.Fatal("reader ready before first poll")
	}
	r.poll(context.Background())
	if !r.Ready() {
		t.Fatal("reader not ready after poll")
	}
	s := r.Snapshot()
	if s.Generation() != 10 {
		t.Fatalf("generation = %d", s.Generation())
	}
	if !s.PublishedAt().Equal(time.Unix(1_800_000_010, 0)) {
		t.Fatalf("published_at = %v", s.PublishedAt())
	}

	st, ok := s.State("t-beta")
	if !ok || st.State != StateSuspended || st.OrgID != "org-2" || st.PlanID != "plan-pro" {
		t.Fatalf("state = %+v %v", st, ok)
	}
	if _, ok := s.State("nobody"); ok {
		t.Fatal("unexpected tenant")
	}

	var want, got any
	if err := json.Unmarshal(golden(t, "limits/mimir.json"), &struct {
		Tenants *any `json:"tenants"`
	}{&want}); err != nil {
		t.Fatal(err)
	}
	mimir := s.Limits("mimir")
	if len(mimir) == 0 {
		t.Fatal("no mimir limits")
	}
	raw, _ := json.Marshal(mimir)
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	wb, _ := json.Marshal(want)
	gb, _ := json.Marshal(got)
	if !bytes.Equal(wb, gb) {
		t.Fatalf("mimir limits differ:\n%s\n%s", wb, gb)
	}
	var alpha map[string]any
	if err := json.Unmarshal(s.Limits("tempo")["t-alpha"], &alpha); err != nil {
		t.Fatal(err)
	}
	if _, ok := alpha["compaction"]; !ok {
		t.Fatalf("tempo block not passed through: %v", alpha)
	}
	if s.Limits("loki")["t-gamma"] == nil || s.Limits("nope") != nil {
		t.Fatal("loki/unknown engine limits wrong")
	}

	if v := testutil.ToFloat64(r.m.generation); v != 10 {
		t.Fatalf("generation metric = %v", v)
	}
	if v := testutil.ToFloat64(r.m.lastSuccess); v == 0 {
		t.Fatal("last success not set")
	}
	if n, err := testutil.GatherAndCount(reg, "xscaler_admin_store_published_timestamp_seconds"); err != nil || n != 1 {
		t.Fatalf("published metric: %d %v", n, err)
	}
}

func TestUnchangedGenerationFetchesNothingButManifest(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	b.resetGets()
	r.poll(context.Background())
	if n := b.totalGets(); n != 1 || b.getCount(pfx+manifestName) != 1 {
		t.Fatalf("gets = %v", b.gets)
	}
}

func TestOnlyChangedObjectsFetched(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	objs["limits/loki.json"] = []byte(`{"schema":1,"tenants":{"t-alpha":{"retention_period":"1h"}}}`)
	publish(t, b, 11, objs)
	b.resetGets()
	r.poll(context.Background())

	if r.Snapshot().Generation() != 11 {
		t.Fatal("not advanced")
	}
	if b.totalGets() != 2 || b.getCount(pfx+"limits/loki.json") != 1 {
		t.Fatalf("gets = %v", b.gets)
	}
	if _, ok := r.Snapshot().State("t-alpha"); !ok {
		t.Fatal("unchanged tenants doc lost")
	}
	if string(r.Snapshot().Limits("loki")["t-alpha"]) != `{"retention_period":"1h"}` {
		t.Fatalf("loki = %s", r.Snapshot().Limits("loki")["t-alpha"])
	}
}

func TestTornPublishKeepsOldSnapshot(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	// The manifest advertises a hash, then the object is overwritten by a
	// newer publish before the reader fetches it.
	objs["tenants.json"] = []byte(`{"schema":1,"tenants":{}}`)
	publish(t, b, 11, objs)
	b.set(pfx+"tenants.json", []byte(`{"schema":1,"tenants":{"x":{}}}`))
	r.poll(context.Background())

	if r.Snapshot().Generation() != 10 {
		t.Fatalf("generation = %d", r.Snapshot().Generation())
	}
	if _, ok := r.Snapshot().State("t-alpha"); !ok {
		t.Fatal("old state lost")
	}
	if failures(r, "tenants.json", reasonHash) < 1 {
		t.Fatal("hash mismatch not counted")
	}
}

func TestGenerationBackwardsIgnored(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	objs["tenants.json"] = []byte(`{"schema":1,"tenants":{}}`)
	publish(t, b, 9, objs)
	b.resetGets()
	r.poll(context.Background())

	if r.Snapshot().Generation() != 10 {
		t.Fatalf("generation = %d", r.Snapshot().Generation())
	}
	if b.totalGets() != 1 {
		t.Fatalf("fetched objects for a lower generation: %v", b.gets)
	}
	if failures(r, manifestName, reasonGeneration) != 1 {
		t.Fatal("backwards generation not counted")
	}
}

func TestUnknownSchemaRejected(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	// Unknown manifest schema.
	raw := []byte(`{"schema":2,"generation":11,"published_at":"2026-11-04T12:00:00Z","objects":{}}`)
	b.set(pfx+manifestName, raw)
	r.poll(context.Background())
	if r.Snapshot().Generation() != 10 || failures(r, manifestName, reasonSchema) != 1 {
		t.Fatal("manifest schema 2 applied")
	}

	// Unknown document schema.
	objs["keys.json"] = []byte(`{"schema":2,"keys":{}}`)
	publish(t, b, 12, objs)
	r.poll(context.Background())
	if r.Snapshot().Generation() != 10 || failures(r, "keys.json", reasonSchema) != 1 {
		t.Fatal("document schema 2 applied")
	}
}

func TestOversizeRejected(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	objs["tenants.json"] = append([]byte(`{"schema":1,"tenants":{}}`), bytes.Repeat([]byte(" "), 2<<20)...)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())

	if r.Ready() {
		t.Fatal("applied an oversize object")
	}
	if failures(r, "tenants.json", reasonOversize) != 1 {
		t.Fatal("oversize not counted")
	}
}

func TestMissingManifestKeepsSnapshot(t *testing.T) {
	b := newFakeBucket()
	r, _ := newReader(t, b, "")
	r.poll(context.Background())
	if r.Ready() {
		t.Fatal("ready without a manifest")
	}
	if failures(r, manifestName, reasonNotFound) != 1 {
		t.Fatal("not_found not counted")
	}
}

func TestInvalidObjectNameRejected(t *testing.T) {
	b := newFakeBucket()
	raw := []byte(`{"schema":1,"generation":1,"published_at":"2026-11-04T12:00:00Z","objects":{"admin/v1/../../etc/passwd":"00"}}`)
	b.set(pfx+manifestName, raw)
	r, _ := newReader(t, b, t.TempDir())
	r.poll(context.Background())
	if r.Ready() || failures(r, manifestName, reasonName) != 1 {
		t.Fatal("unsafe object name accepted")
	}
}

func TestDiskCacheRestoreWithBucketDown(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())
	if !r.Ready() {
		t.Fatal("not ready")
	}

	down := newFakeBucket()
	down.down = true
	r2, _ := newReader(t, down, dir)
	if !r2.Ready() {
		t.Fatal("cache not restored")
	}
	if r2.Snapshot().Generation() != 10 {
		t.Fatalf("generation = %d", r2.Snapshot().Generation())
	}
	if st, ok := r2.Snapshot().State("t-gamma"); !ok || st.State != StateSoftLocked {
		t.Fatalf("state = %+v", st)
	}
	if r2.Snapshot().Limits("mimir")["t-alpha"] == nil {
		t.Fatal("limits not restored")
	}

	// A failing poll keeps the restored snapshot, and Run reports it to
	// callbacks.
	var gens []int64
	r2.OnUpdate(func(s *Snapshot) { gens = append(gens, s.Generation()) })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := r2.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if !r2.Ready() || len(gens) != 1 || gens[0] != 10 {
		t.Fatalf("gens = %v", gens)
	}

	// Exactly one generation directory and the current link are left.
	ents, _ := os.ReadDir(dir)
	if len(ents) != 2 {
		t.Fatalf("cache dir entries = %v", ents)
	}
}

func TestCorruptCacheIgnored(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	if err := os.WriteFile(filepath.Join(dir, "current", "tenants.json"), []byte(`{"schema":1,"tenants":{}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	down := newFakeBucket()
	down.down = true
	r2, _ := newReader(t, down, dir)
	if r2.Ready() {
		t.Fatal("corrupt cache applied")
	}

	// The next poll against a healthy bucket repairs the cache.
	r3, _ := newReader(t, b, dir)
	r3.poll(context.Background())
	r4, _ := newReader(t, down, dir)
	if !r4.Ready() {
		t.Fatal("cache not repaired")
	}
}

func TestAuthenticate(t *testing.T) {
	good, expired, future := "tok-good", "tok-expired", "tok-future"
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	next := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	keys := `{"schema":1,"keys":{` +
		`"` + sha([]byte(good)) + `":{"tenant_id":"t-1","scopes":["read","write"],"expires_at":null},` +
		`"` + sha([]byte(expired)) + `":{"tenant_id":"t-2","scopes":["read"],"expires_at":"` + past + `"},` +
		`"` + sha([]byte(future)) + `":{"tenant_id":"t-3","scopes":["read"],"expires_at":"` + next + `"}}}`
	objs := goldenObjects(t)
	objs["keys.json"] = []byte(keys)
	b := newFakeBucket()
	publish(t, b, 1, objs)
	r, _ := newReader(t, b, "")
	r.poll(context.Background())
	s := r.Snapshot()

	p, err := s.Authenticate(good)
	if err != nil || p.TenantID != "t-1" || len(p.Scopes) != 2 || p.Scopes[1] != "write" {
		t.Fatalf("good: %+v %v", p, err)
	}
	if _, err := s.Authenticate(expired); !errors.Is(err, ErrExpiredKey) {
		t.Fatalf("expired: %v", err)
	}
	if p, err := s.Authenticate(future); err != nil || p.TenantID != "t-3" {
		t.Fatalf("future: %+v %v", p, err)
	}
	if _, err := s.Authenticate("nope"); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("unknown: %v", err)
	}
}

func TestOnUpdateFires(t *testing.T) {
	b := newFakeBucket()
	objs := goldenObjects(t)
	publish(t, b, 10, objs)
	r, _ := newReader(t, b, "")
	var mu sync.Mutex
	var gens []int64
	r.OnUpdate(func(s *Snapshot) {
		mu.Lock()
		gens = append(gens, s.Generation())
		mu.Unlock()
	})
	r.poll(context.Background())
	r.poll(context.Background()) // unchanged: no callback
	objs["limits/tempo.json"] = []byte(`{"schema":1,"tenants":{}}`)
	publish(t, b, 11, objs)
	r.poll(context.Background())

	mu.Lock()
	defer mu.Unlock()
	if len(gens) != 2 || gens[0] != 10 || gens[1] != 11 {
		t.Fatalf("gens = %v", gens)
	}
}

func TestRunPollsAndStops(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, err := New(Config{PollInterval: 10 * time.Millisecond}, b, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	deadline := time.Now().Add(5 * time.Second)
	for !r.Ready() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !r.Ready() {
		t.Fatal("never ready")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not stop")
	}
}

func TestCacheCrashBeforeSwitchKeepsOldGeneration(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	// A second process downloads generation 11 and dies after writing the
	// new directory, before switching the link.
	publish(t, b, 11, goldenObjects(t))
	other, _ := newReader(t, b, t.TempDir())
	other.poll(context.Background())
	if other.Snapshot().Generation() != 11 {
		t.Fatal("generation 11 not fetched")
	}
	if _, err := r.writeGeneration(other.Snapshot()); err != nil {
		t.Fatal(err)
	}

	down := newFakeBucket()
	down.down = true
	r2, _ := newReader(t, down, dir)
	if !r2.Ready() || r2.Snapshot().Generation() != 10 {
		t.Fatalf("old cache not loaded: ready=%v", r2.Ready())
	}

	// The next successful write switches over and removes the orphan.
	r.poll(context.Background())
	r3, _ := newReader(t, down, dir)
	if r3.Snapshot() == nil || r3.Snapshot().Generation() != 11 {
		t.Fatal("generation 11 not loaded after switch")
	}
	gens, _ := filepath.Glob(filepath.Join(dir, "gen-*"))
	if len(gens) != 1 {
		t.Fatalf("generation dirs = %v", gens)
	}
}

func TestStartStopIsIdempotentAndWaits(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, err := New(Config{PollInterval: 10 * time.Millisecond}, b, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	stop := r.Start(context.Background())
	deadline := time.Now().Add(5 * time.Second)
	for !r.Ready() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !r.Ready() {
		t.Fatal("never ready")
	}
	stop()
	stop()
	b.resetGets()
	time.Sleep(50 * time.Millisecond)
	if b.totalGets() != 0 {
		t.Fatal("reader still polling after stop")
	}

	// A cancelled parent also ends the goroutine, and stop still returns.
	ctx, cancel := context.WithCancel(context.Background())
	stop2 := r.Start(ctx)
	cancel()
	stop2()
}

func TestCacheRestoreAcceptsLowerBucketGenerationOnce(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	// The bucket was rolled back to generation 4 while the pod was down.
	publish(t, b, 4, goldenObjects(t))
	r2, _ := newReader(t, b, dir)
	if r2.Snapshot().Generation() != 10 {
		t.Fatal("cache not restored")
	}
	r2.poll(context.Background())
	if g := r2.Snapshot().Generation(); g != 4 {
		t.Fatalf("generation = %d, want 4", g)
	}
	if failures(r2, manifestName, reasonGeneration) != 0 {
		t.Fatal("first bucket fetch counted as backwards")
	}

	// After that the check applies against bucket generations.
	publish(t, b, 3, goldenObjects(t))
	r2.poll(context.Background())
	if r2.Snapshot().Generation() != 4 || failures(r2, manifestName, reasonGeneration) != 1 {
		t.Fatalf("generation = %d", r2.Snapshot().Generation())
	}
}

func TestCacheIgnoredWhenKeyDiffers(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, err := New(Config{CacheDir: dir, CacheKey: "bucket-a/admin/v1/", MaxObjectBytes: 1 << 20}, b, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	r.poll(context.Background())

	down := newFakeBucket()
	down.down = true
	other, _ := New(Config{CacheDir: dir, CacheKey: "bucket-b/admin/v1/", MaxObjectBytes: 1 << 20}, down, nil, nil)
	if other.Ready() {
		t.Fatal("cache of another bucket applied")
	}
	same, _ := New(Config{CacheDir: dir, CacheKey: "bucket-a/admin/v1/", MaxObjectBytes: 1 << 20}, down, nil, nil)
	if !same.Ready() {
		t.Fatal("cache with matching key ignored")
	}
}

func TestNoRawBytesRetainedWithoutCacheDir(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 10, goldenObjects(t))
	r, _ := newReader(t, b, "")
	r.poll(context.Background())
	s := r.Snapshot()
	if len(s.raw) != 0 || s.rawMan != nil {
		t.Fatalf("raw bytes retained: %d objects", len(s.raw))
	}
	if len(s.hashes) == 0 {
		t.Fatal("hashes missing")
	}
}

func TestCacheRestoreEqualGenerationDifferentHashRefetched(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 42, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	// Same generation number, different tenants.json bytes in the bucket.
	objsB := goldenObjects(t)
	objsB["tenants.json"] = append(append([]byte{}, objsB["tenants.json"]...), '\n')
	publish(t, b, 42, objsB)

	r2, _ := newReader(t, b, dir)
	if r2.Snapshot() == nil || r2.Snapshot().Generation() != 42 {
		t.Fatal("cache not restored")
	}
	r2.poll(context.Background())
	if got, want := r2.Snapshot().hashes[pfx+"tenants.json"], sha(objsB["tenants.json"]); got != want {
		t.Fatalf("tenants.json hash = %s, want %s", got, want)
	}

	// Once confirmed by the bucket, an equal generation fetches nothing.
	b.resetGets()
	r2.poll(context.Background())
	if b.getCount("tenants.json") != 0 {
		t.Fatal("refetched after bucket confirmation")
	}
}

func TestCacheRestoreEqualGenerationSameHashesFetchesNothing(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publish(t, b, 42, goldenObjects(t))
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())
	r2, _ := newReader(t, b, dir)
	b.resetGets()
	r2.poll(context.Background())
	if n := b.totalGets(); n != 1 {
		t.Fatalf("gets = %d, want manifest only", n)
	}
}
