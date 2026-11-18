// Package ipc 是界面与核心之间的通道:界面以子进程拉起 egland -ipc,
// 通过 stdin/stdout 一行一个 JSON 通信(行协议,UTF-8)。
//
// 协议约定:
//
//	请求  {"op":"start-host", "code":"…", "name":"…"}   开房间;code 留空自动生成
//	      {"op":"join", "code":"…", "peer":"host:port"} 入房;先回执 joining,完成后发 room-up 事件
//	      {"op":"stop"} {"op":"status"} {"op":"members"}
//	      {"op":"env"} {"op":"restart-admin","exe":"…"}
//	应答  {"type":"ok", …} / {"type":"err","message":"…"}
//	      {"type":"env","admin":false,"canElevate":true}
//	事件  {"type":"event","name":"room-up|room-down", …}
//	      {"type":"event","name":"discovered","rooms":[{"name","code","peer","members"}]}
//	名册  {"type":"members","list":[{"name":"…","ip":"…","pub":"…"}]}
//
// 空闲时核心监听局域网发现端口,把同网段的房间推给界面;开房后改播报,
// 离房后恢复监听。发现只负责列出房间,加入仍走 join。
//
// 每条请求可带 "id":核心在应答与该请求引发的错误、room-up 里原样带回,
// 供界面把异步结果与请求关联;不带 id 则应答也不含 id。
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
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/disc"
	"eglan/internal/elevate"
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
// ID 由界面侧生成,核心原样带回,用于异步应答的关联。
type request struct {
	Op      string `json:"op"`
	ID      string `json:"id"`
	Code    string `json:"code"`
	Name    string `json:"name"`
	Peer    string `json:"peer"`
	Listen  int    `json:"listen"`
	Adapter string `json:"adapter"`
	MTU     int    `json:"mtu"`
	CIDR    string `json:"cidr"`
	Exe     string `json:"exe"`
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
	disc  *disc.Listener  // 空闲时的发现监听
	discA *disc.Announcer // 开房时的信标播报
}

// Run 从 in 逐行读请求、向 out 写应答,直到输入关闭;
// 返回前打扫房间,保证不留虚拟网卡与监听。
func Run(in io.Reader, out io.Writer) error {
	b := &Bridge{in: in, state: "idle"}
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false)
	b.out = enc
	// 发现端口也要能收:规则一次装好,失败不阻断(可能未提权或已手工放行)
	go func() { _ = firewall.Open(disc.Port) }()
	b.mu.Lock()
	b.startDiscoveryLocked()
	b.mu.Unlock()
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
	b.stopDiscoveryLocked()
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
		b.opStop(req)
	case "status":
		b.opStatus(req)
	case "members":
		b.opMembers(req)
	case "env":
		b.opEnv(req)
	case "restart-admin":
		b.opRestartAdmin(req)
	default:
		b.errID(req.ID, "未知操作 %q", req.Op)
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

// errID 带请求 id 的错误应答,供界面关联。
func (b *Bridge) errID(id, format string, args ...any) {
	fields := map[string]any{"type": "err", "message": fmt.Sprintf(format, args...)}
	if id != "" {
		fields["id"] = id
	}
	b.send(fields)
}

// startDiscoveryLocked 在空闲态监听局域网信标;已有监听或非空闲则不动。
// 发现是增强能力:端口被占用时静默降级,不影响房间功能。
func (b *Bridge) startDiscoveryLocked() {
	if b.state != "idle" || b.disc != nil {
		return
	}
	l, err := disc.Listen(disc.Port, b.discovered)
	if err != nil {
		return
	}
	b.disc = l
}

// stopDiscoveryLocked 停止发现监听;须持 b.mu。
func (b *Bridge) stopDiscoveryLocked() {
	if b.disc != nil {
		b.disc.Close()
		b.disc = nil
	}
}

// discovered 把最新房间快照推给界面;由监听协程调用。
func (b *Bridge) discovered(rooms []disc.Room) {
	if rooms == nil {
		rooms = []disc.Room{}
	}
	b.send(map[string]any{"type": "event", "name": "discovered", "rooms": rooms})
}

// opEnv 报告运行环境:是否已提权、能否一键提权。
func (b *Bridge) opEnv(req request) {
	b.send(map[string]any{
		"type":       "env",
		"id":         req.ID,
		"admin":      elevate.Admin(),
		"canElevate": elevate.Available(),
	})
}

