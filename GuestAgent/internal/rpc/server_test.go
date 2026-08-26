package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"testing"
)

// newPipeServer wires a Server directly to one half of a net.Pipe() via the
// unexported serveConn, and a Client to the other half. This exercises the
// full read/dispatch/write path deterministically, without socket flakiness.
func newPipeServer(t *testing.T, s *Server) (*Client, context.CancelFunc) {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	go s.serveConn(ctx, serverConn)
	client := Dial(clientConn, "guest")
	t.Cleanup(func() {
		client.Close()
		cancel()
	})
	return client, cancel
}

func TestUnaryOK(t *testing.T) {
	s := NewServer("guest", Limits{})
	s.Handle("agent.hello", ReadOnly, func(ctx context.Context, req Envelope) (any, error) {
		return map[string]any{"agentVersion": "test", "protocolVersion": 1}, nil
	})
	client, _ := newPipeServer(t, s)

	payload, err := client.Call(context.Background(), "agent.hello", nil)
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	var got struct {
		AgentVersion    string `json:"agentVersion"`
		ProtocolVersion int    `json:"protocolVersion"`
	}
	if err := json.Unmarshal(payload, &got); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if got.AgentVersion != "test" || got.ProtocolVersion != 1 {
		t.Fatalf("unexpected payload: %+v", got)
	}
}

func TestUnaryError(t *testing.T) {
	s := NewServer("guest", Limits{})
	s.Handle("agent.startRunner", SingleShot, func(ctx context.Context, req Envelope) (any, error) {
		return nil, &RPCError{Code: CodeInvalidParams, Message: "missing sessionId", Retryable: false}
	})
	client, _ := newPipeServer(t, s)

	_, err := client.Call(context.Background(), "agent.startRunner", nil)
	if err == nil {
		t.Fatal("expected error")
	}
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) {
		t.Fatalf("expected *RPCError, got %T: %v", err, err)
	}
	if rpcErr.Code != CodeInvalidParams || rpcErr.Retryable {
		t.Fatalf("unexpected error: %+v", rpcErr)
	}
}

func TestUnknownMethod(t *testing.T) {
	s := NewServer("guest", Limits{})
	client, _ := newPipeServer(t, s)

	_, err := client.Call(context.Background(), "agent.doesNotExist", nil)
	if err == nil {
		t.Fatal("expected error")
	}
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeUnknownMethod {
		t.Fatalf("expected UNKNOWN_METHOD, got %v", err)
	}
}

func TestStream100ChunksInOrder(t *testing.T) {
	const n = 100
	s := NewServer("guest", Limits{})
	s.HandleStream("agent.exec", func(ctx context.Context, req Envelope, sink *Sink) error {
		for i := 0; i < n; i++ {
			if err := sink.Send(map[string]any{"i": i}); err != nil {
				return err
			}
		}
		return nil
	})
	client, _ := newPipeServer(t, s)

	ch, err := client.Stream(context.Background(), "agent.exec", nil)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}

	var seen []int64
	var terminal *Chunk
	for c := range ch {
		if c.Err != nil {
			t.Fatalf("chunk error: %v", c.Err)
		}
		if c.Envelope.End != nil && *c.Envelope.End {
			env := c.Envelope
			terminal = &Chunk{Envelope: env}
			continue
		}
		var body struct {
			I int64 `json:"i"`
		}
		if err := json.Unmarshal(c.Envelope.Payload, &body); err != nil {
			t.Fatalf("unmarshal chunk payload: %v", err)
		}
		seen = append(seen, *c.Envelope.StreamSeq)
		if body.I != *c.Envelope.StreamSeq {
			t.Fatalf("chunk payload.i=%d does not match streamSeq=%d", body.I, *c.Envelope.StreamSeq)
		}
	}

	if len(seen) != n {
		t.Fatalf("got %d non-terminal chunks, want %d", len(seen), n)
	}
	for i, seq := range seen {
		if seq != int64(i) {
			t.Fatalf("chunk out of order at index %d: streamSeq=%d", i, seq)
		}
	}
	if terminal == nil {
		t.Fatal("no terminal chunk received")
	}
	if *terminal.Envelope.StreamSeq != n {
		t.Fatalf("terminal streamSeq=%d, want %d", *terminal.Envelope.StreamSeq, n)
	}
	if terminal.Envelope.Error != nil {
		t.Fatalf("unexpected terminal error: %+v", terminal.Envelope.Error)
	}
}

