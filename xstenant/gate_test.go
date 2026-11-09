package xstenant

import (
	"flag"
	"sync"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func gateReader(t *testing.T, tenants map[string]TenantState) (*Reader, *prometheus.Registry) {
	t.Helper()
	r, reg := newReader(t, newFakeBucket(), "")
	if tenants != nil {
		r.snap.Store(&Snapshot{tenants: tenants})
	}
	return r, reg
}

var gateTenants = map[string]TenantState{
	"active":    {State: StateActive},
	"locked":    {State: StateSoftLocked},
	"suspended": {State: StateSuspended},
	"future":    {State: "something_new"},
	"empty":     {},
}

func TestPushAllowed(t *testing.T) {
	r, _ := gateReader(t, gateTenants)
	cases := []struct {
		tenant  string
		allowed bool
		reason  string
	}{
		{"active", true, ReasonAllowed},
		{"locked", false, "billing_soft_locked"},
		{"suspended", true, ReasonAllowed},
		{"future", true, ReasonAllowed},
		{"empty", true, ReasonAllowed},
		{"nobody", true, "unknown_tenant"},
	}
	for _, c := range cases {
		ok, reason := r.PushAllowed(c.tenant)
		if ok != c.allowed || reason != c.reason {
			t.Errorf("%s: got (%v, %q), want (%v, %q)", c.tenant, ok, reason, c.allowed, c.reason)
		}
	}
}

func TestPushAllowedNilSafe(t *testing.T) {
	var nilSnap *Snapshot
	if ok, reason := nilSnap.PushAllowed("x"); !ok || reason != "no_state" {
		t.Errorf("nil snapshot: got (%v, %q)", ok, reason)
	}
	var nilReader *Reader
	if ok, reason := nilReader.PushAllowed("x"); !ok || reason != "no_state" {
		t.Errorf("nil reader: got (%v, %q)", ok, reason)
	}
	if deny, _ := nilReader.CheckPush("x", EnforceOn); deny {
		t.Error("nil reader denied")
	}
	r, _ := gateReader(t, nil)
	if ok, reason := r.PushAllowed("x"); !ok || reason != "no_state" {
		t.Errorf("no snapshot: got (%v, %q)", ok, reason)
	}
	if deny, reason := r.CheckPush("x", EnforceOn); deny || reason != "no_state" {
		t.Errorf("CheckPush no snapshot: got (%v, %q)", deny, reason)
	}
}

func decisions(r *Reader, mode, decision, reason string) float64 {
	return testutil.ToFloat64(r.decisions.WithLabelValues(mode, decision, reason))
}

func TestCheckPushModes(t *testing.T) {
	r, _ := gateReader(t, gateTenants)

	// off: always allow, nothing counted.
	for _, tn := range []string{"locked", "active", "nobody"} {
		if deny, _ := r.CheckPush(tn, EnforceOff); deny {
			t.Errorf("off denied %s", tn)
		}
	}
	if n := testutil.CollectAndCount(r.decisions); n != 0 {
		t.Errorf("off counted %d series", n)
	}

	// shadow: counts would_deny, never denies.
	if deny, reason := r.CheckPush("locked", EnforceShadow); deny || reason != ReasonSoftLocked {
		t.Errorf("shadow locked: got (%v, %q)", deny, reason)
	}
	if deny, _ := r.CheckPush("suspended", EnforceShadow); deny {
		t.Error("shadow denied suspended")
	}
	if got := decisions(r, "shadow", "would_deny", "billing_soft_locked"); got != 1 {
		t.Errorf("shadow would_deny = %v", got)
	}
	if got := decisions(r, "shadow", "allow", "allowed"); got != 1 {
		t.Errorf("shadow allow = %v", got)
	}
	if got := decisions(r, "shadow", "deny", "billing_soft_locked"); got != 0 {
		t.Errorf("shadow deny = %v", got)
	}

	// on: denies only soft locked.
	if deny, reason := r.CheckPush("locked", EnforceOn); !deny || reason != ReasonSoftLocked {
		t.Errorf("on locked: got (%v, %q)", deny, reason)
	}
	for _, tn := range []string{"active", "suspended", "future", "nobody"} {
		if deny, _ := r.CheckPush(tn, EnforceOn); deny {
			t.Errorf("on denied %s", tn)
		}
	}
	if got := decisions(r, "on", "deny", "billing_soft_locked"); got != 1 {
		t.Errorf("on deny = %v", got)
	}
	if got := decisions(r, "on", "allow", "unknown_tenant"); got != 1 {
		t.Errorf("on allow unknown = %v", got)
	}

	// an unknown mode value behaves as off.
	if deny, _ := r.CheckPush("locked", EnforceMode(99)); deny {
		t.Error("unknown mode denied")
	}
}

func TestStateDecisionsCounterShared(t *testing.T) {
	// The existing reader metrics panic on a second Reader per registry, so
	// the shared counter is checked at the helper the Reader uses.
	reg := prometheus.NewRegistry()
	a, b := stateDecisions(reg), stateDecisions(reg)
	if a != b {
		t.Fatal("second registration did not return the existing counter")
	}
	// Separate registries each get their own counter.
	if c := stateDecisions(prometheus.NewRegistry()); c == a {
		t.Fatal("counter shared across registries")
	}
	// nil registerer works.
	r, err := New(Config{MaxObjectBytes: 1 << 20}, newFakeBucket(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	r.snap.Store(&Snapshot{tenants: gateTenants})
	if deny, _ := r.CheckPush("locked", EnforceOn); !deny {
		t.Error("nil registerer reader did not deny")
	}
}

func TestEnforceModeParse(t *testing.T) {
	for in, want := range map[string]EnforceMode{
		"off": EnforceOff, "shadow": EnforceShadow, "on": EnforceOn,
		"ON": EnforceOn, " Shadow ": EnforceShadow,
	} {
		got, err := ParseEnforceMode(in)
		if err != nil || got != want {
			t.Errorf("%q: got (%v, %v)", in, got, err)
		}
	}
	for _, in := range []string{"", "true", "enforce", "1"} {
		if _, err := ParseEnforceMode(in); err == nil {
			t.Errorf("%q: want error", in)
		}
	}
	for m, s := range map[EnforceMode]string{EnforceOff: "off", EnforceShadow: "shadow", EnforceOn: "on"} {
		if m.String() != s {
			t.Errorf("String(%d) = %q", int(m), m.String())
		}
	}
	var zero EnforceMode
	if zero != EnforceOff {
		t.Error("zero value is not off")
	}
	fs := flag.NewFlagSet("x", flag.ContinueOnError)
	var m EnforceMode
	fs.Var(&m, "mode", "")
	if err := fs.Parse([]string{"-mode", "shadow"}); err != nil || m != EnforceShadow {
		t.Errorf("flag: %v %v", m, err)
	}
	if err := m.Set("bogus"); err == nil || m != EnforceShadow {
		t.Errorf("bad Set changed value or passed: %v %v", m, err)
	}
}

func TestCheckPushConcurrent(t *testing.T) {
	r, _ := gateReader(t, gateTenants)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				if j%50 == 0 {
					r.snap.Store(&Snapshot{tenants: gateTenants})
				}
				r.CheckPush("locked", EnforceMode(i%3))
				r.PushAllowed("active")
			}
		}(i)
	}
	wg.Wait()
}
