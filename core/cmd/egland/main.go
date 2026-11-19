// egland 是 EverGreen LAN 的核心命令行入口。
// P1 提供两种能力:
//
//	-test-echo        进程内自检:三人房间网全链路,不建网卡、不需管理员;
//	-role host|client 真实模式:建虚拟网卡,把本机经网卡进出的 IP 包送入房间;
//	-ipc              界面通道:界面以普通权限拉起,stdin/stdout 行协议;
//	-ipc-connect      提权后的核心回调界面:连接本机回环端口,界面不随之提权。
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
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/disc"
	"eglan/internal/firewall"
	"eglan/internal/ipc"
	"eglan/internal/mesh"
	"eglan/internal/room"
	"eglan/internal/stream"
	"eglan/internal/stun"
	"eglan/internal/transfer"
	"eglan/internal/tun"
)

func main() {
	var (
		role    = flag.String("role", "host", "角色:host(开房间)/ client(加入)")
		code    = flag.String("code", "", "房间码;host 留空则自动生成")
		name    = flag.String("name", ipc.DefaultName(), "房间内显示名")
		ip      = flag.String("ip", "", "host 的隧道地址段,如 10.66.7.1/24;默认 10.66.7.1/24")
		listen  = flag.Int("listen", 47777, "host 监听的 UDP 端口")
		peer    = flag.String("peer", "", "client 要连接的主机地址 host:port")
		adapter = flag.String("adapter", "EGLAN", "虚拟网卡名称")
		mtu     = flag.Int("mtu", 1400, "虚拟网卡 MTU")
		echo    = flag.Bool("test-echo", false, "进程内自检,不需要管理员")
		ipcMode = flag.Bool("ipc", false, "界面通道:stdin/stdout 行协议,由界面程序调用")
		ipcAddr = flag.String("ipc-connect", "", "界面回调通道:连接界面提供的本机回环地址(由提权后的核心使用)")
		ipcTok  = flag.String("ipc-token", "", "回调通道令牌,由界面生成")
	)
	flag.Parse()

	// 裸启动(如双击)不开任何模式,只给说明窗口并等回车,绝不闪退
	if len(os.Args) == 1 {
		banner()
		return
	}

	var err error
	switch {
	case *echo:
		err = testEcho()
	case *ipcAddr != "":
		err = ipc.Connect(*ipcAddr, *ipcTok)
	case *ipcMode:
		err = ipc.Run(os.Stdin, os.Stdout)
	default:
		err = relay(*role, *code, *name, *ip, *peer, *listen, *adapter, *mtu)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "eglan:", err)
		// 界面通道由界面程序托管,失败时不能停在隐藏窗口里等回车。
		if !*ipcMode && *ipcAddr == "" {
			waitIfConsole()
		}
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
  egland -ipc                          界面通道(由界面程序调用,不手动使用)
  egland -ipc-connect 地址 -ipc-token 令牌
                                       提权核心回调界面(由界面程序调用)

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
		if err := firewall.Open(listen); err != nil {
			fmt.Println("提示:", err)
		}
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
		// 与界面通道一致:房间开放即播报,同网段的界面可直接发现
		if a, err := disc.Announce(disc.AnnounceConfig{
			Name:    name,
			Code:    code,
			Port:    listen,
			Members: func() int { return len(h.Members()) + 1 },
		}); err != nil {
			fmt.Println("提示: 局域网发现未启动:", err)
		} else {
			defer a.Close()
		}
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
// 错房间码拒绝 → 成员名册 → 防重放 → 发现信标收发与过滤 →
// 可靠流往返 → 文件传输与 SHA-256 校验。
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

	// STUN:本地假服务器回显请求来源。只有从房间套接字发出的探测,
	// 才能拿到与监听端口一致且来源可匹配的映射地址。
	stunSrv, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		host.Close()
		return err
	}
	defer stunSrv.Close()
	go func() {
		buf := make([]byte, 1024)
		for {
			n, from, err := stunSrv.ReadFromUDP(buf)
			if err != nil {
				return
			}
			tx, ok := stun.TransactionIDOf(buf[:n])
			if !ok {
				continue
			}
			_, _ = stunSrv.WriteToUDP(stun.BuildBindingSuccess(tx, from), from)
		}
	}()
	mapped, errMap := host.ProbeSTUN(stunSrv.LocalAddr().String(), 2*time.Second)
	check("STUN:从房间套接字探测到映射地址",
		errMap == nil && mapped != nil &&
			mapped.Port == pc.LocalAddr().(*net.UDPAddr).Port &&
			mapped.IP.IsLoopback())

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

	// 发现:监听临时端口,单播一条信标应得到对应房间
	found := make(chan []disc.Room, 8)
	l, err := disc.Listen(0, func(rooms []disc.Room) {
		select {
		case found <- rooms:
		default:
		}
	})
	if err != nil {
		return err
	}
	defer l.Close()
	sock, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return err
	}
	defer sock.Close()
	to := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: l.Port()}
	beacon, err := disc.Beacon{
		Version: 1,
		Name:    "自检房间",
		Code:    "K7Q2M9XD",
		Peer:    "127.0.0.1:47777",
		Members: 2,
	}.Marshal()
	if err != nil {
		return err
	}
	if _, err := sock.WriteToUDP(beacon, to); err != nil {
		return err
	}
	rooms, gotBeacon := recvRooms(found, 3*time.Second)
	check("发现信标:房间进入列表",
		gotBeacon && len(rooms) == 1 && rooms[0].Code == "K7Q2M9XD" && rooms[0].Peer == "127.0.0.1:47777")

	// 非本协议报文:监听端必须无视,不产生任何事件
	if _, err := sock.WriteToUDP([]byte("EGLAN? not a beacon"), to); err != nil {
		return err
	}
	_, noise := recvRooms(found, 500*time.Millisecond)
	check("发现信标:非法报文被忽略", !noise)

	// ---- 可靠流:主机与成员之间双向字节流 ----
	// 成员通道上流帧与 IP 包共用一条加密链路,Recv 负责把流帧分派给流层。
	// 这里先起收包泵,让成员的流层能收到建流帧与数据帧。
	pump := make(chan struct{})
	defer close(pump)
	for _, g := range []*mesh.Guest{g1, g2} {
		g := g
		go func() {
			for {
				select {
				case <-pump:
					return
				default:
				}
				if _, err := g.Recv(); err != nil {
					return
				}
			}
		}()
	}

	// 甲做回显:读多少写回多少,验证同一流上两个方向互不干扰。
	echoRes := make(chan error, 1)
	go func() {
		st, err := g1.Flow().Accept()
		if err != nil {
			echoRes <- err
			return
		}
		defer st.Close()
		buf := make([]byte, 32*1024)
		for {
			n, rerr := st.Read(buf)
			if n > 0 {
				if _, werr := st.Write(buf[:n]); werr != nil {
					echoRes <- werr
					return
				}
			}
			if rerr != nil {
				if rerr == io.EOF {
					echoRes <- nil
				} else {
					echoRes <- rerr
				}
				return
			}
		}
	}()

	hs, err := host.Flow().Dial(ip1)
	if err != nil {
		return err
	}
	wantEcho := make([]byte, 1<<20)
	for i := range wantEcho {
		wantEcho[i] = byte(i*31 + 7)
	}
	if _, err := hs.Write(wantEcho); err != nil {
		return err
	}
	gotEcho := make([]byte, len(wantEcho))
	if err := readStreamExact(hs, gotEcho); err != nil {
		return err
	}
	if err := hs.Close(); err != nil {
		return err
	}
	check("可靠流:1MB 主机 → 成员甲 → 主机往返完整", bytes.Equal(gotEcho, wantEcho))
	select {
	case err := <-echoRes:
		check("可靠流:成员甲回显侧正常收尾", err == nil)
	case <-time.After(20 * time.Second):
		check("可靠流:成员甲回显侧正常收尾", false)
	}

	// 乙做单向接收:验证第二条流独立编号、按序完整。
	g2Res := make(chan []byte, 1)
	go func() {
		st, err := g2.Flow().Accept()
		if err != nil {
			g2Res <- nil
			return
		}
		defer st.Close()
		buf := make([]byte, 256*1024)
		if err := readStreamExact(st, buf); err != nil {
			g2Res <- nil
			return
		}
		g2Res <- buf
	}()
	hs2, err := host.Flow().Dial(ip2)
	if err != nil {
		return err
	}
	wantOne := make([]byte, 256*1024)
	for i := range wantOne {
		wantOne[i] = byte(i*17 + 3)
	}
	if _, err := hs2.Write(wantOne); err != nil {
		return err
	}
	select {
	case gotOne := <-g2Res:
		check("可靠流:256KB 主机 → 成员乙顺序完整", bytes.Equal(gotOne, wantOne))
	case <-time.After(20 * time.Second):
		check("可靠流:256KB 主机 → 成员乙顺序完整", false)
	}
	_ = hs2.Close()

	// ---- 文件传输:主机 → 成员甲,走同一可靠流层 ----
	// 用系统临时目录,进程结束即清理;接收方自动接受并落盘。
	dir, err := os.MkdirTemp("", "eglan-selftest-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	srcPath := filepath.Join(dir, "自检文件.bin")
	dstPath := filepath.Join(dir, "收到的文件.bin")
	wantFile := make([]byte, 512*1024)
	for i := range wantFile {
		wantFile[i] = byte(i*53 + 11)
	}
	if err := os.WriteFile(srcPath, wantFile, 0o600); err != nil {
		return err
	}

	hostXferEvents := make(chan transfer.Event, 64)
	g1XferEvents := make(chan transfer.Event, 64)
	hostXfer := transfer.New(host.SelfIP(), host.Flow(), func(e transfer.Event) { hostXferEvents <- e })
	g1Xfer := transfer.New(g1.HostIP(), g1.Flow(), func(e transfer.Event) { g1XferEvents <- e })
	defer hostXfer.Close()
	defer g1Xfer.Close()
	go hostXfer.Serve()
	go g1Xfer.Serve()

	g1Done := make(chan transfer.Event, 1)
	go func() {
		for e := range g1XferEvents {
			switch e.Kind {
			case "offer":
				if err := g1Xfer.Accept(e.ID, dstPath); err != nil {
					g1Done <- transfer.Event{Err: err.Error()}
					return
				}
			case "done":
				g1Done <- e
				return
			}
		}
	}()
	hostDone := make(chan transfer.Event, 1)
	go func() {
		for e := range hostXferEvents {
			if e.Kind == "done" {
				hostDone <- e
				return
			}
		}
	}()

	if _, err := hostXfer.Send(ip1, srcPath); err != nil {
		return err
	}
	pick := func(name string, ch chan transfer.Event) transfer.Event {
		select {
		case e := <-ch:
			return e
		case <-time.After(30 * time.Second):
			return transfer.Event{Err: name + " 等待超时"}
		}
	}
	gotGuest := pick("成员甲", g1Done)
	gotHost := pick("主机", hostDone)
	gotFile, ferr := os.ReadFile(dstPath)
	check("文件传输:512KB 主机 → 成员甲完整落盘", ferr == nil && bytes.Equal(gotFile, wantFile))
	check("文件传输:两端均确认且校验通过", gotGuest.OK && gotGuest.Err == "" && gotHost.OK && gotHost.Err == "")

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

// recvRooms 在限时内收一份发现快照;超时返回假,测试不悬挂。
func recvRooms(ch <-chan []disc.Room, d time.Duration) ([]disc.Room, bool) {
	select {
	case rooms := <-ch:
		return rooms, true
	case <-time.After(d):
		return nil, false
	}
}

// readStreamExact 读满 buf;流提前结束视为错误。
func readStreamExact(st stream.Stream, buf []byte) error {
	n := 0
	for n < len(buf) {
		m, err := st.Read(buf[n:])
		n += m
		if err != nil {
			return fmt.Errorf("流提前结束 %d/%d: %w", n, len(buf), err)
		}
	}
	return nil
}
