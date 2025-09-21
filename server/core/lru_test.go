package core

import (
	"testing"
)

type testValue[K comparable, V any] struct {
	key   K
	value V
	size  int
}

func (t testValue[K, V]) Key() K {
	return t.key
}

func (t testValue[K, V]) Value() V {
	return t.value
}

func (t testValue[K, V]) Size() int {
	return t.size
}

func TestLruAdd(t *testing.T) {
	t.Parallel()

	lru := NewLRU[testValue[string, int], string, int](3, 0)

	lt := lruT[int]{
		t:   t,
		lru: lru,
	}

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1
	lt.miss(testValue[string, int]{key: "b", value: 1}) // b1 a1
	lt.miss(testValue[string, int]{key: "c", value: 1}) // c1 b1 a1

	lt.hit(testValue[string, int]{key: "a", value: 5}) // a5 c1 b1
	lt.hit(testValue[string, int]{key: "b", value: 2}) // b1 a1 c1
	lt.hit(testValue[string, int]{key: "c", value: 1}) // c1 b1 a1

	a, _ := lru.Get("a")
	b, _ := lru.Get("b")
	c, _ := lru.Get("c")

	if a != 5 {
		t.Errorf("expected a to be 5, got %d", a)
	}
	if b != 2 {
		t.Errorf("expected b to be 2, got %d", b)
	}
	if c != 1 {
		t.Errorf("expected c to be 1, got %d", c)
	}
}

func TestLruTrim(t *testing.T) {
	t.Parallel()

	lru := NewLRU[testValue[string, int], string, int](3, 0)

	lt := lruT[int]{
		t:   t,
		lru: lru,
	}

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1
	lt.miss(testValue[string, int]{key: "b", value: 1}) // b1 a1
	lt.miss(testValue[string, int]{key: "c", value: 1}) // c1 b1 a1
	lt.miss(testValue[string, int]{key: "d", value: 1}) // d1 c1 b1 - should trim "a"
	lt.checkLen(3)
}

func TestLruRemove(t *testing.T) {
	t.Parallel()

	lru := NewLRU[testValue[string, int], string, int](3, 0)

	lt := lruT[int]{
		t:   t,
		lru: lru,
	}

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1
	lt.miss(testValue[string, int]{key: "b", value: 1}) // b1 a1
	lt.miss(testValue[string, int]{key: "c", value: 1}) // c1 b1 a1

	lt.rm(testValue[string, int]{key: "a", value: 1})
	lt.checkLen(2)

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1
	lt.hit(testValue[string, int]{key: "b", value: 2})  // b2 a1 (b was already in cache)
	lt.hit(testValue[string, int]{key: "c", value: 2})  // c2 b2 a1 (c was already in cache)

	lt.rm(testValue[string, int]{key: "b", value: 1})
	lt.checkLen(2)

	lt.hit(testValue[string, int]{key: "a", value: 1}) // a1
}

func TestLru(t *testing.T) {
	t.Parallel()

	lru := NewLRU[testValue[string, int], string, int](3, 0)

	lt := lruT[int]{
		t:   t,
		lru: lru,
	}

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1
	lt.hit(testValue[string, int]{key: "a", value: 1})  // a1
	lt.miss(testValue[string, int]{key: "b", value: 1}) // b1 a1
	lt.miss(testValue[string, int]{key: "c", value: 1}) // c1 b1 a1
	lt.miss(testValue[string, int]{key: "d", value: 1}) // d1 c1 b1 - should trim "a"

	lt.checkLen(3)

	lt.miss(testValue[string, int]{key: "e", value: 2}) // e2 d1 c1 - should trim "b"
	lt.checkLen(3)

	lt.miss(testValue[string, int]{key: "f", value: 2}) // f2 e2 d1 - should trim "c"
	lt.checkLen(3)

	lt.miss(testValue[string, int]{key: "g", value: 2}) // g2 f2 e2 - should trim "d"
	lt.checkLen(3)

	lt.miss(testValue[string, int]{key: "h", value: 2}) // h2 g2 f2 - should trim "e"
	lt.checkLen(3)

	lt.hit(testValue[string, int]{key: "h", value: 2}) // h2 g2 f2
	lt.hit(testValue[string, int]{key: "f", value: 2}) // f2 h2 g2
	lt.hit(testValue[string, int]{key: "g", value: 2}) // g2 f2 h2

	lt.miss(testValue[string, int]{key: "a", value: 1}) // a1 g2 f2 - should trim "h"
	lt.checkLen(3)

	lt.rm(testValue[string, int]{key: "g", value: 1}) // a1 f2
	lt.checkLen(2)

	lt.miss(testValue[string, int]{key: "g", value: 2}) // g2 a1 f2
	lt.checkLen(3)

	lt.hit(testValue[string, int]{key: "f", value: 2}) // f2 g2 a1 (f was already in cache)
	lt.checkLen(3)

	lt.rm(testValue[string, int]{key: "a", value: 1}) // f2 g2
	lt.checkLen(2)
}

// test byte limit

func object(key string, size int) testValue[string, any] {
	return testValue[string, any]{
		key:   key,
		value: make([]any, size),
		size:  size,
	}
}

func TestLruMaxBytes(t *testing.T) {
	t.Parallel()

	lru := NewLRU[testValue[string, any]](3, 100)

	lt := lruT[any]{
		t:   t,
		lru: lru,
	}

	lt.miss(object("a", 10))
	lt.checkSize(10)
	lt.miss(object("b", 50))
	lt.checkSize(60)
	lt.miss(object("c", 40))
	lt.checkSize(100)
	lt.miss(object("d", 100))
	lt.checkSize(100)
	lt.miss(object("e", 10))
	lt.checkSize(10)
}

// HELPER
type lruT[V any] struct {
	lru *LRU[testValue[string, V], string, V]
	t   *testing.T
}

func (l *lruT[V]) miss(testValue testValue[string, V]) {
	l.t.Helper()
	if l.lru.AddOrUpdate(testValue) {
		l.t.Errorf("Error: AddOrUpdate(\"%s\") expected miss", testValue.Key())
	}
	l.t.Log("miss: ", testValue.Key())
}

func (l *lruT[V]) hit(testValue testValue[string, V]) {
	l.t.Helper()
	if !l.lru.AddOrUpdate(testValue) {
		l.t.Errorf("Error: AddOrUpdate(\"%s\") expected hit", testValue.Key())
	}
	l.t.Log("hit:  ", testValue.Key())
}

func (l *lruT[V]) rm(testValue testValue[string, V]) {
	l.t.Helper()
	len := l.lru.len.Load()
	deleted := l.lru.Delete(testValue.Key())
	if !deleted {
		l.t.Errorf("Error: Delete(\"%s\") expected to delete something", testValue.Key())
	}
	l.t.Log("del:  ", testValue.Key(), "\tlen: ", len, "->", l.lru.len.Load())
}

func (l *lruT[V]) checkLen(expected int) {
	l.t.Helper()
	if l.lru.len.Load() != int32(expected) {
		l.t.Errorf("Error: expected len %d, got %d", expected, l.lru.len.Load())
	}
	l.t.Log("len:  ", l.lru.len.Load())
}

func (l *lruT[V]) checkSize(expected int) {
	l.t.Helper()
	if l.lru.bytes.Load() != int64(expected) {
		l.t.Errorf("Error: expected size %d, got %d", expected, l.lru.bytes.Load())
	}
	l.t.Log("size: ", l.lru.bytes.Load())
}
