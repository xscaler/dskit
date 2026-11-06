package xstenant

import (
	"encoding/json"
	"time"
)

// schemaVersion is the highest document schema this reader understands.
const schemaVersion = 1

const (
	manifestName = "manifest.json"
	tenantsName  = "tenants.json"
	keysName     = "keys.json"
	limitsDir    = "limits/"
)

// Tenant states as published in tenants.json.
const (
	StateActive     = "active"
	StateSoftLocked = "soft_locked"
	StateSuspended  = "suspended"
)

type manifest struct {
	Schema      int               `json:"schema"`
	Generation  int64             `json:"generation"`
	PublishedAt time.Time         `json:"published_at"`
	Objects     map[string]string `json:"objects"`
}

// TenantState is one tenant's entry in tenants.json.
type TenantState struct {
	OrgID  string `json:"org_id"`
	State  string `json:"state"`
	PlanID string `json:"plan_id"`
}

type tenantsDoc struct {
	Schema  int                    `json:"schema"`
	Tenants map[string]TenantState `json:"tenants"`
}

type limitsDoc struct {
	Schema  int                        `json:"schema"`
	Tenants map[string]json.RawMessage `json:"tenants"`
}

type keyRecord struct {
	TenantID  string     `json:"tenant_id"`
	Scopes    []string   `json:"scopes"`
	ExpiresAt *time.Time `json:"expires_at"`
}

type keysDoc struct {
	Schema int                  `json:"schema"`
	Keys   map[string]keyRecord `json:"keys"`
}
