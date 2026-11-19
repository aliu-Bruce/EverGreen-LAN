// Package mesh 实现多成员的加密星型局域网。
// 原则:主机持房间码(预共享密钥)与地址池;成员身份是公钥,地址变化自动跟随;
// 一个数据报一帧;广播与组播向全房间洪水;转发只看 IP 头的目的地址,不解释内容。
package mesh

import (
	"encoding/hex"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"eglan/internal/crypto"
	"eglan/internal/stream"
	"eglan/internal/stun"
)

// 帧魔数取 7~8 字节,远长于常见前缀,避免与真实 IP 包撞形:
// 控制帧长度(7/13 字节)都小于最小 IPv4 包(20 字节),数据帧不会误判成控制帧。
const (
	helloMagic  = "EGLANH1" // 成员 → 主机(明文):公钥 + 名字
	replyMagic  = "EGLANH2" // 主机 → 成员(明文):公钥 + 名字
	readyMagic  = "EGLANR1" // 成员 → 主机(加密):入房证明,凭房间码才造得出
	assignMagic = "EGLANA1" // 主机 → 成员(加密):分配的隧道地址

	nameMax    = 32
	pendingTTL = 10 * time.Second
	pendingCap = 8
)

// MemberInfo 是在房成员的对外快照,供界面与日志展示;JSON 名即为协议字段。
type MemberInfo struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
	Pub  string `json:"pub"`
}

// clipName 截断超长名字并保持 UTF-8 完整。
func clipName(name string) string {
	name = strings.TrimSpace(name)
	for len(name) > nameMax {
		name = name[:len(name)-1]
	}
	for len(name) > 0 && !utf8.ValidString(name) {
		name = name[:len(name)-1]
	}
	return name
}

// packHello 打包握手帧:魔数 + 32 字节公钥 + 1 字节名字长 + 名字。
func packHello(magic string, pub []byte, name string) []byte {
	b := make([]byte, 0, len(magic)+33+len(name))
	b = append(b, magic...)
	b = append(b, pub...)
	b = append(b, byte(len(name)))
	b = append(b, name...)
	return b
}

// parseHello 解析握手帧;名字长度不符即拒绝。
func parseHello(frame []byte, magic string) (pub []byte, name string, ok bool) {
	base := len(magic)
	if len(frame) < base+33 || string(frame[:base]) != magic {
		return nil, "", false
	}
	nl := int(frame[base+32])
	if nl > nameMax || len(frame) < base+33+nl {
		return nil, "", false
	}
	return frame[base : base+32], string(frame[base+33 : base+33+nl]), true
}

// cloneAddr 复制对端地址,避免引用读缓冲里的临时对象。
func cloneAddr(a *net.UDPAddr) *net.UDPAddr {
	return &net.UDPAddr{IP: append(net.IP(nil), a.IP...), Port: a.Port, Zone: a.Zone}
}

// Bind 只绑定 UDP 端口,不参与组网;需要先拿到端口号的调用方先 Bind 再 NewHostOn。
func Bind(port int) (*net.UDPConn, error) {
	return net.ListenUDP("udp", &net.UDPAddr{Port: port})
}

// ------------------------------------------------------------
// 成员一端:Guest
// ------------------------------------------------------------

// Guest 是房间里普通成员的一端:与主机一条加密通道,包都经主机中转。
type Guest struct {
	pc       *net.UDPConn
	remote   *net.UDPAddr
	sess     *crypto.Session
	pub      []byte
	hostName string
	selfNet  *net.IPNet
	flow     *stream.Session
}

