// Package plugin 定义插件的装载与事件接入点。
// 插件以独立进程运行,经 IPC 桥接,不与本进程共享地址空间;
// P0 仅立接口占位。
package plugin

// Manifest 描述一个插件的元信息。
type Manifest struct {
	Name    string
	Version string
}
