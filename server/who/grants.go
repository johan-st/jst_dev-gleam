package who

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
)

type GrantsEngine struct {
	l      *jst_log.Logger
	grants core.RepoKv[Grant]
	// grantsMu    sync.RWMutex
	// grantsSlice []Grant
}

type Grant struct {
	Subject  Agent    `json:"subject"`
	Resource Resource `json:"resource"`
	Action   Action   `json:"action"`
	Grantee  Agent    `json:"grantee"`
}

func (g Grant) Bytes() []byte {
	data, err := json.Marshal(g)
	if err != nil {
		return nil
	}
	return data
}

func (g Grant) FromBytes(data []byte) (Grant, error) {
	var result Grant
	err := json.Unmarshal(data, &result)
	return result, err
}

type Agent string

type Action string

const (
	ActionSee             Action = "see"
	ActionChange          Action = "change"
	ActionHistory         Action = "history"
	ActionDelegateSee     Action = "delegate_see"
	ActionDelegateChange  Action = "delegate_change"
	ActionDelegateHistory Action = "delegate_history"
)

type Resource struct {
	ID     string `json:"id"`
	Domain Domain `json:"domain"`
}

type Domain string

const (
	DomainUrl     Domain = "url"
	DomainUser    Domain = "user"
	DomainArticle Domain = "article"
)

func NewGrantsEngine(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (*GrantsEngine, error) {
	if l == nil {
		return nil, fmt.Errorf("logger can not be nil")
	}
	if nc == nil {
		return nil, fmt.Errorf("nats conn can not be nil")
	}

	kv, err := setupGrantsKV(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("setup grants kv: %w", err)
	}

	repo, err := core.NewRepoKv[Grant](ctx, l, kv)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	ge := GrantsEngine{
		l:      l,
		grants: repo,
	}

	return &ge, nil
}

func setupGrantsKV(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "grants",
		Description:  "grants in json format",
		MaxValueSize: 1024 * 5,         // 5 KB
		MaxBytes:     1024 * 1024 * 50, // 50 MB,
		History:      1,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
