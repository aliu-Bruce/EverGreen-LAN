//go:build !windows || (windows && !amd64 && !arm64)

package filedialog

// 非 Windows(以及 32 位 Windows)没有实现原生对话框:
// 界面据此降级为手动输入路径,而不是让功能不可用。
func open(string) (string, error)         { return "", ErrUnsupported }
func save(string, string) (string, error) { return "", ErrUnsupported }
