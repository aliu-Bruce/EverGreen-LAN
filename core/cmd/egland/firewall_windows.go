//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strconv"
)

// openFirewall 放行主机的监听端口,局域网对端才能连入。
// 规则名固定且先删后加,重复执行结果幂等;
// 失败只提示不阻断:防火墙可能已被手工放行,或由用户自行处理。
func openFirewall(port int) {
	rule := fmt.Sprintf("EverGreen LAN UDP %d", port)
	_, _ = exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+rule).CombinedOutput()
	out, err := exec.Command("netsh", "advfirewall", "firewall", "add", "rule",
		"name="+rule, "dir=in", "action=allow", "protocol=UDP", "localport="+strconv.Itoa(port)).CombinedOutput()
	if err != nil {
		fmt.Printf("提示: 未能自动放行防火墙(%s),请手工放行入站 UDP %d\n", out, port)
	}
}
