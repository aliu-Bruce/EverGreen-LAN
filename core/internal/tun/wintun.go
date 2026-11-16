//go:build windows

package tun

import (
	"fmt"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

// Windows 实现:加载 Wintun 驱动的官方接口 DLL 并直调其 C 导出,
// 地址与 MTU 交给 netsh 配置——两者都是系统自带的驱动接口与工具。
// 需要管理员权限:建卡与改址都是系统级操作,这正是引导页说明过的边界。
// 接口形状以随包分发的 wintun.h 为准,不凭记忆假设。

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
	procStartSession      = modwintun.NewProc("WintunStartSession")
	procEndSession        = modwintun.NewProc("WintunEndSession")
	procGetReadWaitEvent  = modwintun.NewProc("WintunGetReadWaitEvent")
	procReceivePacket     = modwintun.NewProc("WintunReceivePacket")
	procReleaseRecvPacket = modwintun.NewProc("WintunReleaseReceivePacket")
	procAllocateSend      = modwintun.NewProc("WintunAllocateSendPacket")
	procSendPacket        = modwintun.NewProc("WintunSendPacket")
)

// 驱动返回的错误码,wintun.h 文档所列
const (
	errNoMoreItems = 259 // ERROR_NO_MORE_ITEMS:环空,读取继续等
	errHandleEOF   = 38  // ERROR_HANDLE_EOF:适配器终止
	errBufferFull  = 124 // ERROR_BUFFER_OVERFLOW:发送环满

	ringCapacity  = 0x400000
	maxPacketSize = 0xFFFF
	defaultMTU    = 1400
)

type device struct {
	adapter uintptr
	session uintptr
	event   uintptr
	name    string
	mtu     int
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

// errnoOf 还原系统调用返回的错误码;非 Errno 视为零值。
func errnoOf(err error) syscall.Errno {
	if e, ok := err.(syscall.Errno); ok {
		return e
	}
	return 0
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
	adapter, err := createOrOpenAdapter(cfg.Name)
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
	d := &device{adapter: adapter, session: session, event: event, name: cfg.Name, mtu: mtu}
	if err := d.configure(cfg); err != nil {
		d.Close()
		return nil, err
	}
	return d, nil
}

// createOrOpenAdapter 建新卡优先,同名卡(如上次异常退出)直接复用。
// 三个接口都直接返回句柄,零值即失败。
func createOrOpenAdapter(name string) (uintptr, error) {
	name16, _ := syscall.UTF16PtrFromString(name)
	tt16, _ := syscall.UTF16PtrFromString("EGLAN")
	g := guidFromName(name)
	adapter, _, _ := procCreateAdapter.Call(
		uintptr(unsafe.Pointer(name16)), uintptr(unsafe.Pointer(tt16)),
		uintptr(unsafe.Pointer(&g)))
	if adapter != 0 {
		return adapter, nil
	}
	adapter, _, _ = procOpenAdapter.Call(uintptr(unsafe.Pointer(name16)))
	if adapter != 0 {
		return adapter, nil
	}
	return 0, fmt.Errorf("tun: 创建网卡失败(若因权限被拒,请以管理员身份运行)")
}

// configure 用 netsh 写入隧道地址与 MTU。
// 新建的网卡注册进网络栈有延迟,配置按固定间隔重试,直到期限。
func (d *device) configure(cfg Config) error {
	ip, mask, err := ParseCIDR(cfg.CIDR)
	if err != nil {
		return err
	}
	if len(mask) != 4 {
		return fmt.Errorf("tun: 仅支持 IPv4 地址段")
	}
	maskStr := fmt.Sprintf("%d.%d.%d.%d", mask[0], mask[1], mask[2], mask[3])
	deadline := time.Now().Add(8 * time.Second)
	for {
		out, err := exec.Command("netsh", "interface", "ip", "set", "address",
			"name="+d.name, "source=static", "addr="+ip.String(), "mask="+maskStr).CombinedOutput()
		if err == nil {
			out, err = exec.Command("netsh", "interface", "ipv4", "set", "subinterface",
				d.name, "mtu="+itoa(d.mtu), "store=persistent").CombinedOutput()
			if err != nil {
				return fmt.Errorf("tun: 配置 MTU 失败(netsh): %s", out)
			}
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("tun: 配置地址失败(netsh): %s", out)
		}
		time.Sleep(500 * time.Millisecond)
	}
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
		var size int32
		r1, _, callErr := procReceivePacket.Call(d.session, uintptr(unsafe.Pointer(&size)))
		if r1 == 0 {
			if errnoOf(callErr) == errNoMoreItems {
				continue // 空转唤醒,回到等待
			}
			if errnoOf(callErr) == errHandleEOF {
				return nil, fmt.Errorf("tun: 适配器已终止")
			}
			return nil, fmt.Errorf("tun: 读取失败: %w", callErr)
		}
		// 驱动返回的是环内指针;经由指针槽取回,避免把整型值直接转为指针
		var pkt *byte
		*(*uintptr)(unsafe.Pointer(&pkt)) = r1
		buf := make([]byte, size)
		copy(buf, unsafe.Slice(pkt, size))
		procReleaseRecvPacket.Call(d.session, r1)
		return buf, nil
	}
}

// Write 注入一个 IP 包到协议栈。
// 先向驱动申请环内槽位,填入内容后提交;环满视同丢包,不阻塞转发。
func (d *device) Write(pkt []byte) error {
	if len(pkt) == 0 || len(pkt) > maxPacketSize {
		return nil
	}
	r1, _, callErr := procAllocateSend.Call(d.session, uintptr(len(pkt)))
	if r1 == 0 {
		if errnoOf(callErr) == errBufferFull {
			return nil
		}
		if errnoOf(callErr) == errHandleEOF {
			return fmt.Errorf("tun: 适配器已终止")
		}
		return fmt.Errorf("tun: 分配发送槽失败: %w", callErr)
	}
	// 环内槽位指针经由指针槽取回,避免把整型值直接转为指针
	var sp *byte
	*(*uintptr)(unsafe.Pointer(&sp)) = r1
	copy(unsafe.Slice(sp, len(pkt)), pkt)
	procSendPacket.Call(d.session, r1)
	return nil
}

// Close 结束会话并归还适配器。
// 若适配器由本进程创建,CloseAdapter 会一并删除,不在系统里留残留设备;
// 复用的适配器只归还句柄,不动别人的设备。
func (d *device) Close() error {
	procEndSession.Call(d.session)
	procCloseAdapter.Call(d.adapter)
	return nil
}

func itoa(n int) string {
	return fmt.Sprintf("%d", n)
}
