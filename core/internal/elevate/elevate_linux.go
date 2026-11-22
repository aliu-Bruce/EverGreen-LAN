//go:build linux

package elevate

import (
	"fmt"
	"os"
	"os/exec"
)

// Admin 在 Linux 上以有效用户身份判断;TUN 设备需要 root。
func Admin() bool { return os.Geteuid() == 0 }

// Available 报告当前平台能否一键提权:Linux 走 pkexec 的 polkit 图形授权。
// 系统是否真的装了 pkexec 要到点击时才知道,这里先按可用处理,让入口始终可见。
func Available() bool { return true }

// RunAs 用 pkexec 请求 polkit 授权,授权通过后以 root 启动新的核心。
// pkexec 等被调程序退出才返回,所以让 shell 后台拉起核心后立刻退出:
// 授权结果马上拿到,新核心独立存活并连回界面。
func RunAs(exe string, args []string, hidden bool) error {
	_ = hidden // Linux 由桌面会话决定窗口显隐
	if _, err := exec.LookPath("pkexec"); err != nil {
		return fmt.Errorf("系统没有 pkexec,无法在程序内提权;请用 sudo 启动")
	}
	out, err := exec.Command("pkexec", "/bin/sh", "-c", shellCommand(exe, args)).CombinedOutput()
	if err != nil {
		if msg := firstLine(out); msg != "" {
			return fmt.Errorf("未能以管理员权限启动: %s", msg)
		}
		return fmt.Errorf("未能以管理员权限启动(可能取消了授权)")
	}
	return nil
}
