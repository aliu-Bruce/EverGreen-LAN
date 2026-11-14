// Package tunnel 提供点对点的加密 UDP 数据报传输与两步握手。
// 原则:一个数据报即一个加密帧,不做分片与粘包;
// 握手只交换公钥,身份核验由房间码体系承担,本包不掺和。
package tunnel

import (
	"fmt"
	"net"
	"time"

	"eglan/internal/crypto"
)

// 握手帧:4 字节魔数 + 32 字节 X25519 公钥。
// 两个魔数区分发起与应答,方向错乱与误连其他端口的流量当场拒绝。
const (
	helloMagic = "EGHL" // 发起方 → 响应方
	replyMagic = "EGHR" // 响应方 → 发起方
	helloLen   = len(helloMagic) + 32
)

// Conn 是一条建立完毕的加密通道,收发两侧各持一个。
type Conn struct {
	pc      *net.UDPConn
	remote  *net.UDPAddr
	peerPub []byte // 对端公钥,供日志与界面展示
	sess    *crypto.Session
}

// Dial 向对端发起握手。timeout 之内未完成视为失败;timeout 为零表示不限。
// 握手帧按固定间隔重发:单个数据报在网络上是可能丢的,首包失败不该终结加入。
func Dial(addr string, id *crypto.Identity, timeout time.Duration) (*Conn, error) {
	raddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("tunnel: 对端地址无效 %q: %w", addr, err)
	}
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, fmt.Errorf("tunnel: 打开本地端口失败: %w", err)
	}
	hello := make([]byte, 0, helloLen)
	hello = append(hello, helloMagic...)
	hello = append(hello, id.Pub...)
	deadline := time.Now().Add(timeout)
	if timeout == 0 {
		deadline = time.Now().Add(time.Hour) // 无期限时给宽松上限,避免永久悬挂
	}
	buf := make([]byte, helloLen)
	for {
		attempt := 2 * time.Second
		if remain := time.Until(deadline); remain < attempt {
			attempt = remain
		}
		if attempt <= 0 {
			pc.Close()
			return nil, fmt.Errorf("tunnel: 等待应答超时(对端未上线或地址不通)")
		}
		if _, err := pc.WriteToUDP(hello, raddr); err != nil {
			pc.Close()
			return nil, fmt.Errorf("tunnel: 发送握手失败: %w", err)
		}
		_ = pc.SetReadDeadline(time.Now().Add(attempt))
		n, remote, err := pc.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		sess, peerPub, err := finishHandshake(id, buf[:n], replyMagic, true)
		if err != nil {
			continue
		}
		_ = pc.SetDeadline(time.Time{})
		// 应答实际到达的地址作为后续目的地,天然兼容端口重映射
		return &Conn{pc: pc, remote: remote, peerPub: peerPub, sess: sess}, nil
	}
}

// Bind 只绑定 UDP 端口,不参与握手。
// 需要先知道端口号(端口 0 由系统指派)再握手的调用方,先 Bind 再 ListenOn。
func Bind(port int) (*net.UDPConn, error) {
	return net.ListenUDP("udp", &net.UDPAddr{Port: port})
}

// Listen 绑定端口并等待首个握手。timeout 为零表示一直等到握手完成。
func Listen(port int, id *crypto.Identity, timeout time.Duration) (*Conn, error) {
	pc, err := Bind(port)
	if err != nil {
		return nil, fmt.Errorf("tunnel: 监听端口 %d 失败: %w", port, err)
	}
	return ListenOn(pc, id, timeout)
}

// ListenOn 在已绑定的套接字上等待首个握手。
func ListenOn(pc *net.UDPConn, id *crypto.Identity, timeout time.Duration) (*Conn, error) {
	if timeout > 0 {
		if err := pc.SetDeadline(time.Now().Add(timeout)); err != nil {
			pc.Close()
			return nil, fmt.Errorf("tunnel: 设置超时失败: %w", err)
		}
	}
	buf := make([]byte, helloLen)
	var hello []byte
	var remote *net.UDPAddr
	for {
		// 丢弃端口上先到的无关流量,直到出现合法握手
		n, from, err := pc.ReadFromUDP(buf)
		if err != nil {
			pc.Close()
			return nil, fmt.Errorf("tunnel: 等待握手失败: %w", err)
		}
		if n >= len(helloMagic) && string(buf[:len(helloMagic)]) == helloMagic {
			hello, remote = buf[:n], from
			break
		}
	}
	sess, peerPub, err := finishHandshake(id, hello, helloMagic, false)
	if err != nil {
		pc.Close()
		return nil, err
	}
	reply := make([]byte, 0, helloLen)
	reply = append(reply, replyMagic...)
	reply = append(reply, id.Pub...)
	if _, err := pc.WriteToUDP(reply, remote); err != nil {
		pc.Close()
		return nil, fmt.Errorf("tunnel: 发送应答失败: %w", err)
	}
	if timeout > 0 {
		pc.SetDeadline(time.Time{})
	}
	return &Conn{pc: pc, remote: remote, peerPub: peerPub, sess: sess}, nil
}

// finishHandshake 校验对端握手帧并推导本端会话。
func finishHandshake(id *crypto.Identity, frame []byte, wantMagic string, isInitiator bool) (*crypto.Session, []byte, error) {
	if len(frame) != helloLen || string(frame[:4]) != wantMagic {
		return nil, nil, fmt.Errorf("tunnel: 握手帧格式不符")
	}
	sess, err := crypto.Exchange(id, frame[4:helloLen], isInitiator)
	if err != nil {
		return nil, nil, err
	}
	peerPub := make([]byte, 32)
	copy(peerPub, frame[4:helloLen])
	return sess, peerPub, nil
}

// Send 封装并投递一个 IP 包。UDP 无重传,投递失败按普通丢包处理。
func (c *Conn) Send(pkt []byte) error {
	frame := c.sess.Seal(pkt)
	if _, err := c.pc.WriteToUDP(frame, c.remote); err != nil {
		return fmt.Errorf("tunnel: 发送失败: %w", err)
	}
	return nil
}

// Recv 取一个解密后的 IP 包。
// 认证不过或格式不符的帧视为噪声丢弃,继续等待,不打断通道。
func (c *Conn) Recv() ([]byte, error) {
	buf := make([]byte, 65535)
	for {
		n, _, err := c.pc.ReadFromUDP(buf)
		if err != nil {
			return nil, fmt.Errorf("tunnel: 接收失败: %w", err)
		}
		pkt, err := c.sess.Open(buf[:n])
		if err != nil {
			continue
		}
		return pkt, nil
	}
}

// Close 关闭套接字。
func (c *Conn) Close() error { return c.pc.Close() }

// LocalPort 返回本端实际绑定的 UDP 端口,host 端日志与测试用。
func (c *Conn) LocalPort() int {
	if a, ok := c.pc.LocalAddr().(*net.UDPAddr); ok {
		return a.Port
	}
	return 0
}

// PeerPub 返回对端公钥副本。
func (c *Conn) PeerPub() []byte {
	pub := make([]byte, len(c.peerPub))
	copy(pub, c.peerPub)
	return pub
}
