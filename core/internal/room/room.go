// Package room 承担房间状态:房间码、成员表与主机角色的房间规则。
// 房间码是唯一的加入凭证:归一化后作为预共享密钥混入密钥派生,
// 持码者才推得出会话密钥——入房资格由此证明,无需中心服务器。
package room

import (
	"crypto/rand"
	"fmt"
	"strings"
)

// 房间码长度 8;字母表去掉易混字符(0/O、1/I/L),口头转述不出错。
const (
	codeLen      = 8
	codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
)

// Room 描述一个房间的静态信息。
type Room struct {
	Code   string   // 房间码,加入凭证
	Name   string   // 展示名
	Member []string // 成员名列表
}

// NewCode 生成随机房间码,使用密码学随机源,无中心分配。
// 拒绝采样消除取模偏差:落在不能整除字母表的尾部区间就重来。
func NewCode() (string, error) {
	n := len(codeAlphabet)
	out := make([]byte, 0, codeLen)
	buf := make([]byte, codeLen)
	for len(out) < codeLen {
		if _, err := rand.Read(buf); err != nil {
			return "", fmt.Errorf("room: 随机源不可用: %w", err)
		}
		for _, b := range buf {
			if int(b) >= 256/n*n {
				continue
			}
			out = append(out, codeAlphabet[int(b)%n])
			if len(out) == codeLen {
				break
			}
		}
	}
	return string(out), nil
}

// Normalize 把用户输入归一成预共享密钥字节:大写、去分隔符与非字母数字字符。
// 双端对同一输入必须归一出同一结果,密钥派生才能对上;多一个少一个字符都对不上。
func Normalize(code string) []byte {
	code = strings.ToUpper(code)
	var b strings.Builder
	for _, r := range code {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return []byte(b.String())
}

// Display 把房间码排成 4+4,便于口头转述与抄写核对。
func Display(code string) string {
	n := Normalize(code)
	if len(n) <= 4 {
		return string(n)
	}
	return string(n[:4]) + " " + string(n[4:])
}
