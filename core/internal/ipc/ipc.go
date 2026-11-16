// Package ipc 是界面与核心之间的通道:界面以子进程拉起 egland -ipc,
// 通过 stdin/stdout 一行一个 JSON 通信(行协议,UTF-8)。
//
// 协议约定:
//
//	请求  {"op":"start-host", "code":"…", "name":"…"}   开房间;code 留空自动生成
//	      {"op":"join", "code":"…", "peer":"host:port"} 入房;先回执 joining,完成后发 room-up 事件
//	      {"op":"stop"} {"op":"status"} {"op":"members"}
//	应答  {"type":"ok", …} / {"type":"err","message":"…"}
//	事件  {"type":"event","name":"room-up|room-down", …}
//	名册  {"type":"members","list":[{"name":"…","ip":"…","pub":"…"}]}
//
// 一次一个房间:同进程串行承载 host 或 client 之一;
// 界面关闭管道即视为退出指令,核心打扫干净(关网卡、关监听)再走。
package ipc

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os/user"
	"strings"
	"sync"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/firewall"
	"eglan/internal/mesh"
	"eglan/internal/room"
	"eglan/internal/tun"
)

// DefaultName 给未指定名字的成员起默认名:Player-系统用户名。
func DefaultName() string {
	base := "anon"
	if u, err := user.Current(); err == nil && u.Username != "" {
		base = u.Username
	}
	var b strings.Builder
	// 只保留安全字符:名字只进房间名册,不当任何控制面输入
	for _, r := range base {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
			r == '_' || r == '.' || r == '-' {
			b.WriteRune(r)
		}
	}
	clean := b.String()
	if len(clean) > 17 { // 总长上限 24:Player- 前缀 + 17 字符
		clean = clean[:17]
	}
	return "Player-" + clean
}

// request 是界面发来的一条请求;缺省字段由核心补齐。
type request struct {
	Op      string `json:"op"`
	Code    string `json:"code"`
	Name    string `json:"name"`
	Peer    string `json:"peer"`
	Listen  int    `json:"listen"`
	Adapter string `json:"adapter"`
	MTU     int    `json:"mtu"`
	CIDR    string `json:"cidr"`
}

// Bridge 持有房间状态机与全部连接;方法并发安全。
type Bridge struct {
	in  io.Reader
	out *json.Encoder
	wmu sync.Mutex // 输出串行化,一行一个 JSON

	mu    sync.Mutex
	state string // idle / hosting / joining / joined
	code  string // 归一前原码
	self  string
	host  *mesh.Host
	guest *mesh.Guest
	dev   tun.Device
}

// Run 从 in 逐行读请求、向 out 写应答,直到输入关闭;
// 返回前打扫房间,保证不留虚拟网卡与监听。
func Run(in io.Reader, out io.Writer) error {
	b := &Bridge{in: in, state: "idle"}
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false)
	b.out = enc
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64*1024), 64*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		b.dispatch(line)
	}
	b.mu.Lock()
	b.teardownLocked()
	b.mu.Unlock()
	return nil
}

// dispatch 解析并执行一条请求;协议错误即时回报,不中断会话。
func (b *Bridge) dispatch(line string) {
	var req request
	if err := json.Unmarshal([]byte(line), &req); err != nil {
		b.errf("无法解析的请求: %v", err)
		return
	}
	switch req.Op {
	case "start-host":
		b.opStartHost(req)
	case "join":
		b.opJoin(req)
	case "stop":
		b.opStop()
	case "status":
		b.opStatus()
	case "members":
		b.opMembers()
	default:
		b.errf("未知操作 %q", req.Op)
	}
}

// send 串行化写出。
func (b *Bridge) send(fields map[string]any) {
	b.wmu.Lock()
	defer b.wmu.Unlock()
	_ = b.out.Encode(fields)
}

func (b *Bridge) errf(format string, args ...any) {
	b.send(map[string]any{"type": "err", "message": fmt.Sprintf(format, args...)})
}

