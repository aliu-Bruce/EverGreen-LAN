//go:build darwin

package elevate

import (
	"fmt"
	"os"
)

// Admin 在 macOS 上以有效用户身份判断;utun 需要 root。
func Admin() bool { return os.Geteuid() == 0 }

// Available 为 false:没有与 Windows UAC 等价的应用内自提权入口。
func Available() bool { return false }

// RunAs 不可用。macOS 请用 sudo 启动程序,在终端输入本机密码完成授权。
func RunAs(exe string, args []string, hidden bool) error {
	return fmt.Errorf("macOS 不支持应用内提权,请以 sudo 启动")
}
