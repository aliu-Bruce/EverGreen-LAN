//go:build windows

package tun

import (
	"fmt"
	"os/exec"
	"syscall"
	"unsafe"
)

// Windows 实现:加载 Wintun 驱动的官方接口 DLL 并直调其 C 导出,
// 地址与 MTU 交给 netsh 配置——两者都是系统自带的驱动接口与工具。
// 需要管理员权限:建卡与改址都是系统级操作,这正是引导页说明过的边界。

// 与 Windows 的 GUID 二进制布局保持一致,避免为此引入扩展库。
type guid struct {
	D1 uint32
	D2 uint16
	D3 uint16
	D4 [8]byte
}

var (
	modwintun             = syscall.NewLazyDLL("wintun.dll")
	procCreateAdapter     = modwintun.NewProc("WintunCreateAdapter")
	procOpenAdapter       = modwintun.NewProc("WintunOpenAdapter")
	procCloseAdapter      = modwintun.NewProc("WintunCloseAdapter")
	procDeleteAdapter     = modwintun.NewProc("WintunDeleteAdapter")
	procStartSession      = modwintun.NewProc("WintunStartSession")
	procEndSession        = modwintun.NewProc("WintunEndSession")
	procGetReadWaitEvent  = modwintun.NewProc("WintunGetReadWaitEvent")
	procReceivePacket     = modwintun.NewProc("WintunReceivePacket")
	procReleaseRecvPacket = modwintun.NewProc("WintunReleaseReceivePacket")
	procSendPacket        = modwintun.NewProc("WintunSendPacket")
)

const (
	statusSuccess    = 0
	statusNoMoreData = 259 // ERROR_NO_MORE_DATA:读事件唤醒但无包,视为空转
	ringCapacity     = 0x400000
	defaultMTU       = 1400
)

type device struct {
	adapter uintptr
	session uintptr
	event   uintptr
	name    string
	mtu     int
	created bool // 适配器是否为本进程新建:决定关闭时删除还是归还
}

// guidFromName 由适配器别名派生稳定 GUID:
// 同名适配器在系统里始终对应同一设备实例,避免反复创建留下幽灵网卡。
func guidFromName(name string) guid {
	var g guid
	h := fnvOffset(name)
	g.D1 = uint32(h)
	g.D2 = uint16(h >> 17)
	g.D3 = 0xE3 | uint16(h>>32)&0x0FFF
	copy(g.D4[:], "EGLAN.")
	return g
}

func fnvOffset(s string) uint64 {
	const basis = 14695981039346656037
	var h uint64 = basis
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}

// New 创建(或复用)一块 Wintun 网卡并启动收发会话。
func New(cfg Config) (Device, error) {
	if cfg.CIDR == "" {
		return nil, fmt.Errorf("tun: 缺少地址段")
	}
	if err := modwintun.Load(); err != nil {
		return nil, fmt.Errorf("tun: 找不到 wintun.dll(应与主程序同目录): %w", err)
	}
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = defaultMTU
	}
	adapter, created, err := createOrOpenAdapter(cfg.Name)
	if err != nil {
		return nil, err
	}
	// 启动会话:驱动直接返回会话句柄,零值即失败
	session, _, _ := procStartSession.Call(adapter, ringCapacity)
	if session == 0 {
		procCloseAdapter.Call(adapter)
		return nil, fmt.Errorf("tun: 启动会话失败")
	}
	event, _, _ := procGetReadWaitEvent.Call(session)
	d := &device{adapter: adapter, session: session, event: event, name: cfg.Name, mtu: mtu, created: created}
	if err := d.configure(cfg); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