// DialGuest 向主机发起加入:握手 → 入房证明 → 领取地址。
// 握手与证明都按固定间隔重发:单个数据报在网络上就是可能丢的。
func DialGuest(addr string, psk []byte, id *crypto.Identity, name string, timeout time.Duration) (*Guest, error) {
	raddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("mesh: 主机地址无效 %q: %w", addr, err)
	}
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, fmt.Errorf("mesh: 打开本地端口失败: %w", err)
	}
	deadline := time.Now().Add(timeout)
	if timeout == 0 {
		deadline = time.Now().Add(time.Hour)
	}
	hello := packHello(helloMagic, id.Pub, clipName(name))
	buf := make([]byte, 65535)

	// 阶段一:重复握手直到主机应答
	var hpub []byte
	var from *net.UDPAddr
	var hostName string
	for {
		attempt := min(2*time.Second, time.Until(deadline))
		if attempt <= 0 {
			pc.Close()
			return nil, fmt.Errorf("mesh: 等待主机应答超时(地址不通或房间码不对)")
		}
		if _, err := pc.WriteToUDP(hello, raddr); err != nil {
			pc.Close()
			return nil, fmt.Errorf("mesh: 发送握手失败: %w", err)
		}
		_ = pc.SetReadDeadline(time.Now().Add(attempt))
		n, rep, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		pub, hname, ok := parseHello(buf[:n], replyMagic)
		if !ok {
			continue // 无关流量
		}
		hpub, from, hostName = pub, rep, hname
		break
	}
	sess, err := crypto.Exchange(id, hpub, true, psk)
	if err != nil {
		pc.Close()
		return nil, err
	}

	// 阶段二:重复入房证明直到拿到地址;主机对重复证明幂等重发
	for {
		attempt := min(2*time.Second, time.Until(deadline))
		if attempt <= 0 {
			pc.Close()
			return nil, fmt.Errorf("mesh: 等待地址分配超时(房间码不对或主机已满)")
		}
		if _, err := pc.WriteToUDP(sess.Seal([]byte(readyMagic)), from); err != nil {
			pc.Close()
			return nil, fmt.Errorf("mesh: 发送入房证明失败: %w", err)
		}
		_ = pc.SetReadDeadline(time.Now().Add(attempt))
		n, _, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		payload, err := sess.Open(buf[:n])
		if err != nil {
			continue
		}
		ip, prefix, ok := parseAssign(payload)
		if !ok {
			continue
		}
		_ = pc.SetDeadline(time.Time{})
		cloneIP := append(net.IP(nil), ip...)
		g := &Guest{
			pc: pc, remote: cloneAddr(from), sess: sess,
			pub:      append([]byte(nil), hpub...),
			hostName: clipName(hostName),
			selfNet:  &net.IPNet{IP: cloneIP, Mask: net.CIDRMask(prefix, 32)},
		}
		g.flow = stream.NewSession(guestFlow{g})
		return g, nil
	}
}

// guestFlow 把流帧封进主机通道;目标固定是主机,忽略 dst。
type guestFlow struct{ g *Guest }

func (d guestFlow) Deliver(_ net.IP, data []byte) error { return d.g.Send(data) }

// Flow 返回成员侧的可靠流集合,供文件传输与插件宿主使用。
func (g *Guest) Flow() *stream.Session { return g.flow }

// Send 投递一个 IP 包到主机;单播与广播的去向由主机裁决。
func (g *Guest) Send(pkt []byte) error {
	if _, err := g.pc.WriteToUDP(g.sess.Seal(pkt), g.remote); err != nil {
		return fmt.Errorf("mesh: 发送失败: %w", err)
	}
	return nil
}

// Recv 取一个来自房间的 IP 包;无效帧与重复分配帧静默丢弃,继续等待。
func (g *Guest) Recv() ([]byte, error) {
	buf := make([]byte, 65535)
	for {
		n, _, err := g.pc.ReadFromUDP(buf)
		if err != nil {
			return nil, fmt.Errorf("mesh: 接收失败: %w", err)
		}
		payload, err := g.sess.Open(buf[:n])
		if err != nil {
			continue // 噪声或伪造帧
		}
		if isAssign(payload) {
			continue // 主机对重连的幂等重发,首帧分配在握手内已消费
		}
		if len(payload) > 0 && payload[0] < 0x40 {
			g.flow.Dispatch(g.hostTunnelIP(), payload)
			continue // 流帧交给可靠流层,不当作 IP 包
		}
		return payload, nil
	}
}

// hostTunnelIP 推算主机在房间内的隧道地址(子网首个可用地址)。
func (g *Guest) hostTunnelIP() net.IP {
	ip := g.selfNet.IP.To4()
	if ip == nil {
		return nil
	}
	base := make(net.IP, 4)
	for i := 0; i < 4; i++ {
		base[i] = ip[i] & g.selfNet.Mask[i]
	}
	base[3] |= 1
	return base
}

// SelfNet 返回主机分配的隧道地址副本。
func (g *Guest) SelfNet() *net.IPNet {
	return &net.IPNet{IP: append(net.IP(nil), g.selfNet.IP...), Mask: append(net.IPMask(nil), g.selfNet.Mask...)}
}

