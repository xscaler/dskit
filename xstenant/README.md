# xstenant

Reads the per-cell admin store that the control plane publishes to object
storage and serves it to a storage engine as an immutable in-memory snapshot.
It is a separate Go module with no dependency on dskit or any objstore
package.

## What it reads

Under `Config.Prefix` (default `admin/v1/`) in the cell's bucket:

- `manifest.json`: schema, generation, publish time and the sha256 of every object
- `tenants.json`: per-tenant state (`active`, `soft_locked`, `suspended`)
- `limits/<engine>.json`: engine-native per-tenant limits, passed through unmodified
- `keys.json`: sha256 of each API token mapped to a tenant, scopes and expiry

## How it works

The reader polls the manifest, skips an unchanged or older generation, fetches
only objects whose hash changed, verifies each against the manifest and swaps
in a new snapshot only when the whole generation is verified. Any error keeps
the previous snapshot. Objects it does not know are hash-checked and ignored.

### Disk cache

With `CacheDir` set, each applied generation is written to disk so a restart
can serve it while the bucket is unreachable. Layout:

```
CacheDir/
  current -> gen-<generation>-<rand>/     symlink, switched by rename
  gen-<generation>-<rand>/manifest.json   full copy of the bucket layout
  gen-<generation>-<rand>/tenants.json
  gen-<generation>-<rand>/limits/<engine>.json
```

A snapshot is written into a new generation directory, files and directories
are fsynced, then `current` is replaced atomically and `CacheDir` is fsynced.
Older generation directories are removed afterwards. A crash before the switch
leaves the previous generation loadable. The cache is read through `current`
and every object is checked against the manifest hash; a mismatch discards
the cache.

`CacheDir` must be per pod (an `emptyDir`), never shared across pods or
replicas: the layout assumes a single writer. Set `Config.CacheKey` to the
bucket name plus prefix; a cache written under another key is ignored.

The generation-backwards check compares only against generations this process
fetched from the bucket. After a cache restore the first successful bucket
fetch is accepted whatever its generation (logged at info when it is lower
than the cached one). Without `CacheDir` the snapshot keeps hashes only, not
the raw object bytes.

The module has no fail-open or fail-closed policy. `Ready()` means only that
a snapshot exists (from the bucket or the cache). Engines decide what to do
while it is false or the snapshot is old, and gate on `Source.Applied()`.

## Source

`Source[T]` is the per-engine apply helper. It registers on the Reader,
decodes `Snapshot.Limits(engine)` per tenant with a `DecodeFunc[T]` and swaps
in an immutable map per generation.

```go
src := xstenant.NewSource(r, "mimir", decodeMimir, logger, reg)
stop := r.Start(ctx)
if err := src.WaitApplied(ctx, time.Minute); err != nil { stop(); ... }
lim, ok := src.Get("t-alpha")
all := src.All() // do not modify
```

### Lifecycle

`Reader.Start(parent)` runs `Run` in a goroutine with its own cancel derived
from `parent` and returns `stop`, which cancels and waits for the goroutine
to exit. `stop` is idempotent. The engine pattern, with the service's own
lifecycle functions:

- in the starting function: `stop := r.Start(ctx)`, then wait for
  `Source.WaitApplied`; on any starting failure call `stop()` before
  returning the error, so the reader goroutine is not leaked
- in the stopping function: call `stop()`

- A snapshot already held by the Reader (restored from cache) is applied in
  `NewSource`, so `Applied()` is true without waiting for `Run`.
- `Applied()` becomes true only for a snapshot that lists and decodes this
  engine's `limits/<engine>.json`. A snapshot without it is ignored and does
  not satisfy `WaitApplied`.
- A tenant whose block fails to decode keeps its previous value, or is left
  out if it has none. Each failure is logged and counted.
- Tenants missing from a new snapshot are dropped.
- An unchanged generation, or a new one whose `limits/<engine>.json` hash is
  the same, is not decoded again.
- `WaitApplied` with a timeout of zero or less waits until `ctx` is done.

## Push gate

xscaler never blocks customer data except when the organisation is soft
locked for billing (non payment). The control plane publishes that as
`state: "soft_locked"` in `tenants.json`; reads stay allowed and only pushes
are denied. Engines return their usual 429 with `Retry-After: 60`.

`PushAllowed(tenant) (allowed bool, reason string)` exists on `Reader` (current
snapshot) and on `*Snapshot`, and is safe on a nil receiver:

| input                                        | allowed | reason                |
|----------------------------------------------|---------|-----------------------|
| no snapshot                                  | yes     | `no_state`            |
| tenant not in the snapshot                   | yes     | `unknown_tenant`      |
| `soft_locked`                                | no      | `billing_soft_locked` |
| `active`, `suspended`, any unknown state     | yes     | `allowed`             |

Nothing else ever denies a push. `suspended` is handled by auth, not here.

