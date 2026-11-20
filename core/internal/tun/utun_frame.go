// utun 帧格式工具:macOS 内核在每个 IP 包前附 4 字节协议族头。
// 这部分与系统调用无关,单独成文件以便在非 macOS 上做单元测试。
package tun

import "encoding/binary"

// utun 帧头长度(字节)。
const utunHeaderSize = 4

// 本机协议栈交给 utun 的 IPv4 包,补上本机字节序的协议族头。
func utunWrap(pkt []byte) []byte {
	frame := make([]byte, utunHeaderSize+len(pkt))
	binary.NativeEndian.PutUint32(frame, afIPv4)
	copy(frame[utunHeaderSize:], pkt)
	return frame
}

// 从 utun 读到的帧,剥掉协议族头并返回 IP 包。
// 帧太短或不是 IPv4 时返回 false,调用方应继续读下一帧。
func utunUnwrap(frame []byte) ([]byte, bool) {
	if len(frame) <= utunHeaderSize {
		return nil, false
	}
	if binary.NativeEndian.Uint32(frame[:utunHeaderSize]) != afIPv4 {
		return nil, false
	}
	return frame[utunHeaderSize:], true
}

// IPv4 协议族编号。单独命名,避免各平台 syscalls 包定义差异。
const afIPv4 = 2
