// Package transfer 在可靠流上实现房间内的文件传输,属核心第一方功能。
//
// 一条传输 = 一条可靠流,协议为「报价 → 应答 → 定长字节 → 摘要 → 结果」:
//
//	{"t":"offer","v":1,"name":"a.bin","size":123}
//	{"t":"accept"} 或 {"t":"reject","reason":"…"}
//	<size 字节原始数据>
//	{"t":"end","sha256":"…"}
//	{"t":"done","ok":true} 或 {"t":"done","ok":false,"error":"…"}
//
// 发送方边发边算 SHA-256,接收方边收边算,落盘前比对;不符即失败并删除临时文件。
// 接收方先写同目录的 .eglan-part 临时文件,校验通过后再原子改名。
package transfer

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"eglan/internal/stream"
)

const (
	// protoVersion 报价协议版本;不匹配直接拒绝。
	protoVersion = 1

	// offerTimeout 接收方等待用户决定的最长时间。
	offerTimeout = 2 * time.Minute

	// acceptTimeout 发送方等待接收方应答的最长时间,略长于 offerTimeout。
	acceptTimeout = offerTimeout + time.Minute

	// resultTimeout 等待最终 done 的最长时间。
	resultTimeout = 60 * time.Second

	// lineMax JSON 行上限,防止对端用超长行耗尽内存。
	lineMax = 64 * 1024

	// chunkSize 单次读写块大小。
	chunkSize = 64 * 1024

	// progressGap 进度事件最小间隔。
	progressGap = 100 * time.Millisecond
)

var (
	errLineTooLong = errors.New("transfer: 协议行过长")
	errTimeout     = errors.New("transfer: 等待对端超时")
)

// Event 是传输状态变化,供界面展示。回调可能由多个协程并发触发。
type Event struct {
	Kind     string // offer / progress / done
	ID       string
	Peer     string // 对端隧道 IP
	Name     string // 文件名(仅展示,不用于拼路径)
	Size     int64
	Done     int64
	Path     string // 本机路径:发送为源文件,接收为保存位置
	Incoming bool
	OK       bool
	Err      string
}

// Manager 管理本端的发送与接收;一个房间一个。
type Manager struct {
	self net.IP
	flow *stream.Session
	emit func(Event)

	mu     sync.Mutex
	tasks  map[string]*task
	offers map[string]*incoming

	seq       atomic.Uint64
	done      chan struct{}
	closeOnce sync.Once
}

type task struct {
	id   string
	peer net.IP
	path string
	name string
	size int64
	st   stream.Stream // 发送中登记,房间关闭时强制断开
}

type incoming struct {
	id   string
	peer string
	name string
	size int64
	dec  chan decision
}

type decision struct {
	accept bool
	path   string
	reason string
}

// New 构造传输管理器;emit 不能为 nil。
func New(self net.IP, flow *stream.Session, emit func(Event)) *Manager {
	return &Manager{
		self:   self,
		flow:   flow,
		emit:   emit,
		tasks:  map[string]*task{},
		offers: map[string]*incoming{},
		done:   make(chan struct{}),
	}
}

// Serve 接收并处理来流;应在独立协程运行。
func (m *Manager) Serve() {
	for {
		st, err := m.flow.Accept()
		if err != nil {
			if errors.Is(err, stream.ErrClosed) {
				return
			}
			select {
			case <-m.done:
				return
			default:
				continue // Accept 超时,继续等
			}
		}
		go m.handle(st)
	}
}

// Close 停止接收并断开进行中的发送;幂等。
func (m *Manager) Close() {
	m.closeOnce.Do(func() {
		close(m.done)
		m.mu.Lock()
		for _, in := range m.offers {
			select {
			case in.dec <- decision{reason: "房间已关闭"}:
			default:
			}
		}
		for _, t := range m.tasks {
			if t.st != nil {
				_ = t.st.Close()
			}
		}
		m.offers = map[string]*incoming{}
		m.tasks = map[string]*task{}
		m.mu.Unlock()
	})
}