// opRestartAdmin 以管理员权限重新拉起界面程序;由界面在成功后自行退出。
// 路径由界面随请求带来,只接受存在的绝对路径。
func (b *Bridge) opRestartAdmin(req request) {
	if !elevate.Available() {
		b.errID(req.ID, "当前平台暂不支持一键提权")
		return
	}
	if elevate.Admin() {
		b.send(map[string]any{"type": "ok", "id": req.ID, "admin": true, "relaunched": false})
		return
	}
	if req.Exe == "" || !filepath.IsAbs(req.Exe) {
		b.errID(req.ID, "缺少界面程序的绝对路径")
		return
	}
	info, err := os.Stat(req.Exe)
	if err != nil {
		b.errID(req.ID, "找不到界面程序: %s", req.Exe)
		return
	}
	if !info.Mode().IsRegular() {
		b.errID(req.ID, "界面程序路径不是文件: %s", req.Exe)
		return
	}
	if err := elevate.Restart(req.Exe); err != nil {
		b.errID(req.ID, "%v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "admin": false, "relaunched": true})
}

// opStartHost 开房间:建卡(需管理员)→ 放行 → 监听 → 收泵。
// 本地操作,同步完成并应答;失败时状态不变。
func (b *Bridge) opStartHost(req request) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state != "idle" {
		b.errID(req.ID, "已在房间中(%s),请先 stop", b.state)
		return
	}
	code := req.Code
	if code == "" {
		generated, err := room.NewCode()
		if err != nil {
			b.errID(req.ID, "生成房间码失败: %v", err)
			return
		}
		code = generated
	}
	psk := room.Normalize(code)
	if len(psk) == 0 {
		b.errID(req.ID, "房间码无效")
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
		b.errID(req.ID, "生成本机身份失败: %v", err)
		return
	}
	dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
	if err != nil {
		b.errID(req.ID, "建虚拟网卡失败(需要管理员权限): %v", err)
		return
	}
	_ = firewall.Open(listen)
	pc, err := mesh.Bind(listen)
	if err != nil {
		dev.Close()
		b.errID(req.ID, "监听 UDP 端口 %d 失败: %v", listen, err)
		return
	}
	h, err := mesh.NewHostOn(pc, psk, id, name, cidr)
	if err != nil {
		pc.Close()
		dev.Close()
		b.errID(req.ID, "房间初始化失败: %v", err)
		return
	}
	h.Start()
	// 房间已起:停发现监听,改由本机播报,避免自己发现自己
	b.stopDiscoveryLocked()
	if a, err := disc.Announce(disc.AnnounceConfig{
		Name:    name,
		Code:    code,
		Port:    listen,
		Members: func() int { return len(h.Members()) + 1 },
	}); err == nil {
		b.discA = a
	}
	b.host, b.dev, b.code, b.self, b.state = h, dev, code, cidr, "hosting"
	go b.pumpOut(dev, h)
	go b.pumpIn(dev, localSource{ch: h.LocalOut(), done: h.Done()})
	b.send(map[string]any{"type": "ok", "id": req.ID, "state": "hosting", "code": room.Display(code), "self": cidr, "name": name})
}

// opJoin 入房:网络握手可能慢(最多 15 秒),先回执 joining,完成后发 room-up 事件。
func (b *Bridge) opJoin(req request) {
	b.mu.Lock()
	if b.state != "idle" {
		b.mu.Unlock()
		b.errID(req.ID, "已在房间中(%s),请先 stop", b.state)
		return
	}
	if req.Peer == "" || req.Code == "" {
		b.mu.Unlock()
		b.errID(req.ID, "join 需要 code 与 peer(host:port)")
		return
	}
	psk := room.Normalize(req.Code)
	if len(psk) == 0 {
		b.mu.Unlock()
		b.errID(req.ID, "房间码无效")
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
	b.stopDiscoveryLocked()
	b.state = "joining"
	b.mu.Unlock()
	b.send(map[string]any{"type": "ok", "id": req.ID, "state": "joining"})

	jid := req.ID
	go func() {
		id, err := crypto.NewIdentity()
		if err != nil {
			b.joinFailed(jid, err)
			return
		}
		g, err := mesh.DialGuest(req.Peer, psk, id, name, 15*time.Second)
		if err != nil {
			b.joinFailed(jid, err)
			return
		}
		cidr := g.SelfNet().String()
		dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
		if err != nil {
			g.Close()
			b.joinFailed(jid, fmt.Errorf("建虚拟网卡失败(需要管理员权限): %w", err))
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
		fields := map[string]any{"type": "event", "name": "room-up", "state": "joined", "self": cidr, "host": g.HostName()}
		if jid != "" {
			fields["id"] = jid
		}
		b.send(fields)
	}()
}

// joinFailed 把 joining 回退到 idle 并回报原因;id 用于界面关联本次入房请求。
func (b *Bridge) joinFailed(id string, err error) {
	b.mu.Lock()
	if b.state == "joining" {
		b.state = "idle"
		b.startDiscoveryLocked() // 入房未成,回到发现
	}
	b.mu.Unlock()
	b.errID(id, "加入失败: %v", err)
}

// opStop 停止并打扫;幂等。
func (b *Bridge) opStop(req request) {
	b.mu.Lock()
	b.teardownLocked()
	b.startDiscoveryLocked()
	b.mu.Unlock()
	b.send(map[string]any{"type": "ok", "id": req.ID, "state": "idle"})
}

// opStatus 报告当前状态与房间信息。
func (b *Bridge) opStatus(req request) {
	b.mu.Lock()
	fields := map[string]any{"type": "status", "id": req.ID, "state": b.state}
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
func (b *Bridge) opMembers(req request) {
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
	state := b.state
	b.mu.Unlock()
	if list == nil {
		list = []mesh.MemberInfo{}
	}
	b.send(map[string]any{"type": "members", "id": req.ID, "state": state, "list": list})
}

// roomDown 房间因内部错误终止:打扫并广播事件;stop 已打扫时静默。
func (b *Bridge) roomDown(message string) {
	b.mu.Lock()
	if b.state == "idle" {
		b.mu.Unlock()
		return
	}
	b.teardownLocked()
	b.startDiscoveryLocked()
	b.mu.Unlock()
	b.send(map[string]any{"type": "event", "name": "room-down", "message": message})
}

// teardownLocked 关闭房间连接与网卡,状态回 idle;须持 b.mu。
func (b *Bridge) teardownLocked() {
	if b.discA != nil {
		b.discA.Close()
		b.discA = nil
	}
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
