// Package ipc 是界面与核心之间的通道:界面以子进程拉起 egland -ipc,
// 通过 stdin/stdout 一行一个 JSON 通信(行协议,UTF-8)。
// 需要管理员权限时,旧核心用 runas 拉起新的核心,新核心经
// -ipc-connect 连回界面提供的本机回环端口;界面本身始终保持普通权限。
//
// 协议约定:
//
//	请求  {"op":"start-host", "code":"…", "name":"…"}   开房间;code 留空自动生成
//	      {"op":"join", "code":"…", "peer":"host:port"} 入房;先回执 joining,完成后发 room-up 事件
//	      {"op":"stop"} {"op":"status"} {"op":"members"}
//	      {"op":"stun","server":"stun.example:3478"} 从房间套接字探测公网映射
//	      {"op":"env"} {"op":"elevate-core","addr":"127.0.0.1:port","token":"…"}
//	      {"op":"send-file","to":"10.66.7.2","path":"…"} 向成员发文件
//	      {"op":"accept-file","transfer":"t1","path":"…"} 接受并指定保存路径
//	      {"op":"reject-file","transfer":"t1","reason":"…"} 拒绝接收
//	      {"op":"pick-file","title":"…"} / {"op":"pick-save","title":"…","name":"…"}
//	应答  {"type":"ok", …} / {"type":"err","message":"…"}
//	      {"type":"env","admin":false,"canElevate":true}
//	      {"type":"ok","path":"…"} 文件对话框结果;取消时带 "cancel":true
//	事件  {"type":"event","name":"room-up|room-down", …}
//	      {"type":"event","name":"discovered","rooms":[{"name","code","peer","members"}]}
//	      {"type":"event","name":"file-offer","transfer":"t1","peer":"…","file":"…","size":123}
//	      {"type":"event","name":"file-progress","transfer":"t1","done":456,…}
//	      {"type":"event","name":"file-done","transfer":"t1","ok":true,"path":"…",…}
//	名册  {"type":"members","list":[{"name":"…","ip":"…","pub":"…"}]}
//
// 回环通道的第一行固定为 {"type":"auth","token":"…"},由界面核对令牌,
// 防止本机其它进程抢先接管这条连接。
//
// 空闲时核心监听局域网发现端口,把同网段的房间推给界面;开房后改播报,
// 离房后恢复监听。发现只负责列出房间,加入仍走 join。
//
// 每条请求可带 "id":核心在应答与该请求引发的错误、room-up 里原样带回,
// 供界面把异步结果与请求关联;不带 id 则应答也不含 id。
//
// 一次一个房间:同进程串行承载 host 或 client 之一;
// 界面关闭管道或回环连接即视为退出指令,核心打扫干净(关网卡、关监听)再走。
package ipc

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/user"
	"strings"
	"sync"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/disc"
	"eglan/internal/elevate"
	"eglan/internal/filedialog"
	"eglan/internal/firewall"
	"eglan/internal/mesh"
	"eglan/internal/room"
	"eglan/internal/transfer"
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
	Op       string `json:"op"`
	ID       string `json:"id"`
	Code     string `json:"code"`
	Name     string `json:"name"`
	Peer     string `json:"peer"`
	Listen   int    `json:"listen"`
	Adapter  string `json:"adapter"`
	MTU      int    `json:"mtu"`
	CIDR     string `json:"cidr"`
	Addr     string `json:"addr"`
	Token    string `json:"token"`
	Server   string `json:"server"`
	To       string `json:"to"`
	Path     string `json:"path"`
	Transfer string `json:"transfer"`
	Reason   string `json:"reason"`
	Title    string `json:"title"`
}

// Bridge 持有房间状态机与全部连接;方法并发安全。
type Bridge struct {
	in       io.Reader
	out      *json.Encoder
	wmu      sync.Mutex    // 输出串行化,一行一个 JSON
	quit     chan struct{} // 关闭后 Run 打扫并退出
	quitOnce sync.Once

	mu    sync.Mutex
	state string // idle / hosting / joining / joined
	code  string // 归一前原码
	self  string
	host  *mesh.Host
	guest *mesh.Guest
	xfer  *transfer.Manager
	dev   tun.Device
	disc  *disc.Listener  // 空闲时的发现监听
	discA *disc.Announcer // 开房时的信标播报
}

