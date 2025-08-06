package jst_log

import (
	"fmt"
	"strings"
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

// StdOut creates a StdOutService that subscribes to NATS subjects for various log levels and prints received log messages to standard output if they meet the configured log level threshold.
//
// Returns the initialized StdOutService.
func StdOut(nc *nats.Conn, base string, conf LoggerSubjects, level LogLevel) *StdOutService {
	svc := &StdOutService{nc: nc, base: base, conf: conf, level: level}

	_, err := nc.Subscribe(base+"."+conf.debug, func(m *nats.Msg) {
		if svc.level <= LogLevelDebug {
			fmt.Printf("%s [%s] %s\n", conf.debug, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	if err != nil {
		panic(err)
	}
	_, err = nc.Subscribe(base+"."+conf.info, func(m *nats.Msg) {
		if svc.level <= LogLevelInfo {
			fmt.Printf("%s [%s] %s\n", conf.info, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	if err != nil {
		panic(err)
	}
	_, err = nc.Subscribe(base+"."+conf.warn, func(m *nats.Msg) {
		if svc.level <= LogLevelWarn {
			fmt.Printf("%s [%s] %s\n", conf.warn, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	if err != nil {
		panic(err)
	}
	_, err = nc.Subscribe(base+"."+conf.err, func(m *nats.Msg) {
		if svc.level <= LogLevelError {
			fmt.Printf("%s [%s] %s\n", conf.err, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	if err != nil {
		panic(err)
	}
	_, err = nc.Subscribe(base+"."+conf.fatal, func(m *nats.Msg) {
		if svc.level <= LogLevelFatal {
			fmt.Printf("%s [%s] %s\n", conf.fatal, m.Header.Get("breadcrumbs"), m.Data)
		}
	})
	if err != nil {
		panic(err)
	}
	time.Sleep(1 * time.Millisecond) // TODO: refactor this hack
	return svc
}
func (s *StdOutService) SetLevel(level LogLevel) {
	s.level = level
}

// LogLevelFromString parses a string and returns the corresponding LogLevel constant.
// Returns an error if the input does not match a known log level.
func LogLevelFromString(level string) (LogLevel, error) {
	switch strings.ToLower(level) {
	case "debug":
		return LogLevelDebug, nil
	case "info":
		return LogLevelInfo, nil
	case "warn":
		return LogLevelWarn, nil
	case "error":
		return LogLevelError, nil
	case "fatal":
		return LogLevelFatal, nil
	default:
		return LogLevelInfo, fmt.Errorf("invalid log level: %s", level)
	}
}
