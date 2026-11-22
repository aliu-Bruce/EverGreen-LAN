//go:build !windows && !darwin && !linux

package elevate

import (
	"fmt"
	"os"
)

// Admin 在其余平台以有效用户身份判断;没有统一的提权入口。
func Admin() bool { return os.Geteuid() == 0 }

// Available 报告当前平台能否一键提权;目前只实现 Windows、macOS、Linux。
func Available() bool { return false }

// RunAs 在其余平台不可用。
func RunAs(exe string, args []string, hidden bool) error {
	return fmt.Errorf("当前平台暂不支持一键提权")
}
