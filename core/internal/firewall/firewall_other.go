//go:build !windows

// Package firewall 自持主机所需的系统放行规则,不依赖任何脚本。
package firewall

// 非 Windows 平台没有统一的默认防火墙拦截,P1 不做处理;
// 各发行版如需放行,由用户按其防火墙工具自行操作。
func Open(port int) error { return nil }
