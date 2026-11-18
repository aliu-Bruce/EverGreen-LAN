// Package disc 负责局域网房间发现:主机周期向所在网段广播信标,
// 空闲实例监听并汇总为房间列表。
// 原则:发现只回答"同一网段里有哪些房间";入房仍由房间码派生密钥认证。
// 信标只在同一广播域内可见,边界即"同一 WiFi"。
package disc

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"eglan/internal/room"
)

const (
	// Port 是发现信标的固定 UDP 端口,与房间转发的监听端口分开,
	// 空闲实例才能持续监听而不占用房间端口。
	Port = 47778

	beaconVersion = 1
	beaconEvery   = 2 * time.Second // 播报周期:过期前至少三次机会
	roomTTL       = 6 * time.Second // 三轮未闻即视为房间消失
	expireEvery   = 1 * time.Second
	nameMax       = 32
	codeMin       = 4
	codeMax       = 32
)

// Beacon 是一条发现信标的线上形态;JSON 字段名即协议字段。
type Beacon struct {
	Version int    `json:"eglan"`
	Name    string `json:"name"`
	Code    string `json:"code"` // 原始房间码:同网段即可见,列表里不展示
	Peer    string `json:"peer"` // 主机地址 host:port
	Members int    `json:"members"`
}

// Marshal 编码一条信标。
func (b Beacon) Marshal() ([]byte, error) {
	return json.Marshal(b)
}

// ParseBeacon 校验并归一一条信标;不是本协议的报文一律判假。
// 校验在入口完成,监听侧只接触已清洗的字段。
func ParseBeacon(data []byte) (Beacon, bool) {
	var b Beacon
	if err := json.Unmarshal(data, &b); err != nil {
		return Beacon{}, false
	}
	if b.Version != beaconVersion {
		return Beacon{}, false
	}
	b.Name = clipName(b.Name)
	if b.Name == "" {
		return Beacon{}, false
	}
	b.Code = string(room.Normalize(b.Code))
	if len(b.Code) < codeMin || len(b.Code) > codeMax {
		return Beacon{}, false
	}
	if !validPeer(b.Peer) {
		return Beacon{}, false
	}
	if b.Members < 1 {
		b.Members = 1
	}
	if b.Members > 256 {
		b.Members = 256
	}
	return b, true
}

// Room 是监听侧对界面的房间快照;JSON 字段名即协议字段。
type Room struct {
	Name    string `json:"name"`
	Code    string `json:"code"`
	Peer    string `json:"peer"`
	Members int    `json:"members"`
}

type entry struct {
	room Room
	seen time.Time
}

// Listener 监听发现端口,维护一份按房间码去重的短期房间表。
// 首次出现、内容变化与过期删除时才回调,安静时不产生事件。
type Listener struct {
	pc       *net.UDPConn
	onChange func([]Room)

	mu     sync.Mutex
	rooms  map[string]entry
	closed bool

	notifyMu sync.Mutex
	done     chan struct{}
	once     sync.Once
	wg       sync.WaitGroup
}

// Listen 在 UDP 端口上监听信标;传 0 由系统分配,供自检使用。
// 多个实例同机运行时经 SO_REUSEADDR 共享端口。
func Listen(port int, onChange func([]Room)) (*Listener, error) {
	pc, err := listenReuse(port)
	if err != nil {
		return nil, fmt.Errorf("disc: 监听 UDP %d 失败: %w", port, err)
	}
	l := &Listener{
		pc:       pc,
		onChange: onChange,
		rooms:    map[string]entry{},
		done:     make(chan struct{}),
	}
	l.wg.Add(2)
	go l.readLoop()
	go l.expireLoop()
	return l, nil
}

// Port 返回实际监听端口。
func (l *Listener) Port() int {
	return l.pc.LocalAddr().(*net.UDPAddr).Port
}

// Close 停止监听并等待协程退出;幂等。
func (l *Listener) Close() error {
	l.once.Do(func() {
		l.mu.Lock()
		l.closed = true
		l.mu.Unlock()
		close(l.done)
		_ = l.pc.Close()
	})
	l.wg.Wait()
	return nil
}

func (l *Listener) readLoop() {
	defer l.wg.Done()
	buf := make([]byte, 2048)
	for {
		n, _, err := l.pc.ReadFromUDP(buf)
		if err != nil {
			return // Close 已关闭套接字
		}
		b, ok := ParseBeacon(buf[:n])
		if !ok {
			continue
		}
		l.observe(b)
	}
}

// observe 记录一条有效信标;只有内容实际变化才触发回调。
func (l *Listener) observe(b Beacon) {
	r := Room{Name: b.Name, Code: b.Code, Peer: b.Peer, Members: b.Members}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	old, exists := l.rooms[r.Code]
	l.rooms[r.Code] = entry{room: r, seen: time.Now()}
	l.mu.Unlock()
	if !exists || old.room != r {
		l.notify()
	}
}

// expireLoop 定期清掉久未刷新的房间:主机退出后列表随之消失。
func (l *Listener) expireLoop() {
	defer l.wg.Done()
	t := time.NewTicker(expireEvery)
	defer t.Stop()
	for {
		select {
		case <-l.done:
			return
		case now := <-t.C:
			l.mu.Lock()
			changed := false
			for code, e := range l.rooms {
				if now.Sub(e.seen) > roomTTL {
					delete(l.rooms, code)
					changed = true
				}
			}
			l.mu.Unlock()
			if changed {
				l.notify()
			}
		}
	}
}

