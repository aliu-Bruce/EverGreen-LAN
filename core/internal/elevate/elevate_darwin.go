//go:build darwin

package elevate

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Admin 在 macOS 上以有效用户身份判断;utun 需要 root。
func Admin() bool { return os.Geteuid() == 0 }

// Available 报告当前平台能否一键提权:macOS 走 osascript 的系统授权框。
func Available() bool { return true }

// RunAs 用 AppleScript 的 do shell script 请求管理员授权,授权通过后以 root
// 启动新的核心。授权工具等 shell 退出就返回,因此本函数只阻塞到"授权完成",
// 用户取消时立刻拿到错误;新核心则已后台运行,随后连回界面。
func RunAs(exe string, args []string, hidden bool) error {
	_ = hidden // macOS 没有"隐藏窗口"的概念
	cmd := shellCommand(exe, args)
	script := `do shell script "` + appleEscape(cmd) + `" with administrator privileges`
	out, err := exec.Command("/usr/bin/osascript", "-e", script).CombinedOutput()
	if err != nil {
		if msg := firstLine(out); msg != "" {
			return fmt.Errorf("未能以管理员权限启动: %s", msg)
		}
		return fmt.Errorf("未能以管理员权限启动(可能取消了授权)")
	}
	return nil
}

// appleEscape 转义 AppleScript 双引号字符串里的反斜杠与双引号。
func appleEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s)
}
