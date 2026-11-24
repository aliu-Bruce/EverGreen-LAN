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
//
// 核心的输出不丢弃而是落到临时日志:新核心连不回界面时,界面才能把真正
// 的原因(权限被拒、网卡被占用、二进制不见了)报给用户,而不是一句超时。
func RunAs(exe string, args []string, hidden bool) error {
	_ = hidden // macOS 没有"隐藏窗口"的概念
	command := buildShellCommand(exe, args, coreLogPath())
	script := `do shell script "` + appleEscape(command) +
		`" with administrator privileges`
	out, err := exec.Command("/usr/bin/osascript", "-e", script).CombinedOutput()
	if err != nil {
		if msg := firstLine(out); msg != "" {
			return fmt.Errorf("未能以管理员权限启动: %s", msg)
		}
		return fmt.Errorf("未能以管理员权限启动(可能取消了授权)")
	}
	return nil
}

// buildShellCommand 直接经 sh 拉起核心,不写中间脚本:授权工具只认可执行文件,
// 免签名的 .app 里也没有能给脚本占位的解释器。
//
// 尾巴上的 & 让 sh 立刻退出,osascript 才不会陪着核心一起等;核心的输出转到
// 临时日志,既保住授权框之后的错误信息,也不会撑爆管道。
func buildShellCommand(exe string, args []string, logPath string) string {
	run := quotedCommand(exe, args)
	if logPath == "" {
		return run + " >/dev/null 2>&1 &"
	}
	return run + " >" + shellQuote(logPath) + " 2>&1 &"
}

// appleEscape 把一段 shell 命令放进 AppleScript 的双引号字面量里。
// AppleScript 只把 " 与 \ 当作字面量内部的语法字符,这两个必须转义;
// 其余字符原样保留,由内层每个参数自带的单引号隔离 sh。
func appleEscape(s string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return replacer.Replace(s)
}
