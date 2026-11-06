package xstenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type lim struct{ N int }

func decodeLim(tenant string, raw json.RawMessage) (lim, error) {
	var l lim
	if err := json.Unmarshal(raw, &l); err != nil {
		return l, err
	}
	if l.N < 0 {
		return l, errors.New("negative")
	}
	return l, nil
}

func publishLimits(t *testing.T, b *fakeBucket, gen int64, tenants map[string]string) {
	t.Helper()
	parts := []string{}
	for k, v := range tenants {
		parts = append(parts, fmt.Sprintf("%q: %s", k, v))
	}
	doc := fmt.Sprintf(`{"schema":1,"tenants":{%s}}`, strings.Join(parts, ","))
	publish(t, b, gen, map[string][]byte{"limits/mimir.json": []byte(doc)})
}

func decodeFailureCount(reg *prometheus.Registry, engine string) float64 {
	mfs, _ := reg.Gather()
	for _, mf := range mfs {
		if mf.GetName() != "xscaler_admin_store_tenant_decode_failures_total" {
			continue
		}
		for _, m := range mf.Metric {
			if m.Label[0].GetValue() == engine {
				return m.Counter.GetValue()
			}
		}
	}
	return 0
}

func TestSourceApplyKeepPreviousAndDrop(t *testing.T) {
	b := newFakeBucket()
	publishLimits(t, b, 1, map[string]string{"a": `{"N":1}`, "b": `{"N":2}`, "c": `{"N":3}`})
	r, reg := newReader(t, b, "")
	src := NewSource(r, "mimir", decodeLim, nil, reg)
	if src.Applied() {
		t.Fatal("applied before any snapshot")
	}
	r.poll(context.Background())
	if !src.Applied() {
		t.Fatal("not applied")
	}
	if v, ok := src.Get("b"); !ok || v.N != 2 {
		t.Fatalf("b = %+v %v", v, ok)
	}

	// a breaks (keeps 1), b is dropped, c changes, d breaks on first sight.
	publishLimits(t, b, 2, map[string]string{"a": `{"N":-1}`, "c": `{"N":30}`, "d": `{"N":"x"}`})
	r.poll(context.Background())
	all := src.All()
	if len(all) != 2 || all["a"].N != 1 || all["c"].N != 30 {
		t.Fatalf("all = %+v", all)
	}
	if _, ok := src.Get("b"); ok {
		t.Fatal("dropped tenant still served")
	}
	if _, ok := src.Get("d"); ok {
		t.Fatal("undecodable new tenant served")
	}
	if got := decodeFailureCount(reg, "mimir"); got != 2 {
		t.Fatalf("decode failures = %v", got)
	}
}

func TestSourceSkipsUnchangedGeneration(t *testing.T) {
	b := newFakeBucket()
	publishLimits(t, b, 1, map[string]string{"a": `{"N":1}`})
	r, reg := newReader(t, b, "")
	calls := 0
	src := NewSource(r, "mimir", func(tn string, raw json.RawMessage) (lim, error) {
		calls++
		return decodeLim(tn, raw)
	}, nil, reg)
	r.poll(context.Background())
	r.notify(r.Snapshot())
	if calls != 1 {
		t.Fatalf("decode calls = %d", calls)
	}
	_ = src
}