`CheckPush(tenant, mode) (deny bool, reason string)` applies a rollout mode.
`EnforceMode` implements `flag.Value` (`off`, `shadow`, `on`; zero value is
`off`):

- `off`: always allow, nothing counted.
- `shadow`: always allow; a soft locked tenant is counted as `would_deny`.
- `on`: deny a soft locked tenant, allow everything else.

```go
var mode xstenant.EnforceMode
flag.Var(&mode, "tenant-state.enforce", "off, shadow or on")
...
if deny, reason := r.CheckPush(tenantID, mode); deny {
	// respond 429, Retry-After: 60, reason
}
```

Modes `shadow` and `on` count every decision in
`xscaler_admin_store_state_decisions_total{mode,decision,reason}` with
`decision` one of `allow`, `deny`, `would_deny`. Several Readers can share one
registry; they share the counter.

## API key authorization

`Authorize` decides whether an API key may make a request to an engine. It
takes strings only:

```go
d := r.CheckAuth(xstenant.AuthRequest{
	Kind:          xstenant.KindLogs, // KindMetrics, KindLogs, KindTraces
	Method:        req.Method,
	Path:          req.URL.RequestURI(), // as the engine received it
	PathPrefix:    "/prometheus",        // the engine's route prefix, if any
	Authorization: req.Header.Get("Authorization"),
	OrgID:         req.Header.Get("X-Scope-OrgID"),
}, mode)
if !d.Allowed {
	// respond d.Status with d.Message; count or log d.Reason
}
if d.Enforced {
	// replace X-Scope-OrgID with d.Tenant
}
```

`Reader.Authorize` uses the current snapshot; `Snapshot.Authorize` is the same
on a given snapshot. Both are safe on a nil receiver and do not count
anything. An empty or unknown `Kind` is treated as metrics.

`Path` is the request path as the engine received it; a query string and
fragment are removed. `PathPrefix` is the engine's route prefix setting (for
example `/prometheus` for Mimir). When `Path` starts with it, it is removed
once before any check; a `Path` without it (the public form) is used as is.

`ExtraReadPaths` lets a deployment that serves extra read APIs next to an
engine allow them per request. Each entry is matched exactly against the
cleaned path (after query-string removal and prefix stripping), so prefixes,
trailing slashes and case variants do not match. A match needs the `read`
scope for every method and is never treated as a push or config path. The
dot-segment and encoding checks apply first. A path the built-in allowlist
already covers keeps its built-in scope. Unset, nothing changes.

Rules, in order, first match wins:

| # | condition                                                        | status | reason                 |
|---|------------------------------------------------------------------|--------|------------------------|
| 1 | `Authorization` is not `Bearer <token>` (two fields, case-insensitive scheme) | 401 | `missing_token`        |
| 2 | `OrgID` is empty after trimming whitespace                       | 401    | `missing_scope_orgid`  |
| 3 | no snapshot                                                      | 503    | `state_unavailable`    |
| 4 | sha256 hex of the raw token not in `keys.json`                   | 401    | `unknown_token`        |
| 5 | key has `expires_at` and it is not in the future                 | 401    | `key_expired`          |
| 6 | tenant state is `suspended` in `tenants.json`                    | 401    | `tenant_inactive`      |
| 7 | trimmed `OrgID` differs from the key's tenant                    | 401    | `scope_orgid_mismatch` |
| 8 | path is empty, not allowed for the kind, or rejected (below)     | 403    | `path_not_allowed`     |
| 9 | key lacks the needed scope                                       | 403    | `scope_read_missing` or `scope_write_missing` |

Unknown, expired and inactive credentials all answer with the same client
message (`unknown token`) so a caller cannot probe which tokens or tenants
exist; `Reason` keeps the distinction. A tenant missing from `tenants.json` is
allowed (as in `PushAllowed`). A `soft_locked` tenant is authorized here; the
push gate denies its pushes. `Tenant` is set only when the request is allowed.

`OrgID` is compared as received, after trimming. There is no default value:
an empty or blank header is `missing_scope_orgid`, and any value that is not
the key's tenant (`anonymous`, or several tenants joined with a comma) is
`scope_orgid_mismatch`.

Paths: the path is percent-decoded once, then checked. Percent-encoded dots,
slashes and backslashes (`%2e`, `%2f`, `%5c`, any case), raw backslashes and
invalid escapes are rejected, as are empty segments (`//`) and `.` or `..`
segments. An empty path is rejected. The allowlist per kind is the public API
of the engine, including the OTLP gRPC trace service
(`/opentelemetry.proto.collector.trace.v1.TraceService/`) as a traces push
path, the three Mimir cardinality endpoints and the rule forecast endpoint.

Scopes: a push path (with or without a trailing slash) needs `write`. Paths
that return secret-bearing config (Mimir's `/api/v1/alerts`, the Alertmanager
status and multitenant pages) need `write` for every method. Rule, delete and
Alertmanager config paths need `write` for any method other than GET, HEAD
and OPTIONS; an empty method is not a read. Everything else needs `read`. A
key whose `scopes` field is absent or null can read and write; an explicit
empty list can do neither. A key with `["read"]` can query but never push or
change config.

