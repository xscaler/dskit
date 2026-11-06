// Package xstenant reads the per-cell admin store that the control plane
// publishes to object storage: tenant state, resolved per-engine limits and
// API key hashes. A Reader polls the bucket, verifies every object against
// the manifest and swaps in an immutable Snapshot atomically.
//
// The package applies no policy. Engines decide what to do before the first
// snapshot exists or when it goes stale.
package xstenant
