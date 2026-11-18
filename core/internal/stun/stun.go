// Package stun 实现公网映射探测所需的最小 STUN Binding 客户端。
// 只做两件事:编码 Binding 请求,解析 XOR-MAPPED-ADDRESS/MAPPED-ADDRESS;
// 不实现认证、ICE 或中继。服务器只在用户显式探测时访问。
package stun

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"strings"
)

// DefaultServer 是界面与核心共用的默认 STUN 服务器。
const DefaultServer = "stun.l.google.com:19302"

const (
	headerLen = 20
	magic     = 0x2112A442

	typeBindingRequest = 0x0001
	typeBindingSuccess = 0x0101
	typeBindingError   = 0x0111

	attrMappedAddress    = 0x0001
	attrErrorCode        = 0x0009
	attrXORMappedAddress = 0x0020
)

// TransactionID 是 96 位事务标识,响应必须原样带回,用于匹配本次探测。
type TransactionID [12]byte

// NewTransactionID 从密码学随机源生成事务标识。
func NewTransactionID() (TransactionID, error) {
	var tx TransactionID
	if _, err := rand.Read(tx[:]); err != nil {
		return TransactionID{}, fmt.Errorf("stun: 随机源不可用: %w", err)
	}
	return tx, nil
}

// IsMessage 判断报文是否具备 STUN 头部特征:首两位为 0、魔数正确、长度足够。
// 只作为分流条件,进一步校验由 TransactionIDOf 与 ParseSuccess 完成。
func IsMessage(pkt []byte) bool {
	return len(pkt) >= headerLen && pkt[0]&0xC0 == 0 &&
		binary.BigEndian.Uint32(pkt[4:8]) == magic
}

// TransactionIDOf 取出报文中的事务标识。
func TransactionIDOf(pkt []byte) (TransactionID, bool) {
	var tx TransactionID
	if !IsMessage(pkt) {
		return tx, false
	}
	copy(tx[:], pkt[8:20])
	return tx, true
}

// BuildBindingRequest 编码一个不带属性的 Binding 请求。
func BuildBindingRequest(tx TransactionID) []byte {
	out := make([]byte, headerLen)
	binary.BigEndian.PutUint16(out[0:2], typeBindingRequest)
	binary.BigEndian.PutUint16(out[2:4], 0)
	binary.BigEndian.PutUint32(out[4:8], magic)
	copy(out[8:20], tx[:])
	return out
}

// BuildBindingSuccess 编码一个带 XOR-MAPPED-ADDRESS 的成功响应。
// 生产路径只解析响应;此函数供本地自检与测试搭建假服务器。
func BuildBindingSuccess(tx TransactionID, observed *net.UDPAddr) []byte {
	ip := observed.IP.To4()
	if ip == nil {
		ip = net.IPv4zero.To4()
	}
	out := make([]byte, headerLen+12)
	binary.BigEndian.PutUint16(out[0:2], typeBindingSuccess)
	binary.BigEndian.PutUint16(out[2:4], 12)
	binary.BigEndian.PutUint32(out[4:8], magic)
	copy(out[8:20], tx[:])
	binary.BigEndian.PutUint16(out[20:22], attrXORMappedAddress)
	binary.BigEndian.PutUint16(out[22:24], 8)
	out[25] = 0x01 // IPv4
	binary.BigEndian.PutUint16(out[26:28], uint16(observed.Port)^0x2112)
	binary.BigEndian.PutUint32(out[28:32], binary.BigEndian.Uint32(ip)^magic)
	return out
}

