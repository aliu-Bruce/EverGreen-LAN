//go:build windows

package main

import "syscall"

// Windows 控制台默认代码页跟随系统区域,程序输出的 UTF-8 会被渲染成乱码。
// 启动即把输入与输出代码页统一到 UTF-8,窗口里的中文才能正确显示;
// 此改动只影响本进程所属的控制台,不动系统全局设置。
func init() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	setOut := kernel32.NewProc("SetConsoleOutputCP")
	setIn := kernel32.NewProc("SetConsoleCP")
	const cpUTF8 = 65001
	setOut.Call(cpUTF8)
	setIn.Call(cpUTF8)
}
