//go:build darwin || linux

package elevate

import "strings"

// shellQuote 把一个参数包成 POSIX 单引号形式,交给 sh 直接使用。
// 单引号内一切按字面处理,内部的单引号用 '\'' 依次脱开。
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// shellCommand 拼出"以后台方式启动核心"的整条 shell 命令。
// 后台执行是为了让授权工具立刻返回:授权结果拿到了,新核心也能独立存活。
func shellCommand(exe string, args []string) string {
	parts := make([]string, 0, len(args)+1)
	parts = append(parts, shellQuote(exe))
	for _, a := range args {
		parts = append(parts, shellQuote(a))
	}
	return "nohup " + strings.Join(parts, " ") + " >/dev/null 2>&1 &"
}

// firstLine 取输出的首行非空内容,错误弹窗里只放一行,避免把整段日志糊给用户。
func firstLine(out []byte) string {
	msg := strings.TrimSpace(string(out))
	if msg == "" {
		return ""
	}
	if i := strings.IndexByte(msg, '\n'); i >= 0 {
		msg = strings.TrimSpace(msg[:i])
	}
	return msg
}
