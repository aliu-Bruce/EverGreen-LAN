package stun

import (
	"encoding/binary"
	"encoding/hex"
	"net"
	"strings"
	"testing"
)

// RFC 5769 2.2 的 IPv4 响应:SOFTWARE + XOR-MAPPED-ADDRESS + 完整性与指纹。
const rfc5769IPv4 = "0101003c2112a442b7e7a701bc34d686fa87dfae" +
	"8022000b7465737420766563746f7220" +
	"002000080001a147e112a643" +
	"000800142b91f599fd9e90c38c7489f92af9ba53f06be7d7" +
	"80280004c07d4c96"

// RFC 5769 2.3 的 IPv6 响应:本版只支持 IPv4,应给出明确拒绝。
const rfc5769IPv6 = "010100482112a442b7e7a701bc34d686fa87dfae" +
	"8022000b7465737420766563746f7220" +
	"002000140002a1470113a9faa5d3f179bc25f4b5bed2b9d9" +
	"00080014a382954e4be67bf11784c97c8292c275bfe3ed41" +
	"80280004c8fb0b4c"

func decode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("测试向量不是合法十六进制: %v", err)
	}
	return b
}

func TestParseRFC5769IPv4(t *testing.T) {
	addr, err := ParseSuccess(decode(t, rfc5769IPv4))
	if err != nil {
		t.Fatalf("解析 RFC 5769 IPv4 响应失败: %v", err)
	}
	if got, want := addr.String(), "192.0.2.1:32853"; got != want {
		t.Fatalf("映射地址 = %s, want %s", got, want)
	}
}

func TestParseRFC5769IPv6(t *testing.T) {
	_, err := ParseSuccess(decode(t, rfc5769IPv6))
	if err == nil || !strings.Contains(err.Error(), "IPv6") {
		t.Fatalf("IPv6 响应应被明确拒绝, got %v", err)
	}
}

func TestRequestRoundTrip(t *testing.T) {
	tx, err := NewTransactionID()
	if err != nil {
		t.Fatal(err)
	}
	req := BuildBindingRequest(tx)
	if len(req) != headerLen {
		t.Fatalf("请求长度 = %d, want %d", len(req), headerLen)
	}
	if !IsMessage(req) {
		t.Fatal("请求应被识别为 STUN 报文")
	}
	got, ok := TransactionIDOf(req)
	if !ok || got != tx {
		t.Fatalf("事务标识不匹配: %v %v", got, ok)
	}
	if binary.BigEndian.Uint16(req[0:2]) != typeBindingRequest {
		t.Fatalf("请求类型 = %#x", binary.BigEndian.Uint16(req[0:2]))
	}
}

func TestSuccessRoundTrip(t *testing.T) {
	tx, err := NewTransactionID()
	if err != nil {
		t.Fatal(err)
	}
	want := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 9), Port: 62000}
	got, err := ParseSuccess(BuildBindingSuccess(tx, want))
	if err != nil {
		t.Fatalf("解析成功响应失败: %v", err)
	}
	if !got.IP.Equal(want.IP) || got.Port != want.Port {
		t.Fatalf("映射地址 = %s, want %s", got, want)
	}
}

func TestLegacyMappedAddress(t *testing.T) {
	tx, _ := NewTransactionID()
	pkt := make([]byte, headerLen+12)
	binary.BigEndian.PutUint16(pkt[0:2], typeBindingSuccess)
	binary.BigEndian.PutUint16(pkt[2:4], 12)
	binary.BigEndian.PutUint32(pkt[4:8], magic)
	copy(pkt[8:20], tx[:])
	binary.BigEndian.PutUint16(pkt[20:22], attrMappedAddress)
	binary.BigEndian.PutUint16(pkt[22:24], 8)
	pkt[25] = 0x01
	binary.BigEndian.PutUint16(pkt[26:28], 47777)
	copy(pkt[28:32], net.IPv4(198, 51, 100, 7).To4())
	addr, err := ParseSuccess(pkt)
	if err != nil {
		t.Fatalf("解析旧式 MAPPED-ADDRESS 失败: %v", err)
	}
	if got, want := addr.String(), "198.51.100.7:47777"; got != want {
		t.Fatalf("映射地址 = %s, want %s", got, want)
	}
}

func TestErrorResponse(t *testing.T) {
	tx, _ := NewTransactionID()
	reason := []byte("Allocation Mismatch")
	valueLen := 4 + len(reason)
	padded := (valueLen + 3) &^ 3
	pkt := make([]byte, headerLen+4+padded)
	binary.BigEndian.PutUint16(pkt[0:2], typeBindingError)
	binary.BigEndian.PutUint16(pkt[2:4], uint16(4+padded))
	binary.BigEndian.PutUint32(pkt[4:8], magic)
	copy(pkt[8:20], tx[:])
	binary.BigEndian.PutUint16(pkt[20:22], attrErrorCode)
	binary.BigEndian.PutUint16(pkt[22:24], uint16(valueLen))
	pkt[26] = 4
	pkt[27] = 37
	copy(pkt[28:], reason)
	_, err := ParseSuccess(pkt)
	if err == nil || !strings.Contains(err.Error(), "437") {
		t.Fatalf("错误响应应带错误码 437, got %v", err)
	}
}

func TestRejectNoise(t *testing.T) {
	for _, pkt := range [][]byte{
		nil,
		[]byte("EGLANH1"),
		{0x00, 0x01, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	} {
		if IsMessage(pkt) {
			t.Fatalf("噪声报文被误判为 STUN: %x", pkt)
		}
	}
}
