package core

// RepoValue is a value type that can be used to identify a repository entry.
// It must have a Bytes() method that returns a slice of bytes.
type RepoValue[V any] interface {
	Bytes() []byte
	FromBytes(value []byte) (V, error)
}

// Repo common interface.
type Repo[V RepoValue[V]] interface {
	Keys() (<-chan string, error)
	Get(key string) (V, error)
	History(key string) ([]V, error)
	Put(key string, value V) error
	Delete(key string) error
	Watch() (<-chan RepoUpdate[V], error)
	Close() error
}

type RepoWithIndexes[V RepoValue[V]] interface {
	Repo[V]
	GetByIndex(index string, value V) (V, error)
	Index(index string, IndexFunc func(V) string) error
	Unindex(index string) error
}
