//go:build !windows

package main

// 非 Windows 平台没有统一的默认防火墙拦截,P0 不做处理;
// 各发行版如需放行,由用户按其防火墙工具自行操作。
func openFirewall(port int) {}
