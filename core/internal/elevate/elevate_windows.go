//go:build windows

package elevate

import (
	"fmt"
	"path/filepath"
	"syscall"
	"unsafe"
)

var (
	shell32           = syscall.NewLazyDLL("shell32.dll")
	procIsUserAnAdmin = shell32.NewProc("IsUserAnAdmin")
	procShellExecuteW = shell32.NewProc("ShellExecuteW")
)

// Admin 报告当前进程是否已提权。只查询,不改动任何系统状态。
func Admin() bool {
	r, _, _ := procIsUserAnAdmin.Call()
	return r != 0
}

// Available 报告当前平台能否一键提权。
func Available() bool { return true }

// Restart 用 runas 动词重新拉起 exe,由系统弹出 UAC 确认。
// 用户取消或提权失败时返回错误;成功返回即代表新进程已创建。
func Restart(exe string) error {
	verb, err := syscall.UTF16PtrFromString("runas")
	if err != nil {
		return fmt.Errorf("提权参数无效: %w", err)
	}
	file, err := syscall.UTF16PtrFromString(exe)
	if err != nil {
		return fmt.Errorf("程序路径无效: %w", err)
	}
	dir, err := syscall.UTF16PtrFromString(filepath.Dir(exe))
	if err != nil {
		return fmt.Errorf("程序目录无效: %w", err)
	}
	const swShownormal = 1
	ret, _, _ := procShellExecuteW.Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(file)),
		0, // 无启动参数:界面自己从偏好恢复
		uintptr(unsafe.Pointer(dir)),
		swShownormal,
	)
	if ret <= 32 {
		return fmt.Errorf("未能以管理员权限启动(可能取消了 UAC 提示)")
	}
	return nil
}
