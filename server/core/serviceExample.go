package core

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"
	"time"
)

type ExampleService struct {
	name string
}

func New(idx int) (*ExampleService, error) {
	fmt.Printf("ExampleService %d created\n", idx)
	return &ExampleService{name: fmt.Sprintf("ExampleService %d", idx)}, nil
}

func (s *ExampleService) Run(ctx context.Context) error {
	fmt.Printf("%s started\n", s.name)

	// Wait for context cancellation
	<-ctx.Done()
	fail := time.Now().UnixMicro()%3 == 0
	if fail {
		// Int cannot return an error when using rand.Reader.
		randInt, _ := rand.Int(rand.Reader, big.NewInt(10))
		time.Sleep(5 + time.Duration(randInt.Int64())*time.Second)
		return fmt.Errorf("%s stopped: FAIL", s.name)
	}

	fmt.Printf("%s stopped: OK\n", s.name)
	return nil
}

func (s *ExampleService) Name() string {
	return s.name
}
