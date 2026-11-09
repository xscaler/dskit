package xstenant

import (
	"errors"
	"fmt"
	"strings"

	"github.com/prometheus/client_golang/prometheus"
)

// Reasons returned with a push decision.
const (
	// ReasonSoftLocked is the only reason a push is ever denied.
	ReasonSoftLocked = "billing_soft_locked"
	// ReasonNoState means no snapshot is available yet.
	ReasonNoState = "no_state"
	// ReasonUnknownTenant means the snapshot has no entry for the tenant.
	ReasonUnknownTenant = "unknown_tenant"
	// ReasonAllowed is the reason for a tenant with a state other than soft_locked.
	ReasonAllowed = "allowed"
)

// PushAllowed reports whether the tenant may push. Only a soft locked tenant
// is denied. A nil snapshot, an unknown tenant, and any other state (active,
// suspended, or a value this version does not know) are allowed. It is safe to
// call on a nil Snapshot.
func (s *Snapshot) PushAllowed(tenant string) (allowed bool, reason string) {
	if s == nil {
		return true, ReasonNoState
	}
	st, ok := s.tenants[tenant]
	if !ok {
		return true, ReasonUnknownTenant
	}
	if st.State == StateSoftLocked {
		return false, ReasonSoftLocked
	}
	return true, ReasonAllowed
}

// PushAllowed applies Snapshot.PushAllowed to the snapshot currently served.
// It is safe to call on a nil Reader and does not count a decision.
func (r *Reader) PushAllowed(tenant string) (allowed bool, reason string) {
	if r == nil {
		return true, ReasonNoState
	}
	return r.snap.Load().PushAllowed(tenant)
}

// EnforceMode selects what CheckPush does with a soft locked tenant. The zero
// value is EnforceOff. It implements flag.Value.
type EnforceMode int

const (
	// EnforceOff never denies and does not count decisions.
	EnforceOff EnforceMode = iota
	// EnforceShadow allows every push and counts the ones that would be denied.
	EnforceShadow
	// EnforceOn denies pushes from soft locked tenants.
	EnforceOn
)

// ParseEnforceMode parses "off", "shadow" or "on" (case-insensitive).
func ParseEnforceMode(s string) (EnforceMode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "off":
		return EnforceOff, nil
	case "shadow":
		return EnforceShadow, nil
	case "on":
		return EnforceOn, nil
	}
	return EnforceOff, fmt.Errorf("xstenant: invalid enforce mode %q, want off, shadow or on", s)
}

// String returns the flag form of the mode.
func (m EnforceMode) String() string {
	switch m {
	case EnforceOff:
		return "off"
	case EnforceShadow:
		return "shadow"
	case EnforceOn:
		return "on"
	}
	return fmt.Sprintf("EnforceMode(%d)", int(m))
}

// Set implements flag.Value.
func (m *EnforceMode) Set(s string) error {
	v, err := ParseEnforceMode(s)
	if err != nil {
		return err
	}
	*m = v
	return nil
}

// Decision label values of xscaler_admin_store_state_decisions_total.
const (
	decisionAllow     = "allow"
	decisionDeny      = "deny"
	decisionWouldDeny = "would_deny"
)

// CheckPush applies the push gate for the tenant. deny is true only in mode
// EnforceOn and only for a soft locked tenant; reason is the PushAllowed
// reason. In EnforceShadow and EnforceOn the decision is counted in
// xscaler_admin_store_state_decisions_total. In EnforceOff (and any mode this
// version does not know) the push is allowed and nothing is counted.
func (r *Reader) CheckPush(tenant string, mode EnforceMode) (deny bool, reason string) {
	allowed, reason := r.PushAllowed(tenant)
	if mode != EnforceShadow && mode != EnforceOn {
		return false, reason
	}
	decision := decisionAllow
	if !allowed {
		if mode == EnforceOn {
			decision = decisionDeny
			deny = true
		} else {
			decision = decisionWouldDeny
		}
	}
	if r != nil && r.decisions != nil {
		r.decisions.WithLabelValues(mode.String(), decision, reason).Inc()
	}
	return deny, reason
}

// stateDecisions returns the shared counter vec, reusing it when another
// Reader already registered it on reg.
func stateDecisions(reg prometheus.Registerer) *prometheus.CounterVec {
	return registerOrReuse(reg, prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "xscaler_admin_store_state_decisions_total",
		Help: "Push gate decisions by enforce mode, decision (allow, deny, would_deny) and reason.",
	}, []string{"mode", "decision", "reason"}))
}

// registerOrReuse registers v on reg, or returns the vec an earlier Reader
// already registered under the same name.
func registerOrReuse(reg prometheus.Registerer, v *prometheus.CounterVec) *prometheus.CounterVec {
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
