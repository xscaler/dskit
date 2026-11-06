package xstenant

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/go-kit/log/level"
)

// The cache is a set of generation directories below CacheDir. Each holds a
// full copy of the bucket layout and is written completely before the
// "current" symlink is switched to it, so a crash at any point leaves the
// previous generation intact and loadable.

const (
	currentLink = "current"
	genPrefix   = "gen-"
	metaName    = ".xstenant-cache.json"
)

// cacheMeta ties a cache to the bucket it was filled from.
type cacheMeta struct {
	Key string `json:"key"`
}

func (r *Reader) writeCache(s *Snapshot) error {
	name, err := r.writeGeneration(s)
	if err != nil {
		return err
	}
	if err := r.switchCurrent(name); err != nil {
		return err
	}
	r.pruneCache(name)
	return nil
}

// writeGeneration writes the snapshot into a fresh generation directory and
// returns its name. Nothing refers to it until switchCurrent runs.
func (r *Reader) writeGeneration(s *Snapshot) (string, error) {
	if err := os.MkdirAll(r.cfg.CacheDir, 0o755); err != nil {
		return "", err
	}
	name := fmt.Sprintf("%s%d-%s", genPrefix, s.man.Generation, randSuffix())
	root := filepath.Join(r.cfg.CacheDir, name)
	if err := os.Mkdir(root, 0o755); err != nil {
		return "", err
	}
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(root)
		}
	}()
	dirs := map[string]struct{}{root: {}}
	write := func(objName string, b []byte) error {
		p := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(objName, r.cfg.Prefix)))
		for d := filepath.Dir(p); ; d = filepath.Dir(d) {
			dirs[d] = struct{}{}
			if d == root {
				break
			}
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		return writeFileSync(p, b)
	}
	meta, err := json.Marshal(cacheMeta{Key: r.cfg.CacheKey})
	if err != nil {
		return "", err
	}
	if err := writeFileSync(filepath.Join(root, metaName), meta); err != nil {
		return "", err
	}
	for objName := range s.hashes {
		b, held := s.raw[objName]
		if !held {
			return "", fmt.Errorf("object %s not held", objName)
		}
		if err := write(objName, b); err != nil {
			return "", err
		}
	}
	if err := write(r.cfg.Prefix+manifestName, s.rawMan); err != nil {
		return "", err
	}
	for d := range dirs {
		if err := syncDir(d); err != nil {
			return "", err
		}
	}
	ok = true
	return name, nil
}

// switchCurrent points the current symlink at the generation directory with a
// rename, which replaces the old link atomically.
func (r *Reader) switchCurrent(name string) error {
	tmp := filepath.Join(r.cfg.CacheDir, ".current-"+randSuffix())
	if err := os.Symlink(name, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(r.cfg.CacheDir, currentLink)); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return syncDir(r.cfg.CacheDir)
}

// pruneCache removes every generation directory except keep, plus leftovers
// of interrupted writes.
func (r *Reader) pruneCache(keep string) {
	ents, err := os.ReadDir(r.cfg.CacheDir)
	if err != nil {
		return
	}
	for _, e := range ents {
		n := e.Name()
		if n == keep || n == currentLink {
			continue
		}
		if strings.HasPrefix(n, genPrefix) || strings.HasPrefix(n, ".current-") {
			_ = os.RemoveAll(filepath.Join(r.cfg.CacheDir, n))
		}
	}
}

func randSuffix() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (r *Reader) loadCache() {
	s, err := r.readCache()
	if err != nil {
		if !os.IsNotExist(err) {
			level.Warn(r.logger).Log("msg", "ignoring admin store cache", "err", err)
		}
		return
	}
	r.snap.Store(s)
	r.m.generation.Set(float64(s.man.Generation))
	r.m.published.Set(float64(s.man.PublishedAt.Unix()))
}

// readCache loads the generation the current symlink points to and verifies
// every object against its manifest hash.
func (r *Reader) readCache() (*Snapshot, error) {
	root := filepath.Join(r.cfg.CacheDir, currentLink)
	path := func(name string) string {
		return filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(name, r.cfg.Prefix)))
	}
	rawMeta, err := readCapped(filepath.Join(root, metaName), r.cfg.MaxObjectBytes)
	if err != nil {
		return nil, err
	}
	var meta cacheMeta
	if err := json.Unmarshal(rawMeta, &meta); err != nil {
		return nil, err
	}
	if meta.Key != r.cfg.CacheKey {
		return nil, fmt.Errorf("cache belongs to %q, not %q", meta.Key, r.cfg.CacheKey)
	}
	rawMan, err := readCapped(path(r.cfg.Prefix+manifestName), r.cfg.MaxObjectBytes)
	if err != nil {
		return nil, err
	}
	man, err := r.decodeManifest(rawMan)
	if err != nil {
		return nil, err
	}
	fetched := make(map[string][]byte, len(man.Objects))
	for name, want := range man.Objects {
		b, err := readCapped(path(name), r.cfg.MaxObjectBytes)
		if err != nil {
			return nil, err
		}
		if got := hashHex(b); got != want {
			return nil, fmt.Errorf("%s: sha256 %s, manifest has %s", name, got, want)
		}
		fetched[name] = b
	}
	return r.assemble(man, rawMan, fetched, nil)
}

func readCapped(p string, max int64) ([]byte, error) {
	fi, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	if fi.Size() > max {
		return nil, fmt.Errorf("%s larger than %d bytes", p, max)
	}
	return os.ReadFile(p)
}

// writeFileSync creates p and fsyncs it. p lives in a generation directory
// that is not visible until the symlink switch, so no rename is needed.
func writeFileSync(p string, b []byte) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func syncDir(p string) error {
	d, err := os.Open(p)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
