// Package ipc 是核心与界面之间的本地 JSON 通道。
// 界面经标准输入输出与本进程通信,双向均为一行一个 JSON 对象;
// 本包先立信封骨架,消息随 P1 实装。
package ipc

// Envelope 是消息信封:type 字段定位方法,其余字段由具体消息定义。
type Envelope struct {
	Type string `json:"type"`
}
