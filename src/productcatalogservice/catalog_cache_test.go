package main

import (
	"bufio"
	"context"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRedis is a tiny in-memory Redis speaking RESP, for GET and SET ... EX.
type fakeRedis struct {
	ln   net.Listener
	mu   sync.Mutex
	data map[string]string
	ttls map[string]string
}

func startFakeRedis(t *testing.T) *fakeRedis {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeRedis{ln: ln, data: map[string]string{}, ttls: map[string]string{}}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeRedis) serve(conn net.Conn) {
	defer conn.Close()
	rd := bufio.NewReader(conn)
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return
		}
		n, _ := strconv.Atoi(strings.TrimSpace(line[1:]))
		args := make([]string, n)
		for i := range args {
			if _, err := rd.ReadString('\n'); err != nil { // $len
				return
			}
			v, err := rd.ReadString('\n')
			if err != nil {
				return
			}
			args[i] = strings.TrimSuffix(v, "\r\n")
		}
		f.mu.Lock()
		switch strings.ToUpper(args[0]) {
		case "GET":
			if v, ok := f.data[args[1]]; ok {
				conn.Write([]byte("$" + strconv.Itoa(len(v)) + "\r\n" + v + "\r\n"))
			} else {
				conn.Write([]byte("$-1\r\n"))
			}
		case "SET":
			f.data[args[1]] = args[2]
			if len(args) >= 5 {
				f.ttls[args[1]] = args[4]
			}
			conn.Write([]byte("+OK\r\n"))
		default:
			conn.Write([]byte("-ERR unknown command\r\n"))
		}
		f.mu.Unlock()
	}
}

func TestRedisGetMissingKey(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	_, found, err := c.Get(context.Background(), "nope")
	if err != nil || found {
		t.Fatalf("got found=%v err=%v, want a clean miss", found, err)
	}
}

func TestRedisSetThenGet(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	ctx := context.Background()
	value := `{"products":[{"id":"A","name":"Line\r\nbreak"}]}` // binary-safe
	if err := c.Set(ctx, "k", []byte(value), 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := f.ttls["k"]; got != "300" {
		t.Errorf("TTL sent = %q, want 300 seconds", got)
	}
	got, found, err := c.Get(ctx, "k")
	if err != nil || !found || string(got) != value {
		t.Fatalf("got %q found=%v err=%v", got, found, err)
	}
}

func TestRedisErrorReplyKeepsConnection(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	if _, err := c.do(context.Background(), "BOGUS"); err == nil {
		t.Fatal("want an error reply")
	}
	if c.conn == nil {
		t.Fatal("an error reply from Redis should not drop the connection")
	}
}

func TestRedisUnreachable(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close() // nothing listens there now
	c := newRedisCache(addr)
	if _, _, err := c.Get(context.Background(), "k"); err == nil {
		t.Fatal("want a connection error")
	}
}

func TestEncodeCommand(t *testing.T) {
	got := string(encodeCommand([]string{"GET", "key"}))
	if want := "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