// HostName 返回主机显示名。
func (g *Guest) HostName() string { return g.hostName }

// HostIP 返回主机在房间内的隧道地址。
func (g *Guest) HostIP() net.IP { return g.hostTunnelIP() }

// PeerPub 返回主机公钥副本。
func (g *Guest) PeerPub() []byte { return append([]byte(nil), g.pub...) }

// Close 关闭套接字与全部流。
func (g *Guest) Close() error {
	if g.flow != nil {
		g.flow.Close()
	}
	return g.pc.Close()
}

// ------------------------------------------------------------
// 帧助手
// ------------------------------------------------------------

// parseAssign 解析分配帧:魔数 + 4 字节地址 + 1 字节前缀长。
func parseAssign(payload []byte) (net.IP, int, bool) {
	if len(payload) != len(assignMagic)+5 || string(payload[:len(assignMagic)]) != assignMagic {
		return nil, 0, false
	}
	prefix := int(payload[len(assignMagic)+4])
	if prefix < 1 || prefix > 32 {
		return nil, 0, false
	}
	return net.IP(payload[len(assignMagic) : len(assignMagic)+4]), prefix, true
}

// isAssign 与 isReady 依赖"控制帧长度必小于最小 IPv4 包"这一点区分数据。
func isAssign(payload []byte) bool {
	return len(payload) == len(assignMagic)+5 && string(payload[:len(assignMagic)]) == assignMagic
}

func isReady(payload []byte) bool {
	return len(payload) == len(readyMagic) && string(payload) == readyMagic
}

// isFlood 判断目的地址是否要向全房间复制:受限广播、子网广播、组播。
// 游戏的局域网发现靠广播与组播,这一类包必须全员可达。
func isFlood(dst net.IP, sub *net.IPNet) bool {
	if dst.Equal(net.IPv4bcast) || dst[0]&0xF0 == 0xE0 {
		return true
	}
	if len(sub.IP) == 4 && len(sub.Mask) == 4 {
		b := make(net.IP, 4)
		for i := 0; i < 4; i++ {
			b[i] = sub.IP[i] | ^sub.Mask[i]
		}
		return dst.Equal(b)
	}
	return false
}

// ------------------------------------------------------------
// 主机一端:Host
// ------------------------------------------------------------

// member 是主机关心的单个成员;pend 期间未通过入房证明,不占地址。
type member struct {
	addr *net.UDPAddr
	pub  string
	sess *crypto.Session
	name string
	ip   net.IP
	at   time.Time
	pend bool
}

// Host 是房间主端:掌管地址池,凭入房证明验证成员,在成员之间转发 IP 包。
type Host struct {
	pc     *net.UDPConn
	psk    []byte
	id     *crypto.Identity
	name   string
	subnet *net.IPNet
	selfIP net.IP

	mu     sync.RWMutex
	byAddr map[string]*member
	byPub  map[string]*member
	byIP   map[string]*member
	next   byte

	stunMu sync.Mutex
	stuns  map[stun.TransactionID]stunPending

	localOut  chan []byte
	done      chan struct{}
	closeOnce sync.Once
	sendMu    sync.Mutex // 会话封包内含发送计数器,并发封包必须串行

	flow *stream.Session
}

// NewHost 绑定端口并构造主机;调用 Start 开始收包。
func NewHost(port int, psk []byte, id *crypto.Identity, name, cidr string) (*Host, error) {
	pc, err := net.ListenUDP("udp", &net.UDPAddr{Port: port})
	if err != nil {
		return nil, fmt.Errorf("mesh: 监听端口 %d 失败: %w", port, err)
	}
	return NewHostOn(pc, psk, id, name, cidr)
}

// NewHostOn 在已绑定的套接字上构造主机。
// cidr 形如 10.66.7.1/24:本机取其中地址,成员从同段依次分配。
func NewHostOn(pc *net.UDPConn, psk []byte, id *crypto.Identity, name, cidr string) (*Host, error) {
	ip, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		pc.Close()
		return nil, fmt.Errorf("mesh: 地址段无效 %q: %w", cidr, err)
	}
	selfIP := ip.To4()
	if selfIP == nil {
		pc.Close()
		return nil, fmt.Errorf("mesh: 仅支持 IPv4 地址段")
	}
	h := &Host{
		pc: pc, psk: psk, id: id, name: clipName(name),
		subnet: ipnet, selfIP: selfIP,
		byAddr: map[string]*member{}, byPub: map[string]*member{}, byIP: map[string]*member{},
		next:     2,
		stuns:    map[stun.TransactionID]stunPending{},
		localOut: make(chan []byte, 256),
		done:     make(chan struct{}),
	}
	h.flow = stream.NewSession(hostFlow{h})
	return h, nil
}

