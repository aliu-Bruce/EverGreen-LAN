//go:build darwin

package tun

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

// macOS 实现:经由 AF_SYSTEM/SYSPROTO_CONTROL 控制套接字挂接内核 utun 设备。
// utun 是点对点三层设备,帧前带 4 字节协议族头;地址与路由交给系统自带的
// ifconfig/route 配置,不引入第三方依赖。接口名由内核分配(utun0、utun1…),
// Config.Name 在 macOS 上无法自定义,仅保留给 Windows 使用。

const (
	sysProtoControl = 2          // SYSPROTO_CONTROL
	afSysControl    = 2          // AF_SYS_CONTROL
	utunOptIfname   = 2          // UTUN_OPT_IFNAME
	ctlIoCGInfo     = 0xc0644e03 // CTLIOCGINFO = _IOWR('N', 3, struct ctl_info)
	ctlNameMax      = 96         // MAX_KCTL_NAME
	defaultMTU      = 1400
)

// ctl_info:查询 utun 控制接口的 id。
type ctlInfo struct {
	id   uint32
	name [ctlNameMax]byte
}

// sockaddr_ctl:连接到指定控制接口;unit 为 0 时由内核分配单元号。
type sockaddrCtl struct {
	len      uint8
	family   uint8
	sysaddr  uint16
	id       uint32
	unit     uint32
	reserved [5]uint32
}

type device struct {
	fd   int
	name string
	mtu  int
}

// New 创建一块 utun 网卡。调用方需要 root 权限。
func New(cfg Config) (Device, error) {
	if cfg.CIDR == "" {
		return nil, fmt.Errorf("tun: 缺少地址段")
	}
	fd, err := syscall.Socket(syscall.AF_SYSTEM, syscall.SOCK_DGRAM, sysProtoControl)
	if err != nil {
		return nil, fmt.Errorf("tun: 打开控制套接字失败(需要 root): %w", err)
	}
	var info ctlInfo
	copy(info.name[:], "utun")
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), ctlIoCGInfo, uintptr(unsafe.Pointer(&info)))
	if errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("tun: 查询 utun 控制接口失败: %w", errno)
	}
	addr := sockaddrCtl{
		len:     uint8(unsafe.Sizeof(sockaddrCtl{})),
		family:  syscall.AF_SYSTEM,
		sysaddr: afSysControl,
		id:      info.id,
	}
	_, _, errno = syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&addr)), uintptr(unsafe.Sizeof(addr)))
	if errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("tun: 连接 utun 控制接口失败(需要 root): %w", errno)
	}
	var nameBuf [256]byte
	nameLen := uint32(len(nameBuf))
	_, _, errno = syscall.Syscall6(syscall.SYS_GETSOCKOPT, uintptr(fd), sysProtoControl, utunOptIfname,
		uintptr(unsafe.Pointer(&nameBuf[0])), uintptr(unsafe.Pointer(&nameLen)), 0)
	if errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("tun: 获取 utun 接口名失败: %w", errno)
	}
	if nameLen == 0 || nameLen > uint32(len(nameBuf)) {
		syscall.Close(fd)
		return nil, fmt.Errorf("tun: utun 接口名长度异常: %d", nameLen)
	}
	name := string(nameBuf[:nameLen-1]) // 末尾是 NUL
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = defaultMTU
	}
	d := &device{fd: fd, name: name, mtu: mtu}
	if err := d.configure(cfg); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

// configure 写入地址、MTU 与隧道网段路由。
func (d *device) configure(cfg Config) error {
	ip, mask, err := ParseCIDR(cfg.CIDR)
	if err != nil {
		return err
	}
	if len(mask) != 4 {
		return fmt.Errorf("tun: 仅支持 IPv4 地址段")
	}
	maskStr := fmt.Sprintf("%d.%d.%d.%d", mask[0], mask[1], mask[2], mask[3])
	// utun 是点对点设备,本地与对端都填本端地址;同段走向由掩码与下面的路由决定。
	out, err := exec.Command("/sbin/ifconfig", d.name, "inet", ip.String(), ip.String(),
		"netmask", maskStr, "mtu", fmt.Sprintf("%d", d.mtu), "up").CombinedOutput()
	if err != nil {
		return fmt.Errorf("tun: 配置 utun 失败(ifconfig): %s", out)
	}
	_, network, err := net.ParseCIDR(cfg.CIDR)
	if err != nil {
		return err
	}
	out, err = exec.Command("/sbin/route", "-n", "add", "-net", network.String(), "-interface", d.name).CombinedOutput()
	// 路由已存在时继续:可能是 ifconfig 自动生成的同段路由。
	if err != nil && !strings.Contains(string(out), "File exists") {
		return fmt.Errorf("tun: 添加隧道路由失败(route): %s", out)
	}
	return nil
}

func (d *device) Name() string { return d.name }
func (d *device) MTU() int     { return d.mtu }

// Read 返回去掉协议族头的 IPv4 包;非 IPv4 帧直接跳过。
func (d *device) Read() ([]byte, error) {
	buf := make([]byte, 65535+utunHeaderSize)
	for {
		n, err := syscall.Read(d.fd, buf)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			return nil, err
		}
		if n == 0 {
			return nil, fmt.Errorf("tun: utun 读取返回空帧")
		}
		if pkt, ok := utunUnwrap(buf[:n]); ok {
			out := make([]byte, len(pkt))
			copy(out, pkt)
			return out, nil
		}
	}
}

// Write 补上协议族头后注入内核;短写时续写直到完成。
func (d *device) Write(pkt []byte) error {
	frame := utunWrap(pkt)
	for len(frame) > 0 {
		n, err := syscall.Write(d.fd, frame)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			return err
		}
		if n <= 0 {
			return fmt.Errorf("tun: utun 写入未推进")
		}
		frame = frame[n:]
	}
	return nil
}

func (d *device) Close() error { return syscall.Close(d.fd) }