// notify 推送一份排序后的快照;串行化保证事件顺序与快照一致。
func (l *Listener) notify() {
	l.notifyMu.Lock()
	defer l.notifyMu.Unlock()

	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	list := make([]Room, 0, len(l.rooms))
	for _, e := range l.rooms {
		list = append(list, e.room)
	}
	l.mu.Unlock()

	sort.Slice(list, func(i, j int) bool {
		if list[i].Name != list[j].Name {
			return list[i].Name < list[j].Name
		}
		return list[i].Code < list[j].Code
	})
	if l.onChange != nil {
		l.onChange(list)
	}
}

// AnnounceConfig 描述一台主机的播报内容。
// Members 每轮取值,人数变化不必重启播报器。
type AnnounceConfig struct {
	Name    string
	Code    string
	Port    int // 房间转发端口,与网卡地址拼成 peer
	Members func() int
}

// Announcer 周期向各网卡所在子网广播信标。
type Announcer struct {
	cfg  AnnounceConfig
	pc   *net.UDPConn
	done chan struct{}
	once sync.Once
	wg   sync.WaitGroup
}

// Announce 启动播报;首条信标立即发出,之后按固定周期重复。
func Announce(cfg AnnounceConfig) (*Announcer, error) {
	cfg.Code = string(room.Normalize(cfg.Code))
	if cfg.Code == "" {
		return nil, fmt.Errorf("disc: 房间码为空,无法播报")
	}
	if cfg.Port == 0 {
		cfg.Port = 47777
	}
	if cfg.Members == nil {
		cfg.Members = func() int { return 1 }
	}
	pc, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil, fmt.Errorf("disc: 创建播报套接字失败: %w", err)
	}
	a := &Announcer{cfg: cfg, pc: pc, done: make(chan struct{})}
	a.wg.Add(1)
	go a.loop()
	return a, nil
}

// Close 停止播报;幂等。
func (a *Announcer) Close() error {
	a.once.Do(func() {
		close(a.done)
		_ = a.pc.Close()
	})
	a.wg.Wait()
	return nil
}

func (a *Announcer) loop() {
	defer a.wg.Done()
	a.send()
	t := time.NewTicker(beaconEvery)
	defer t.Stop()
	for {
		select {
		case <-a.done:
			return
		case <-t.C:
			a.send()
		}
	}
}

// send 向每张可用网卡的子网广播地址各发一条信标。
// peer 取该网卡自己的地址:接收方拿到的永远是本网段可达的那个。
func (a *Announcer) send() {
	members := a.cfg.Members()
	if members < 1 {
		members = 1
	}
	for _, t := range targets() {
		b := Beacon{
			Version: beaconVersion,
			Name:    a.cfg.Name,
			Code:    a.cfg.Code,
			Peer:    net.JoinHostPort(t.ip.String(), strconv.Itoa(a.cfg.Port)),
			Members: members,
		}
		data, err := b.Marshal()
		if err != nil {
			continue
		}
		_, _ = a.pc.WriteToUDP(data, &net.UDPAddr{IP: t.bcast, Port: Port})
	}
}

// target 是一张网卡的播报参数:自己的地址与子网广播地址。
type target struct {
	ip    net.IP
	bcast net.IP
}

// targets 枚举可播报的网卡:跳过环回与隧道网卡。
// 隧道网卡名称以 EGLAN 开头,信标灌进去只会绕回本机。
func targets() []target {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []target
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		if strings.HasPrefix(strings.ToUpper(ifi.Name), "EGLAN") {
			continue
		}
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip == nil {
				continue
			}
			ones, bits := ipnet.Mask.Size()
			if bits != 32 || ones >= 31 {
				continue // 无广播地址的网段
			}
			bcast := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bcast[i] = ip[i] | ^ipnet.Mask[i]
			}
			out = append(out, target{ip: ip, bcast: bcast})
		}
	}
	return out
}

// LocalPeers 返回本机各可用网卡的 host:port,供界面展示局域网地址。
// 跳过环回、隧道网卡与无广播地址的接口;同一地址只保留一次。
func LocalPeers(port int) []string {
	seen := map[string]bool{}
	out := make([]string, 0, 2)
	for _, t := range targets() {
		ip := t.ip.String()
		if seen[ip] {
			continue
		}
		seen[ip] = true
		out = append(out, net.JoinHostPort(ip, strconv.Itoa(port)))
	}
	return out
}

func listenReuse(port int) (*net.UDPConn, error) {
	lc := net.ListenConfig{Control: reuseAddr}
	pc, err := lc.ListenPacket(context.Background(), "udp4", fmt.Sprintf(":%d", port))
	if err != nil {
		return nil, err
	}
	return pc.(*net.UDPConn), nil
}

// clipName 截断超长名字并保持 UTF-8 完整。
func clipName(name string) string {
	name = strings.TrimSpace(name)
	if len(name) > nameMax {
		cut := nameMax
		for cut > 0 && !utf8.ValidString(name[:cut]) {
			cut--
		}
		name = name[:cut]
	}
	return strings.TrimSpace(name)
}

// validPeer 只接受 IPv4 地址加端口:信标里的地址直接用于入房连接。
func validPeer(peer string) bool {
	host, port, err := net.SplitHostPort(peer)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return false
	}
	n, err := strconv.Atoi(port)
	return err == nil && n > 0 && n < 65536
}
