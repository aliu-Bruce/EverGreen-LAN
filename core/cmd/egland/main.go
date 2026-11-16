// egland 是 EverGreen LAN 的核心命令行入口。
// P1 提供两种能力:
//
//	-test-echo        进程内自检:三人房间网全链路,不建网卡、不需管理员;
//	-role host|client 真实模式:建虚拟网卡,把本机经网卡进出的 IP 包送入房间。
//
// 房间码是唯一凭证:归一化后作为预共享密钥混入密钥派生,持码者才能入房。
// 转发原则:只搬运 IP 包,不改内容、不辨协议;一切服务(如 ping、游戏)
// 都由成员操作系统的协议栈照常处理,本进程对它们透明。
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"os/user"
	"runtime"
	"strings"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/mesh"
	"eglan/internal/room"
	"eglan/internal/tun"
)

func main() {
	var (
		role    = flag.String("role", "host", "角色:host(开房间)/ client(加入)")
		code    = flag.String("code", "", "房间码;host 留空则自动生成")
		name    = flag.String("name", defaultName(), "房间内显示名")
		ip      = flag.String("ip", "", "host 的隧道地址段,如 10.66.7.1/24;默认 10.66.7.1/24")
		listen  = flag.Int("listen", 47777, "host 监听的 UDP 端口")
		peer    = flag.String("peer", "", "client 要连接的主机地址 host:port")
		adapter = flag.String("adapter", "EGLAN", "虚拟网卡名称")
		mtu     = flag.Int("mtu", 1400, "虚拟网卡 MTU")
		echo    = flag.Bool("test-echo", false, "进程内自检,不需要管理员")
	)
	flag.Parse()

	// 裸启动(如双击)不开任何模式,只给说明窗口并等回车,绝不闪退
	if len(os.Args) == 1 {
		banner()
		return
	}

	var err error
	if *echo {
		err = testEcho()
	} else {
		err = relay(*role, *code, *name, *ip, *peer, *listen, *adapter, *mtu)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "eglan:", err)
		waitIfConsole()
		os.Exit(1)
	}
}

// banner 是无参数启动时的说明窗口:P1 阶段是命令行核心,图形界面随后接入。
func banner() {
	fmt.Print(`EverGreen LAN 核心 · P1(命令行阶段,图形界面随界面客户端接入)
把本机加入一个虚拟局域网房间;创建虚拟网卡需要管理员权限。

  egland -test-echo                    免管理员自检:房间网全链路
  egland -role host                    开房间:自动生成房间码,以管理员运行
  egland -role client -code 房间码 -peer 主机IP:47777
                                       加入房间:以管理员运行

按回车键退出...`)
	bufio.NewReader(os.Stdin).ReadString('\n')
}

