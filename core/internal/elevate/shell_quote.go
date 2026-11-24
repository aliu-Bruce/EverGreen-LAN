//go:build darwin || linux

package elevate

import (
	"os"
	"path/filepath"
	"strings"
)

// shellQuote 把一个参数包成 POSIX 单引号形式,交给 sh 直接使用。
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// quotedCommand 拼出可执行文件加参数,每一段都是单引号字面量。
func quotedCommand(exe string, args []string) string {
	parts := make([]string, 0, len(args)+1)
	parts = append(parts, shellQuote(exe))
	for _, a := range args {
		parts = append(parts, shellQuote(a))
	}
	return strings.Join(parts, " ")
}

// coreLogPath 返回提权核心的启动日志位置(系统临时目录)。
// 核心由授权工具拉起,界面拿不到它的 stderr,只能借这个文件把失败原因带回来。
// 取不到临时目录时返回空串,调用方退回丢弃输出。
func coreLogPath() string {
	dir := os.TempDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "egland-core.log")
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
