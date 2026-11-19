package transfer

import (
	"bytes"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"eglan/internal/stream"
)

type peer struct {
	ip   net.IP
	sess *stream.Session
}

// link 把一端的流帧同步投递给另一端,模拟房间数据面。
// 目标是 peer 指针,读取时取 sess,避免构造顺序依赖。
type link struct {
	from net.IP
	to   *peer
}

func (l link) Deliver(_ net.IP, data []byte) error {
	l.to.sess.Dispatch(l.from, data)
	return nil
}

// newPair 构造两条已连通的可靠流会话。
func newPair() (*peer, *peer) {
	a := &peer{ip: net.IPv4(10, 66, 7, 1).To4()}
	b := &peer{ip: net.IPv4(10, 66, 7, 2).To4()}
	a.sess = stream.NewSession(link{from: a.ip, to: b})
	b.sess = stream.NewSession(link{from: b.ip, to: a})
	return a, b
}

func TestSendReceive(t *testing.T) {
	a, b := newPair()
	eventsA := make(chan Event, 256)
	eventsB := make(chan Event, 256)
	mA := New(a.ip, a.sess, func(e Event) { eventsA <- e })
	mB := New(b.ip, b.sess, func(e Event) { eventsB <- e })
	defer func() {
		mA.Close()
		mB.Close()
		a.sess.Close()
		b.sess.Close()
	}()
	go mB.Serve()
	go mA.Serve()

	dir := t.TempDir()
	src := filepath.Join(dir, "源 文件.bin")
	want := make([]byte, 300*1024)
	if _, err := rand.Read(want); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, want, 0o600); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "收到的副本.bin")

	if _, err := mA.Send(b.ip, src); err != nil {
		t.Fatalf("发起发送失败: %v", err)
	}
	off := waitKind(t, eventsB, "offer", 15*time.Second)
	if off.Name != "源 文件.bin" || off.Size != int64(len(want)) || !off.Incoming {
		t.Fatalf("报价内容不符: %+v", off)
	}
	if err := mB.Accept(off.ID, dst); err != nil {
		t.Fatalf("接受失败: %v", err)
	}

	doneB := waitKind(t, eventsB, "done", 30*time.Second)
	if !doneB.OK || doneB.Err != "" {
		t.Fatalf("接收方失败: %+v", doneB)
	}
	doneA := waitKind(t, eventsA, "done", 30*time.Second)
	if !doneA.OK {
		t.Fatalf("发送方失败: %+v", doneA)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("读取保存文件失败: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("文件内容不一致: got=%d want=%d", len(got), len(want))
	}
	if _, err := os.Stat(dst + ".eglan-part"); !os.IsNotExist(err) {
		t.Fatalf("临时文件未清理: %v", err)
	}
}

func TestRejectOffer(t *testing.T) {
	a, b := newPair()
	eventsA := make(chan Event, 256)
	eventsB := make(chan Event, 256)
	mA := New(a.ip, a.sess, func(e Event) { eventsA <- e })
	mB := New(b.ip, b.sess, func(e Event) { eventsB <- e })
	defer func() {
		mA.Close()
		mB.Close()
		a.sess.Close()
		b.sess.Close()
	}()
	go mB.Serve()
	go mA.Serve()

	dir := t.TempDir()
	src := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(src, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := mA.Send(b.ip, src); err != nil {
		t.Fatal(err)
	}
	off := waitKind(t, eventsB, "offer", 15*time.Second)
	if err := mB.Reject(off.ID, "不需要"); err != nil {
		t.Fatalf("拒绝失败: %v", err)
	}
	doneA := waitKind(t, eventsA, "done", 15*time.Second)
	if doneA.OK || doneA.Err != "不需要" {
		t.Fatalf("拒绝结果不符: %+v", doneA)
	}
}

func TestSafeName(t *testing.T) {
	cases := map[string]string{
		`..\..\evil.txt`: "evil.txt",
		"a/b/c.txt":      "c.txt",
		"  ..  ":         "未命名文件",
		"":               "未命名文件",
		"正常名称.txt":       "正常名称.txt",
	}
	for in, want := range cases {
		if got := safeName(in); got != want {
			t.Errorf("safeName(%q)=%q want %q", in, got, want)
		}
	}
}

func waitKind(t *testing.T, ch <-chan Event, kind string, d time.Duration) Event {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case e := <-ch:
			if e.Kind == kind {
				return e
			}
		case <-deadline:
			t.Fatalf("等待 %s 事件超时", kind)
		}
	}
}
