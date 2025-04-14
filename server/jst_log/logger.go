package jst_log

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
)

// Level represents the severity of a log message
type Level int

const (
	// Debug level for detailed troubleshooting
	Debug Level = iota - 1
	// Info level for general operational information
	Info
	// Warn level for potentially harmful situations
	Warn
	// Error level for errors that might still allow the application to continue
	Error
	// Fatal level for severe errors that prevent normal operation
	Fatal
)

type LoggerSubjects struct {
	base  string
	debug string
	info  string
	warn  string
	err   string
	fatal string
}

type Logger struct {
	nc          *nats.Conn
	appName     string
	breadcrumbs []string
	conf        LoggerSubjects
	level       Level
}

func NewLogger(appName string, subjects LoggerSubjects) *Logger {

	logger := &Logger{
		nc:          nil,
		appName:     appName,
		conf:        subjects,
		breadcrumbs: []string{},
		level:       Info,
	}

	// go logCnc(nc, subjects, logger)

	return logger
}
func (l *Logger) Connect(nc *nats.Conn) {
	l.nc = nc
	go logCnc(l.nc, l.conf, l)
}

func DefaultSubjects() LoggerSubjects {
	return LoggerSubjects{
		base:  "log",
		debug: "debug",
		info:  "info",
		warn:  "warn",
		err:   "error",
		fatal: "fatal",
	}
}

func (l *Logger) WithBreadcrumb(breadcrumb string) *Logger {
	newLogger := &Logger{
		nc:          l.nc,
		conf:        l.conf,
		breadcrumbs: append(l.breadcrumbs, breadcrumb),
		appName:     l.appName,
	}
	return newLogger
}

func (l *Logger) Debug(msg string, args ...interface{}) {
	l.log(Debug, msg, args...)
}

func (l *Logger) Info(msg string, args ...interface{}) {
	l.log(Info, msg, args...)
}

func (l *Logger) Warn(msg string, args ...interface{}) {
	l.log(Warn, msg, args...)
}

func (l *Logger) Error(msg string, args ...interface{}) {
	l.log(Error, msg, args...)
}

func (l *Logger) Fatal(msg string, args ...interface{}) {
	l.log(Fatal, msg, args...)
	<-time.After(1 * time.Second)
	os.Exit(1)
}

func (l *Logger) log(level Level, msg string, args ...interface{}) {
	if l.nc == nil {
		fmt.Printf("logger not connected. Local logging only. Msg: %s\n", msg)
		return
	}
	unixMicro := strconv.FormatInt(time.Now().UnixMicro(), 10)
	// Format the message if args are provided
	if len(args) > 0 {
		msg = fmt.Sprintf(msg, args...)
	}

	levelStr := []string{l.conf.debug, l.conf.info, l.conf.warn, l.conf.err, l.conf.fatal}[level+1]

	// Create headers
	headers := nats.Header{
		"level":       []string{levelStr},
		"timestamp":   []string{unixMicro},
		"app":         []string{l.appName},
		"breadcrumbs": []string{strings.Join(l.breadcrumbs, ".")},
	}

	// Create message with headers
	m := nats.NewMsg(l.conf.base + "." + l.appName + "." + levelStr)
	m.Header = headers
	m.Data = []byte(msg)

	// Publish the message
	if err := l.nc.PublishMsg(m); err != nil {
		// If we can't publish, print to stderr as fallback
		fmt.Printf("Failed to publish log message: %v\n", err)
	}
}

func logCnc(nc *nats.Conn, subjects LoggerSubjects, logger *Logger) {

	nc.Publish("add_cmd_description.log.set_level.{debug,info,warn,error,fatal}", []byte("set log level"))

	nc.Subscribe("cmd.set_level.*", func(msg *nats.Msg) {
		level := strings.TrimPrefix(msg.Subject, "log.set_level.")
		levelFromStr, err := levelFromString(level)
		if err != nil {
			fmt.Println(err)
		}
		logger.level = levelFromStr
	})
}

func levelFromString(level string) (Level, error) {
	switch strings.ToLower(level) {
	case "debug":
		return Debug, nil
	case "info":
		return Info, nil
	case "warn":
		return Warn, nil
	case "error":
		return Error, nil
	case "fatal":
		return Fatal, nil
	default:
		return Info, fmt.Errorf("invalid log level: %s", level)
	}
}
