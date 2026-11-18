//go:build windows

// Package firewall 自持主机所需的系统放行规则,不依赖任何脚本。
package firewall

import (
	"fmt"
	"os/exec"
	"strconv"
)

// Open 放行主机的监听端口,局域网对端才能连入。
// 规则名固定且先删后加,重复执行结果幂等。
// 失败把原因交还调用方:界面通道静默降级,命令行模式给提示;
// 输出不能写到 stdout,那是 IPC 的 JSON 通道。
func Open(port int) error {
	rule := fmt.Sprintf("EverGreen LAN UDP %d", port)
	_, _ = exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+rule).CombinedOutput()
	_, err := exec.Command("netsh", "advfirewall", "firewall", "add", "rule",
		"name="+rule, "dir=in", "action=allow", "protocol=UDP", "localport="+strconv.Itoa(port)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("未能自动放行防火墙入站 UDP %d(需要管理员权限);若无法连接,请手工放行", port)
	}
	return nil
}
