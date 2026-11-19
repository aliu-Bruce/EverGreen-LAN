package stream

import "time"

// 可靠传输参数:所有涉及传输行为的代码以此为准。
const (
	// maxOutstanding 是未确认加排队字节的上限,即发送窗口(背压来源)。
	maxOutstanding = 256 * 1024

	// maxChunk 是单个数据帧载荷上限;须保证整帧装进一个 UDP 报文。
	maxChunk = 32 * 1024

	// rtoStart/rtoMax 重传计时起点与上限(逐次翻倍,确认清空后复位)。
	rtoStart = 200 * time.Millisecond
	rtoMax   = 3 * time.Second

	// watchInterval 发送守护的轮转节拍。
	watchInterval = 10 * time.Millisecond

	// closeGrace 关闭后等待对端确认的宽限期,超时放弃剩余数据。
	closeGrace = 15 * time.Second

	// acceptTimeout 等待对端建流的最长时间。
	acceptTimeout = 30 * time.Second
)

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
