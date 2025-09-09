package core

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// NATSClient provides a wrapper around NATS operations with consistent error handling
type NATSClient struct {
	nc      *nats.Conn
	logger  *jst_log.Logger
	timeout time.Duration
}

// NewNATSClient creates a new NATS client wrapper
func NewNATSClient(nc *nats.Conn, logger *jst_log.Logger, timeout time.Duration) *NATSClient {
	return &NATSClient{
		nc:      nc,
		logger:  logger,
		timeout: timeout,
	}
}

// Request performs a NATS request with timeout and error handling
func (c *NATSClient) Request(subject string, data []byte) (*nats.Msg, error) {
	return c.RequestWithTimeout(subject, data, c.timeout)
}

// RequestWithTimeout performs a NATS request with custom timeout
func (c *NATSClient) RequestWithTimeout(subject string, data []byte, timeout time.Duration) (*nats.Msg, error) {
	if c.nc.Status() != nats.CONNECTED {
		return nil, ErrNatsNotConnected()
	}

	c.logger.Debug("NATS request to %s", subject)

	msg, err := c.nc.Request(subject, data, timeout)
	if err != nil {
		c.logger.Error("NATS request failed: %v", err)
		if err == nats.ErrTimeout {
			return nil, ErrTimeout("nats_request").WithCause(err)
		}
		return nil, NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "request",
			fmt.Sprintf("request to %s failed", subject)).WithCause(err)
	}

	// Check for service errors in response headers
	if msg.Header.Get("Nats-Service-Error") != "" {
		errorCode := msg.Header.Get("Nats-Service-Error-Code")
		errorMsg := string(msg.Data)
		c.logger.Error("Service error response: %s - %s", errorCode, errorMsg)

		return nil, NewServiceError(ErrorCode(errorCode), "service", "request", errorMsg)
	}

	return msg, nil
}

// RequestJSON performs a NATS request with JSON marshaling/unmarshaling
func (c *NATSClient) RequestJSON(subject string, request interface{}, response interface{}) error {
	// Marshal request
	reqData, err := json.Marshal(request)
	if err != nil {
		return NewServiceError(ErrorCodeValidation, "nats", "marshal",
			"failed to marshal request").WithCause(err)
	}

	// Make request
	msg, err := c.Request(subject, reqData)
	if err != nil {
		return err
	}

	// Unmarshal response
	if err := json.Unmarshal(msg.Data, response); err != nil {
		return NewServiceError(ErrorCodeValidation, "nats", "unmarshal",
			"failed to unmarshal response").WithCause(err)
	}

	return nil
}

// Publish publishes a message to a subject
func (c *NATSClient) Publish(subject string, data []byte) error {
	if c.nc.Status() != nats.CONNECTED {
		return ErrNatsNotConnected()
	}

	c.logger.Debug("NATS publish to %s", subject)

	if err := c.nc.Publish(subject, data); err != nil {
		c.logger.Error("NATS publish failed: %v", err)
		return NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "publish",
			fmt.Sprintf("publish to %s failed", subject)).WithCause(err)
	}

	return nil
}

// PublishJSON publishes a JSON message to a subject
func (c *NATSClient) PublishJSON(subject string, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return NewServiceError(ErrorCodeValidation, "nats", "marshal",
			"failed to marshal data").WithCause(err)
	}

	return c.Publish(subject, jsonData)
}

// Subscribe creates a subscription to a subject
func (c *NATSClient) Subscribe(subject string, handler nats.MsgHandler) (*nats.Subscription, error) {
	if c.nc.Status() != nats.CONNECTED {
		return nil, ErrNatsNotConnected()
	}

	c.logger.Debug("NATS subscribe to %s", subject)

	sub, err := c.nc.Subscribe(subject, handler)
	if err != nil {
		c.logger.Error("NATS subscribe failed: %v", err)
		return nil, NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "subscribe",
			fmt.Sprintf("subscribe to %s failed", subject)).WithCause(err)
	}

	return sub, nil
}

// QueueSubscribe creates a queue subscription to a subject
func (c *NATSClient) QueueSubscribe(subject, queue string, handler nats.MsgHandler) (*nats.Subscription, error) {
	if c.nc.Status() != nats.CONNECTED {
		return nil, ErrNatsNotConnected()
	}

	c.logger.Debug("NATS queue subscribe to %s (queue: %s)", subject, queue)

	sub, err := c.nc.QueueSubscribe(subject, queue, handler)
	if err != nil {
		c.logger.Error("NATS queue subscribe failed: %v", err)
		return nil, NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "queue_subscribe",
			fmt.Sprintf("queue subscribe to %s failed", subject)).WithCause(err)
	}

	return sub, nil
}

// Status returns the NATS connection status
func (c *NATSClient) Status() nats.Status {
	return c.nc.Status()
}

// IsConnected returns true if NATS is connected
func (c *NATSClient) IsConnected() bool {
	return c.nc.Status() == nats.CONNECTED
}

// Flush flushes the NATS connection
func (c *NATSClient) Flush() error {
	if err := c.nc.Flush(); err != nil {
		return NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "flush",
			"failed to flush connection").WithCause(err)
	}
	return nil
}

// FlushWithTimeout flushes the NATS connection with timeout
func (c *NATSClient) FlushWithTimeout(timeout time.Duration) error {
	if err := c.nc.FlushTimeout(timeout); err != nil {
		return NewServiceError(ErrorCodeTimeout, "nats", "flush",
			"failed to flush connection").WithCause(err)
	}
	return nil
}

// Close closes the NATS connection
func (c *NATSClient) Close() {
	c.nc.Close()
}

// RequestWithContext performs a NATS request with context cancellation
func (c *NATSClient) RequestWithContext(ctx context.Context, subject string, data []byte) (*nats.Msg, error) {
	if c.nc.Status() != nats.CONNECTED {
		return nil, ErrNatsNotConnected()
	}

	c.logger.Debug("NATS request to %s (with context)", subject)

	// Create a channel to receive the response
	responseChan := make(chan *nats.Msg, 1)
	errorChan := make(chan error, 1)

	// Make the request in a goroutine
	go func() {
		msg, err := c.nc.Request(subject, data, c.timeout)
		if err != nil {
			errorChan <- err
			return
		}
		responseChan <- msg
	}()

	// Wait for either the response or context cancellation
	select {
	case msg := <-responseChan:
		// Check for service errors in response headers
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			errorMsg := string(msg.Data)
			c.logger.Error("Service error response: %s - %s", errorCode, errorMsg)

			return nil, NewServiceError(ErrorCode(errorCode), "service", "request", errorMsg)
		}
		return msg, nil

	case err := <-errorChan:
		c.logger.Error("NATS request failed: %v", err)
		if err == nats.ErrTimeout {
			return nil, ErrTimeout("nats_request").WithCause(err)
		}
		return nil, NewServiceError(ErrorCodeNatsRequestTimeout, "nats", "request",
			fmt.Sprintf("request to %s failed", subject)).WithCause(err)

	case <-ctx.Done():
		return nil, ErrTimeout("nats_request").WithCause(ctx.Err())
	}
}
