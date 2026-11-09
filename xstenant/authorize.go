package xstenant

import (
	"net/http"
	"net/url"
	"slices"
	"strings"

	"github.com/prometheus/client_golang/prometheus"
)

// Kind is the signal a backend serves. It selects the path allowlist. An
// empty or unknown Kind is treated as KindMetrics.
type Kind string

const (
	KindMetrics Kind = "metrics"
	KindLogs    Kind = "logs"
	KindTraces  Kind = "traces"
)

// normalizeKind maps anything but logs and traces to metrics.
func normalizeKind(k Kind) Kind {
	switch Kind(strings.ToLower(strings.TrimSpace(string(k)))) {
	case KindLogs:
		return KindLogs
	case KindTraces:
		return KindTraces
	default:
		return KindMetrics
	}
}

// Reasons returned with an authorization decision. ReasonAuthAllowed is the
// reason of an allowed request.
const (
	ReasonAuthAllowed        = "none"
	ReasonMissingToken       = "missing_token"
	ReasonMissingScopeOrgID  = "missing_scope_orgid"
	ReasonStateUnavailable   = "state_unavailable"
	ReasonUnknownToken       = "unknown_token"
	ReasonKeyExpired         = "key_expired"
	ReasonTenantInactive     = "tenant_inactive"
	ReasonScopeOrgIDMismatch = "scope_orgid_mismatch"
	ReasonPathNotAllowed     = "path_not_allowed"
	ReasonScopeReadMissing   = "scope_read_missing"
	ReasonScopeWriteMissing  = "scope_write_missing"
)

// Key scopes as published in keys.json.
const (
	scopeRead  = "read"
	scopeWrite = "write"
)

// AuthRequest is what the decision needs from an HTTP request. Path may carry
// a query string and fragment; both are removed before any path check.
// Authorization and OrgID are the raw header values.
type AuthRequest struct {
	Kind          Kind
	Method, Path  string
	Authorization string
	OrgID         string
	// PathPrefix is the route prefix the engine's own router adds, for
	// example "/prometheus" for Mimir behind a gateway that rewrites
	// /api/v1/query to /prometheus/api/v1/query. When Path starts with it, it
	// is removed before every check. A Path without it (the public form) is
	// used as is.
	PathPrefix string
	// ExtraReadPaths lists additional paths the caller serves next to the
	// engine and wants API keys to reach for this request's Kind. Each entry
	// is matched exactly against the path after query-string removal and
	// prefix stripping: no prefix, case or trailing-slash variants. A match
	// needs the read scope for every method and is never treated as a push
	// or config path. The path hygiene checks (dot segments, encoded dots
	// and slashes) run first. A path the built-in allowlist already covers
	// keeps its built-in classification. Unset, behaviour is unchanged.
	ExtraReadPaths []string
}

// AuthDecision is the outcome. Status is the HTTP status to answer with when
// Allowed is false (0 when allowed). Message is the client-facing text; it is
// opaque for unknown, expired and inactive credentials so a caller cannot
// probe which tokens or tenants exist. Reason is the precise cause for logs
// and metrics. Tenant is the key's tenant and is set only when the rules
// allowed the request.
//
// Enforced is set by CheckAuth only in mode on for an allowed request. An
// engine replaces X-Scope-OrgID with Tenant only when Enforced is true; in
// shadow and off it leaves the request as received.
type AuthDecision struct {
	Allowed  bool
	Enforced bool
	Tenant   string
	// KeyID and Managed are the key's optional key_id and managed fields
	// from keys.json, set only when the request is allowed. They are empty
	// and false for a key that does not carry them.
	KeyID   string
	Managed bool
	Status  int
	Reason  string
	Message string
}

func deny(status int, reason, msg string) AuthDecision {
	return AuthDecision{Status: status, Reason: reason, Message: msg}
}

