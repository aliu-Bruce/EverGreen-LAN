package ipc

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"eglan/internal/tun"
)

// 测试用网卡:不碰系统网络栈,只让收发泵有可读可写的对象。
type fakeDevice struct {
	name string
	mtu  int
	once sync.Once
	done chan struct{}
}

func newFakeDevice(cfg tun.Config) (tun.Device, error) {
	return &fakeDevice{name: cfg.Name, mtu: cfg.MTU, done: make(chan struct{})}, nil
}

func (d *fakeDevice) Name() string { return d.name }
func (d *fakeDevice) MTU() int     { return d.mtu }
func (d *fakeDevice) Read() ([]byte, error) {
	<-d.done // 没有真实包时保持阻塞,避免产生无关的 room-down 事件
	return nil, io.EOF
}
func (d *fakeDevice) Write(pkt []byte) error { return nil }
func (d *fakeDevice) Close() error {
	d.once.Do(func() { close(d.done) })
	return nil
}

// 把平台能力换成不建网卡、不改防火墙的假实现;本文件内测试不能并发。
func useFakeCapabilities(t *testing.T) {
	t.Helper()
	oldTun, oldFirewall := newTun, openFirewall
	newTun, openFirewall = newFakeDevice, func(int) error { return nil }
	t.Cleanup(func() { newTun, openFirewall = oldTun, oldFirewall })
}

// 行协议测试台:一侧写请求,另一侧读应答;异步事件按谓词过滤。
type harness struct {
	in     *io.PipeWriter
	out    *io.PipeReader
	scan   *bufio.Scanner
	done   chan error
	nextID int
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &harness{in: inW, out: outR, scan: bufio.NewScanner(outR), done: make(chan error, 1)}
	go func() { h.done <- Run(inR, outW) }()
	t.Cleanup(func() {
		h.out.Close() // 先放开可能阻塞的写,再让 Run 看到输入结束
		h.in.Close()
		select {
		case <-h.done:
		case <-time.After(5 * time.Second):
			t.Error("Bridge 未在期限内退出")
		}
	})
	return h
}

func (h *harness) wait(t *testing.T, match func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		line := make(chan string, 1)
		closed := make(chan struct{})
		go func() {
			if h.scan.Scan() {
				line <- h.scan.Text()
			} else {
				close(closed)
			}
		}()
		select {
		case text := <-line:
			var msg map[string]any
			if err := json.Unmarshal([]byte(text), &msg); err != nil {
				t.Fatalf("应答不是 JSON: %s", text)
			}
			if match(msg) {
				return msg
			}
		case <-closed:
			t.Fatal("输出流提前结束")
		case <-deadline:
			t.Fatal("等待应答超时")
		}
	}
}

func (h *harness) request(t *testing.T, op string, fields map[string]any) map[string]any {
	t.Helper()
	h.nextID++
	id := "q" + itoa(h.nextID)
	msg := map[string]any{"op": op, "id": id}
	for k, v := range fields {
		msg[k] = v
	}
	b, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.in.Write(append(b, '\n')); err != nil {
		t.Fatalf("写请求失败: %v", err)
	}
	return h.wait(t, func(m map[string]any) bool { return m["id"] == id && m["type"] != "event" })
}

func (h *harness) event(t *testing.T, name, id string) map[string]any {
	t.Helper()
	return h.wait(t, func(m map[string]any) bool {
		return m["type"] == "event" && m["name"] == name && (id == "" || m["id"] == id)
	})
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := c.LocalAddr().(*net.UDPAddr).Port
	c.Close()
	return port
}

