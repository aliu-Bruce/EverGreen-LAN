//go:build !windows

package disc

import "syscall"

// reuseAddr 允许同机多个实例共享发现端口;广播信标给谁都算数。
func reuseAddr(network, address string, c syscall.RawConn) error {
	var serr error
	if err := c.Control(func(fd uintptr) {
		serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
	}); err != nil {
		return err
	}
	return serr
}