// Authorize applies Snapshot.Authorize to the snapshot currently served. It
// is safe on a nil Reader (no snapshot, 503 state_unavailable) and does not
// count a decision.
func (r *Reader) Authorize(req AuthRequest) AuthDecision {
	if r == nil {
		return (*Snapshot)(nil).Authorize(req)
	}
	return r.snap.Load().Authorize(req)
}

// Authorize decides whether the request may reach the backend. It applies
// the gateway authorization decision, in this order:
//
//  1. Authorization is not "Bearer <token>": 401 missing_token.
//  2. OrgID is empty after trimming: 401 missing_scope_orgid.
//  3. nil snapshot: 503 state_unavailable.
//  4. sha256 of the token not in keys.json: 401 unknown_token.
//  5. key expired: 401 key_expired.
//  6. tenant state suspended: 401 tenant_inactive.
//  7. OrgID differs from the key's tenant: 401 scope_orgid_mismatch.
//  8. path empty, ambiguous, encoded in a way that hides a separator or dot,
//     or not allowed for the Kind: 403 path_not_allowed.
//     A path in ExtraReadPaths is allowed here and needs the read scope.
//  9. key lacks the scope the request needs: 403 scope_read_missing or
//     scope_write_missing.
//
// A tenant absent from tenants.json is allowed, as in PushAllowed. A soft
// locked tenant is allowed here; the push gate handles it. It is safe on a
// nil Snapshot.
func (s *Snapshot) Authorize(req AuthRequest) AuthDecision {
	token, ok := bearerToken(req.Authorization)
	if !ok {
		return deny(http.StatusUnauthorized, ReasonMissingToken, "missing token")
	}
	scope := strings.TrimSpace(req.OrgID)
	if scope == "" {
		return deny(http.StatusUnauthorized, ReasonMissingScopeOrgID, "missing x-scope-orgid")
	}
	if s == nil {
		return deny(http.StatusServiceUnavailable, ReasonStateUnavailable, "authorization service unavailable")
	}
	k, err := s.lookupKey(token)
	switch err {
	case nil:
	case ErrExpiredKey:
		return deny(http.StatusUnauthorized, ReasonKeyExpired, "unknown token")
	default:
		return deny(http.StatusUnauthorized, ReasonUnknownToken, "unknown token")
	}
	if st, ok := s.tenants[k.TenantID]; ok && st.State == StateSuspended {
		return deny(http.StatusUnauthorized, ReasonTenantInactive, "unknown token")
	}
	if scope != k.TenantID {
		return deny(http.StatusUnauthorized, ReasonScopeOrgIDMismatch, "x-scope-orgid mismatch")
	}

	kind := normalizeKind(req.Kind)
	path, ok := cleanPath(req.Path, req.PathPrefix)
	if !ok || path == "" || hasAmbiguousSegments(path) {
		return deny(http.StatusForbidden, ReasonPathNotAllowed, "unsupported path")
	}
	needed := scopeRead
	if pathAllowed(path, kind) {
		needed = requiredScope(req.Method, path, kind)
	} else if !slices.Contains(req.ExtraReadPaths, path) {
		return deny(http.StatusForbidden, ReasonPathNotAllowed, "unsupported path")
	}
	if !allowsScope(k.Scopes, needed) {
		return deny(http.StatusForbidden, "scope_"+needed+"_missing", "api key lacks "+needed+" scope")
	}
	return AuthDecision{Allowed: true, Tenant: k.TenantID, KeyID: k.KeyID, Managed: k.Managed, Reason: ReasonAuthAllowed}
}

// allowsScope reports whether a key may do an operation that needs scope. A
// key with no scopes field (nil) predates scopes and can read and write; an
// explicit empty list can do neither. the publisher always writes an explicit
// list once it knows about scopes, so nil never means "none".
func allowsScope(scopes []string, scope string) bool {
	if scopes == nil {
		return true
	}
	return slices.Contains(scopes, scope)
}

// bearerToken extracts the token from "Bearer <token>": exactly two
// whitespace separated fields, the first "bearer" in any case.
func bearerToken(h string) (string, bool) {
	parts := strings.Fields(h)
	if len(parts) == 2 && strings.EqualFold(parts[0], "bearer") {
		return parts[1], true
	}
	return "", false
}

