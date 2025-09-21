package core

import (
	"sync"
	"sync/atomic"
)

type CacheValue[K comparable, V any] interface {
	Size() int
	Key() K
	Value() V
}

// CacheStat represents cache statistics
type CacheStat struct {
	Size      int
	Capacity  int
	Bytes     int
	MaxBytes  int
	Hit       uint32
	Miss      uint32
	Evictions uint32
}

// LRU is a generic Least Recently Used cache. It can store any comparable key type
// with any value type. LRU is thread safe.
type LRU[C CacheValue[K, V], K comparable, V any] struct {
	cap           uint
	len           atomic.Int32
	bytes         atomic.Int64
	maxBytes      uint
	evictions     atomic.Uint32
	hits          atomic.Uint32
	misses        atomic.Uint32
	head          *node[C, K, V]
	tail          *node[C, K, V]
	lookup        map[K]*node[C, K, V]
	reverseLookup map[*node[C, K, V]]K
	lMutex        sync.RWMutex
	rlMutex       sync.RWMutex
}

// NewLRU creates a new LRU cache with the given capacity.
// The capacity is the maximum number of items that can be stored in the cache.
// The maxBytes is the maximum number of bytes that can be stored in the cache. 0 means no limit.
func NewLRU[C CacheValue[K, V], K comparable, V any](cap int, maxBytes int) *LRU[C, K, V] {
	if cap < 0 {
		cap = 0
	}
	if maxBytes < 0 {
		maxBytes = 0
	}
	return &LRU[C, K, V]{
		cap:           uint(cap),
		maxBytes:      uint(maxBytes),
		lookup:        make(map[K]*node[C, K, V]),
		reverseLookup: make(map[*node[C, K, V]]K),
	}
}

type node[C CacheValue[K, V], K comparable, V any] struct {
	prev, next *node[C, K, V]
	key        K
	value      C
}

func (l *LRU[C, K, V]) Contains(key K) bool {
	if _, ok := l.lookupNode(key); ok {
		return true
	} else {
		return false
	}
}

func (l *LRU[C, K, V]) AddOrUpdate(c C) bool {
	if n, ok := l.lookupNode(c.Key()); ok {
		n.value = c
		l.moveToFront(n)
		l.hits.Add(1)
		return true
	} else {
		// create new node
		n := &node[C, K, V]{key: c.Key(), value: c}
		// set lookups
		l.addToLookup(n, c.Key())
		// add to front
		l.addToFront(n)
		// trim if needed
		l.trim()
		// update misses
		l.misses.Add(1)
		// return false (miss)
		return false
	}
}

func (l *LRU[C, K, V]) Delete(key K) bool {
	n, ok := l.lookupNode(key)
	if !ok {
		return false
	}

	retrievedKey, ok := l.lookupKey(n)
	if !ok {
		panic("lru.Delete(key): node not found in lookup")
	}
	if retrievedKey != key {
		panic("lru.Delete(key): key mismatch")
	}

	l.detatchNode(n)
	l.removeFromLookup(n, retrievedKey)
	l.evictions.Add(1)
	return true
}

func (l *LRU[C, K, V]) Stat() CacheStat {
	return CacheStat{
		Size:      int(l.len.Load()),
		Capacity:  int(l.cap),
		Bytes:     int(l.bytes.Load()),
		MaxBytes:  int(l.maxBytes),
		Hit:       l.hits.Load(),
		Miss:      l.misses.Load(),
		Evictions: l.evictions.Load(),
	}
}

func (l *LRU[C, K, V]) Get(key K) (V, bool) {
	n, ok := l.lookupNode(key)
	if !ok {
		var zero V
		return zero, false
	}
	l.moveToFront(n)
	l.hits.Add(1)
	return n.value.Value(), true
}

func (l *LRU[C, K, V]) trim() {
	for l.len.Load() > int32(l.cap) || l.bytes.Load() > int64(l.maxBytes) {
		node := l.tail
		key, _ := l.lookupKey(node)

		l.detatchTail()
		l.removeFromLookup(node, key)

		l.evictions.Add(1)
	}
}

// List operations

func (l *LRU[C, K, V]) addToFront(n *node[C, K, V]) {
	if l.len.Load() == 0 {
		l.head = n
		l.tail = n
		l.bytes.Add(int64(n.value.Size()))
		l.len.Add(int32(1))
		return
	}
	n.next = l.head
	l.head.prev = n
	l.head = n
	l.bytes.Add(int64(n.value.Size()))
	l.len.Add(1)
}

func (l *LRU[C, K, V]) moveToFront(n *node[C, K, V]) {
	// check if n is front
	if l.head == n {
		return
	}

	// check if n is tail
	if l.tail == n {
		l.tail = n.prev
	}

	// detatch from neighbours
	if n.prev != nil {
		n.prev.next = n.next
	}
	if n.next != nil {
		n.next.prev = n.prev
	}

	// set node links
	n.prev = nil
	n.next = l.head

	// set current head to point new node
	l.head.prev = n

	// set new head
	l.head = n
}

func (l *LRU[C, K, V]) detatchTail() {
	n := l.tail

	// link tail to previous node
	l.tail = n.prev

	// tail next is nil
	l.tail.next = nil

	// detatch node from list
	n.prev = nil

	// reduce bytes
	l.bytes.Add(int64(-n.value.Size()))

	// decrement len
	l.len.Add(-1)
}

func (l *LRU[C, K, V]) detatchNode(n *node[C, K, V]) {
	// update head if this is the head node
	if l.head == n {
		l.head = n.next
	}

	// update tail if this is the tail node
	if l.tail == n {
		l.tail = n.prev
	}

	// link previous node to next node
	if n.prev != nil {
		n.prev.next = n.next
	}

	// link next node to previous node
	if n.next != nil {
		n.next.prev = n.prev
	}

	// remove node links
	n.prev = nil
	n.next = nil

	// reduce bytes
	l.bytes.Add(int64(-n.value.Size()))

	// decrement len
	l.len.Add(-1)
}

// Lookup operations

func (l *LRU[C, K, V]) lookupNode(key K) (*node[C, K, V], bool) {
	l.lMutex.RLock()
	n, ok := l.lookup[key]
	l.lMutex.RUnlock()
	return n, ok
}

func (l *LRU[C, K, V]) lookupKey(n *node[C, K, V]) (K, bool) {
	l.rlMutex.RLock()
	key, ok := l.reverseLookup[n]
	l.rlMutex.RUnlock()
	return key, ok
}

func (l *LRU[C, K, V]) addToLookup(n *node[C, K, V], key K) {
	l.lMutex.Lock()
	l.rlMutex.Lock()
	l.lookup[key] = n
	l.reverseLookup[n] = key
	l.lMutex.Unlock()
	l.rlMutex.Unlock()
}

func (l *LRU[C, K, V]) removeFromLookup(n *node[C, K, V], key K) {
	l.lMutex.Lock()
	l.rlMutex.Lock()
	delete(l.lookup, key)
	delete(l.reverseLookup, n)
	l.lMutex.Unlock()
	l.rlMutex.Unlock()
}
