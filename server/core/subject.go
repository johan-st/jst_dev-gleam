package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

type Subscriber[V SubscriptionValue] interface {
	Subscribe(ctx context.Context, opts SubscribeOptions) (<-chan SubscriptionUpdate[V], error)
}

type SubscriptionUpdate[V SubscriptionValue] interface {
	InSync() bool
	Revision() uint64
	Value() V
}

type SubscriptionValue interface {
	Bytes() []byte
	FromBytes(value []byte) error
}

// SubscribeOptions configures a durable JetStream subscription
// - Stream: JetStream stream name to bind the consumer to
// - Filter: Filter subject (must match a stream subject)
// - Durable: Durable consumer name; if empty a stable one is generated
// - StartSeq: Start at this stream sequence (0 means start at default/latest as server decides)
// - BatchSize: Number of messages to fetch per request (default 50)
// - MaxWait: Max wait per fetch (default 200ms)
// The subscription ends when the provided ctx is cancelled.
// ------------------------------------------------------------

type SubscribeOptions struct {
	Stream    string
	Filter    string
	Durable   string
	StartSeq  uint64
	BatchSize int
	MaxWait   time.Duration
}

// ------------------------------------------------------------
// Implementation
// ------------------------------------------------------------

type subscriber[V SubscriptionValue] struct {
	ctx context.Context
	l   *jst_log.Logger
	js  nats.JetStreamContext
}

func NewSubscriber[V SubscriptionValue](ctx context.Context, l *jst_log.Logger, js nats.JetStreamContext) Subscriber[V] {
	sub := &subscriber[V]{
		ctx: ctx,
		l:   l,
		js:  js,
	}
	return sub
}

type subscriptionUpdate[V SubscriptionValue] struct {
	inSync   bool
	revision uint64
	value    V
}

func (u subscriptionUpdate[V]) InSync() bool     { return u.inSync }
func (u subscriptionUpdate[V]) Revision() uint64 { return u.revision }
func (u subscriptionUpdate[V]) Value() V         { return u.value }

func (s *subscriber[V]) Subscribe(ctx context.Context, opts SubscribeOptions) (<-chan SubscriptionUpdate[V], error) {
	if opts.Stream == "" {
		return nil, fmt.Errorf("stream is required")
	}
	if opts.Filter == "" {
		return nil, fmt.Errorf("filter subject is required")
	}
	if opts.BatchSize <= 0 {
		opts.BatchSize = 50
	}
	if opts.MaxWait <= 0 {
		opts.MaxWait = 200 * time.Millisecond
	}
	// Determine durable name
	if opts.Durable == "" {
		opts.Durable = durableName("core", opts.Stream, opts.Filter)
	}

	// Bind to stream and optional start sequence
	subOpts := []nats.SubOpt{nats.BindStream(opts.Stream)}
	if opts.StartSeq > 0 {
		subOpts = append(subOpts, nats.StartSequence(opts.StartSeq))
	}

	sub, err := s.js.PullSubscribe(opts.Filter, opts.Durable, subOpts...)
	if err != nil {
		return nil, fmt.Errorf("pull subscribe: %w", err)
	}

	updates := make(chan SubscriptionUpdate[V], opts.BatchSize)

	// Track in-sync by comparing to current last sequence at start
	var lastSeq uint64 = 0
	if si, err := s.js.StreamInfo(opts.Stream); err == nil && si != nil {
		lastSeq = si.State.LastSeq
	}

	go func() {
		defer func() { _ = sub.Drain(); close(updates) }()
		inSyncSent := lastSeq == 0
		for {
			select {
			case <-ctx.Done():
				return
			case <-s.ctx.Done():
				return
			default:
				msgs, err := sub.Fetch(opts.BatchSize, nats.MaxWait(opts.MaxWait))
				if err != nil {
					if err == nats.ErrTimeout {
						// idle
						continue
					}
					// other errors end loop; channel will close
					return
				}
				for _, msg := range msgs {
					var value V
					_ = value.FromBytes(msg.Data)
					md, _ := msg.Metadata()
					seq := uint64(0)
					if md != nil {
						seq = md.Sequence.Stream
					}
					update := subscriptionUpdate[V]{
						inSync:   inSyncSent || (lastSeq > 0 && seq >= lastSeq),
						revision: seq,
						value:    value,
					}
					select {
					case updates <- update:
						_ = msg.Ack()
					case <-ctx.Done():
						return
					}
					if !inSyncSent && update.inSync {
						inSyncSent = true
					}
				}
			}
		}
	}()

	return updates, nil
}

// durableName mirrors the websocket durable generator for stability
func durableName(userID, stream, filter string) string {
	h := sha256.New()
	_, _ = h.Write([]byte(fmt.Sprintf("%s:%s:%s", userID, stream, filter)))
	hash := hex.EncodeToString(h.Sum(nil))[:16]
	name := fmt.Sprintf("core_%s_%s_%s", sanitizeName(stream), sanitizeName(filter), hash)
	if len(name) > 200 {
		name = name[:200]
	}
	return name
}

func sanitizeName(s string) string {
	var out []rune
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' || r == '.' {
			out = append(out, r)
		} else {
			out = append(out, '_')
		}
	}
	if len(out) == 0 {
		return "_"
	}
	return string(out)
}
