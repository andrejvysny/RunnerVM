package rpc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"sync"
)

// Chunk is one streamed envelope delivered to a Client.Stream caller. Err is
// set (and the channel closed immediately after) if the connection failed
// before a terminal chunk arrived.
type Chunk struct {
	Envelope Envelope
	Err      error
}

type pendingCall struct {
	unaryCh  chan Envelope
	streamCh chan Chunk
}

// Client is a minimal envelope-protocol client, primarily for exercising
// Server in tests and as a building block for future host-side tooling.
type Client struct {
	protocol string
	conn     net.Conn
	cw       *connWriter

	mu      sync.Mutex
	pending map[string]pendingCall
	readErr error

	closeOnce sync.Once
	closeCh   chan struct{}
}

// Dial wraps an already-established connection (a real vsock/TCP dial, or
// one half of a net.Pipe() in tests) as a Client speaking protocol.
func Dial(conn net.Conn, protocol string) *Client {
	c := &Client{
		protocol: protocol,
		conn:     conn,
		cw:       &connWriter{conn: conn},
		pending:  make(map[string]pendingCall),
		closeCh:  make(chan struct{}),
	}
	go c.readLoop()
	return c
}

// Call sends a unary request and waits for its response. If ctx is done
// first, a cancel envelope is sent (best effort) and ctx.Err() is returned;
// the eventual server-side response, if any, is discarded.
func (c *Client) Call(ctx context.Context, method string, payload any) (json.RawMessage, error) {
	requestID := newRequestID()
	respCh := make(chan Envelope, 1)
	c.register(requestID, pendingCall{unaryCh: respCh})
	defer c.unregister(requestID)

	payloadBytes, err := marshalPayload(payload)
	if err != nil {
		return nil, err
	}
	req := Envelope{
		Protocol: c.protocol, Version: protocolVersion, Kind: KindRequest,
		RequestID: requestID, Method: method, Payload: payloadBytes,
	}
	if err := c.cw.write(req); err != nil {
		return nil, err
	}

	select {
	case env, ok := <-respCh:
		if !ok {
			return nil, c.readErrSafe()
		}
		if env.Error != nil {
			return nil, &RPCError{Code: env.Error.Code, Message: env.Error.Message, Retryable: env.Error.Retryable}
		}
		return env.Payload, nil
	case <-ctx.Done():
		_ = c.Cancel(requestID)
		return nil, ctx.Err()
	case <-c.closeCh:
		return nil, c.readErrSafe()
	}
}

// Stream sends a streaming request and returns a channel of its chunks; the
// channel is closed after the terminal chunk (or immediately, with a final
// Chunk carrying Err, if the connection fails first). If ctx is done before
// the stream terminates, a cancel envelope is sent (best effort); the
// terminal chunk (expected to carry error.code=CANCELLED) still arrives on
// the channel.
func (c *Client) Stream(ctx context.Context, method string, payload any) (<-chan Chunk, error) {
	requestID := newRequestID()
	chunkCh := make(chan Chunk, 8)
	c.register(requestID, pendingCall{streamCh: chunkCh})

	payloadBytes, err := marshalPayload(payload)
	if err != nil {
		c.unregister(requestID)
		return nil, err
	}
	req := Envelope{
		Protocol: c.protocol, Version: protocolVersion, Kind: KindRequest,
		RequestID: requestID, Method: method, Payload: payloadBytes,
	}
	if err := c.cw.write(req); err != nil {
		c.unregister(requestID)
		return nil, err
	}

	go func() {
		select {
		case <-ctx.Done():
			_ = c.Cancel(requestID)
		case <-c.closeCh:
		}
	}()

	return chunkCh, nil
}

// Cancel sends a cancel envelope for requestID. It does not wait for the
// server's terminal response.
func (c *Client) Cancel(requestID string) error {
	return c.cw.write(Envelope{
		Protocol: c.protocol, Version: protocolVersion, Kind: KindCancel, RequestID: requestID,
	})
}

// Close closes the underlying connection and fails any pending calls.
func (c *Client) Close() error {
	err := c.conn.Close()
	c.failAll(errors.New("rpc: client closed"))
	return err
}

func (c *Client) readLoop() {
	for {
		frame, err := ReadFrame(c.conn, FrameCapGuest)
		if err != nil {
			c.failAll(err)
			return
		}
		env, err := Decode(frame, c.protocol)
		if err != nil {
			c.failAll(err)
			return
		}
		c.dispatch(env)
	}
}

func (c *Client) dispatch(env Envelope) {
	c.mu.Lock()
	p, ok := c.pending[env.RequestID]
	c.mu.Unlock()
	if !ok {
		return // unknown or already-completed request: drop
	}

	switch env.Kind {
	case KindResponse:
		c.unregister(env.RequestID)
		if p.unaryCh != nil {
			p.unaryCh <- env
		}
	case KindChunk:
		if p.streamCh == nil {
			return
		}
		terminal := env.End != nil && *env.End
		p.streamCh <- Chunk{Envelope: env}
		if terminal {
			c.unregister(env.RequestID)
			close(p.streamCh)
		}
	}
}

func (c *Client) failAll(err error) {
	c.mu.Lock()
	if c.readErr == nil {
		c.readErr = err
	}
	pending := c.pending
	c.pending = make(map[string]pendingCall)
	c.mu.Unlock()

	for _, p := range pending {
		if p.unaryCh != nil {
			close(p.unaryCh)
		}
		if p.streamCh != nil {
			close(p.streamCh)
		}
	}
	c.closeOnce.Do(func() { close(c.closeCh) })
}

func (c *Client) readErrSafe() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.readErr != nil {
		return c.readErr
	}
	return errors.New("rpc: connection closed")
}

func (c *Client) register(requestID string, p pendingCall) {
	c.mu.Lock()
	c.pending[requestID] = p
	c.mu.Unlock()
}

func (c *Client) unregister(requestID string) {
	c.mu.Lock()
	delete(c.pending, requestID)
	c.mu.Unlock()
}

func marshalPayload(v any) (json.RawMessage, error) {
	if v == nil {
		return nil, nil
	}
	if raw, ok := v.(json.RawMessage); ok {
		return raw, nil
	}
	return json.Marshal(v)
}

// newRequestID returns a unique-per-process identifier; the wire format
// does not require RFC 4122 UUIDs, only per-connection uniqueness.
func newRequestID() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // crypto/rand.Read on a fixed-size buffer cannot fail
	return hex.EncodeToString(b[:])
}