func createOrOpenAdapter(name string) (uintptr, bool, error) {
	name16, _ := syscall.UTF16PtrFromString(name)
	tt16, _ := syscall.UTF16PtrFromString("EGLAN")
	g := guidFromName(name)
	// 三个接口都直接返回句柄,零值即失败
	adapter, _, _ := procCreateAdapter.Call(
		uintptr(unsafe.Pointer(name16)), uintptr(unsafe.Pointer(tt16)),
		uintptr(unsafe.Pointer(&g)))
	if adapter != 0 {
		return adapter, true, nil
	}
	// 同名适配器已存在(如上次异常退出)时直接复用
	adapter, _, _ = procOpenAdapter.Call(uintptr(unsafe.Pointer(name16)))
	if adapter != 0 {
		return adapter, false, nil
	}
	return 0, false, fmt.Errorf("tun: 创建网卡失败(若因权限被拒,请以管理员身份运行)")
}

// configure 用 netsh 写入隧道地址与 MTU。
// 只配地址不配网关:路由完全由本机地址段与对端地址段表达。
func (d *device) configure(cfg Config) error {
	ip, mask, err := ParseCIDR(cfg.CIDR)
	if err != nil {
		return err
	}
	out, err := exec.Command("netsh", "interface", "ip", "set", "address",
		"name="+d.name, "source=static", "addr="+ip.String(), "mask="+mask.String()).CombinedOutput()
	if err != nil {
		return fmt.Errorf("tun: 配置地址失败(netsh): %s", out)
	}
	out, err = exec.Command("netsh", "interface", "ipv4", "set", "subinterface",
		d.name, "mtu="+itoa(d.mtu), "store=persistent").CombinedOutput()
	if err != nil {
		return fmt.Errorf("tun: 配置 MTU 失败(netsh): %s", out)
	}
	return nil
}

// Name 与 MTU 暴露给日志与上层诊断。
func (d *device) Name() string { return d.name }
func (d *device) MTU() int     { return d.mtu }

// Read 等待读事件,取一个完整 IP 包。
// 驱动返回的是会话环形缓冲里的临时指针,必须在返回前拷贝并归还。
func (d *device) Read() ([]byte, error) {
	for {
		if s, err := syscall.WaitForSingleObject(syscall.Handle(d.event), syscall.INFINITE); s != syscall.WAIT_OBJECT_0 {
			return nil, fmt.Errorf("tun: 等待读事件失败: %w", err)
		}
		var pkt *byte
		var size int32
		r1, _, _ := procReceivePacket.Call(d.session,
			uintptr(unsafe.Pointer(&pkt)), uintptr(unsafe.Pointer(&size)))
		if r1 != statusSuccess {
			if r1 == statusNoMoreData {
				continue // 空转唤醒,继续等下一个事件
			}
			return nil, fmt.Errorf("tun: 读取失败 status=%d", r1)
		}
		buf := make([]byte, size)
		copy(buf, unsafe.Slice(pkt, size))
		procReleaseRecvPacket.Call(d.session, uintptr(unsafe.Pointer(pkt)))
		return buf, nil
	}
}

// Write 注入一个 IP 包到协议栈。
// 拷贝一份再交驱动,避免与调用方缓冲产生竞态。
func (d *device) Write(pkt []byte) error {
	if len(pkt) == 0 {
		return nil
	}
	buf := make([]byte, len(pkt))
	copy(buf, pkt)
	r1, _, _ := procSendPacket.Call(d.session, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r1 != statusSuccess {
		return fmt.Errorf("tun: 写入失败 status=%d", r1)
	}
	return nil
}

// Close 结束会话并回收适配器:
// 本进程新建的直接删除,不留残留设备;复用既有适配器的只归还句柄,不动别人的设备。
func (d *device) Close() error {
	procEndSession.Call(d.session)
	if d.created {
		var reboot int32
		procDeleteAdapter.Call(d.adapter, 1, uintptr(unsafe.Pointer(&reboot)))
	} else {
		procCloseAdapter.Call(d.adapter)
	}
	return nil
}

func itoa(n int) string {
	return fmt.Sprintf("%d", n)
}
