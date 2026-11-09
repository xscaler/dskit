package xstenant

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

var authNow = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func tokHash(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

func authSnap() *Snapshot {
	past := authNow.Add(-time.Hour)
	future := authNow.Add(time.Hour)
	return &Snapshot{
		now: func() time.Time { return authNow },
		tenants: map[string]TenantState{
			"tenant-1": {State: StateActive},
			"tenant-s": {State: StateSuspended},
			"tenant-l": {State: StateSoftLocked},
		},
		keys: map[string]keyRecord{
			tokHash("rw"):      {TenantID: "tenant-1", Scopes: []string{"read", "write"}},
			tokHash("read"):    {TenantID: "tenant-1", Scopes: []string{"read"}},
			tokHash("write"):   {TenantID: "tenant-1", Scopes: []string{"write"}},
			tokHash("empty"):   {TenantID: "tenant-1", Scopes: []string{}},
			tokHash("legacy"):  {TenantID: "tenant-1"},
			tokHash("expired"): {TenantID: "tenant-1", Scopes: []string{"read"}, ExpiresAt: &past},
			tokHash("valid"):   {TenantID: "tenant-1", Scopes: []string{"read"}, ExpiresAt: &future},
			tokHash("susp"):    {TenantID: "tenant-s", Scopes: []string{"read", "write"}},
			tokHash("locked"):  {TenantID: "tenant-l", Scopes: []string{"read", "write"}},
			tokHash("orphan"):  {TenantID: "tenant-x", Scopes: []string{"read"}},
		},
	}
}

func areq(kind Kind, method, path, tok string) AuthRequest {
	return AuthRequest{Kind: kind, Method: method, Path: path, Authorization: "Bearer " + tok, OrgID: "tenant-1"}
}

func TestAuthorizeOrder(t *testing.T) {
	s := authSnap()
	cases := []struct {
		name   string
		snap   *Snapshot
		req    AuthRequest
		allow  bool
		status int
		reason string
		tenant string
	}{
		{"no authorization", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1"}, false, 401, "missing_token", ""},
		{"basic scheme", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1", Authorization: "Basic abc"}, false, 401, "missing_token", ""},
		{"bearer without token", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1", Authorization: "Bearer"}, false, 401, "missing_token", ""},
		{"three fields", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1", Authorization: "Bearer a b"}, false, 401, "missing_token", ""},
		{"lowercase bearer", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1", Authorization: "bearer rw"}, true, 0, "none", "tenant-1"},
		{"extra spaces", s, AuthRequest{Path: "/api/v1/push", OrgID: "tenant-1", Authorization: "  BEARER   rw  "}, true, 0, "none", "tenant-1"},
		{"missing orgid", s, AuthRequest{Path: "/api/v1/push", Authorization: "Bearer rw"}, false, 401, "missing_scope_orgid", ""},
		{"blank orgid", s, AuthRequest{Path: "/api/v1/push", Authorization: "Bearer rw", OrgID: "  \t"}, false, 401, "missing_scope_orgid", ""},
		{"padded orgid", s, AuthRequest{Path: "/api/v1/push", Authorization: "Bearer rw", OrgID: " tenant-1 "}, true, 0, "none", "tenant-1"},
		{"token checked before orgid", s, AuthRequest{Path: "/api/v1/push"}, false, 401, "missing_token", ""},
		{"nil snapshot", nil, areq(KindMetrics, "POST", "/api/v1/push", "rw"), false, 503, "state_unavailable", ""},
		{"nil snapshot, no token", nil, AuthRequest{OrgID: "tenant-1"}, false, 401, "missing_token", ""},
		{"nil snapshot, no orgid", nil, AuthRequest{Authorization: "Bearer rw"}, false, 401, "missing_scope_orgid", ""},
		{"unknown token", s, areq(KindMetrics, "POST", "/api/v1/push", "nope"), false, 401, "unknown_token", ""},
		{"expired key", s, areq(KindMetrics, "POST", "/api/v1/push", "expired"), false, 401, "key_expired", ""},
		{"key not yet expired", s, areq(KindMetrics, "GET", "/api/v1/query", "valid"), true, 0, "none", "tenant-1"},
		{"suspended tenant", s, AuthRequest{Method: "POST", Path: "/api/v1/push", Authorization: "Bearer susp", OrgID: "tenant-s"}, false, 401, "tenant_inactive", ""},
		{"soft locked tenant still authorized", s, AuthRequest{Method: "POST", Path: "/api/v1/push", Authorization: "Bearer locked", OrgID: "tenant-l"}, true, 0, "none", "tenant-l"},
		{"tenant missing from tenants.json", s, AuthRequest{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer orphan", OrgID: "tenant-x"}, true, 0, "none", "tenant-x"},
		{"orgid mismatch", s, AuthRequest{Method: "POST", Path: "/api/v1/push", Authorization: "Bearer rw", OrgID: "tenant-2"}, false, 401, "scope_orgid_mismatch", ""},
		{"anonymous orgid", s, AuthRequest{Method: "POST", Path: "/api/v1/push", Authorization: "Bearer rw", OrgID: "anonymous"}, false, 401, "scope_orgid_mismatch", ""},
		{"comma joined orgid", s, AuthRequest{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer rw", OrgID: "tenant-1,tenant-2"}, false, 401, "scope_orgid_mismatch", ""},
		{"mismatch before path", s, AuthRequest{Method: "GET", Path: "/nope", Authorization: "Bearer rw", OrgID: "tenant-2"}, false, 401, "scope_orgid_mismatch", ""},
		{"path before scope", s, areq(KindMetrics, "GET", "/api/v1/targets", "empty"), false, 403, "path_not_allowed", ""},
		{"suspended before mismatch", s, AuthRequest{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer susp", OrgID: "other"}, false, 401, "tenant_inactive", ""},
		{"expired before suspended-style checks", s, AuthRequest{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer expired", OrgID: "other"}, false, 401, "key_expired", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := c.snap.Authorize(c.req)
			if d.Allowed != c.allow || d.Status != c.status || d.Reason != c.reason || d.Tenant != c.tenant {
				t.Fatalf("got %+v, want allow=%v status=%d reason=%q tenant=%q", d, c.allow, c.status, c.reason, c.tenant)
			}
			if !d.Allowed && d.Message == "" {
				t.Error("deny without message")
			}
		})
	}
}

func TestAuthorizeOpaqueMessages(t *testing.T) {
	s := authSnap()
	for _, tok := range []string{"nope", "expired"} {
		if d := s.Authorize(areq(KindMetrics, "GET", "/api/v1/query", tok)); d.Message != "unknown token" {
			t.Errorf("%s: message %q", tok, d.Message)
		}
	}
	d := s.Authorize(AuthRequest{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer susp", OrgID: "tenant-s"})
	if d.Message != "unknown token" {
		t.Errorf("suspended: message %q", d.Message)
	}
}

func TestAuthorizeReaderNilAndNoSnapshot(t *testing.T) {
	var nr *Reader
	if d := nr.Authorize(areq(KindMetrics, "GET", "/api/v1/query", "rw")); d.Allowed || d.Status != 503 {
		t.Errorf("nil reader: %+v", d)
	}
	r, _ := gateReader(t, nil)
	if d := r.Authorize(areq(KindMetrics, "GET", "/api/v1/query", "rw")); d.Allowed || d.Reason != "state_unavailable" {
		t.Errorf("no snapshot: %+v", d)
	}
	r.snap.Store(authSnap())
	if d := r.Authorize(areq(KindMetrics, "GET", "/api/v1/query", "rw")); !d.Allowed || d.Tenant != "tenant-1" {
		t.Errorf("with snapshot: %+v", d)
	}
}

// Scope rules per kind and path.
func TestAuthorizeScopes(t *testing.T) {
	cases := []struct {
		name      string
		kind      Kind
		token     string
		method    string
		path      string
		allowed   bool
		denyScope string
	}{
		{"write key pushes metrics", KindMetrics, "write", "POST", "/api/v1/push", true, ""},
		{"write key pushes otlp metrics", KindMetrics, "write", "POST", "/otlp/v1/metrics", true, ""},
		{"write key cannot query metrics", KindMetrics, "write", "GET", "/api/v1/query_range?query=up", false, "read"},
		{"write key cannot list series", KindMetrics, "write", "GET", "/api/v1/series", false, "read"},
		{"read key queries metrics", KindMetrics, "read", "GET", "/api/v1/query?query=up", true, ""},
		{"read key cannot push metrics", KindMetrics, "read", "POST", "/api/v1/push", false, "write"},
		{"write key pushes logs", KindLogs, "write", "POST", "/loki/api/v1/push", true, ""},
		{"write key cannot query logs", KindLogs, "write", "GET", "/loki/api/v1/query_range", false, "read"},
		{"write key cannot tail logs", KindLogs, "write", "GET", "/loki/api/v1/tail", false, "read"},
		{"read key cannot push logs", KindLogs, "read", "POST", "/otlp/v1/logs", false, "write"},
		{"write key pushes traces", KindTraces, "write", "POST", "/otlp/v1/traces", true, ""},
		{"write key cannot search traces", KindTraces, "write", "GET", "/api/search?q=%7B%7D", false, "read"},
		{"read key cannot push traces over grpc", KindTraces, "read", "POST",
			"/opentelemetry.proto.collector.trace.v1.TraceService/Export", false, "write"},
		{"write key pushes traces over grpc", KindTraces, "write", "POST",
			"/opentelemetry.proto.collector.trace.v1.TraceService/Export", true, ""},
		{"both scopes query", KindMetrics, "rw", "GET", "/api/v1/query", true, ""},
		{"both scopes push", KindMetrics, "rw", "POST", "/api/v1/push", true, ""},
		{"legacy nil scopes query", KindMetrics, "legacy", "GET", "/api/v1/query", true, ""},
		{"legacy nil scopes push", KindMetrics, "legacy", "POST", "/api/v1/push", true, ""},
		{"empty scopes cannot query", KindMetrics, "empty", "GET", "/api/v1/query", false, "read"},
		{"empty scopes cannot push", KindMetrics, "empty", "POST", "/api/v1/push", false, "write"},
		// Read-only key: reads only, never pushes or config.
		{"read key lists rules", KindMetrics, "read", "GET", "/api/v1/rules", true, ""},
		{"read key cannot read alertmanager config", KindMetrics, "read", "GET", "/api/v1/alerts", false, "write"},
		// Cardinality endpoints.
		{"read key cardinality names", KindMetrics, "read", "GET", "/api/v1/cardinality/label_names", true, ""},
		{"read key cardinality values", KindMetrics, "read", "GET", "/api/v1/cardinality/label_values?label_names[]=__name__", true, ""},
		{"read key cardinality active series", KindMetrics, "read", "GET", "/api/v1/cardinality/active_series?selector=up", true, ""},
		{"write key cannot read cardinality", KindMetrics, "write", "GET", "/api/v1/cardinality/label_names", false, "read"},
		// Forecast endpoint.
	}
	s := authSnap()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := s.Authorize(areq(c.kind, c.method, c.path, c.token))
			if c.allowed {
				if !d.Allowed {
					t.Fatalf("want allow, got %+v", d)
				}
				return
			}
			if d.Allowed || d.Status != http.StatusForbidden || d.Reason != "scope_"+c.denyScope+"_missing" {
				t.Fatalf("got %+v, want 403 scope_%s_missing", d, c.denyScope)
			}
			if d.Message != "api key lacks "+c.denyScope+" scope" {
				t.Errorf("message %q", d.Message)
			}
		})
	}
}

// A query string or
// fragment must not turn a push into a read.
func TestAuthorizeQueryStringStripped(t *testing.T) {
	s := authSnap()
	cases := []struct {
		kind Kind
		path string
	}{
		{KindMetrics, "/api/v1/push?x=1"},
		{KindMetrics, "/otlp/v1/metrics?x=1"},
		{KindLogs, "/loki/api/v1/push?x=1"},
		{KindLogs, "/api/v1/push?x=1"},
		{KindLogs, "/loki/api/v1/push#frag"},
		{KindLogs, "/otlp/v1/logs?x=1"},
		{KindTraces, "/v1/traces?x=1"},
		{KindTraces, "/otlp/v1/traces?x=1"},
	}
	for _, c := range cases {
		if d := s.Authorize(areq(c.kind, "POST", c.path, "read")); d.Reason != "scope_write_missing" || d.Status != 403 {
			t.Errorf("%s %s read key: %+v", c.kind, c.path, d)
		}
		if d := s.Authorize(areq(c.kind, "POST", c.path, "write")); !d.Allowed {
			t.Errorf("%s %s write key: %+v", c.kind, c.path, d)
		}
	}
	// The query string never reaches the allowlist or ambiguity check.
	if d := s.Authorize(areq(KindMetrics, "GET", "/api/v1/query?next=//x/../y", "read")); !d.Allowed {
		t.Errorf("query with slashes: %+v", d)
	}
	if d := s.Authorize(areq(KindMetrics, "GET", "/nope?x=/api/v1/query", "read")); d.Reason != "path_not_allowed" {
		t.Errorf("path hidden in query: %+v", d)
	}
}

func TestAuthorizeAmbiguousPaths(t *testing.T) {
	s := authSnap()
	for _, path := range []string{
		"//loki/api/v1/push",
		"/loki/api/v1/query/../push",
		"/./loki/api/v1/push",
		"/loki/api/v1//push",
		"/loki/api/v1/push/.",
	} {
		d := s.Authorize(areq(KindLogs, "POST", path, "rw"))
		if d.Allowed || d.Status != 403 || d.Reason != "path_not_allowed" || d.Message != "unsupported path" {
			t.Errorf("%s: %+v", path, d)
		}
	}
}

// Configuration paths need write.
func TestAuthorizeConfigNeedsWrite(t *testing.T) {
	s := authSnap()
	for _, m := range []string{"POST", "DELETE", "PUT", "GET", "HEAD"} {
		if d := s.Authorize(areq(KindMetrics, m, "/api/v1/alerts", "read")); d.Reason != "scope_write_missing" {
			t.Errorf("%s /api/v1/alerts read key: %+v", m, d)
		}
	}
	for _, p := range []string{"/alertmanager/api/v2/status", "/alertmanager/api/v1/status"} {
		if d := s.Authorize(areq(KindMetrics, "GET", p, "read")); d.Allowed {
			t.Errorf("%s allowed for a read key", p)
		}
	}
	if d := s.Authorize(areq(KindMetrics, "GET", "/api/v1/rules", "read")); !d.Allowed {
		t.Errorf("GET rules: %+v", d)
	}
	if d := s.Authorize(areq(KindLogs, "GET", "/loki/api/v1/rules", "read")); !d.Allowed {
		t.Errorf("logs GET rules: %+v", d)
	}
	if d := s.Authorize(areq(KindLogs, "POST", "/loki/api/v1/rules/ns", "read")); d.Reason != "scope_write_missing" {
		t.Errorf("logs POST rules: %+v", d)
	}
	if d := s.Authorize(areq(KindLogs, "DELETE", "/loki/api/v1/delete", "read")); d.Reason != "scope_write_missing" {
		t.Errorf("logs delete: %+v", d)
	}
	if d := s.Authorize(areq(KindMetrics, "POST", "/api/v1/query", "read")); !d.Allowed {
		t.Errorf("POSTed query: %+v", d)
	}
	if d := s.Authorize(areq(KindMetrics, "DELETE", "/api/v1/alerts", "write")); !d.Allowed {
		t.Errorf("DELETE alerts write key: %+v", d)
	}
	// Loki and Tempo serve no Alertmanager config, so /api/v1/alerts is plain
	// there (and under logs it is an allowed /api/v1/ read).
	if got := requiredScope("GET", "/api/v1/alerts", KindLogs); got != scopeRead {
		t.Errorf("logs alerts needs %q", got)
	}
	if got := requiredScope("DELETE", "/loki/api/v1/delete", KindLogs); got != scopeWrite {
		t.Errorf("loki delete needs %q", got)
	}
}

func TestPathAllowlists(t *testing.T) {
	cases := []struct {
		kind Kind
		path string
		ok   bool
	}{
		{KindMetrics, "", false},
		{KindMetrics, "/api/v1/push", true},
		{KindMetrics, "/api/v1/push/extra", true},
		{KindMetrics, "/otlp/v1/metrics", true},
		{KindMetrics, "/api/v1/read", true},
		{KindMetrics, "/api/v1/labels", true},
		{KindMetrics, "/api/v1/label/job/values", true},
		{KindMetrics, "/api/v1/series", true},
		{KindMetrics, "/api/v1/metadata", true},
		{KindMetrics, "/api/v1/status/runtimeinfo", true},
		{KindMetrics, "/api/v1/rules", true},
		{KindMetrics, "/api/v1/alerts", true},
		{KindMetrics, "/api/v1/query", true},
		{KindMetrics, "/api/v1/query_range", true},
		{KindMetrics, "/api/v1/query_exemplars", true},
		{KindMetrics, "/api/v1/cardinality/something_new", false},
		{KindMetrics, "/otlp/v1/logs", false},
		{KindMetrics, "/api/v1/targets", false},
		{KindMetrics, "/", false},
		{KindMetrics, "/some/random/path", false},
		{KindMetrics, "/loki/api/v1/push", false},
		{KindLogs, "", false},
		{KindLogs, "/api/v1/push", true},
		{KindLogs, "/api/v1/query_range", true},
		{KindLogs, "/api/v1/labels", true},
		{KindLogs, "/api/v1/label/app/values", true},
		{KindLogs, "/api/v1/series", true},
		{KindLogs, "/api/v1/index/stats", true},
		{KindLogs, "/api/v1/detected_labels", true},
		{KindLogs, "/api/v1/detected_fields", true},
		{KindLogs, "/api/v1/detected_field/level/values", true},
		{KindLogs, "/api/v1/patterns", true},
		{KindLogs, "/api/v1/drilldown-limits", true},
		{KindLogs, "/api/v1/tail", true},
		{KindLogs, "/loki/api/v1/push", true},
		{KindLogs, "/loki/api/v1/query", true},
		{KindLogs, "/loki/api/v1/query_range", true},
		{KindLogs, "/loki/api/v1/detected_labels", true},
		{KindLogs, "/otlp/v1/logs", true},
		{KindLogs, "/api/v1/status/buildinfo", true},
		{KindLogs, "/prometheus/api/v1/query", false},
		{KindLogs, "/some/random/path", false},
		{KindLogs, "/admin", false},
		{"", "/api/v1/push", true},
		{"", "/loki/api/v1/push", false},
		{"bogus", "/loki/api/v1/push", false},
		{KindTraces, "", false},
		{KindTraces, "/v1/traces", true},
		{KindTraces, "/otlp/v1/traces", true},
		{KindTraces, "/opentelemetry.proto.collector.trace.v1.TraceService/Export", true},
		{KindTraces, "/api/search?tags=service.name", true},
		{KindTraces, "/api/v2/search/tags", true},
		{KindTraces, "/api/traces/abc", true},
		{KindTraces, "/api/v2/traces/abc", true},
		{KindTraces, "/api/echo", true},
		{KindTraces, "/api/status/buildinfo", true},
		{KindTraces, "/api/metrics/query_range", true},
		{KindTraces, "/api/metrics/instant_query", true},
		{KindTraces, "/api/v1/push", false},
		{KindTraces, "/loki/api/v1/push", false},
		{KindTraces, "/otlp/v1/logs", false},
		{KindTraces, "/some/random/path", false},
	}
	for _, c := range cases {
		// Cases may carry a query string; the decision strips it first.
		path, _ := splitRequestPath(c.path)
		if got := pathAllowed(path, normalizeKind(c.kind)); got != c.ok {
			t.Errorf("pathAllowed(%q, %q) = %v, want %v", c.path, c.kind, got, c.ok)
		}
	}
}

func TestIsPushPath(t *testing.T) {
	cases := []struct {
		kind Kind
		path string
		want bool
	}{
		{KindMetrics, "/api/v1/push", true},
		{KindMetrics, "/api/v1/push/foo", true},
		{KindMetrics, "/otlp/v1/metrics", true},
		{KindMetrics, "/api/v1/query", false},
		{KindMetrics, "/loki/api/v1/push", false},
		{KindLogs, "/api/v1/push", true},
		{KindLogs, "/loki/api/v1/push", true},
		{KindLogs, "/otlp/v1/logs", true},
		{KindLogs, "/api/v1/query", false},
		{KindLogs, "/loki/api/v1/query", false},
		{KindTraces, "/v1/traces", true},
		{KindTraces, "/otlp/v1/traces", true},
		{KindTraces, "/opentelemetry.proto.collector.trace.v1.TraceService/Export", true},
		{KindTraces, "/api/search", false},
		{KindTraces, "/api/traces/abc", false},
	}
	for _, c := range cases {
		if got := isPushPath(c.path, c.kind); got != c.want {
			t.Errorf("isPushPath(%q, %q) = %v, want %v", c.path, c.kind, got, c.want)
		}
	}
}

func TestSplitRequestPath(t *testing.T) {
	cases := []struct{ in, path, query string }{
		{"/api/v1/push", "/api/v1/push", ""},
		{"/api/v1/push?x=1", "/api/v1/push", "x=1"},
		{"/api/v1/push#frag", "/api/v1/push", ""},
		{"/api/v1/push?x=1#frag", "/api/v1/push", "x=1"},
		{"/a#b?c", "/a", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		p, q := splitRequestPath(c.in)
		if p != c.path || q != c.query {
			t.Errorf("splitRequestPath(%q) = %q, %q", c.in, p, q)
		}
	}
}

func TestHasAmbiguousSegments(t *testing.T) {
	for p, want := range map[string]bool{
		"/api/v1/push": false, "//a": true, "/a//b": true, "/a/./b": true,
		"/a/../b": true, "/.": true, "/a/..": true, "/a/.b": false, "/a/..b": false,
		"/a/b/": false, "": false, "/": false,
	} {
		if got := hasAmbiguousSegments(p); got != want {
			t.Errorf("hasAmbiguousSegments(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestIsSafeMethod(t *testing.T) {
	for m, want := range map[string]bool{
		"": false, "GET": true, "get": true, " HEAD ": true, "OPTIONS": true,
		"POST": false, "PUT": false, "DELETE": false, "PATCH": false,
	} {
		if got := isSafeMethod(m); got != want {
			t.Errorf("isSafeMethod(%q) = %v, want %v", m, got, want)
		}
	}
}

func TestBearerToken(t *testing.T) {
	cases := []struct {
		in  string
		tok string
		ok  bool
	}{
		{"Bearer abc", "abc", true},
		{"bearer abc", "abc", true},
		{"BEARER abc", "abc", true},
		{"  Bearer   abc  ", "abc", true},
		{"Bearer\tabc", "abc", true},
		{"", "", false},
		{"Bearer", "", false},
		{"abc", "", false},
		{"Basic abc", "", false},
		{"Bearer a b", "", false},
		{"Bearerabc", "", false},
	}
	for _, c := range cases {
		tok, ok := bearerToken(c.in)
		if tok != c.tok || ok != c.ok {
			t.Errorf("bearerToken(%q) = %q, %v", c.in, tok, ok)
		}
	}
}

// The raw token is hashed; a token with different case or padding is a
// different token.
func TestAuthorizeHashesRawToken(t *testing.T) {
	s := authSnap()
	if d := s.Authorize(areq(KindMetrics, "GET", "/api/v1/query", "RW")); d.Reason != "unknown_token" {
		t.Errorf("upper-cased token: %+v", d)
	}
	if tokHash("token-1") != tokHash("token-1") || tokHash("token-1") == tokHash("token-2") {
		t.Error("hash not deterministic or not distinct")
	}
}

func TestAuthorizeUnknownKindIsMetrics(t *testing.T) {
	s := authSnap()
	for _, k := range []Kind{"", "bogus", "Metrics"} {
		if d := s.Authorize(areq(k, "POST", "/api/v1/push", "rw")); !d.Allowed {
			t.Errorf("kind %q: %+v", k, d)
		}
		if d := s.Authorize(areq(k, "POST", "/loki/api/v1/push", "rw")); d.Reason != "path_not_allowed" {
			t.Errorf("kind %q loki path: %+v", k, d)
		}
	}
	if d := s.Authorize(areq("LOGS", "POST", "/loki/api/v1/push", "rw")); !d.Allowed {
		t.Errorf("upper-case logs: %+v", d)
	}
}

func authCount(t *testing.T, r *Reader, mode, kind, decision, reason string) float64 {
	t.Helper()
	return testutil.ToFloat64(r.authDecisions.WithLabelValues(mode, kind, decision, reason))
}

func TestCheckAuthModes(t *testing.T) {
	r, reg := gateReader(t, nil)
	r.snap.Store(authSnap())
	good := areq(KindLogs, "POST", "/loki/api/v1/push", "rw")
	bad := areq(KindLogs, "POST", "/loki/api/v1/push", "nope")

	// off: allowed, nothing counted.
	if d := r.CheckAuth(bad, EnforceOff); !d.Allowed || d.Enforced || d.Tenant != "" {
		t.Errorf("off: %+v", d)
	}
	if n, _ := testutil.GatherAndCount(reg, "xscaler_admin_store_auth_decisions_total"); n != 0 {
		t.Errorf("off counted %d series", n)
	}
	// unknown mode behaves like off.
	if d := r.CheckAuth(bad, EnforceMode(9)); !d.Allowed || d.Enforced {
		t.Errorf("unknown mode: %+v", d)
	}

	// shadow: allowed, counted as would_deny.
	if d := r.CheckAuth(bad, EnforceShadow); !d.Allowed || d.Enforced || d.Tenant != "" || d.Reason != "unknown_token" || d.Status != 401 {
		t.Errorf("shadow bad: %+v", d)
	}
	if d := r.CheckAuth(good, EnforceShadow); !d.Allowed || d.Enforced || d.Tenant != "tenant-1" {
		t.Errorf("shadow good: %+v", d)
	}
	if got := authCount(t, r, "shadow", "logs", "would_deny", "unknown_token"); got != 1 {
		t.Errorf("shadow would_deny = %v", got)
	}
	if got := authCount(t, r, "shadow", "logs", "allow", "none"); got != 1 {
		t.Errorf("shadow allow = %v", got)
	}

	// on: denies and counts.
	if d := r.CheckAuth(bad, EnforceOn); d.Allowed || d.Enforced || d.Tenant != "" || d.Status != 401 {
		t.Errorf("on bad: %+v", d)
	}
	if d := r.CheckAuth(good, EnforceOn); !d.Allowed || !d.Enforced || d.Tenant != "tenant-1" {
		t.Errorf("on good: %+v", d)
	}
	if got := authCount(t, r, "on", "logs", "deny", "unknown_token"); got != 1 {
		t.Errorf("on deny = %v", got)
	}
	if got := authCount(t, r, "on", "logs", "allow", "none"); got != 1 {
		t.Errorf("on allow = %v", got)
	}
}

func TestCheckAuthNilReaderAndSharedCounter(t *testing.T) {
	var nr *Reader
	req := areq(KindMetrics, "GET", "/api/v1/query", "rw")
	if d := nr.CheckAuth(req, EnforceOn); d.Allowed || d.Reason != "state_unavailable" {
		t.Errorf("nil reader on: %+v", d)
	}
	if d := nr.CheckAuth(req, EnforceShadow); !d.Allowed {
		t.Errorf("nil reader shadow: %+v", d)
	}
	reg := prometheus.NewRegistry()
	a, b := authDecisionsVec(reg), authDecisionsVec(reg)
	if a != b {
		t.Fatal("counter not shared on one registry")
	}
	if c := authDecisionsVec(prometheus.NewRegistry()); c == a {
		t.Fatal("counter shared across registries")
	}
	if authDecisionsVec(nil) == nil {
		t.Fatal("nil registerer gives no counter")
	}
}

// Off must not look the token up: an engine in off mode pays nothing.
func TestCheckAuthOffDoesNotHash(t *testing.T) {
	var nr *Reader
	if d := nr.CheckAuth(AuthRequest{}, EnforceOff); !d.Allowed || d.Enforced || d.Tenant != "" {
		t.Errorf("off, empty request: %+v", d)
	}
	r, _ := gateReader(t, nil)
	r.snap.Store(&Snapshot{}) // nil now func and keys: any lookup would panic
	if d := r.CheckAuth(areq(KindMetrics, "GET", "/api/v1/query", "rw"), EnforceOff); !d.Allowed {
		t.Errorf("off: %+v", d)
	}
}

func TestDeniedDecisionsCarryNoTenant(t *testing.T) {
	s := authSnap()
	reqs := []AuthRequest{
		areq(KindMetrics, "GET", "/api/v1/query", "expired"),
		{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer susp", OrgID: "tenant-s"},
		{Method: "GET", Path: "/api/v1/query", Authorization: "Bearer rw", OrgID: "tenant-2"},
		areq(KindMetrics, "GET", "/api/v1/targets", "rw"),
		areq(KindMetrics, "GET", "/api/v1/push", "read"),
		areq(KindMetrics, "POST", "/api/v1/push", "read"),
	}
	for _, r := range reqs {
		if d := s.Authorize(r); d.Allowed || d.Tenant != "" || d.Enforced {
			t.Errorf("%+v: %+v", r, d)
		}
	}
}

// Engines see the path their router uses. Mimir behind a rewriting gateway
// serves /prometheus/api/v1/query for the public /api/v1/query.
func TestAuthorizePathPrefix(t *testing.T) {
	s := authSnap()
	cases := []struct {
		name   string
		method string
		path   string
		prefix string
		token  string
		reason string // "" means allowed
	}{
		{"prefixed query", "GET", "/prometheus/api/v1/query?query=up", "/prometheus", "read", ""},
		{"prefixed query_range", "GET", "/prometheus/api/v1/query_range", "/prometheus", "read", ""},
		{"public form still accepted", "GET", "/api/v1/query", "/prometheus", "read", ""},
		{"trailing slash in prefix setting", "GET", "/prometheus/api/v1/query", "/prometheus/", "read", ""},
		{"prefixed push needs write", "POST", "/prometheus/api/v1/push", "/prometheus", "read", "scope_write_missing"},
		{"prefixed push with write", "POST", "/prometheus/api/v1/push", "/prometheus", "write", ""},
		{"prefixed rules list is a read", "GET", "/prometheus/api/v1/rules", "/prometheus", "read", ""},
		{"prefixed rules change needs write", "POST", "/prometheus/api/v1/rules/ns", "/prometheus", "read", "scope_write_missing"},
		{"prefixed rules delete needs write", "DELETE", "/prometheus/api/v1/rules/ns/g", "/prometheus", "read", "scope_write_missing"},
		{"prefixed alerts config read needs write", "GET", "/prometheus/api/v1/alerts", "/prometheus", "read", "scope_write_missing"},
		{"prefixed config path not allowlisted", "POST", "/prometheus/config/v1/rules", "/prometheus", "rw", "path_not_allowed"},
		{"prefix alone", "GET", "/prometheus", "/prometheus", "rw", "path_not_allowed"},
		{"prefix as a name prefix only", "GET", "/prometheusx/api/v1/query", "/prometheus", "rw", "path_not_allowed"},
		{"prefix removed once", "GET", "/prometheus/prometheus/api/v1/query", "/prometheus", "rw", "path_not_allowed"},
		{"slashes after prefix", "GET", "/prometheus//api/v1/query", "/prometheus", "rw", "path_not_allowed"},
		{"dot segment after prefix", "GET", "/prometheus/api/../api/v1/query", "/prometheus", "rw", "path_not_allowed"},
		{"prefixed path without a prefix setting", "GET", "/prometheus/api/v1/query", "", "rw", "path_not_allowed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := areq(KindMetrics, c.method, c.path, c.token)
			req.PathPrefix = c.prefix
			d := s.Authorize(req)
			if c.reason == "" {
				if !d.Allowed {
					t.Fatalf("want allow, got %+v", d)
				}
				return
			}
			if d.Allowed || d.Reason != c.reason {
				t.Fatalf("got %+v, want %s", d, c.reason)
			}
		})
	}
}

func TestAuthorizeEncodedPaths(t *testing.T) {
	s := authSnap()
	cases := []struct {
		name   string
		kind   Kind
		method string
		path   string
		token  string
		reason string // "" means allowed
	}{
		{"encoded dot", KindMetrics, "GET", "/api/v1/%2e%2e/v1/query", "rw", "path_not_allowed"},
		{"encoded dot upper", KindMetrics, "GET", "/api/v1/%2E%2E/query", "rw", "path_not_allowed"},
		{"encoded slash", KindLogs, "POST", "/loki/api/v1%2fpush", "rw", "path_not_allowed"},
		{"encoded slash upper", KindLogs, "POST", "/loki/api/v1%2Fpush", "rw", "path_not_allowed"},
		{"encoded backslash", KindLogs, "POST", "/loki/api/v1%5cpush", "rw", "path_not_allowed"},
		{"encoded backslash upper", KindLogs, "POST", "/loki/api/v1%5Cpush", "rw", "path_not_allowed"},
		{"raw backslash", KindLogs, "POST", `/loki/api/v1\push`, "rw", "path_not_allowed"},
		{"bad escape", KindMetrics, "GET", "/api/v1/query%zz", "rw", "path_not_allowed"},
		{"truncated escape", KindMetrics, "GET", "/api/v1/query%", "rw", "path_not_allowed"},
		// A decoded letter is classified as the letter: %70 is p.
		{"decoded push needs write", KindMetrics, "POST", "/api/v1/%70ush", "read", "scope_write_missing"},
		{"decoded push with write", KindMetrics, "POST", "/api/v1/%70ush", "write", ""},
		{"decoded push upper hex", KindMetrics, "POST", "/api/v1/%70%75sh", "read", "scope_write_missing"},
		{"decoded logs push", KindLogs, "POST", "/loki/api/v1/pu%73h", "read", "scope_write_missing"},
		{"decoded query is a read", KindMetrics, "GET", "/api/v1/qu%65ry", "read", ""},
		{"decoded alerts config", KindMetrics, "GET", "/api/v1/al%65rts", "read", "scope_write_missing"},
		{"decoded path not allowlisted", KindMetrics, "GET", "/api/v1/t%61rgets", "rw", "path_not_allowed"},
		// Decoded once only: %252e is the literal text %2e, not a dot.
		{"double encoding stays literal", KindMetrics, "GET", "/api/v1/query%252e", "rw", ""},
		{"double encoded push segment", KindMetrics, "POST", "/api/v1/%2570ush", "write", "path_not_allowed"},
		{"encoded query string ignored", KindMetrics, "GET", "/api/v1/query?x=%2e%2e%2f", "read", ""},
		// A trailing slash reaches the same handler.
		{"logs push trailing slash needs write", KindLogs, "POST", "/loki/api/v1/push/", "read", "scope_write_missing"},
		{"logs push trailing slash with write", KindLogs, "POST", "/loki/api/v1/push/", "write", ""},
		{"logs api push trailing slash", KindLogs, "POST", "/api/v1/push/", "read", "scope_write_missing"},
		{"traces push trailing slash is not listed", KindTraces, "POST", "/v1/traces/", "write", "path_not_allowed"},
		{"traces otlp trailing slash is not listed", KindTraces, "POST", "/otlp/v1/traces/", "write", "path_not_allowed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := s.Authorize(areq(c.kind, c.method, c.path, c.token))
			if c.reason == "" {
				if !d.Allowed {
					t.Fatalf("want allow, got %+v", d)
				}
				return
			}
			if d.Allowed || d.Reason != c.reason {
				t.Fatalf("got %+v, want %s", d, c.reason)
			}
		})
	}
}

func TestAuthorizeEmptyPathAndMethod(t *testing.T) {
	s := authSnap()
	for _, kind := range []Kind{KindMetrics, KindLogs, KindTraces} {
		for _, p := range []string{"", "?x=1", "#frag"} {
			d := s.Authorize(areq(kind, "GET", p, "rw"))
			if d.Allowed || d.Status != 403 || d.Reason != "path_not_allowed" {
				t.Errorf("%s %q: %+v", kind, p, d)
			}
		}
	}
	// An empty method is not a read: a config path needs write.
	if d := s.Authorize(areq(KindMetrics, "", "/api/v1/rules", "read")); d.Reason != "scope_write_missing" {
		t.Errorf("empty method on rules: %+v", d)
	}
	if d := s.Authorize(areq(KindMetrics, "", "/api/v1/query", "read")); !d.Allowed {
		t.Errorf("empty method on query: %+v", d)
	}
}

func TestIsCardinalityPath(t *testing.T) {
	for p, want := range map[string]bool{
		"/api/v1/cardinality/label_names":    true,
		"/api/v1/cardinality/label_values":   true,
		"/api/v1/cardinality/active_series":  true,
		"/api/v1/cardinality/label_names/x":  false,
		"/api/v1/cardinality/label_names?x=": false,
		"/api/v1/cardinality":                false,
	} {
		if got := isCardinalityPath(p); got != want {
			t.Errorf("isCardinalityPath(%q) = %v, want %v", p, got, want)
		}
	}
}