// hostFlow 把流帧加密投递给房间成员;成员地址即隧道地址。
type hostFlow struct{ h *Host }

func (d hostFlow) Deliver(dst net.IP, data []byte) error {
	if dst == nil {
		return stream.ErrNoRoute
	}
	d.h.mu.RLock()
	m := d.h.byIP[dst.String()]
	d.h.mu.RUnlock()
	if m == nil {
		return stream.ErrNoRoute
	}
	d.h.rawSend(m, data)
	return nil
}

// Flow 返回主机侧的可靠流集合,供文件传输与插件宿主使用。
func (h *Host) Flow() *stream.Session { return h.flow }

// SelfIP 返回主机在房间内的隧道地址。
func (h *Host) SelfIP() net.IP { return append(net.IP(nil), h.selfIP...) }

// Start 启动接收循环,直到 Close 或套接字出错。
func (h *Host) Start() {
	go h.loop()
}

func (h *Host) loop() {
	buf := make([]byte, 65535)
	for {
		n, from, err := h.pc.ReadFromUDP(buf)
		if err != nil {
			return // Close 已关闭套接字,循环自然结束
		}
		h.handle(from, buf[:n])
	}
}

// handle 按帧类型分派:STUN 探测响应优先,握手登记,数据转发。
func (h *Host) handle(from *net.UDPAddr, frame []byte) {
	if h.handleSTUN(from, frame) {
		return
	}
	if _, name, ok := parseHello(frame, helloMagic); ok {
		h.handshake(from, frame[len(helloMagic):len(helloMagic)+32], name)
		return
	}
	h.mu.RLock()
	m := h.byAddr[from.String()]
	h.mu.RUnlock()
	if m == nil {
		return // 未握手的来源,丢弃
	}
	payload, err := m.sess.Open(frame)
	if err != nil {
		return // 无效帧
	}
	if m.pend {
		if !isReady(payload) {
			return // 入房前只认入房证明
		}
		h.admit(m)
		h.sendAssign(m)
		return
	}
	if isReady(payload) {
		h.sendAssign(m) // 成员丢了分配帧,幂等重发
		return
	}
	h.dispatch(m, payload)
}

// stunPending 是一次等待中的 STUN 探测:只接受来自目标服务器的响应。
type stunPending struct {
	server *net.UDPAddr
	reply  chan stunResult
}

type stunResult struct {
	addr *net.UDPAddr
	err  error
}

// ProbeSTUN 从房间自身的 UDP 套接字向 STUN 服务器发一次 Binding 请求,
// 返回该套接字在 NAT 上被映射到的公网地址。响应在 Host 收包循环里按
// 事务标识与来源地址双重匹配,其他来源的报文一律不当成探测结果。
func (h *Host) ProbeSTUN(server string, timeout time.Duration) (*net.UDPAddr, error) {
	raddr, err := resolveSTUNServer(server)
	if err != nil {
		return nil, err
	}
	tx, err := stun.NewTransactionID()
	if err != nil {
		return nil, err
	}
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	reply := make(chan stunResult, 1)
	h.stunMu.Lock()
	h.stuns[tx] = stunPending{server: raddr, reply: reply}
	h.stunMu.Unlock()
	defer func() {
		h.stunMu.Lock()
		delete(h.stuns, tx)
		h.stunMu.Unlock()
	}()

	if _, err := h.pc.WriteToUDP(stun.BuildBindingRequest(tx), raddr); err != nil {
		return nil, fmt.Errorf("stun: 发送探测请求失败: %w", err)
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case r := <-reply:
		if r.err != nil {
			return nil, r.err
		}
		return r.addr, nil
	case <-timer.C:
		return nil, fmt.Errorf("stun: 等待 %s 响应超时", raddr)
	case <-h.done:
		return nil, fmt.Errorf("stun: 房间已结束")
	}
}