// waitIfConsole 在交互式控制台下等一次回车再退出,窗口不闪退;
// 输出被重定向(脚本调用)时不等待。
func waitIfConsole() {
	if fi, err := os.Stdout.Stat(); err == nil && (fi.Mode()&os.ModeCharDevice) != 0 {
		fmt.Println()
		fmt.Println("按回车键退出...")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
}

// defaultName 给未指定名字的成员起默认名:Player-系统用户名。
func defaultName() string {
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

// relay 真实模式:建网卡、入房间,双泵转发直至出错或收到中断。
func relay(role, code, name, ip, peer string, listen int, adapter string, mtu int) error {
	switch role {
	case "host", "client":
	default:
		return fmt.Errorf("未知角色 %q,应为 host 或 client", role)
	}
	if role == "client" {
		if peer == "" {
			return fmt.Errorf("client 模式需要 -peer 主机地址(host:port)")
		}
		if code == "" {
			return fmt.Errorf("client 模式需要 -code 房间码(向房主索取)")
		}
	} else if code == "" {
		// host 未给码则当场生成:房间码只在主机一侧诞生
		generated, err := room.NewCode()
		if err != nil {
			return err
		}
		code = generated
	}
	psk := room.Normalize(code)
	if len(psk) == 0 {
		return fmt.Errorf("房间码无效")
	}
	id, err := crypto.NewIdentity()
	if err != nil {
		return err
	}

	// 中断时关闭房间连接;网卡由 defer 统一归还,不在信号处理里动它
	interrupted := make(chan struct{})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	done := make(chan error, 2)
	if role == "host" {
		cidr := ip
		if cidr == "" {
			cidr = "10.66.7.1/24"
		}
		// 先做需要权限的操作,再开监听:网卡建不起来时第一时间给出明确报错
		dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
		if err != nil {
			return err
		}
		defer dev.Close()
		openFirewall(listen)
		pc, err := mesh.Bind(listen)
		if err != nil {
			return fmt.Errorf("监听 UDP 端口 %d 失败: %w", listen, err)
		}
		h, err := mesh.NewHostOn(pc, psk, id, name, cidr)
		if err != nil {
			pc.Close()
			return err
		}
		go func() {
			<-sig
			close(interrupted)
			h.Close()
		}()
		h.Start()
		fmt.Printf("虚拟网卡 %s(%s)就绪\n", dev.Name(), cidr)
		fmt.Printf("房间已开放,房间码:%s(把码告诉想加入的伙伴)\n", room.Display(code))
		fmt.Printf("监听 UDP :%d;此窗口保持打开,Ctrl+C 退出\n", listen)
		go pumpOut(dev, h, done)                                         // 网卡 → 房间
		go pumpIn(hostRecv{ch: h.LocalOut(), done: h.Done()}, dev, done) // 房间 → 网卡
		return cleanExit(<-done, interrupted)
	}

	// client:先入房拿地址,再按分配到的地址建网卡
	fmt.Printf("以房间码 %s 加入 %s ...\n", room.Display(code), peer)
	g, err := mesh.DialGuest(peer, psk, id, name, 15*time.Second)
	if err != nil {
		return err
	}
	defer g.Close()
	cidr := g.SelfNet().String()
	dev, err := tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
	if err != nil {
		return err
	}
	defer dev.Close()
	go func() {
		<-sig
		close(interrupted)
		g.Close()
	}()
	fmt.Printf("虚拟网卡 %s(%s)就绪;房间主机 %s(公钥 %x...)\n", dev.Name(), cidr, g.HostName(), g.PeerPub()[:8])
	fmt.Println("此窗口保持打开;Ctrl+C 退出")
	go pumpOut(dev, g, done) // 网卡 → 房间
	go pumpIn(g, dev, done)  // 房间 → 网卡
	return cleanExit(<-done, interrupted)
}

// cleanExit 把中断引起的退出还原成正常退出,不让 Ctrl+C 报错。
func cleanExit(err error, interrupted <-chan struct{}) error {
	select {
	case <-interrupted:
		return nil
	default:
		return err
	}
}

// hostRecv 把主机的本机交付队列适配成接收器:泵只认 Recv。
type hostRecv struct {
	ch   <-chan []byte
	done <-chan struct{}
}

func (r hostRecv) Recv() ([]byte, error) {
	select {
	case pkt := <-r.ch:
		return pkt, nil
	case <-r.done:
		return nil, fmt.Errorf("房间已结束")
	}
}

// packetSender / packetReceiver 是主机与成员共用的转发接口。
type (
	packetSender   interface{ Send(pkt []byte) error }
	packetReceiver interface{ Recv() ([]byte, error) }
)

// pumpOut 从网卡读 IP 包送入房间:单播按目的转发,广播与组播洪水全房。
func pumpOut(dev tun.Device, to packetSender, done chan<- error) {
	for {
		pkt, err := dev.Read()
		if err != nil {
			done <- fmt.Errorf("网卡读取结束: %w", err)
			return
		}
		if err := to.Send(pkt); err != nil {
			done <- fmt.Errorf("房间发送结束: %w", err)
			return
		}
	}
}

// pumpIn 从房间收 IP 包,注入本机协议栈。
func pumpIn(from packetReceiver, dev tun.Device, done chan<- error) {
	for {
		pkt, err := from.Recv()
		if err != nil {
			done <- fmt.Errorf("房间接收结束: %w", err)
			return
		}
		if err := dev.Write(pkt); err != nil {
			done <- fmt.Errorf("网卡写入结束: %w", err)
			return
		}
	}
}

// testEcho 在进程内走一遍三人房间网全链路:
// 房间码握手与地址分配 → 成员间单播 → 广播洪水 → 交付主机本机 →
// 错房间码拒绝 → 成员名册 → 防重放。
// 全程不建网卡,因此不需要管理员权限。
func testEcho() error {
	check := func(name string, cond bool) {
		mark := "PASS"
		if !cond {
			mark = "FAIL"
		}
		fmt.Printf("%s %s\n", mark, name)
		if !cond {
			os.Exit(1)
		}
	}

	psk := room.Normalize("TESTCODE")
	hostID, err := crypto.NewIdentity()
	if err != nil {
		return err
	}
	g1ID, err := crypto.NewIdentity()
	if err != nil {
		return err
	}
	g2ID, err := crypto.NewIdentity()
	if err != nil {
		return err
	}

	// 先绑定拿到确定端口,再构造主机:两步分开,消除重绑竞态
	pc, err := mesh.Bind(0)
	if err != nil {
		return err
	}
	host, err := mesh.NewHostOn(pc, psk, hostID, "主机", "10.66.7.1/24")
	if err != nil {
		pc.Close()
		return err
	}
	host.Start()
	time.Sleep(100 * time.Millisecond) // 留出让接收循环进入等待的间隙
	addr := fmt.Sprintf("127.0.0.1:%d", pc.LocalAddr().(*net.UDPAddr).Port)

	g1, err := mesh.DialGuest(addr, psk, g1ID, "甲", 5*time.Second)
	if err != nil {
		host.Close()
		return err
	}
	defer g1.Close()
	g2, err := mesh.DialGuest(addr, psk, g2ID, "乙", 5*time.Second)
	if err != nil {
		host.Close()
		return err
	}
	defer g2.Close()

	ip1 := g1.SelfNet().IP.To4()
	ip2 := g2.SelfNet().IP.To4()
	check("握手与地址分配(两成员各得一址)", ip1 != nil && ip2 != nil && !ip1.Equal(ip2))

	// 成员间单播:甲发往乙,经主机按目的地址转发
	u1 := fakePkt(ip1, ip2, "unicast-A2B")
	if err := g1.Send(u1); err != nil {
		return err
	}
	got, ok := recvWithin(g2, 3*time.Second)
	check("成员间单播经主机转发", ok && bytes.Equal(got, u1))

	// 广播洪水:乙发受限广播,甲与主机本机都该收到,发方自身不收
	bc := fakePkt(ip2, net.IPv4bcast.To4(), "lan-discover")
	if err := g2.Send(bc); err != nil {
		return err
	}
	local := hostRecv{ch: host.LocalOut(), done: host.Done()}
	gotB1, okB1 := recvWithin(g1, 3*time.Second)
	gotLocal, okLocal := recvWithin(local, 3*time.Second)
	check("广播洪水:其他成员收到副本", okB1 && bytes.Equal(gotB1, bc))
	check("广播洪水:主机本机收到副本", okLocal && bytes.Equal(gotLocal, bc))

	// 目的为主机自身地址的包:交付本机队列,不转发
	th := fakePkt(ip1, net.IPv4(10, 66, 7, 1).To4(), "to-host")
	if err := g1.Send(th); err != nil {
		return err
	}
	gotH, okH := recvWithin(local, 3*time.Second)
	check("目的为主机的包交付本机", okH && bytes.Equal(gotH, th))

	// 错房间码:不持码者推不出会话密钥,拿不到地址,加入超时被拒
	wrongID, err := crypto.NewIdentity()
	if err != nil {
		return err
	}
	_, errWrong := mesh.DialGuest(addr, room.Normalize("WRONGCODE"), wrongID, "丙", 2*time.Second)
	check("错房间码被拒绝", errWrong != nil)

	// 成员名册:正式成员两人(错码者不曾入房)
	check("成员名册计 2 人", len(host.Members()) == 2)

	// 防重放:同一会话重收已消费的旧帧必须被拒
	s1, err := crypto.Exchange(hostID, g1ID.Pub, true, psk)
	if err != nil {
		return err
	}
	s2, err := crypto.Exchange(g1ID, hostID.Pub, false, psk)
	if err != nil {
		return err
	}
	f1 := s1.Seal([]byte("old"))
	_ = s1.Seal([]byte("new"))
	if _, err := s2.Open(f1); err != nil {
		return err
	}
	_, replayed := s2.Open(f1)
	check("重放旧帧被拒绝", replayed != nil)

	host.Close()
	fmt.Printf("全部通过(runtime %s)\n", runtime.Version())
	return nil
}

// fakePkt 构造最小合法 IPv4 包:20 字节头 + 载荷,供进程内转发测试。
func fakePkt(src, dst net.IP, payload string) []byte {
	p := []byte(payload)
	pkt := make([]byte, 20+len(p))
	pkt[0] = 0x45 // 版本 4,首部 20 字节
	binary.BigEndian.PutUint16(pkt[2:4], uint16(len(pkt)))
	pkt[8] = 64 // TTL
	copy(pkt[12:16], src.To4())
	copy(pkt[16:20], dst.To4())
	copy(pkt[20:], p)
	return pkt
}

// recvWithin 在限时内收一个包;超时返回假,测试不悬挂。
func recvWithin(r packetReceiver, d time.Duration) ([]byte, bool) {
	type result struct {
		pkt []byte
		err error
	}
	ch := make(chan result, 1)
	go func() {
		pkt, err := r.Recv()
		ch <- result{pkt, err}
	}()
	select {
	case res := <-ch:
		return res.pkt, res.err == nil
	case <-time.After(d):
		return nil, false
	}
}