A `keys.json` entry may also carry `key_id` (string) and `managed` (bool).
Both are optional; an entry without them stays valid and reads as an empty
`KeyID` and `Managed` false. When a request is allowed, `AuthDecision.KeyID`
and `AuthDecision.Managed` return them so a caller can attribute the request
to a key. A denied decision carries neither.

### Classification on the decision

`Authorize` is the single source for how a request was classified, so callers
do not re-derive it from the raw path (which can differ from the cleaned,
decoded one):

- `Path`: the cleaned path (query and fragment removed, route prefix
  stripped, decoded once).
- `Push`: the path is a push path for the kind, trailing slash included.
- `RequiredScope`: `read` or `write`.
- `SoftLocked`: the request is allowed, `Push` is true and the tenant is
  `soft_locked`. Answer 429 with `Retry-After: 60`, or apply a rollout mode
  with `CheckPush(d.Tenant, mode)` when `d.Push` is true.

`Path` is set whenever the path cleaned, allowed or denied. `Push` and
`RequiredScope` are set once the path passed the allowlist (so also on
`scope_read_missing` and `scope_write_missing`). All are unset for denials
before the path step (`missing_token`, `missing_scope_orgid`,
`state_unavailable`, `unknown_token`, `key_expired`, `tenant_inactive`,
`scope_orgid_mismatch`), for a path that does not clean, and for `CheckAuth`
in mode `off`.

### Rollout mode

`CheckAuth(req, mode)` applies an `EnforceMode` (`off`, `shadow`, `on`):

- `off`: returns `Allowed` true at once, without looking at the request.
  Nothing is counted.
- `shadow`: `Allowed` is true and `Enforced` is false. A request `Authorize`
  would deny keeps its `Status`, `Reason` and `Message` but is counted as
  `would_deny`.
- `on`: the `Authorize` result, with `Enforced` true when it is allowed.

An engine replaces `X-Scope-OrgID` with `Tenant` only when `Enforced` is true.
In shadow and off it leaves the request as received, so a mode never changes
routing. In shadow, act on `Allowed` only, not on `Status`.

`shadow` and `on` count every decision in
`xscaler_admin_store_auth_decisions_total{mode,kind,decision,reason}` with
`decision` one of `allow`, `deny`, `would_deny`. Readers sharing a registry
share the counter.

### Where to apply it

Engines must apply this only on external entry points, the listeners that
receive customer requests. Traffic between components must not go through it.
Shadow runs on external entry points whose requests were already authorized by
another mechanism, so any `would_deny` is a disagreement to investigate before
switching to `on`.

Scope of the rules: there is no region or cluster check, since `keys.json` is
per cell. `keys.json` has no key status, so a disabled key is simply absent
(`unknown_token`).

## Wiring

```go
r, err := xstenant.New(xstenant.DefaultConfig(), bucket, logger, reg)
if err != nil { ... }
r.OnUpdate(func(s *xstenant.Snapshot) { /* apply s.Limits("loki") */ })
go r.Run(ctx)

if s := r.Snapshot(); s != nil {
	p, err := s.Authenticate(token)
	st, ok := s.State(p.TenantID)
}
```

`bucket` is anything with `Get(ctx, name) (io.ReadCloser, error)` and
`IsObjNotFoundErr(error) bool`; a thanos objstore bucket qualifies as is.

Metrics: `xscaler_admin_store_generation`,
`xscaler_admin_store_published_timestamp_seconds`,
`xscaler_admin_store_last_success_timestamp_seconds`,
`xscaler_admin_store_fetch_failures_total{object,reason}` and
`xscaler_admin_store_tenant_decode_failures_total{engine}` and
`xscaler_admin_store_engine_limits_missing{engine}` and
`xscaler_admin_store_state_decisions_total{mode,decision,reason}` and
`xscaler_admin_store_auth_decisions_total{mode,kind,decision,reason}`.

Alerting:

- A generation going backwards is
  `xscaler_admin_store_fetch_failures_total{object="manifest.json",reason="generation_backwards"}`.
  The previous snapshot is kept. Any increase means the publisher regressed or
  the bucket was rolled back.
- `time() - xscaler_admin_store_last_success_timestamp_seconds` grows while
  polls fail or the bucket is unreachable.
- Any increase of `xscaler_admin_store_tenant_decode_failures_total` means a
  tenant is running on stale or no limits.
- `xscaler_admin_store_engine_limits_missing{engine}` is 1 while the snapshot
  being served has no limits object for the engine. The source keeps serving
  the last decoded map, so retention and other limits do not vanish, and logs
  one warning per generation. It means the publisher dropped
  `limits/<engine>.json`; fix the publisher.
