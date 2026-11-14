// Package room 承担房间状态:房间码、成员表与主机角色的房间规则。
// P0 仅立骨架:通道与转发先行,成员管理随后接入。
package room

// Room 描述一个房间的静态信息。
type Room struct {
	Code   string   // 房间码,加入凭证
	Name   string   // 展示名
	Member []string // 成员名列表
}
