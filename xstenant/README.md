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
`xscaler_admin_store_engine_limits_missing{engine}`.

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