// Run 从 in 逐行读请求、向 out 写应答,直到输入关闭;
// 返回前打扫房间,保证不留虚拟网卡与监听。
func Run(in io.Reader, out io.Writer) error {
	b := &Bridge{in: in, state: "idle", quit: make(chan struct{})}
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false)
	b.out = enc
	// 发现端口也要能收:规则一次装好,失败不阻断(可能未提权或已手工放行)
	go func() { _ = firewall.Open(disc.Port) }()
	b.mu.Lock()
	b.startDiscoveryLocked()
	b.mu.Unlock()

	lines := make(chan string)
	scanDone := make(chan error, 1)
	go func() {
		sc := bufio.NewScanner(in)
		sc.Buffer(make([]byte, 0, 64*1024), 64*1024)
		for sc.Scan() {
			select {
			case lines <- sc.Text():
			case <-b.quit:
				return
			}
		}
		scanDone <- sc.Err()
	}()

	for {
		select {
		case line := <-lines:
			line = strings.TrimSpace(line)
			if line != "" {
				b.dispatch(line)
			}
		case err := <-scanDone:
			b.shutdown()
			return err
		case <-b.quit:
			b.shutdown()
			return nil
		}
	}
}

// shutdown 统一打扫房间与发现监听。
func (b *Bridge) shutdown() {
	b.mu.Lock()
	b.teardownLocked()
	b.stopDiscoveryLocked()
	b.mu.Unlock()
}

// Connect 连接界面监听的本地端口,首行携带令牌,随后使用同一行协议。
// 只用于界面以管理员权限拉起核心的场景:界面保持普通权限,核心单独提权。
func Connect(addr, token string) error {
	if addr == "" || token == "" {
		return fmt.Errorf("缺少回调地址或令牌")
	}
	conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return fmt.Errorf("连接界面失败: %w", err)
	}
	defer conn.Close()
	enc := json.NewEncoder(conn)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(map[string]string{"type": "auth", "token": token}); err != nil {
		return fmt.Errorf("向界面认证失败: %w", err)
	}
	return Run(conn, conn)
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
	case "stun":
		b.opStun(req)
	case "env":
		b.opEnv(req)
	case "elevate-core":
		b.opElevateCore(req)
	case "send-file":
		b.opSendFile(req)
	case "accept-file":
		b.opAcceptFile(req)
	case "reject-file":
		b.opRejectFile(req)
	case "pick-file":
		b.opPickFile(req)
	case "pick-save":
		b.opPickSave(req)
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