// handleSTUN 在收包循环里消费 STUN 响应;返回 true 表示该报文不应再按房间帧处理。
func (h *Host) handleSTUN(from *net.UDPAddr, frame []byte) bool {
	if !stun.IsMessage(frame) {
		return false
	}
	tx, ok := stun.TransactionIDOf(frame)
	if !ok {
		return true
	}
	h.stunMu.Lock()
	p, waiting := h.stuns[tx]
	if !waiting || !from.IP.Equal(p.server.IP) || from.Port != p.server.Port {
		h.stunMu.Unlock()
		return true // 未知事务或非目标服务器:静默丢弃
	}
	delete(h.stuns, tx)
	h.stunMu.Unlock()
	addr, err := stun.ParseSuccess(frame)
	p.reply <- stunResult{addr: addr, err: err}
	return true
}

// resolveSTUNServer 只解析 IPv4 服务器地址;省略端口时补 STUN 默认端口 3478。
func resolveSTUNServer(server string) (*net.UDPAddr, error) {
	server = strings.TrimSpace(server)
	if server == "" {
		server = stun.DefaultServer
	}
	host, port, err := net.SplitHostPort(server)
	if err != nil {
		host, port = server, "3478"
	}
	if host == "" || port == "" {
		return nil, fmt.Errorf("stun: 服务器地址无效 %q", server)
	}
	raddr, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(host, port))
	if err != nil {
		return nil, fmt.Errorf("stun: 无法解析服务器 %q: %w", server, err)
	}
	return raddr, nil
}

// handshake 登记 or 刷新成员:老成员按公钥认出,换地址换会话,保留隧道地址。
// 新成员先记为 pending:只有随后第一帧入房证明能通过认证,通过才分配地址;
// 未证明者按期清理,不占地址池。
func (h *Host) handshake(from *net.UDPAddr, pub []byte, name string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.prunePending()
	key := hex.EncodeToString(pub)
	if m, ok := h.byPub[key]; ok {
		if old := m.addr.String(); old != from.String() {
			delete(h.byAddr, old)
			h.byAddr[from.String()] = m
		}
		m.addr = cloneAddr(from)
		sess, err := crypto.Exchange(h.id, pub, false, h.psk)
		if err != nil {
			return
		}
		m.sess, m.at, m.pend = sess, time.Now(), true
		m.name = clipName(name) // 重连可换名,以最新一次握手为准
	} else {
		if h.pendingCount() >= pendingCap {
			return // 握手洪泛上限,丢弃
		}
		sess, err := crypto.Exchange(h.id, pub, false, h.psk)
		if err != nil {
			return
		}
		m := &member{addr: cloneAddr(from), pub: key, sess: sess, name: clipName(name), at: time.Now(), pend: true}
		h.byAddr[from.String()] = m
		h.byPub[key] = m
	}
	h.writeTo(from, packHello(replyMagic, h.id.Pub, h.name))
}

// admit 通过入房证明:从地址池分配隧道地址,晋升为正式成员。
func (h *Host) admit(m *member) {
	m.pend = false
	if m.ip == nil {
		ip := h.allocate()
		if ip == nil {
			m.pend = true // 地址池满:不入房,成员将因拿不到地址而自行退避
			return
		}
		m.ip = ip
		h.byIP[ip.String()] = m
	}
	m.at = time.Now()
}

// allocate 从地址段按序取空闲地址;全满返回 nil。
func (h *Host) allocate() net.IP {
	for i := 0; i < 253; i++ {
		octet := h.next
		h.next++
		if h.next > 254 {
			h.next = 2
		}
		ip := net.IPv4(h.selfIP[0], h.selfIP[1], h.selfIP[2], octet).To4()
		if _, taken := h.byIP[ip.String()]; !taken {
			return ip
		}
	}
	return nil
}

// dispatch 把成员发来的数据分派:流帧交给可靠流层,其余按 IPv4 处理。
// 本机地址交给本机协议栈;广播与组播向全房间洪水;其余按目的地址单播转发。
func (h *Host) dispatch(m *member, pkt []byte) {
	if len(pkt) > 0 && pkt[0] < 0x40 {
		h.flow.Dispatch(m.ip, pkt) // 流帧首字节为帧类型(1~4),与 IPv4 首字节(0x4x)不重叠
		return
	}
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return // 只转发 IPv4
	}
	dst := net.IP(pkt[16:20])
	if dst.Equal(h.selfIP) {
		h.emit(pkt)
		return
	}
	if isFlood(dst, h.subnet) {
		h.flood(m.addr.String(), pkt)
		h.emit(pkt)
		return
	}
	h.mu.RLock()
	to := h.byIP[dst.String()]
	h.mu.RUnlock()
	if to != nil {
		h.rawSend(to, pkt)
	}
	// 未知目的(段外等)按无路由丢弃
}