func TestSourceAppliesCacheRestoredSnapshotAtConstruction(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publishLimits(t, b, 5, map[string]string{"a": `{"N":7}`})
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	down := newFakeBucket()
	down.down = true
	r2, reg := newReader(t, down, dir)
	src := NewSource(r2, "mimir", decodeLim, nil, reg)
	if !src.Applied() {
		t.Fatal("not applied at construction")
	}
	if v, ok := src.Get("a"); !ok || v.N != 7 {
		t.Fatalf("a = %+v %v", v, ok)
	}
	if err := src.WaitApplied(context.Background(), time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestSourceSharedRegistry(t *testing.T) {
	b := newFakeBucket()
	r, reg := newReader(t, b, "")
	NewSource(r, "mimir", decodeLim, nil, reg)
	NewSource(r, "loki", decodeLim, nil, reg)
}

func TestSourceWaitApplied(t *testing.T) {
	b := newFakeBucket()
	r, reg := newReader(t, b, "")
	src := NewSource(r, "mimir", decodeLim, nil, reg)

	err := src.WaitApplied(context.Background(), 20*time.Millisecond)
	if err == nil || errors.Is(err, context.Canceled) {
		t.Fatalf("timeout err = %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- src.WaitApplied(ctx, 0) }()
	select {
	case <-done:
		t.Fatal("returned early")
	case <-time.After(20 * time.Millisecond):
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("ctx err = %v", err)
	}

	publishLimits(t, b, 1, map[string]string{"a": `{"N":1}`})
	go func() { done <- src.WaitApplied(context.Background(), 0) }()
	time.Sleep(10 * time.Millisecond)
	r.poll(context.Background())
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestSourceConcurrentGetDuringApply(t *testing.T) {
	b := newFakeBucket()
	publishLimits(t, b, 1, map[string]string{"a": `{"N":1}`})
	r, reg := newReader(t, b, "")
	src := NewSource(r, "mimir", decodeLim, nil, reg)
	r.poll(context.Background())

	stop := make(chan struct{})
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				if _, ok := src.Get("a"); !ok {
					t.Error("a vanished")
					return
				}
				for range src.All() {
				}
				_ = src.Applied()
			}
		}()
	}
	for i := int64(2); i < 40; i++ {
		publishLimits(t, b, i, map[string]string{"a": fmt.Sprintf(`{"N":%d}`, i)})
		r.poll(context.Background())
	}
	close(stop)
	wg.Wait()
	if v, _ := src.Get("a"); v.N != 39 {
		t.Fatalf("a = %+v", v)
	}
}

func TestSourceNotAppliedWithoutOwnLimits(t *testing.T) {
	b := newFakeBucket()
	publish(t, b, 1, map[string][]byte{
		"tenants.json":     golden(t, "tenants.json"),
		"limits/loki.json": []byte(`{"schema":1,"tenants":{"a":{"N":1}}}`),
	})
	r, reg := newReader(t, b, "")
	src := NewSource(r, "mimir", decodeLim, nil, reg)
	r.poll(context.Background())
	if src.Applied() {
		t.Fatal("applied from a snapshot without limits/mimir.json")
	}
	if err := src.WaitApplied(context.Background(), 20*time.Millisecond); err == nil {
		t.Fatal("WaitApplied satisfied without own limits")
	}

	publishLimits(t, b, 2, map[string]string{"a": `{"N":5}`})
	r.poll(context.Background())
	if !src.Applied() {
		t.Fatal("not applied once limits/mimir.json is listed")
	}
	if v, _ := src.Get("a"); v.N != 5 {
		t.Fatalf("a = %+v", v)
	}
}

func TestSourceSkipsDecodeWhenOnlyOtherObjectsChange(t *testing.T) {
	b := newFakeBucket()
	objs := map[string][]byte{
		"keys.json":         []byte(`{"schema":1,"keys":{}}`),
		"limits/mimir.json": []byte(`{"schema":1,"tenants":{"a":{"N":1}}}`),
	}
	publish(t, b, 1, objs)
	r, reg := newReader(t, b, "")
	calls := 0
	src := NewSource(r, "mimir", func(tn string, raw json.RawMessage) (lim, error) {
		calls++
		return decodeLim(tn, raw)
	}, nil, reg)
	r.poll(context.Background())
	if calls != 1 {
		t.Fatalf("decode calls = %d", calls)
	}

	objs["keys.json"] = []byte(`{"schema":1,"keys":{"x":{"tenant_id":"a"}}}`)
	publish(t, b, 2, objs)
	r.poll(context.Background())
	if r.Snapshot().Generation() != 2 {
		t.Fatal("generation 2 not swapped in")
	}
	if calls != 1 {
		t.Fatalf("decode called for a keys-only change: %d", calls)
	}
	if v, ok := src.Get("a"); !ok || v.N != 1 {
		t.Fatalf("a = %+v %v", v, ok)
	}

	// A real change decodes again.
	objs["limits/mimir.json"] = []byte(`{"schema":1,"tenants":{"a":{"N":2}}}`)
	publish(t, b, 3, objs)
	r.poll(context.Background())
	if calls != 2 {
		t.Fatalf("decode calls = %d", calls)
	}
	if v, _ := src.Get("a"); v.N != 2 {
		t.Fatalf("a = %+v", v)
	}
}

func gaugeValue(reg *prometheus.Registry, name, engine string) (float64, bool) {
	mfs, _ := reg.Gather()
	for _, mf := range mfs {
		if mf.GetName() != name {
			continue
		}
		for _, m := range mf.Metric {
			if m.Label[0].GetValue() == engine {
				return m.Gauge.GetValue(), true
			}
		}
	}
	return 0, false
}

type captureLogger struct {
	mu    sync.Mutex
	lines []string
}

func (c *captureLogger) Log(kv ...interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lines = append(c.lines, fmt.Sprint(kv...))
	return nil
}

func (c *captureLogger) count(sub string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, l := range c.lines {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

func TestSourceLimitsMissingKeepsServingAndSignals(t *testing.T) {
	const metric = "xscaler_admin_store_engine_limits_missing"
	b := newFakeBucket()
	publishLimits(t, b, 1, map[string]string{"a": `{"N":3}`})
	r, reg := newReader(t, b, "")
	lg := &captureLogger{}
	src := NewSource(r, "mimir", decodeLim, lg, reg)
	r.poll(context.Background())
	if v, ok := gaugeValue(reg, metric, "mimir"); !ok || v != 0 {
		t.Fatalf("gauge = %v %v, want 0", v, ok)
	}

	// Generation 2 lists only loki limits.
	publish(t, b, 2, map[string][]byte{
		"tenants.json":     golden(t, "tenants.json"),
		"limits/loki.json": []byte(`{"schema":1,"tenants":{"a":{"N":1}}}`),
	})
	r.poll(context.Background())
	if v, _ := src.Get("a"); v.N != 3 {
		t.Fatalf("a = %+v, want last decoded value kept", v)
	}
	if v, _ := gaugeValue(reg, metric, "mimir"); v != 1 {
		t.Fatalf("gauge = %v, want 1", v)
	}
	if n := lg.count("no limits object"); n != 1 {
		t.Fatalf("warnings = %d, want 1", n)
	}

	// A second pass over the same generation does not warn again.
	src.apply(r.Snapshot())
	if n := lg.count("no limits object"); n != 1 {
		t.Fatalf("warnings = %d after repeat, want 1", n)
	}

	// A new generation that still lacks the object warns once more.
	publish(t, b, 3, map[string][]byte{
		"tenants.json":     golden(t, "tenants.json"),
		"limits/loki.json": []byte(`{"schema":1,"tenants":{"a":{"N":1}}}`),
	})
	r.poll(context.Background())
	if n := lg.count("no limits object"); n != 2 {
		t.Fatalf("warnings = %d, want 2", n)
	}

	// The object returns: gauge drops to 0 and new limits apply.
	publishLimits(t, b, 4, map[string]string{"a": `{"N":9}`})
	r.poll(context.Background())
	if v, _ := gaugeValue(reg, metric, "mimir"); v != 0 {
		t.Fatalf("gauge = %v, want 0", v)
	}
	if v, _ := src.Get("a"); v.N != 9 {
		t.Fatalf("a = %+v", v)
	}
}

func TestSourceAppliesEqualGenerationWithChangedLimits(t *testing.T) {
	dir := t.TempDir()
	b := newFakeBucket()
	publishLimits(t, b, 42, map[string]string{"a": `{"N":1}`})
	r, _ := newReader(t, b, dir)
	r.poll(context.Background())

	publishLimits(t, b, 42, map[string]string{"a": `{"N":2}`})
	r2, reg := newReader(t, b, dir)
	src := NewSource(r2, "mimir", decodeLim, nil, reg)
	if v, _ := src.Get("a"); v.N != 1 {
		t.Fatalf("a = %+v, want cached value", v)
	}
	r2.poll(context.Background())
	if v, _ := src.Get("a"); v.N != 2 {
		t.Fatalf("a = %+v, want bucket value", v)
	}
}
