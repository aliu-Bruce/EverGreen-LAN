//go:build linux

package tun

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

// Linux 实现:打开 /dev/net/tun,ioctl 挂接一块 TUN 设备(无帧头、无附元),
// 地址与 MTU 交给 ip(8) 配置——命令是发行版标准工具,不属于第三方依赖。

const (
	cloneDevice = "/dev/net/tun"
	tunSetIFF   = 0x400454ca
	iffTun      = 0x0001
	iffNoPI     = 0x1000
)

type ifReq struct {
	Name  [16]byte
	Flags uint16
	pad   [22]byte
}

type device struct {
	fd   int
	name string
	mtu  int
}

// New 创建并启用一块 TUN 网卡。调用方需要 CAP_NET_ADMIN(通常即 root)。
func New(cfg Config) (Device, error) {
	if cfg.CIDR == "" {
		return nil, fmt.Errorf("tun: 缺少地址段")
	}
	fd, err := syscall.Open(cloneDevice, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("tun: 打开 %s 失败(需要内核 TUN 支持): %w", cloneDevice, err)
	}
	req := ifReq{Flags: iffTun | iffNoPI}
	copy(req.Name[:], cfg.Name)
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunSetIFF, uintptr(unsafe.Pointer(&req)))
	if errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("tun: 挂接设备失败: %w", errno)
	}
	name := cfg.Name
	if name == "" {
		name = cstring(req.Name[:])
	}
	d := &device{fd: fd, name: name, mtu: cfg.MTU}
	if err := d.configure(cfg); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

func (d *device) configure(cfg Config) error {
	run := func(args ...string) error {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("tun: ip %v: %s", args, out)
		}
		return nil
	}
	if err := run("link", "set", "dev", d.name, "mtu", itoa(cfg.MTU), "up"); err != nil {
		return err
	}
	return run("addr", "add", "dev", d.name, cfg.CIDR)
}

func (d *device) Name() string { return d.name }
func (d *device) MTU() int     { return d.mtu }

func (d *device) Read() ([]byte, error) {
	buf := make([]byte, 65535)
	n, err := syscall.Read(d.fd, buf)
	if n < 0 {
		return nil, err
	}
	return buf[:n], err
}

func (d *device) Write(pkt []byte) error {
	_, err := syscall.Write(d.fd, pkt)
	return err
}

func (d *device) Close() error {
	return syscall.Close(d.fd)
}

func cstring(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

func itoa(n int) string {
	if n <= 0 {
		return "1400"
	}
	return fmt.Sprintf("%d", n)
}