// Send 把本机协议栈发出的 IP 包送进房间:单播按目的转发,广播与组播洪水全房间。
func (h *Host) Send(pkt []byte) error {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return nil
	}
	dst := net.IP(pkt[16:20])
	if !isFlood(dst, h.subnet) {
		h.mu.RLock()
		to := h.byIP[dst.String()]
		h.mu.RUnlock()
		if to != nil {
			h.rawSend(to, pkt)
		}
		return nil
	}
	h.mu.RLock()
	targets := make([]*member, 0, len(h.byAddr))
	for _, m := range h.byAddr {
		if !m.pend && m.ip != nil {
			targets = append(targets, m)
		}
	}
	h.mu.RUnlock()
	for _, m := range targets {
		h.rawSend(m, pkt)
	}
	return nil
}

// Members 返回在房成员快照,按隧道地址排序,供界面稳定展示。
func (h *Host) Members() []MemberInfo {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]MemberInfo, 0, len(h.byIP))
	for _, m := range h.byIP {
		out = append(out, MemberInfo{Name: m.name, IP: m.ip.String(), Pub: m.pub})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].IP < out[j].IP
	})
	return out
}

// LocalOut 是交付给本机协议栈的包队列(到主机自身的与广播/组播副本)。
func (h *Host) LocalOut() <-chan []byte { return h.localOut }

// Done 返回结束信号,等待方在 Close 后据此及时退出。
func (h *Host) Done() <-chan struct{} { return h.done }

// Close 关闭套接字并发出结束信号;幂等,重复调用安全。
func (h *Host) Close() error {
	h.closeOnce.Do(func() {
		close(h.done)
		if h.flow != nil {
			h.flow.Close()
		}
		_ = h.pc.Close()
	})
	return nil
}

// writeTo 直接写套接字给指定地址,错误忽略(UDP 无重传,按丢包处理)。
func (h *Host) writeTo(to *net.UDPAddr, frame []byte) {
	_, _ = h.pc.WriteToUDP(frame, to)
}

// rawSend 加密后投递给成员;封包串行化,保护会话内的发送计数器。
func (h *Host) rawSend(m *member, pkt []byte) {
	h.sendMu.Lock()
	defer h.sendMu.Unlock()
	h.writeTo(m.addr, m.sess.Seal(pkt))
}

// sendAssign 把分配帧(加密)发给成员。
func (h *Host) sendAssign(m *member) {
	if m.ip == nil {
		return
	}
	ones, _ := h.subnet.Mask.Size()
	p := make([]byte, 0, len(assignMagic)+5)
	p = append(p, assignMagic...)
	p = append(p, m.ip...)
	p = append(p, byte(ones))
	h.writeTo(m.addr, m.sess.Seal(p))
}

// flood 向除来源以外的全部正式成员复制一份。
func (h *Host) flood(fromKey string, pkt []byte) {
	h.mu.RLock()
	targets := make([]*member, 0, len(h.byAddr))
	for k, m := range h.byAddr {
		if k != fromKey && !m.pend && m.ip != nil {
			targets = append(targets, m)
		}
	}
	h.mu.RUnlock()
	for _, m := range targets {
		h.rawSend(m, pkt)
	}
}

// emit 把包排进本机交付队列;队列满即丢,转发不该被慢消费方堵住。
func (h *Host) emit(pkt []byte) {
	select {
	case <-h.done:
		return
	case h.localOut <- pkt:
	default:
	}
}

func (h *Host) prunePending() {
	now := time.Now()
	for k, m := range h.byAddr {
		if m.pend && now.Sub(m.at) > pendingTTL {
			delete(h.byAddr, k)
			delete(h.byPub, m.pub)
		}
	}
}

func (h *Host) pendingCount() int {
	n := 0
	for _, m := range h.byAddr {
		if m.pend {
			n++
		}
	}
	return n
}