// opElevateCore 用管理员权限拉起新的核心进程,并让它连回界面提供的本地端口。
// 旧核心只在新进程创建成功后退出;界面本身始终保持普通权限。
func (b *Bridge) opElevateCore(req request) {
	if !elevate.Available() {
		b.errID(req.ID, "当前平台暂不支持一键提权")
		return
	}
	if elevate.Admin() {
		b.send(map[string]any{"type": "ok", "id": req.ID, "admin": true, "relaunched": false})
		return
	}
	b.mu.Lock()
	idle := b.state == "idle"
	b.mu.Unlock()
	if !idle {
		b.errID(req.ID, "请先退出房间,再切换管理员核心")
		return
	}
	addr, err := net.ResolveTCPAddr("tcp", req.Addr)
	if err != nil || !addr.IP.IsLoopback() {
		b.errID(req.ID, "回调地址必须是本机回环地址")
		return
	}
	raw, err := hex.DecodeString(req.Token)
	if err != nil || len(raw) < 16 {
		b.errID(req.ID, "回调令牌无效")
		return
	}
	exe, err := os.Executable()
	if err != nil {
		b.errID(req.ID, "找不到核心程序: %v", err)
		return
	}
	args := []string{"-ipc-connect", req.Addr, "-ipc-token", req.Token}
	if err := elevate.RunAs(exe, args, true); err != nil {
		b.errID(req.ID, "%v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "admin": false, "relaunched": true})
	b.requestQuit()
}

// requestQuit 让 Run 在处理完当前请求后打扫退出;重复调用安全。
func (b *Bridge) requestQuit() {
	b.quitOnce.Do(func() { close(b.quit) })
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
	b.xfer = transfer.New(h.SelfIP(), h.Flow(), b.transferEvent)
	go b.xfer.Serve()
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
	b.send(map[string]any{
		"type": "ok", "id": req.ID, "state": "hosting",
		"code": room.Display(code), "self": cidr, "name": name,
		"port": listen, "lan": disc.LocalPeers(listen),
	})
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
		xfer := transfer.New(g.HostIP(), g.Flow(), b.transferEvent)
		b.xfer = xfer
		b.mu.Unlock()
		go xfer.Serve()
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

// opSendFile 向房间内成员发起文件传输:主机可指定任一成员,成员侧只发主机。
func (b *Bridge) opSendFile(req request) {
	if req.Path == "" {
		b.errID(req.ID, "缺少要发送的文件路径")
		return
	}
	b.mu.Lock()
	mgr, state := b.xfer, b.state
	var target net.IP
	switch state {
	case "hosting":
		if ip4 := net.ParseIP(req.To).To4(); ip4 != nil {
			for _, m := range b.host.Members() {
				if m.IP == ip4.String() {
					target = ip4
					break
				}
			}
		}
	case "joined":
		target = b.guest.HostIP()
		if req.To != "" {
			if ip4 := net.ParseIP(req.To).To4(); ip4 == nil || !ip4.Equal(target) {
				target = nil
			}
		}
	}
	b.mu.Unlock()
	if mgr == nil || (state != "hosting" && state != "joined") {
		b.errID(req.ID, "加入房间后才能发送文件")
		return
	}
	if target == nil {
		b.errID(req.ID, "目标成员不在房间内")
		return
	}
	id, err := mgr.Send(target, req.Path)
	if err != nil {
		b.errID(req.ID, "%v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "transfer": id})
}

// opAcceptFile 接受一条接收请求,并指定本机保存路径(绝对路径)。
func (b *Bridge) opAcceptFile(req request) {
	b.mu.Lock()
	mgr := b.xfer
	b.mu.Unlock()
	if mgr == nil {
		b.errID(req.ID, "不在房间中")
		return
	}
	if req.Transfer == "" || req.Path == "" {
		b.errID(req.ID, "accept-file 需要 transfer 与 path")
		return
	}
	if err := mgr.Accept(req.Transfer, req.Path); err != nil {
		b.errID(req.ID, "%v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "transfer": req.Transfer})
}

// opRejectFile 拒绝一条接收请求。
func (b *Bridge) opRejectFile(req request) {
	b.mu.Lock()
	mgr := b.xfer
	b.mu.Unlock()
	if mgr == nil {
		b.errID(req.ID, "不在房间中")
		return
	}
	if req.Transfer == "" {
		b.errID(req.ID, "reject-file 需要 transfer")
		return
	}
	if err := mgr.Reject(req.Transfer, req.Reason); err != nil {
		b.errID(req.ID, "%v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "transfer": req.Transfer})
}

// opPickFile / opPickSave 调系统原生对话框;对话框会阻塞,放到独立协程,
// 避免期间其它请求(例如 stop)无法处理。
func (b *Bridge) opPickFile(req request) {
	title := req.Title
	if title == "" {
		title = "选择文件"
	}
	go func() {
		path, err := filedialog.Open(title)
		b.replyPick(req.ID, path, err)
	}()
}

func (b *Bridge) opPickSave(req request) {
	title := req.Title
	if title == "" {
		title = "保存文件"
	}
	go func() {
		path, err := filedialog.Save(title, req.Name)
		b.replyPick(req.ID, path, err)
	}()
}

func (b *Bridge) replyPick(id, path string, err error) {
	if errors.Is(err, filedialog.ErrUnsupported) {
		b.errID(id, "当前平台不支持系统文件对话框,请手动输入完整路径")
		return
	}
	if err != nil {
		b.errID(id, "%v", err)
		return
	}
	if path == "" {
		b.send(map[string]any{"type": "ok", "id": id, "cancel": true})
		return
	}
	b.send(map[string]any{"type": "ok", "id": id, "path": path})
}

// transferEvent 把传输状态转为界面事件;回调来自多个传输协程。
func (b *Bridge) transferEvent(e transfer.Event) {
	fields := map[string]any{
		"type": "event", "name": "file-" + e.Kind,
		"transfer": e.ID, "peer": e.Peer, "file": e.Name,
		"size": e.Size, "incoming": e.Incoming,
	}
	if e.Kind == "progress" || e.Kind == "done" {
		fields["done"] = e.Done
	}
	if e.Kind != "offer" && e.Path != "" {
		fields["path"] = e.Path
	}
	if e.Kind == "done" {
		fields["ok"] = e.OK
		fields["error"] = e.Err
	}
	b.send(fields)
}

// opStun 从房间自身的 UDP 套接字探测公网映射;只有开房后套接字才存在。
// 探测是一次用户显式动作,不做后台轮询。
func (b *Bridge) opStun(req request) {
	b.mu.Lock()
	host, state := b.host, b.state
	b.mu.Unlock()
	if state != "hosting" || host == nil {
		b.errID(req.ID, "只有开房后才能探测公网地址")
		return
	}
	addr, err := host.ProbeSTUN(req.Server, 4*time.Second)
	if err != nil {
		b.errID(req.ID, "探测公网地址失败: %v", err)
		return
	}
	b.send(map[string]any{"type": "ok", "id": req.ID, "ip": addr.IP.String(), "port": addr.Port})
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
	if b.xfer != nil {
		b.xfer.Close()
		b.xfer = nil
	}
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
