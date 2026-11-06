package xstenant

import (
	"context"
	"io"
	"strings"
	"time"
)

// Bucket is the read side of an object store. The thanos objstore
// BucketReader satisfies it structurally.
type Bucket interface {
	Get(ctx context.Context, name string) (io.ReadCloser, error)
	IsObjNotFoundErr(err error) bool
}

// Config configures a Reader.
type Config struct {
	// Prefix is the key prefix of the admin store in the bucket.
	Prefix string
	// PollInterval is the time between manifest polls.
	PollInterval time.Duration
	// CacheDir, when set, keeps the last applied generation on disk so a
	// restart can serve it while the bucket is unreachable.
	CacheDir string
	// CacheKey identifies the bucket and prefix the cache belongs to
	// (engines pass bucket name plus prefix). A cache written under a
	// different key is ignored. Empty matches only caches written with an
	// empty key.
	CacheKey string
	// MaxObjectBytes caps the size of any single object, manifest included.
	MaxObjectBytes int64
}

// DefaultConfig returns a Config with the defaults filled in.
func DefaultConfig() Config {
	return Config{
		Prefix:         "admin/v1/",
		PollInterval:   5 * time.Second,
		MaxObjectBytes: 64 << 20,
	}
}

func (c *Config) applyDefaults() {
	d := DefaultConfig()
	if c.Prefix == "" {
		c.Prefix = d.Prefix
	}
	if !strings.HasSuffix(c.Prefix, "/") {
		c.Prefix += "/"
	}
	if c.PollInterval <= 0 {
		c.PollInterval = d.PollInterval
	}
	if c.MaxObjectBytes <= 0 {
		c.MaxObjectBytes = d.MaxObjectBytes
	}
}
