// Package disc 负责对端发现:从房间码解析出可连接的地址。
// P0 直接使用 host:port,房间码解析在 P1 接入。
package disc

// Target 是一次连接的目标。
type Target struct {
	Addr string // host:port
}