// Send 把本机文件发给成员 peer;立即返回传输编号,进度与结果通过事件报告。
func (m *Manager) Send(peer net.IP, path string) (string, error) {
	if peer == nil {
		return "", errors.New("transfer: 缺少目标成员")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("transfer: 无法读取文件: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("transfer: 只能发送普通文件")
	}
	t := &task{
		id:   m.newID(),
		peer: peer,
		path: path,
		name: safeName(filepath.Base(path)),
		size: info.Size(),
	}
	m.mu.Lock()
	m.tasks[t.id] = t
	m.mu.Unlock()
	go m.runSend(t)
	return t.id, nil
}

// Accept 同意接收指定传输,并指定保存的绝对路径。
func (m *Manager) Accept(id, path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("transfer: 保存路径必须是绝对路径")
	}
	dir := filepath.Dir(path)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return errors.New("transfer: 保存目录不存在")
	}
	m.mu.Lock()
	in := m.offers[id]
	m.mu.Unlock()
	if in == nil {
		return errors.New("transfer: 传输不存在或已处理")
	}
	select {
	case in.dec <- decision{accept: true, path: path}:
		return nil
	default:
		return errors.New("transfer: 该传输已在处理")
	}
}

// Reject 拒绝指定传输。
func (m *Manager) Reject(id, reason string) error {
	m.mu.Lock()
	in := m.offers[id]
	m.mu.Unlock()
	if in == nil {
		return errors.New("transfer: 传输不存在或已处理")
	}
	if reason == "" {
		reason = "接收方拒绝了文件"
	}
	select {
	case in.dec <- decision{reason: reason}:
		return nil
	default:
		return errors.New("transfer: 该传输已在处理")
	}
}

func (m *Manager) newID() string {
	n := m.seq.Add(1)
	return fmt.Sprintf("t%d", n)
}

// ---- 发送 ----

func (m *Manager) runSend(t *task) {
	fail := func(err error) { m.finish(t, false, err.Error()) }

	st, err := m.flow.Dial(t.peer)
	if err != nil {
		fail(fmt.Errorf("建立流失败: %w", err))
		return
	}
	m.mu.Lock()
	t.st = st
	m.mu.Unlock()
	defer func() {
		_ = st.Close()
		m.mu.Lock()
		delete(m.tasks, t.id)
		m.mu.Unlock()
	}()

	if err := writeLine(st, wireOffer{T: "offer", V: protoVersion, Name: t.name, Size: t.size}); err != nil {
		fail(fmt.Errorf("发送报价失败: %w", err))
		return
	}
	br := bufio.NewReaderSize(st, 4096)
	line, err := readLineTimeout(br, acceptTimeout)
	if err != nil {
		fail(fmt.Errorf("等待接收方应答失败: %w", err))
		return
	}
	var resp wireResp
	if err := json.Unmarshal(line, &resp); err != nil || resp.T != "accept" {
		reason := resp.Reason
		if reason == "" {
			reason = "接收方拒绝了文件"
		}
		fail(errors.New(reason))
		return
	}

	f, err := os.Open(t.path)
	if err != nil {
		fail(fmt.Errorf("打开文件失败: %w", err))
		return
	}
	defer f.Close()

	h := sha256.New()
	buf := make([]byte, chunkSize)
	var sent int64
	lastEmit := time.Now()
	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			if _, werr := st.Write(buf[:n]); werr != nil {
				fail(fmt.Errorf("发送数据失败: %w", werr))
				return
			}
			_, _ = h.Write(buf[:n])
			sent += int64(n)
			if time.Since(lastEmit) >= progressGap {
				m.emit(Event{Kind: "progress", ID: t.id, Peer: t.peer.String(), Name: t.name,
					Size: t.size, Done: sent, Path: t.path})
				lastEmit = time.Now()
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			fail(fmt.Errorf("读取文件失败: %w", rerr))
			return
		}
	}
	m.emit(Event{Kind: "progress", ID: t.id, Peer: t.peer.String(), Name: t.name,
		Size: t.size, Done: sent, Path: t.path})

	if err := writeLine(st, wireEnd{T: "end", SHA256: hex.EncodeToString(h.Sum(nil))}); err != nil {
		fail(fmt.Errorf("发送摘要失败: %w", err))
		return
	}
	line, err = readLineTimeout(br, resultTimeout)
	if err != nil {
		fail(fmt.Errorf("等待接收方校验结果失败: %w", err))
		return
	}
	var done wireDone
	if err := json.Unmarshal(line, &done); err != nil || done.T != "done" {
		fail(errors.New("接收方返回了无效结果"))
		return
	}
	if !done.OK {
		reason := done.Error
		if reason == "" {
			reason = "接收方校验失败"
		}
		fail(errors.New(reason))
		return
	}
	m.finish(t, true, "")
}