// ParseSuccess 解析 Binding 成功响应中的映射地址。
// 优先 XOR-MAPPED-ADDRESS,兼容只给 MAPPED-ADDRESS 的旧服务器;仅支持 IPv4。
func ParseSuccess(pkt []byte) (*net.UDPAddr, error) {
	if !IsMessage(pkt) {
		return nil, fmt.Errorf("stun: 不是有效的 STUN 报文")
	}
	length := int(binary.BigEndian.Uint16(pkt[2:4]))
	end := headerLen + length
	if length%4 != 0 || end > len(pkt) {
		return nil, fmt.Errorf("stun: 报文长度无效")
	}
	switch binary.BigEndian.Uint16(pkt[0:2]) {
	case typeBindingError:
		return nil, parseError(pkt[headerLen:end])
	case typeBindingSuccess:
	default:
		return nil, fmt.Errorf("stun: 非 Binding 响应")
	}

	var mapped, xorMapped *net.UDPAddr
	var ipv6 bool
	for rest := pkt[headerLen:end]; len(rest) >= 4; {
		at := binary.BigEndian.Uint16(rest[0:2])
		alen := int(binary.BigEndian.Uint16(rest[2:4]))
		if 4+alen > len(rest) {
			return nil, fmt.Errorf("stun: 属性长度越界")
		}
		val := rest[4 : 4+alen]
		switch at {
		case attrXORMappedAddress:
			if addr, err := parseAddress(val, true); err == nil {
				xorMapped = addr
			} else if isIPv6(err) {
				ipv6 = true
			}
		case attrMappedAddress:
			if addr, err := parseAddress(val, false); err == nil {
				mapped = addr
			} else if isIPv6(err) {
				ipv6 = true
			}
		}
		advance := (alen + 3) &^ 3
		if 4+advance > len(rest) {
			return nil, fmt.Errorf("stun: 属性填充越界")
		}
		rest = rest[4+advance:]
	}
	if xorMapped != nil {
		return xorMapped, nil
	}
	if mapped != nil {
		return mapped, nil
	}
	if ipv6 {
		return nil, fmt.Errorf("stun: 服务器只返回 IPv6 地址,本版仅支持 IPv4")
	}
	return nil, fmt.Errorf("stun: 响应中没有映射地址")
}

var errIPv6 = fmt.Errorf("stun: IPv6 地址")

// cookie 是魔数按网络字节序的四个字节,用于 XOR-MAPPED-ADDRESS 的地址还原。
var cookie = [4]byte{0x21, 0x12, 0xA4, 0x42}

func isIPv6(err error) bool { return err == errIPv6 }

// parseAddress 解析 MAPPED-ADDRESS 类属性的值;IPv6 只标记,不展开。
func parseAddress(val []byte, xor bool) (*net.UDPAddr, error) {
	if len(val) < 4 {
		return nil, fmt.Errorf("stun: 地址属性过短")
	}
	family := val[1]
	port := int(binary.BigEndian.Uint16(val[2:4]))
	if xor {
		port ^= 0x2112
	}
	switch family {
	case 0x01:
		if len(val) < 8 {
			return nil, fmt.Errorf("stun: IPv4 地址属性过短")
		}
		ip := make(net.IP, 4)
		copy(ip, val[4:8])
		if xor {
			for i := 0; i < 4; i++ {
				ip[i] ^= cookie[i]
			}
		}
		return &net.UDPAddr{IP: ip, Port: port}, nil
	case 0x02:
		return nil, errIPv6
	default:
		return nil, fmt.Errorf("stun: 未知地址族 %d", family)
	}
}

// parseError 解析 ERROR-CODE 属性,整理成可直接展示的中文错误。
func parseError(attrs []byte) error {
	for len(attrs) >= 4 {
		at := binary.BigEndian.Uint16(attrs[0:2])
		alen := int(binary.BigEndian.Uint16(attrs[2:4]))
		if 4+alen > len(attrs) {
			break
		}
		if at == attrErrorCode && alen >= 4 {
			v := attrs[4 : 4+alen]
			code := int(v[2]&0x07)*100 + int(v[3])
			reason := strings.TrimSpace(string(v[4:]))
			reason = strings.ToValidUTF8(reason, "")
			if reason == "" {
				return fmt.Errorf("stun: 服务器返回错误 %d", code)
			}
			return fmt.Errorf("stun: 服务器返回错误 %d:%s", code, reason)
		}
		advance := (alen + 3) &^ 3
		if 4+advance > len(attrs) {
			break
		}
		attrs = attrs[4+advance:]
	}
	return fmt.Errorf("stun: 服务器返回错误响应")
}
