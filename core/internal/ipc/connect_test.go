package ipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// 回环通道:核心先报令牌,界面核对后即可沿用同一套行协议。
func TestConnectAuthAndStatus(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	const token = "0123456789abcdef0123456789abcdef"
	serverErr := make(chan error, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		sc := bufio.NewScanner(conn)

		if !sc.Scan() {
			serverErr <- errors.New("缺少认证行")
			return
		}
		var auth map[string]string
		if err := json.Unmarshal(sc.Bytes(), &auth); err != nil {
			serverErr <- err
			return
		}
		if auth["type"] != "auth" || auth["token"] != token {
			serverErr <- errors.New("认证行不符: " + sc.Text())
			return
		}

		if _, err := conn.Write([]byte(`{"op":"status","id":"s1"}` + "\n")); err != nil {
			serverErr <- err
			return
		}
		if !sc.Scan() {
			serverErr <- errors.New("缺少状态应答")
			return
		}
		var status map[string]any
		if err := json.Unmarshal(sc.Bytes(), &status); err != nil {
			serverErr <- err
			return
		}
		if status["type"] != "status" || status["id"] != "s1" || status["state"] != "idle" {
			serverErr <- errors.New("状态应答不符: " + sc.Text())
			return
		}
		serverErr <- nil
	}()

	done := make(chan error, 1)
	go func() { done <- Connect(ln.Addr().String(), token) }()

	select {
	case err := <-serverErr:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("界面侧等待超时")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("核心退出超时")
	}
}

func TestConnectRequiresToken(t *testing.T) {
	if err := Connect("127.0.0.1:1", ""); err == nil || !strings.Contains(err.Error(), "令牌") {
		t.Fatalf("缺少令牌时应拒绝,得到 %v", err)
	}
}
