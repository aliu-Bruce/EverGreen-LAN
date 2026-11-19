package stream

import "encoding/binary"

// 流帧 wire 格式:
//
//	[1B 类型][4B 流号][4B seq][4B ack][1B flags][4B 载荷长][载荷]
//
// 类型语义:
//   - FrameOpen:  建流;seq/ack 为 0。
//   - FrameData:  seq 为数据帧号(每流每方向从 0 递增);ack 为 0。
//   - FrameAck:   ack 为累积确认(下一个期望的帧号)。
//   - FrameClose: ack 为本方向数据帧总数(finSeq),接收方据此判断数据是否收齐。
//   - FrameCloseAck: 接收方确认收到 FrameClose,ack 原样回填 finSeq。
//
// flags 预留,当前恒为 0。
const (
	FrameData     byte = 0x01
	FrameAck      byte = 0x02
	FrameClose    byte = 0x03
	FrameOpen     byte = 0x04
	FrameCloseAck byte = 0x05
)

const headerLen = 1 + 4 + 4 + 4 + 1 + 4

// Frame 是一帧的解码结果。
type Frame struct {
	Kind    byte
	ID      uint32
	Seq     uint32
	Ack     uint32
	Flags   byte
	Payload []byte
}

func packFrame(f Frame) []byte {
	b := make([]byte, headerLen+len(f.Payload))
	b[0] = f.Kind
	binary.BigEndian.PutUint32(b[1:5], f.ID)
	binary.BigEndian.PutUint32(b[5:9], f.Seq)
	binary.BigEndian.PutUint32(b[9:13], f.Ack)
	b[13] = f.Flags
	binary.BigEndian.PutUint32(b[14:18], uint32(len(f.Payload)))
	copy(b[headerLen:], f.Payload)
	return b
}

// parseFrame 解码一帧;长度不符或类型未知时返回 false。
func parseFrame(b []byte) (Frame, bool) {
	if len(b) < headerLen {
		return Frame{}, false
	}
	f := Frame{
		Kind:  b[0],
		ID:    binary.BigEndian.Uint32(b[1:5]),
		Seq:   binary.BigEndian.Uint32(b[5:9]),
		Ack:   binary.BigEndian.Uint32(b[9:13]),
		Flags: b[13],
	}
	if f.Kind < FrameData || f.Kind > FrameCloseAck {
		return Frame{}, false
	}
	n := int(binary.BigEndian.Uint32(b[14:18]))
	if n < 0 || len(b) < headerLen+n {
		return Frame{}, false
	}
	if n > 0 {
		f.Payload = append([]byte(nil), b[headerLen:headerLen+n]...)
	}
	return f, true
}
