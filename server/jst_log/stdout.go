package jst_log

import (
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
)

type LogLevel int

const (
	LogLevelDebug LogLevel = iota - 1
	LogLevelInfo
	LogLevelWarn
	LogLevelError
	LogLevelFatal
)

type StdOutService struct {
	nc    *nats.Conn
	base  string
	conf  LoggerSubjects
	level LogLevel
}

func StdOut(nc *nats.Conn, base string, conf LoggerSubjects, level LogLevel) *StdOutService {
	svc := &StdOutService{nc: nc, base: base, conf: conf, level: level}

	nc.Subscribe(base+"."+conf.debug, func(m *nats.Msg) {
		if svc.level <= LogLevelDebug {
			fmt.Printf("%s [%s] %s\n", conf.debug, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	nc.Subscribe(base+"."+conf.info, func(m *nats.Msg) {
		if svc.level <= LogLevelInfo {
			fmt.Printf("%s [%s] %s\n", conf.info, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	nc.Subscribe(base+"."+conf.warn, func(m *nats.Msg) {
		if svc.level <= LogLevelWarn {
			fmt.Printf("%s [%s] %s\n", conf.warn, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	nc.Subscribe(base+"."+conf.err, func(m *nats.Msg) {
		if svc.level <= LogLevelError {
			fmt.Printf("%s [%s] %s\n", conf.err, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	nc.Subscribe(base+"."+conf.fatal, func(m *nats.Msg) {
		if svc.level <= LogLevelFatal {
			fmt.Printf("%s [%s] %s\n", conf.fatal, m.Header.Get("breadcrumbs"), m.Data)
		}
	})

	time.Sleep(1 * time.Millisecond) // TODO: refactor this hack
	return svc
}
func (s *StdOutService) SetLevel(level LogLevel) {
	s.level = level
}