// opStartHost 开房间:建卡(需管理员)→ 放行 → 监听 → 收泵。
// 本地操作,同步完成并应答;失败时状态不变。
func (b *Bridge) opStartHost(req request) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state != "idle" {
		b.errf("已在房间中(%s),请先 stop", b.state)
		return
	}
	code := req.Code
	if code == "" {
		generated, err := room.NewCode()
		if err != nil {
			b.errf("生成房间码失败: %v", err)
			return
		}
		code = generated
	}
	psk := room.Normalize(code)
	if len(psk) == 0 {
		b.errf("房间码无效")
		return
	}
	name := req.Name
	if name == "" {
		name = DefaultName()
	}
	listen := req.Listen
	if listen == 0 {
		listen = 47777
	}
	adapter := req.Adapter
	if adapter == "" {
		adapter = "EGLAN"
	}
	mtu := req.MTU
	if mtu == 0 {
		mtu = 1400
	}
	cidr := req.CIDR
	if cidr == "" {
		cidr = "10.66.7.1/24"
	}
	id, err := crypto.NewIdentity()
	if err != nil {
		b.errf("生成本机身份失败: %v", err)
		return
	}
	dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
	if err != nil {
		b.errf("建虚拟网卡失败(需要管理员权限): %v", err)
		return
	}
	firewall.Open(listen)
	pc, err := mesh.Bind(listen)
	if err != nil {
		dev.Close()
		b.errf("监听 UDP 端口 %d 失败: %v", listen, err)
		return
	}
	h, err := mesh.NewHostOn(pc, psk, id, name, cidr)
	if err != nil {
		pc.Close()
		dev.Close()
		b.errf("房间初始化失败: %v", err)
		return
	}
	h.Start()
	b.host, b.dev, b.code, b.self, b.state = h, dev, code, cidr, "hosting"
	go b.pumpOut(dev, h)
	go b.pumpIn(dev, localSource{ch: h.LocalOut(), done: h.Done()})
	b.send(map[string]any{"type": "ok", "state": "hosting", "code": room.Display(code), "self": cidr, "name": name})
}

// opJoin 入房:网络握手可能慢(最多 15 秒),先回执 joining,完成后发 room-up 事件。
func (b *Bridge) opJoin(req request) {
	b.mu.Lock()
	if b.state != "idle" {
		b.mu.Unlock()
		b.errf("已在房间中(%s),请先 stop", b.state)
		return
	}
	if req.Peer == "" || req.Code == "" {
		b.mu.Unlock()
		b.errf("join 需要 code 与 peer(host:port)")
		return
	}
	psk := room.Normalize(req.Code)
	if len(psk) == 0 {
		b.mu.Unlock()
		b.errf("房间码无效")
		return
	}
	name := req.Name
	if name == "" {
		name = DefaultName()
	}
	adapter := req.Adapter
	if adapter == "" {
		adapter = "EGLAN"
	}
	mtu := req.MTU
	if mtu == 0 {
		mtu = 1400
	}
	b.state = "joining"
	b.mu.Unlock()
	b.send(map[string]any{"type": "ok", "state": "joining"})

	go func() {
		id, err := crypto.NewIdentity()
		if err != nil {
			b.joinFailed(err)
			return
		}
		g, err := mesh.DialGuest(req.Peer, psk, id, name, 15*time.Second)
		if err != nil {
			b.joinFailed(err)
			return
		}
		cidr := g.SelfNet().String()
		dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
		if err != nil {
			g.Close()
			b.joinFailed(fmt.Errorf("建虚拟网卡失败(需要管理员权限): %w", err))
			return
		}
		b.mu.Lock()
		if b.state != "joining" { // 等待期间被 stop
			b.mu.Unlock()
			dev.Close()
			g.Close()
			return
		}
		b.guest, b.dev, b.self, b.code, b.state = g, dev, cidr, req.Code, "joined"
		b.mu.Unlock()
		go b.pumpOut(dev, g)
		go b.pumpIn(dev, g)
		b.send(map[string]any{"type": "event", "name": "room-up", "state": "joined", "self": cidr, "host": g.HostName()})
	}()
}

