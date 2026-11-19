// Package filedialog 调用操作系统的原生文件选择与保存对话框。
//
// 平台能力在 Go 二进制内实现(Windows 用 comdlg32 的 GetOpenFileNameW /
// GetSaveFileNameW),符合「不依赖脚本、不引入第三方库」的约定;
// 不支持的平台返回 ErrUnsupported,由界面降级为手动输入路径。
package filedialog

import "errors"

// ErrUnsupported 表示当前平台没有实现原生对话框。
var ErrUnsupported = errors.New("filedialog: 当前平台不支持系统文件对话框")

// Open 弹出打开文件对话框,返回用户选择的绝对路径。
// 用户取消时 path 为空且 err 为 nil。
func Open(title string) (string, error) { return open(title) }

// Save 弹出保存对话框,defaultName 作为建议文件名。
// 用户取消时 path 为空且 err 为 nil。
func Save(title, defaultName string) (string, error) { return save(title, defaultName) }
