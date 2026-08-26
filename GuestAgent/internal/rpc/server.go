package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

// MethodClass documents the retry/idempotency contract of a unary method,
// per ../../../Proto/guest_agent.md. It has no effect on dispatch; it is
// registered metadata for callers/introspection.
type MethodClass int

const (
	ReadOnly MethodClass = iota
	IdempotentMutation
	SingleShot
)

// Limits bounds a single connection's resource usage.
type Limits struct {
	MaxInFlight    int           // concurrent in-flight requests before BUSY
	IdleTimeout    time.Duration // max time between frames before the connection is closed
	MaxStreamBytes int64         // per-request stream payload budget; 0 = unlimited
}

const (
	defaultMaxInFlight = 16
	defaultIdleTimeout = 60 * time.Second
)

type unaryHandler struct {
	class MethodClass
	fn    func(ctx context.Context, req Envelope) (any, error)
}

type streamHandler struct {
	fn func(ctx context.Context, req Envelope, sink *Sink) error
}

// Server dispatches decoded envelopes on accepted connections to registered
// method handlers. One goroutine serves each connection; one goroutine
// serves each request on that connection.
type Server struct {
	protocol string
	limits   Limits

	mu     sync.RWMutex
	unary  map[string]unaryHandler
	stream map[string]streamHandler
}

// NewServer creates a Server for the given protocol ("daemon"|"worker"|
// "guest"). Zero-valued Limits fields fall back to the envelope.md defaults.
func NewServer(protocol string, limits Limits) *Server {
	if limits.MaxInFlight <= 0 {
		limits.MaxInFlight = defaultMaxInFlight
	}
	if limits.IdleTimeout <= 0 {
		limits.IdleTimeout = defaultIdleTimeout
	}
	return &Server{
		protocol: protocol,
		limits:   limits,
		unary:    make(map[string]unaryHandler),
		stream:   make(map[string]streamHandler),
	}
}

// Handle registers a unary method handler. fn's result is marshalled to the
// response payload; a returned error becomes the response error.
func (s *Server) Handle(method string, class MethodClass, fn func(ctx context.Context, req Envelope) (any, error)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.unary[method] = unaryHandler{class: class, fn: fn}
}

// HandleStream registers a streaming method handler. fn emits chunks via
// sink.Send; the server appends the terminal chunk (end:true) once fn
// returns, carrying fn's error if any.
func (s *Server) HandleStream(method string, fn func(ctx context.Context, req Envelope, sink *Sink) error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stream[method] = streamHandler{fn: fn}
}

func (s *Server) lookupUnary(method string) (unaryHandler, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	h, ok := s.unary[method]
	return h, ok
}

func (s *Server) lookupStream(method string) (streamHandler, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	h, ok := s.stream[method]
	return h, ok
}

// Serve accepts connections from ln until ctx is cancelled or Accept
// returns a fatal error. It blocks until every spawned connection
// goroutine has returned.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	stopWatch := make(chan struct{})
	defer close(stopWatch)
	go func() {
		select {
		case <-ctx.Done():
			_ = ln.Close()
		case <-stopWatch:
		}
	}()

	var wg sync.WaitGroup
	var acceptErr error
	for {
		conn, err := ln.Accept()
		if err != nil {
			acceptErr = err
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.serveConn(ctx, conn)
		}()
	}
	wg.Wait()

	if ctx.Err() != nil {
		return ctx.Err()
	}
	return acceptErr
}

// serveConn owns one connection: it reads frames sequentially, dispatches
// request/event envelopes to per-request goroutines, and forwards cancel
// envelopes to the matching in-flight request's context.
func (s *Server) serveConn(parentCtx context.Context, conn net.Conn) {
	defer conn.Close()

	cw := &connWriter{conn: conn}
	sem := make(chan struct{}, s.limits.MaxInFlight)

	var mu sync.Mutex
	cancels := make(map[string]context.CancelFunc)

	var wg sync.WaitGroup
	defer wg.Wait()

	for {
		if s.limits.IdleTimeout > 0 {
			_ = conn.SetReadDeadline(time.Now().Add(s.limits.IdleTimeout))
		}

		frame, err := ReadFrame(conn, FrameCapGuest)
		if err != nil {
			return // framing error: no recoverable requestId, just close
		}

		env, err := Decode(frame, s.protocol)
		if err != nil {
			s.respondMalformedBestEffort(cw, frame, err)
			return // malformed envelope: best-effort response, then close
		}

		switch env.Kind {
		case KindCancel:
			mu.Lock()
			cancel, ok := cancels[env.RequestID]
			mu.Unlock()
			if ok {
				cancel()
			}
			continue
		case KindRequest, KindEvent:
			// dispatched below
		default:
			// A server never receives response/chunk kinds from a client;
			// drop silently rather than tearing down the connection.
			continue
		}

		uh, isUnary := s.lookupUnary(env.Method)
		sh, isStream := s.lookupStream(env.Method)
		if !isUnary && !isStream {
			_ = cw.write(errorEnvelope(s.protocol, env.RequestID, CodeUnknownMethod,
				fmt.Sprintf("unknown method %q", env.Method), false))
			continue
		}

		select {
		case sem <- struct{}{}:
		default:
			_ = cw.write(errorEnvelope(s.protocol, env.RequestID, CodeBusy,
				"too many in-flight requests", true))
			continue
		}

		reqCtx, cancel := context.WithCancel(parentCtx)
		mu.Lock()
		cancels[env.RequestID] = cancel
		mu.Unlock()

		req := env
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				mu.Lock()
				delete(cancels, req.RequestID)
				mu.Unlock()
				<-sem
				cancel()
			}()

			if isUnary {
				s.runUnary(reqCtx, cw, uh, req)
			} else {
				s.runStream(reqCtx, cw, sh, req)
			}
		}()
	}
}