// joinFailed 把 joining 回退到 idle 并回报原因。
func (b *Bridge) joinFailed(err error) {
	b.mu.Lock()
	if b.state == "joining" {
		b.state = "idle"
	}
	b.mu.Unlock()
	b.errf("加入失败: %v", err)
}

// opStop 停止并打扫;幂等。
func (b *Bridge) opStop() {
	b.mu.Lock()
	b.teardownLocked()
	b.mu.Unlock()
	b.send(map[string]any{"type": "ok", "state": "idle"})
}

// opStatus 报告当前状态与房间信息。
func (b *Bridge) opStatus() {
	b.mu.Lock()
	fields := map[string]any{"type": "status", "state": b.state}
	if b.code != "" {
		fields["code"] = room.Display(b.code)
	}
	if b.self != "" {
		fields["self"] = b.self
	}
	b.mu.Unlock()
	b.send(fields)
}

// opMembers 报告在房名册:主机给全员,成员侧只给主机一行。
func (b *Bridge) opMembers() {
	b.mu.Lock()
	var list []mesh.MemberInfo
	switch b.state {
	case "hosting":
		list = b.host.Members()
	case "joined":
		list = []mesh.MemberInfo{{
			Name: b.guest.HostName(),
			Pub:  hex.EncodeToString(b.guest.PeerPub()),
		}}
	}
	b.mu.Unlock()
	if list == nil {
		list = []mesh.MemberInfo{}
	}
	b.send(map[string]any{"type": "members", "state": b.state, "list": list})
}

// roomDown 房间因内部错误终止:打扫并广播事件;stop 已打扫时静默。
func (b *Bridge) roomDown(message string) {
	b.mu.Lock()
	if b.state == "idle" {
		b.mu.Unlock()
		return
	}
	b.teardownLocked()
	b.mu.Unlock()
	b.send(map[string]any{"type": "event", "name": "room-down", "message": message})
}

// teardownLocked 关闭房间连接与网卡,状态回 idle;须持 b.mu。
func (b *Bridge) teardownLocked() {
	if b.host != nil {
		b.host.Close()
		b.host = nil
	}
	if b.guest != nil {
		b.guest.Close()
		b.guest = nil
	}
	if b.dev != nil {
		b.dev.Close()
		b.dev = nil
	}
	b.state = "idle"
	b.code = ""
	b.self = ""
}

// packetSender / packetReceiver 是主机与成员共用的转发接口。
type (
	packetSender   interface{ Send(pkt []byte) error }
	packetReceiver interface{ Recv() ([]byte, error) }
)

// localSource 把主机的本机交付队列适配成接收器:泵只认 Recv。
type localSource struct {
	ch   <-chan []byte
	done <-chan struct{}
}

func (s localSource) Recv() ([]byte, error) {
	select {
	case pkt := <-s.ch:
		return pkt, nil
	case <-s.done:
		return nil, fmt.Errorf("房间已结束")
	}
}

// pumpOut 从网卡读 IP 包送入房间。
func (b *Bridge) pumpOut(dev tun.Device, to packetSender) {
	for {
		pkt, err := dev.Read()
		if err != nil {
			b.roomDown(fmt.Sprintf("网卡读取结束: %v", err))
			return
		}
		if err := to.Send(pkt); err != nil {
			b.roomDown(fmt.Sprintf("房间发送结束: %v", err))
			return
		}
	}
}

// pumpIn 从房间收 IP 包,注入本机协议栈。
func (b *Bridge) pumpIn(dev tun.Device, from packetReceiver) {
	for {
		pkt, err := from.Recv()
		if err != nil {
			b.roomDown(fmt.Sprintf("房间接收结束: %v", err))
			return
		}
		if err := dev.Write(pkt); err != nil {
			b.roomDown(fmt.Sprintf("网卡写入结束: %v", err))
			return
		}
	}
}