func str(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

func TestHostLifecycle(t *testing.T) {
	useFakeCapabilities(t)
	h := newHarness(t)
	port := freeUDPPort(t)

	start := h.request(t, "start-host", map[string]any{
		"code": "eglan1234", "name": "主机", "listen": port,
	})
	if start["state"] != "hosting" || str(start, "code") == "" {
		t.Fatalf("start-host 应答不符: %v", start)
	}
	if str(start, "self") != "10.66.7.1/24" {
		t.Fatalf("本端地址不符: %v", start["self"])
	}

	status := h.request(t, "status", nil)
	if status["state"] != "hosting" || str(status, "code") != str(start, "code") {
		t.Fatalf("status 不符: %v", status)
	}

	members := h.request(t, "members", nil)
	if members["state"] != "hosting" {
		t.Fatalf("members 状态不符: %v", members)
	}
	if list, ok := members["list"].([]any); !ok || len(list) != 0 {
		t.Fatalf("空房名册应为空数组: %v", members["list"])
	}

	stop := h.request(t, "stop", nil)
	if stop["state"] != "idle" {
		t.Fatalf("stop 应回到 idle: %v", stop)
	}
	if s := h.request(t, "status", nil); s["state"] != "idle" {
		t.Fatalf("stop 后状态不符: %v", s)
	}

	// 再开一次应拿到新房间码,状态机没有残留在 hosting。
	again := h.request(t, "start-host", map[string]any{"listen": port})
	if again["state"] != "hosting" || str(again, "code") == str(start, "code") {
		t.Fatalf("二次开房失败: %v", again)
	}
}

func TestJoinLifecycle(t *testing.T) {
	useFakeCapabilities(t)
	host := newHarness(t)
	guest := newHarness(t)
	port := freeUDPPort(t)
	const code = "eglan5678"

	if got := host.request(t, "start-host", map[string]any{
		"code": code, "name": "房主", "listen": port,
	}); got["state"] != "hosting" {
		t.Fatalf("开房失败: %v", got)
	}

	joinID := "j1"
	b, _ := json.Marshal(map[string]any{
		"op": "join", "id": joinID, "code": code,
		"peer": net.JoinHostPort("127.0.0.1", itoa(port)), "name": "访客",
	})
	if _, err := guest.in.Write(append(b, '\n')); err != nil {
		t.Fatal(err)
	}
	ack := guest.wait(t, func(m map[string]any) bool { return m["id"] == joinID && m["type"] == "ok" })
	if ack["state"] != "joining" {
		t.Fatalf("join 应先回 joining: %v", ack)
	}
	up := guest.event(t, "room-up", joinID)
	if up["state"] != "joined" || str(up, "host") != "房主" {
		t.Fatalf("room-up 不符: %v", up)
	}
	if str(up, "self") == "" {
		t.Fatal("成员未拿到隧道地址")
	}

	guestMembers := guest.request(t, "members", nil)
	if list, ok := guestMembers["list"].([]any); !ok || len(list) != 1 {
		t.Fatalf("成员侧名册应只有主机: %v", guestMembers)
	}
	hostMembers := host.request(t, "members", nil)
	if list, ok := hostMembers["list"].([]any); !ok || len(list) != 1 {
		t.Fatalf("主机侧名册应只有一名成员: %v", hostMembers)
	}

	if s := guest.request(t, "status", nil); s["state"] != "joined" {
		t.Fatalf("成员状态不符: %v", s)
	}
	if s := guest.request(t, "stop", nil); s["state"] != "idle" {
		t.Fatalf("成员 stop 失败: %v", s)
	}
	if s := host.request(t, "stop", nil); s["state"] != "idle" {
		t.Fatalf("主机 stop 失败: %v", s)
	}
}

func TestRoomValidationErrors(t *testing.T) {
	useFakeCapabilities(t)
	h := newHarness(t)

	if got := h.request(t, "start-host", map[string]any{"code": "!!!"}); got["type"] != "err" {
		t.Fatalf("非法房间码应报错: %v", got)
	}
	start := h.request(t, "start-host", map[string]any{"code": "eglan0000"})
	if start["state"] != "hosting" {
		t.Fatalf("开房失败: %v", start)
	}
	if got := h.request(t, "start-host", nil); got["type"] != "err" {
		t.Fatalf("已在房间中再开房应报错: %v", got)
	}
	if got := h.request(t, "join", map[string]any{"code": "eglan0000"}); got["type"] != "err" {
		t.Fatalf("缺少 peer 的 join 应报错: %v", got)
	}
	if got := h.request(t, "stop", nil); got["state"] != "idle" {
		t.Fatalf("stop 失败: %v", got)
	}
}

// 测试内用的整数转字符串,避免引入 strconv 只为一次调用。
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
