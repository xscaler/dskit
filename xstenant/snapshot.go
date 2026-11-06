package xstenant

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

var (
	// ErrUnknownKey is returned by Authenticate for a token with no entry.
	ErrUnknownKey = errors.New("xstenant: unknown key")
	// ErrExpiredKey is returned by Authenticate for an expired key.
	ErrExpiredKey = errors.New("xstenant: key expired")
)

// Principal is the identity behind an authenticated token.
type Principal struct {
	TenantID string
	Scopes   []string
}

// Snapshot is one applied generation of the admin store. It is immutable and
// safe for concurrent use.
type Snapshot struct {
	man     manifest
	tenants map[string]TenantState
	keys    map[string]keyRecord
	limits  map[string]map[string]json.RawMessage // engine -> tenant -> block
	hashes  map[string]string                     // object name -> sha256 hex
	lhash   map[string]string                     // engine -> sha256 of its limits object
	raw     map[string][]byte                     // object name -> bytes; only held when the disk cache is on
	rawMan  []byte
	now     func() time.Time
}

// Generation returns the generation counter of the manifest.
func (s *Snapshot) Generation() int64 { return s.man.Generation }

// PublishedAt returns the time the control plane published the generation.
func (s *Snapshot) PublishedAt() time.Time { return s.man.PublishedAt }

// Limits returns the engine-native limits per tenant, as published. The map
// and its values must not be modified.
func (s *Snapshot) Limits(engine string) map[string]json.RawMessage {
	return s.limits[engine]
}

// HasLimits reports whether the snapshot lists and decoded a limits object for
// the engine.
func (s *Snapshot) HasLimits(engine string) bool {
	_, ok := s.limits[engine]
	return ok
}

// State returns the tenant's published state.
func (s *Snapshot) State(tenant string) (TenantState, bool) {
	st, ok := s.tenants[tenant]
	return st, ok
}

// Authenticate looks the token up by its sha256 hash.
func (s *Snapshot) Authenticate(token string) (Principal, error) {
	sum := sha256.Sum256([]byte(token))
	k, ok := s.keys[hex.EncodeToString(sum[:])]
	if !ok {
		return Principal{}, ErrUnknownKey
	}
	if k.ExpiresAt != nil && !s.now().Before(*k.ExpiresAt) {
		return Principal{}, ErrExpiredKey
	}
	return Principal{TenantID: k.TenantID, Scopes: append([]string(nil), k.Scopes...)}, nil
}