// splitRequestPath separates the path an HTTP router matches on from the
// query string and fragment, which it does not.
func splitRequestPath(raw string) (path, rawQuery string) {
	raw, _, _ = strings.Cut(raw, "#")
	path, rawQuery, _ = strings.Cut(raw, "?")
	return path, rawQuery
}

// hasAmbiguousSegments reports a path whose meaning depends on who
// normalises it: an empty segment ("//") or a dot segment.
func hasAmbiguousSegments(path string) bool {
	if strings.Contains(path, "//") {
		return true
	}
	for _, seg := range strings.Split(path, "/") {
		if seg == "." || seg == ".." {
			return true
		}
	}
	return false
}

// isSafeMethod reports a method that reads. An empty method is not safe.
func isSafeMethod(method string) bool {
	switch strings.ToUpper(strings.TrimSpace(method)) {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return true
	}
	return false
}

// cleanPath turns the request path into the one the checks classify: query
// and fragment removed, percent-encoding decoded once, the engine's route
// prefix removed. It refuses (false) a path that hides a slash, dot or
// backslash behind an encoding, or that does not decode.
func cleanPath(raw, prefix string) (string, bool) {
	path, _ := splitRequestPath(raw)
	lower := strings.ToLower(path)
	if strings.Contains(lower, "%2e") || strings.Contains(lower, "%2f") ||
		strings.Contains(lower, "%5c") || strings.Contains(path, `\`) {
		return "", false
	}
	dec, err := url.PathUnescape(path)
	if err != nil {
		return "", false
	}
	if dec != path {
		for _, c := range []string{"/", ".", `\`} {
			if strings.Count(dec, c) != strings.Count(path, c) {
				return "", false
			}
		}
	}
	if prefix = strings.TrimRight(prefix, "/"); prefix != "" &&
		strings.HasPrefix(dec, prefix) && (len(dec) == len(prefix) || dec[len(prefix)] == '/') {
		dec = dec[len(prefix):]
	}
	return dec, true
}

// pathAllowed reports whether path is on the allowlist for the kind. An empty
// path is refused. path is already clean (cleanPath).
func pathAllowed(path string, kind Kind) bool {
	if path == "" {
		return false
	}
	if hasAmbiguousSegments(path) {
		return false
	}
	switch kind {
	case KindLogs:
		return hasAnyPrefix(path, "/api/v1/", "/loki/api/v1/", "/otlp/v1/logs")
	case KindTraces:
		return path == "/v1/traces" || path == "/otlp/v1/traces" ||
			hasAnyPrefix(path, traceGRPCPrefix, "/api/search", "/api/v2/search",
				"/api/traces/", "/api/v2/traces/", "/api/metrics/", "/api/echo", "/api/status/")
	}
	return hasAnyPrefix(path, "/api/v1/push", "/otlp/v1/metrics",
		"/api/v1/read", "/api/v1/query", "/api/v1/labels", "/api/v1/label/",
		"/api/v1/series", "/api/v1/metadata", "/api/v1/status/", "/api/v1/rules",
		"/api/v1/alerts") ||
		isCardinalityPath(path)
}

const traceGRPCPrefix = "/opentelemetry.proto.collector.trace.v1.TraceService/"

// isCardinalityPath lists Mimir's cardinality endpoints one by one rather
// than by prefix so a later addition is not exposed by accident.
func isCardinalityPath(path string) bool {
	for _, p := range []string{
		"/api/v1/cardinality/label_names",
		"/api/v1/cardinality/label_values",
		"/api/v1/cardinality/active_series",
	} {
		if path == p {
			return true
		}
	}
	return false
}

func hasAnyPrefix(path string, prefixes ...string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(path, p) {
			return true
		}
	}
	return false
}

func isPushPath(path string, kind Kind) bool {
	// "/loki/api/v1/push/" reaches the same handler as "/loki/api/v1/push".
	path = strings.TrimSuffix(path, "/")
	switch kind {
	case KindLogs:
		return path == "/api/v1/push" || path == "/loki/api/v1/push" ||
			strings.HasPrefix(path, "/otlp/v1/logs")
	case KindTraces:
		return path == "/v1/traces" || path == "/otlp/v1/traces" ||
			strings.HasPrefix(path, traceGRPCPrefix)
	}
	return strings.HasPrefix(path, "/api/v1/push") || strings.HasPrefix(path, "/otlp/v1/metrics")
}

// requiredScope is the scope a request needs: write for a push path or a
// change to tenant configuration, read for everything else the allowlist
// lets through. path must have its query string removed. Paths that return
// secret-bearing config need write for every method.
func requiredScope(method, path string, kind Kind) string {
	if isPushPath(path, kind) || isSensitiveConfigPath(path, kind) {
		return scopeWrite
	}
	if isConfigPath(path, kind) && !isSafeMethod(method) {
		return scopeWrite
	}
	return scopeRead
}

// isSensitiveConfigPath matches APIs that return receiver secrets: Mimir's
// Alertmanager config API and the Alertmanager status and multitenant pages.
// Loki and Tempo serve none.
func isSensitiveConfigPath(path string, kind Kind) bool {
	if kind == KindLogs || kind == KindTraces {
		return false
	}
	return hasAnyPrefix(path, "/api/v1/alerts", "/alertmanager/api/v2/status",
		"/alertmanager/api/v1/status", "/multitenant_alertmanager")
}

// isConfigPath matches paths where a non-read method changes tenant state.
func isConfigPath(path string, kind Kind) bool {
	switch kind {
	case KindLogs:
		return hasAnyPrefix(path, "/loki/api/v1/delete", "/api/v1/delete",
			"/loki/api/v1/rules", "/api/v1/rules", "/api/prom/rules", "/prometheus/config/")
	case KindTraces:
		return false
	}
	return hasAnyPrefix(path, "/api/v1/alerts", "/api/v1/rules", "/alertmanager",
		"/multitenant_alertmanager", "/prometheus/config/", "/prometheus/api/v1/rules",
		"/prometheus/api/v1/alerts")
}

// CheckAuth applies Authorize under a rollout mode.
//
//   - EnforceOff: Allowed is true, nothing is counted, and no hashing or
//     lookup happens.
//   - EnforceShadow: Allowed is true; a request Authorize would deny is
//     counted as would_deny, anything else as allow. Status, Reason and
//     Message still describe the would-be denial.
//   - EnforceOn: the Authorize result, counted as allow or deny.
//
// Enforced is true only in mode on for an allowed request. Tenant is empty
// unless the rules allowed the request, in every mode.
//
// Counted in xscaler_admin_store_auth_decisions_total{mode,kind,decision,reason}.
func (r *Reader) CheckAuth(req AuthRequest, mode EnforceMode) AuthDecision {
	if mode != EnforceShadow && mode != EnforceOn {
		return AuthDecision{Allowed: true, Reason: ReasonAuthAllowed}
	}
	d := r.Authorize(req)
	decision := decisionAllow
	if !d.Allowed {
		if mode == EnforceOn {
			decision = decisionDeny
		} else {
			decision = decisionWouldDeny
			d.Allowed = true
		}
	} else if mode == EnforceOn {
		d.Enforced = true
	}
	if r != nil && r.authDecisions != nil {
		r.authDecisions.WithLabelValues(mode.String(), string(normalizeKind(req.Kind)), decision, d.Reason).Inc()
	}
	return d
}

func authDecisionsVec(reg prometheus.Registerer) *prometheus.CounterVec {
	return registerOrReuse(reg, prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "xscaler_admin_store_auth_decisions_total",
		Help: "API key authorization decisions by enforce mode, kind, decision (allow, deny, would_deny) and reason.",
	}, []string{"mode", "kind", "decision", "reason"}))
}
