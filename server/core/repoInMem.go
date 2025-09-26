package core

import (
	"fmt"
	"sync"
)

// repoInMem is a simple in-memory repository.
// It is used for testing and development.
// It is thread-safe.
type repoInMem[V RepoValue[V]] struct {
	data       map[string]V
	dataMu     sync.RWMutex
	watchers   []chan RepoUpdate[V]
	watchersMu sync.RWMutex
}

func NewRepoInMem[V RepoValue[V]]() Repo[V] {
	return &repoInMem[V]{
		data:       make(map[string]V),
		dataMu:     sync.RWMutex{},
		watchers:   make([]chan RepoUpdate[V], 0),
		watchersMu: sync.RWMutex{},
	}
}

func (r *repoInMem[V]) Keys() (<-chan string, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	keysChan := make(chan string)
	go func() {
		for key := range r.data {
			keysChan <- key
		}
		close(keysChan)
	}()
	return keysChan, nil
}

func (r *repoInMem[V]) Get(key string) (V, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	var value V
	value, ok := r.data[key]
	if !ok {
		return value, fmt.Errorf("key not found")
	}
	return value, nil
}

func (r *repoInMem[V]) History(key string) ([]V, error) {
	return []V{}, fmt.Errorf("not available on RepoInMem")
}

func (r *repoInMem[V]) Put(key string, value V) error {
	r.dataMu.Lock()
	_, existed := r.data[key]
	r.data[key] = value
	r.dataMu.Unlock()

	op := OperationAdd
	if existed {
		op = OperationUpdate
	}

	r.broadcastUpdate(RepoUpdate[V]{
		operation: op,
		key:       key,
		value:     value,
	})
	return nil
}

func (r *repoInMem[V]) Delete(key string) error {
	r.dataMu.Lock()
	delete(r.data, key)
	r.dataMu.Unlock()

	r.broadcastUpdate(RepoUpdate[V]{
		operation: OperationDelete,
		key:       key,
	})
	return nil
}

func (r *repoInMem[V]) Watch() (<-chan RepoUpdate[V], error) {
	r.watchersMu.Lock()
	defer r.watchersMu.Unlock()
	watcherChan := make(chan RepoUpdate[V])
	r.watchers = append(r.watchers, watcherChan)
	return watcherChan, nil
}

func (r *repoInMem[V]) Close() error {
	return nil
}

func (r *repoInMem[V]) broadcastUpdate(update RepoUpdate[V]) {
	r.watchersMu.RLock()
	defer r.watchersMu.RUnlock()
	for _, watcher := range r.watchers {
		watcher <- update
	}
}
