package tun

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestUtunFrameRoundTrip(t *testing.T) {
	pkt := []byte{0x45, 0x00, 0x00, 0x54, 0x12, 0x34, 0x56, 0x78}
	frame := utunWrap(pkt)
	if len(frame) != len(pkt)+4 {
		t.Fatalf("帧长 = %d, 期望 %d", len(frame), len(pkt)+4)
	}
	if got := binary.NativeEndian.Uint32(frame[:4]); got != afIPv4 {
		t.Fatalf("协议族头 = %d, 期望 %d", got, afIPv4)
	}
	got, ok := utunUnwrap(frame)
	if !ok {
		t.Fatal("合法 IPv4 帧被拒绝")
	}
	if !bytes.Equal(got, pkt) {
		t.Fatalf("解出的包 = %v, 期望 %v", got, pkt)
	}
}

func TestUtunFrameRejectsBadFrames(t *testing.T) {
	cases := [][]byte{
		nil,
		{0x45, 0x00},
		{0x45, 0x00, 0x00, 0x00}, // 只有头,没有包
	}
	for _, frame := range cases {
		if _, ok := utunUnwrap(frame); ok {
			t.Fatalf("残帧被接受: %v", frame)
		}
	}
	ipv6 := make([]byte, 8)
	binary.NativeEndian.PutUint32(ipv6[:4], 30) // AF_INET6
	if _, ok := utunUnwrap(ipv6); ok {
		t.Fatal("非 IPv4 帧被接受")
	}
}
