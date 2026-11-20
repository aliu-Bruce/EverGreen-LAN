//go:build !windows && !darwin

package elevate

import "fmt"

// Admin 在非 Windows 平台没有统一的权限模型,按未提权处理。
func Admin() bool { return false }

// Available 报告当前平台能否一键提权;P2 只支持 Windows。
func Available() bool { return false }

// RunAs 在非 Windows 平台不可用。
func RunAs(exe string, args []string, hidden bool) error {
	return fmt.Errorf("当前平台暂不支持一键提权")
}