func (m *Manager) finish(t *task, ok bool, errText string) {
	m.emit(Event{Kind: "done", ID: t.id, Peer: t.peer.String(), Name: t.name,
		Size: t.size, Done: t.size, Path: t.path, OK: ok, Err: errText})
}

// ---- 接收 ----

func (m *Manager) handle(st stream.Stream) {
	peer := safePeer(st.Peer())
	br := bufio.NewReaderSize(st, 4096)
	line, err := readLineTimeout(br, 30*time.Second)
	if err != nil {
		_ = st.Close()
		return
	}
	var off wireOffer
	if err := json.Unmarshal(line, &off); err != nil || off.T != "offer" || off.V != protoVersion {
		_ = writeLine(st, wireResp{T: "reject", Reason: "不支持的传输协议"})
		_ = st.Close()
		return
	}
	if off.Size < 0 {
		_ = writeLine(st, wireResp{T: "reject", Reason: "文件大小无效"})
		_ = st.Close()
		return
	}
	id := m.newID()
	in := &incoming{id: id, peer: peer, name: safeName(off.Name), size: off.Size, dec: make(chan decision, 1)}
	m.mu.Lock()
	m.offers[id] = in
	m.mu.Unlock()
	m.emit(Event{Kind: "offer", ID: id, Peer: peer, Name: in.name, Size: in.size, Incoming: true})

	var dec decision
	expired := ""
	select {
	case dec = <-in.dec:
	case <-time.After(offerTimeout):
		dec = decision{reason: "等待接收方确认超时"}
		expired = dec.reason
	case <-m.done:
		dec = decision{reason: "房间已关闭"}
		expired = dec.reason
	}
	m.mu.Lock()
	delete(m.offers, id)
	m.mu.Unlock()
	// 报价自行过期时也要给界面一个收尾事件,避免待接收条目一直悬挂;
	// 用户主动拒绝由界面移除条目,不重复发。
	if expired != "" {
		m.emit(Event{Kind: "done", ID: id, Peer: peer, Name: in.name,
			Size: in.size, Incoming: true, Err: expired})
	}

	if !dec.accept {
		_ = writeLine(st, wireResp{T: "reject", Reason: dec.reason})
		_ = st.Close()
		return
	}
	_ = writeLine(st, wireResp{T: "accept"})
	m.receive(st, br, in, dec.path)
	_ = st.Close()
}

