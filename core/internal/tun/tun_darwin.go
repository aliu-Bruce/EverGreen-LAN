//go:build darwin

package tun

import (
	"errors"
)

// macOS 实现:经由 utun 控制接口创建内核隧道设备,地址与 MTU 交给 ifconfig。
// utun 的挂接依赖 AF_SYSTEM 控制套接字,细节须在真实 macOS 上验证,
// P0 阶段先明确拒绝,避免给出半成品行为。

var errUnsupported = errors.New("tun: macOS(utun)实现待接入,须在 macOS 上开发验证")

func New(cfg Config) (Device, error) { return nil, errUnsupported }