func (s *Server) runUnary(ctx context.Context, cw *connWriter, h unaryHandler, req Envelope) {
	result, err := h.fn(ctx, req)
	if ctx.Err() != nil && errors.Is(ctx.Err(), context.Canceled) {
		_ = cw.write(errorEnvelope(s.protocol, req.RequestID, CodeCancelled, "request cancelled", false))
		return
	}
	if err != nil {
		code, msg, retryable := errorParts(err)
		_ = cw.write(errorEnvelope(s.protocol, req.RequestID, code, msg, retryable))
		return
	}

	payload, err := json.Marshal(result)
	if err != nil {
		_ = cw.write(errorEnvelope(s.protocol, req.RequestID, CodeInternal, err.Error(), false))
		return
	}
	_ = cw.write(Envelope{
		Protocol: s.protocol, Version: protocolVersion, Kind: KindResponse,
		RequestID: req.RequestID, Payload: payload,
	})
}

func (s *Server) runStream(ctx context.Context, cw *connWriter, h streamHandler, req Envelope) {
	sink := &Sink{
		cw: cw, protocol: s.protocol, requestID: req.RequestID, method: req.Method,
		maxBytes: s.limits.MaxStreamBytes,
	}

	err := h.fn(ctx, req, sink)
	if ctx.Err() != nil && errors.Is(ctx.Err(), context.Canceled) {
		_ = sink.sendTerminal(&ErrorPayload{Code: CodeCancelled, Message: "request cancelled", Retryable: false})
		return
	}
	if err != nil {
		code, msg, retryable := errorParts(err)
		_ = sink.sendTerminal(&ErrorPayload{Code: code, Message: msg, Retryable: retryable})
		return
	}
	_ = sink.sendTerminal(nil)
}

// respondMalformedBestEffort attempts a lenient (non-strict) extraction of
// requestId from an envelope that failed strict Decode, so the peer can
// correlate the MALFORMED response before the connection closes.
func (s *Server) respondMalformedBestEffort(cw *connWriter, frame []byte, decodeErr error) {
	var probe struct {
		RequestID string `json:"requestId"`
	}
	if err := json.Unmarshal(frame, &probe); err != nil || probe.RequestID == "" {
		return
	}
	code, msg, retryable := errorParts(decodeErr)
	_ = cw.write(errorEnvelope(s.protocol, probe.RequestID, code, msg, retryable))
}

func errorParts(err error) (code, message string, retryable bool) {
	var rpcErr *RPCError
	if errors.As(err, &rpcErr) {
		return rpcErr.Code, rpcErr.Message, rpcErr.Retryable
	}
	return CodeInternal, err.Error(), false
}

func errorEnvelope(protocol, requestID, code, message string, retryable bool) Envelope {
	return Envelope{
		Protocol: protocol, Version: protocolVersion, Kind: KindResponse,
		RequestID: requestID,
		Error:     &ErrorPayload{Code: code, Message: message, Retryable: retryable},
	}
}

// connWriter serializes frame writes on one connection so concurrent
// request/stream goroutines never interleave partial frames.
type connWriter struct {
	mu   sync.Mutex
	conn net.Conn
}

func (c *connWriter) write(env Envelope) error {
	b, err := Encode(env)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return WriteFrame(c.conn, b)
}

// Sink is the write side of a streaming request, passed to HandleStream
// handlers. Send is not safe for concurrent use by multiple goroutines.
type Sink struct {
	cw        *connWriter
	protocol  string
	requestID string
	method    string
	maxBytes  int64

	seq       int64
	bytesSent int64
}

// Send marshals v and emits it as the next chunk (streamSeq increasing from
// zero, end:false).
func (s *Sink) Send(v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if s.maxBytes > 0 {
		s.bytesSent += int64(len(payload))
		if s.bytesSent > s.maxBytes {
			return newRPCError(CodeInternal, "stream byte budget exceeded")
		}
	}

	seq := s.seq
	s.seq++
	end := false
	return s.cw.write(Envelope{
		Protocol: s.protocol, Version: protocolVersion, Kind: KindChunk,
		RequestID: s.requestID, Method: s.method,
		StreamSeq: &seq, End: &end, Payload: payload,
	})
}

// sendTerminal emits the final chunk (end:true), optionally carrying an
// error. Only the server's dispatch loop calls this, after the handler
// function returns.
func (s *Sink) sendTerminal(errPayload *ErrorPayload) error {
	seq := s.seq
	s.seq++
	end := true
	return s.cw.write(Envelope{
		Protocol: s.protocol, Version: protocolVersion, Kind: KindChunk,
		RequestID: s.requestID, Method: s.method,
		StreamSeq: &seq, End: &end, Error: errPayload,
	})
}