func (m *Manager) receive(st stream.Stream, br *bufio.Reader, in *incoming, path string) {
	fail := func(msg string) {
		_ = writeLine(st, wireDone{T: "done", OK: false, Error: msg})
		m.emit(Event{Kind: "done", ID: in.id, Peer: in.peer, Name: in.name,
			Size: in.size, Path: path, Incoming: true, Err: msg})
	}
	tmp := path + ".eglan-part"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o600)
	if err != nil {
		fail(fmt.Sprintf("无法创建保存文件: %v", err))
		return
	}
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(tmp)
		}
	}()

	h := sha256.New()
	buf := make([]byte, chunkSize)
	var got int64
	lastEmit := time.Now()
	for got < in.size {
		n := int64(len(buf))
		if rem := in.size - got; rem < n {
			n = rem
		}
		if _, err := io.ReadFull(br, buf[:n]); err != nil {
			fail(fmt.Sprintf("接收数据中断: %v", err))
			return
		}
		if _, err := f.Write(buf[:n]); err != nil {
			fail(fmt.Sprintf("写入文件失败: %v", err))
			return
		}
		_, _ = h.Write(buf[:n])
		got += n
		if time.Since(lastEmit) >= progressGap {
			m.emit(Event{Kind: "progress", ID: in.id, Peer: in.peer, Name: in.name,
				Size: in.size, Done: got, Path: path, Incoming: true})
			lastEmit = time.Now()
		}
	}
	line, err := readLineTimeout(br, resultTimeout)
	if err != nil {
		fail(fmt.Sprintf("等待摘要失败: %v", err))
		return
	}
	var end wireEnd
	if err := json.Unmarshal(line, &end); err != nil || end.T != "end" {
		fail("传输尾部无效")
		return
	}
	if !strings.EqualFold(end.SHA256, hex.EncodeToString(h.Sum(nil))) {
		fail("文件校验失败(SHA-256 不符)")
		return
	}
	if err := f.Close(); err != nil {
		fail(fmt.Sprintf("关闭文件失败: %v", err))
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		fail(fmt.Sprintf("保存文件失败: %v", err))
		return
	}
	ok = true
	_ = writeLine(st, wireDone{T: "done", OK: true})
	m.emit(Event{Kind: "done", ID: in.id, Peer: in.peer, Name: in.name,
		Size: in.size, Done: in.size, Path: path, Incoming: true, OK: true})
}

// ---- 协议工具 ----

type wireOffer struct {
	T    string `json:"t"`
	V    int    `json:"v"`
	Name string `json:"name"`
	Size int64  `json:"size"`
}

type wireResp struct {
	T      string `json:"t"`
	Reason string `json:"reason,omitempty"`
}

type wireEnd struct {
	T      string `json:"t"`
	SHA256 string `json:"sha256"`
}

type wireDone struct {
	T     string `json:"t"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func writeLine(st stream.Stream, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if _, err := st.Write(b); err != nil {
		return err
	}
	return nil
}

// readLine 逐字节读到换行,超过 lineMax 即报错。
func readLine(br *bufio.Reader) ([]byte, error) {
	var b []byte
	for {
		c, err := br.ReadByte()
		if err != nil {
			return nil, err
		}
		if c == '\n' {
			if len(b) > 0 && b[len(b)-1] == '\r' {
				b = b[:len(b)-1]
			}
			return b, nil
		}
		if len(b) >= lineMax {
			return nil, errLineTooLong
		}
		b = append(b, c)
	}
}

// readLineTimeout 给行读取加时限;流不支持读超时,超时后由调用方关闭流解除阻塞。
func readLineTimeout(br *bufio.Reader, d time.Duration) ([]byte, error) {
	type result struct {
		b   []byte
		err error
	}
	ch := make(chan result, 1)
	go func() {
		b, err := readLine(br)
		ch <- result{b, err}
	}()
	select {
	case r := <-ch:
		return r.b, r.err
	case <-time.After(d):
		return nil, errTimeout
	}
}

// safeName 只保留文件名本身:去掉路径分隔符与控制字符,限长 255 字节。
func safeName(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	var b strings.Builder
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			continue
		}
		b.WriteRune(r)
		if b.Len() >= 255 {
			break
		}
	}
	s := strings.TrimSpace(b.String())
	if s == "" || s == "." || s == ".." {
		return "未命名文件"
	}
	return s
}

func safePeer(p string) string {
	if p == "" {
		return "未知成员"
	}
	return p
}
