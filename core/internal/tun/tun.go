// Package tun 提供虚拟网卡的平台抽象。
// 原则:本包只做 IP 包的读取与写入,不承担加密、转发与地址管理;
// 平台差异全部收敛在各平台实现文件中,上层只面向统一接口。
package tun

import (
	"fmt"
	"net"
)

// Device 是一块已经就绪的虚拟网卡。
// Read 阻塞直到取到一个 IP 包;Write 立即注入一个 IP 包。
// 两次 Read 之间允许返回零值错误重试,调用方应当只在致命错误时退出。
type Device interface {
	Name() string
	MTU() int
	Read() ([]byte, error)
	Write(pkt []byte) error
	Close() error
}

// Config 描述创建网卡所需的全部信息。
type Config struct {
	Name string // 适配器别名,如 EGLAN;同机多实例时用不同名
	CIDR string // 本端隧道地址,如 10.66.7.1/24
	MTU  int    // 0 表示采用平台默认值
}

// ParseCIDR 拆出地址与掩码,给平台实现配置用。
func ParseCIDR(cidr string) (net.IP, net.IPMask, error) {
	ip, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, nil, fmt.Errorf("tun: 地址段无效 %q: %w", cidr, err)
	}
	if ip4 := ip.To4(); ip4 != nil {
		return ip4, ipnet.Mask, nil
	}
	return ip, ipnet.Mask, nil
}