func TestCancelMidStream(t *testing.T) {
	started := make(chan struct{})
	s := NewServer("guest", Limits{})
	s.HandleStream("agent.wait", func(ctx context.Context, req Envelope, sink *Sink) error {
		if err := sink.Send(map[string]any{"started": true}); err != nil {
			return err
		}
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	client, _ := newPipeServer(t, s)

	ctx, cancel := context.WithCancel(context.Background())
	ch, err := client.Stream(ctx, "agent.wait", nil)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}

	first := <-ch
	if first.Envelope.End != nil && *first.Envelope.End {
		t.Fatal("first chunk unexpectedly terminal")
	}
	<-started
	cancel()

	var last Chunk
	for c := range ch {
		last = c
	}
	if last.Envelope.End == nil || !*last.Envelope.End {
		t.Fatalf("expected terminal chunk, got %+v", last.Envelope)
	}
	if last.Envelope.Error == nil || last.Envelope.Error.Code != CodeCancelled {
		t.Fatalf("expected CANCELLED terminal, got %+v", last.Envelope.Error)
	}
}

func TestBusyOnTooManyInFlight(t *testing.T) {
	const maxInFlight = 16
	started := make(chan struct{}, maxInFlight)
	release := make(chan struct{})

	s := NewServer("guest", Limits{MaxInFlight: maxInFlight})
	s.Handle("agent.occupy", ReadOnly, func(ctx context.Context, req Envelope) (any, error) {
		started <- struct{}{}
		<-release
		return map[string]any{"ok": true}, nil
	})
	client, _ := newPipeServer(t, s)

	var wg sync.WaitGroup
	errs := make(chan error, maxInFlight)
	for i := 0; i < maxInFlight; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := client.Call(context.Background(), "agent.occupy", nil)
			errs <- err
		}()
	}
	for i := 0; i < maxInFlight; i++ {
		<-started // block until all maxInFlight handlers hold their semaphore slot
	}

	_, err := client.Call(context.Background(), "agent.occupy", nil)
	if err == nil {
		t.Fatal("expected BUSY error")
	}
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeBusy {
		t.Fatalf("expected BUSY, got %v", err)
	}

	close(release)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("occupying call failed: %v", err)
		}
	}
}

func TestMalformedFrameClosesConnection(t *testing.T) {
	t.Run("recoverable requestId", func(t *testing.T) {
		serverConn, clientConn := net.Pipe()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go NewServer("guest", Limits{}).serveConn(ctx, serverConn)

		bad := []byte(`{"protocol":"guest","version":1,"kind":"request","requestId":"bad-1","method":"x","method":"y"}`)
		if err := WriteFrame(clientConn, bad); err != nil {
			t.Fatalf("WriteFrame: %v", err)
		}

		frame, err := ReadFrame(clientConn, FrameCapGuest)
		if err != nil {
			t.Fatalf("expected a best-effort MALFORMED response, got: %v", err)
		}
		env, err := Decode(frame, "guest")
		if err != nil {
			t.Fatalf("decode best-effort response: %v", err)
		}
		if env.Kind != KindResponse || env.RequestID != "bad-1" || env.Error == nil || env.Error.Code != CodeMalformed {
			t.Fatalf("unexpected response: %+v", env)
		}

		if _, err := ReadFrame(clientConn, FrameCapGuest); err == nil {
			t.Fatal("expected connection to be closed after the malformed frame")
		}
	})

	t.Run("unrecoverable requestId", func(t *testing.T) {
		serverConn, clientConn := net.Pipe()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go NewServer("guest", Limits{}).serveConn(ctx, serverConn)

		if err := WriteFrame(clientConn, []byte("not json at all")); err != nil {
			t.Fatalf("WriteFrame: %v", err)
		}

		if _, err := ReadFrame(clientConn, FrameCapGuest); err == nil {
			t.Fatal("expected connection to be closed with no recoverable response")
		}
	})
}

func TestServeAcceptsConnections(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	s := NewServer("guest", Limits{})
	s.Handle("agent.hello", ReadOnly, func(ctx context.Context, req Envelope) (any, error) {
		return map[string]any{"ok": true}, nil
	})

	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- s.Serve(ctx, ln) }()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	client := Dial(conn, "guest")

	payload, err := client.Call(context.Background(), "agent.hello", nil)
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	var got struct {
		Ok bool `json:"ok"`
	}
	if err := json.Unmarshal(payload, &got); err != nil || !got.Ok {
		t.Fatalf("unexpected payload: %s (err=%v)", payload, err)
	}

	client.Close()
	cancel()
	if err := <-serveDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("expected Serve to return context.Canceled, got %v", err)
	}
}
