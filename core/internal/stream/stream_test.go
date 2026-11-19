package stream

import (
	"bytes"
	"io"
	"math/rand"
	"net"
	"sync"
	"testing"
	"time"
)

// ---- 测试传输层 ----

type pipe struct {
	mu        sync.Mutex
	loss      float64
	delay     time.Duration
	inflight  int
	failWith  error // 用于循环传输间歇短接测试
	dropClose int   // 模拟丢失前 N 个 Close 帧
}

type pipeSide struct {
	ip      net.IP
	session *Session
	d       *delivery
}

type delivery struct {
	side *pipeSide
	dest *pipeSide
	p    *pipe
}

func (d *delivery) Deliver(dst net.IP, data []byte) error {
	p := d.p
	p.mu.Lock()
	if p.failWith != nil {
		err := p.failWith
		p.mu.Unlock()
		return err
	}
	if p.loss > 0 && rand.Float64() < p.loss {
		p.mu.Unlock()
		return nil // 静默丢
	}
	if len(data) > 0 && data[0] == FrameClose && p.dropClose > 0 {
		p.dropClose--
		p.mu.Unlock()
		return nil // 故意丢 Close,验证重传
	}
	dest := d.dest
	p.mu.Unlock()
	if p.delay > 0 {
		go func() {
			time.Sleep(p.delay)
			dest.session.Dispatch(d.side.ip, data)
		}()
		return nil
	}
	dest.session.Dispatch(d.side.ip, data)
	return nil
}

func newPipe(loss float64) (*pipe, *pipeSide, *pipeSide) {
	p := &pipe{loss: loss}
	a := &pipeSide{ip: net.ParseIP("10.66.7.1")}
	b := &pipeSide{ip: net.ParseIP("10.66.7.2")}
	a.d = &delivery{side: a, dest: b, p: p}
	b.d = &delivery{side: b, dest: a, p: p}
	a.session = NewSession(a.d)
	b.session = NewSession(b.d)
	return p, a, b
}

// ---- 测试 ----

// TestStreamRoundTrip 基础可靠流:写/读/确认。
func TestStreamRoundTrip(t *testing.T) {
	_, a, b := newPipe(0)
	st, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("hello world, this is a reliable stream")
	if _, err := st.Write(payload); err != nil {
		t.Fatal(err)
	}
	st2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, len(payload))
	if err := readFull(st2, buf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf, payload) {
		t.Fatalf("数据不一致: got %q want %q", buf, payload)
	}
}

// readFull 读到 buf 满(仅用于测试)。
func readFull(s Stream, buf []byte) error {
	n := 0
	for n < len(buf) {
		m, err := s.Read(buf[n:])
		n += m
		if err != nil {
			return err
		}
	}
	return nil
}

// TestStreamBigTransfer 大载荷、多段,完整性与顺序。
func TestStreamBigTransfer(t *testing.T) {
	_, a, b := newPipe(0)
	st, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	want := randBytes(4 * 1024 * 1024)
	done := make(chan struct{})
	go func() {
		for off := 0; off < len(want); off += 777 {
			end := off + 777
			if end > len(want) {
				end = len(want)
			}
			_, _ = st.Write(want[off:end])
		}
		_ = st.Close()
		close(done)
	}()
	st2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 0, len(want))
	buf := make([]byte, 4096)
	for {
		n, err := st2.Read(buf)
		if n > 0 {
			got = append(got, buf[:n]...)
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			t.Fatal(err)
		}
		if len(got) >= len(want) {
			break
		}
	}
	<-done
	if !bytes.Equal(got, want) {
		t.Fatalf("大载荷数据不一致: got=%d want=%d", len(got), len(want))
	}
}

// TestStreamDropout 随机丢包:0.2 重传后完整。
func TestStreamDropout(t *testing.T) {
	_, a, b := newPipe(0.2)
	st, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	want := randBytes(256 * 1024)
	if _, err := st.Write(want); err != nil {
		t.Fatal(err)
	}
	st2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 0, len(want))
	buf := make([]byte, 2048)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		n, err := st2.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			if err == io.EOF {
				break
			}
			t.Fatal(err)
		}
		if len(got) >= len(want) {
			break
		}
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("丢包后数据不一致: got=%d want=%d", len(got), len(want))
	}
}

// TestStreamBidirectional 同一条流双向读写:两个方向各有独立序列。
func TestStreamBidirectional(t *testing.T) {
	_, a, b := newPipe(0)
	as, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	bs, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	wantAB := randBytes(200 * 1024)
	wantBA := randBytes(150 * 1024)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if _, err := as.Write(wantAB); err != nil {
			t.Errorf("A→B 写入失败: %v", err)
		}
	}()
	go func() {
		defer wg.Done()
		if _, err := bs.Write(wantBA); err != nil {
			t.Errorf("B→A 写入失败: %v", err)
		}
	}()
	gotBA := make([]byte, len(wantBA))
	if err := readFull(as, gotBA); err != nil {
		t.Fatal(err)
	}
	gotAB := make([]byte, len(wantAB))
	if err := readFull(bs, gotAB); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if !bytes.Equal(gotAB, wantAB) || !bytes.Equal(gotBA, wantBA) {
		t.Fatalf("双向数据不一致: A→B=%d/%d B→A=%d/%d",
			len(gotAB), len(wantAB), len(gotBA), len(wantBA))
	}
}

// TestStreamEmptyClose 零数据直接关闭:对端读到 EOF。
func TestStreamEmptyClose(t *testing.T) {
	_, a, b := newPipe(0)
	st, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 16)
	n, err := st2.Read(buf)
	if n != 0 || err != io.EOF {
		t.Fatalf("空流关闭应得 EOF,得到 n=%d err=%v", n, err)
	}
}

// TestStreamLostClose Close 帧丢失时靠重传补齐,读方仍能读到 EOF。
func TestStreamLostClose(t *testing.T) {
	p, a, b := newPipe(0)
	p.dropClose = 2
	st, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte("fin 丢失后仍应可靠地读到结尾")
	if _, err := st.Write(want); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(st2)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("数据不一致: got=%q want=%q", got, want)
	}
}

// TestStreamSimultaneousDial 双方同时建流:流号段不冲突,各能收到对方。
func TestStreamSimultaneousDial(t *testing.T) {
	_, a, b := newPipe(0)
	as, err := a.session.Dial(b.ip)
	if err != nil {
		t.Fatal(err)
	}
	bs, err := b.session.Dial(a.ip)
	if err != nil {
		t.Fatal(err)
	}
	as2, err := a.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	bs2, err := b.session.Accept()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := as.Write([]byte("A 主动建流")); err != nil {
		t.Fatal(err)
	}
	if _, err := bs.Write([]byte("B 主动建流")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	n, err := bs2.Read(buf)
	if err != nil || string(buf[:n]) != "A 主动建流" {
		t.Fatalf("B 收到 A: n=%d err=%v", n, err)
	}
	n, err = as2.Read(buf)
	if err != nil || string(buf[:n]) != "B 主动建流" {
		t.Fatalf("A 收到 B: n=%d err=%v", n, err)
	}
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rand.Intn(256))
	}
	return b
}
