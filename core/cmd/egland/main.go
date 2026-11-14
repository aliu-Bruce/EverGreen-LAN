// egland 是 EverGreen LAN 的核心命令行入口。
// P0 提供两种能力:
//
//	-test-echo        进程内自检:握手 + 加密回声 + 防重放,不建网卡、不需管理员;
//	-role host|client 真实模式:建虚拟网卡,把本机经网卡进出的 IP 包加密转发给对端。
//
// 转发原则:只搬运 IP 包,不改内容、不辨协议;一切服务(如 ping、游戏)
// 都由两端操作系统的协议栈照常处理,本进程对它们透明。
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"runtime"
	"time"

	"eglan/internal/crypto"
	"eglan/internal/tun"
	"eglan/internal/tunnel"
)

func main() {
	var (
		role    = flag.String("role", "host", "角色:host(建房间)/ client(加入)")
		ip      = flag.String("ip", "", "本端隧道地址;host 默认 10.66.7.1/24,client 默认 10.66.7.2/24")
		listen  = flag.Int("listen", 47777, "host 监听的 UDP 端口")
		peer    = flag.String("peer", "", "client 要连接的对端 host:port")
		adapter = flag.String("adapter", "EGLAN", "虚拟网卡名称")
		mtu     = flag.Int("mtu", 1400, "虚拟网卡 MTU")
		echo    = flag.Bool("test-echo", false, "进程内自检,不需要管理员")
	)
	flag.Parse()

	var err error
	if *echo {
		err = testEcho()
	} else {
		err = relay(*role, *ip, *peer, *listen, *adapter, *mtu)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "eglan:", err)
		os.Exit(1)
	}
}

// relay 真实模式:建网卡、建通道,双泵转发直至出错或收到中断。
func relay(role, ip, peer string, listen int, adapter string, mtu int) error {
	switch role {
	case "host", "client":
	default:
		return fmt.Errorf("未知角色 %q,应为 host 或 client", role)
	}
	if role == "client" && peer == "" {
		return fmt.Errorf("client 模式需要 -peer host:port")
	}
	cidr := ip
	if cidr == "" {
		if role == "host" {
			cidr = "10.66.7.1/24"
		} else {
			cidr = "10.66.7.2/24"
		}
	}
	id, err := crypto.NewIdentity()
	if err != nil {
		return err
	}

	// 先做需要权限的操作,再等握手:网卡建不起来时第一时间给出明确报错
	var dev tun.Device
	if role == "host" {
		dev, err = tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
		if err != nil {
			return err
		}
		defer dev.Close()
		fmt.Printf("虚拟网卡 %s(%s)就绪\n", dev.Name(), cidr)
		fmt.Printf("等待对端加入,监听 UDP :%d ...\n", listen)
	} else {
		fmt.Printf("连接对端 %s ...\n", peer)
	}

	var conn *tunnel.Conn
	if role == "host" {
		conn, err = tunnel.Listen(listen, id, 0)
	} else {
		conn, err = tunnel.Dial(peer, id, 15*time.Second)
		if err == nil {
			dev, err = tun.New(tun.Config{Name: adapter, CIDR: cidr, MTU: mtu})
			if err != nil {
				conn.Close()
				return err
			}
			defer dev.Close()
			fmt.Printf("虚拟网卡 %s(%s)就绪\n", dev.Name(), cidr)
		}
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	fmt.Printf("通道就绪,对端公钥 %x...\n(此窗口保持打开;Ctrl+C 退出)\n", conn.PeerPub()[:8])

	// 中断时关闭套接字,让阻塞中的收发循环及时退出
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		conn.Close()
	}()

	done := make(chan error, 2)
	go pumpOut(dev, conn, done) // 网卡 → 隧道
	go pumpIn(conn, dev, done)  // 隧道 → 网卡
	return <-done
}

// pumpOut 从网卡读 IP 包,加密后投向对端。
func pumpOut(dev tun.Device, conn *tunnel.Conn, done chan<- error) {
	for {
		pkt, err := dev.Read()
		if err != nil {
			done <- fmt.Errorf("网卡读取结束: %w", err)
			return
		}
		if err := conn.Send(pkt); err != nil {
			done <- fmt.Errorf("隧道发送结束: %w", err)
			return
		}
	}
}

// pumpIn 从隧道收 IP 包,解密后注入本机协议栈。
func pumpIn(conn *tunnel.Conn, dev tun.Device, done chan<- error) {
	for {
		pkt, err := conn.Recv()
		if err != nil {
			done <- fmt.Errorf("隧道接收结束: %w", err)
			return
		}
		if err := dev.Write(pkt); err != nil {
			done <- fmt.Errorf("网卡写入结束: %w", err)
			return
		}
	}
}

// testEcho 在进程内走一遍完整链路:
// X25519 握手 → 双向加密回声 → 大包 → 计数器防重放。
// 全程不建网卡,因此不需要管理员权限。
func testEcho() error {
	host, err := crypto.NewIdentity()
	if err != nil {
		return err
	}
	guest, err := crypto.NewIdentity()
	if err != nil {
		return err
	}
	// 先绑定拿到确定端口,再在后台完成握手:两步分开,消除重绑竞态
	pc, err := tunnel.Bind(0)
	if err != nil {
		return err
	}
	port := pc.LocalAddr().(*net.UDPAddr).Port

	type listenResult struct {
		conn *tunnel.Conn
		err  error
	}
	lr := make(chan listenResult, 1)
	go func() {
		l, err := tunnel.ListenOn(pc, host, 10*time.Second)
		lr <- listenResult{l, err}
	}()
	time.Sleep(100 * time.Millisecond) // 留出让监听 goroutine 进入等待的间隙
	guestConn, err := tunnel.Dial(fmt.Sprintf("127.0.0.1:%d", port), guest, 5*time.Second)
	if err != nil {
		return err
	}
	defer guestConn.Close()
	res := <-lr
	if res.err != nil {
		return res.err
	}
	listener := res.conn
	defer listener.Close()

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

	// 发起方 → 响应方:小包与大包各一轮,收发内容必须一致
	check("握手建立,对端公钥交换", len(guestConn.PeerPub()) == 32)
	small := []byte("eglan-echo-small")
	check("小包回声", roundTrip(small, guestConn, listener))
	big := make([]byte, 1400)
	for i := range big {
		big[i] = byte(i % 251)
	}
	check("大包回声(1400B,与隧道 MTU 相当)", roundTrip(big, guestConn, listener))

	// 响应方 → 发起方:反方向也要通
	check("反方向回声", roundTrip(small, listener, guestConn))

	// 防重放:同一会话重收已消费的旧帧必须被拒
	s1, err := crypto.Exchange(host, guest.Pub, true)
	if err != nil {
		return err
	}
	s2, err := crypto.Exchange(guest, host.Pub, false)
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

	fmt.Printf("全部通过(runtime %s)\n", runtime.Version())
	return nil
}

// roundTrip 把一个包从 from 发到 to,再从 to 原样发回,比对内容。
func roundTrip(pkt []byte, from, to *tunnel.Conn) bool {
	if err := from.Send(pkt); err != nil {
		return false
	}
	got, err := to.Recv()
	if err != nil || string(got) != string(pkt) {
		return false
	}
	if err := to.Send(got); err != nil {
		return false
	}
	back, err := from.Recv()
	return err == nil && string(back) == string(pkt)
}
