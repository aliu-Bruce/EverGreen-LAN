//go:build windows && (amd64 || arm64)

package filedialog

import (
	"fmt"
	"syscall"
	"unsafe"
)

// OPENFILENAMEW 的 64 位布局;字段名与 Win32 对应,中间补位保持对齐。
type openFileName struct {
	structSize      uint32
	pad1            uint32
	owner           uintptr
	instance        uintptr
	filter          *uint16
	customFilter    *uint16
	maxCustomFilter uint32
	filterIndex     uint32
	file            *uint16
	maxFile         uint32
	pad2            uint32
	fileTitle       *uint16
	maxFileTitle    uint32
	pad3            uint32
	initialDir      *uint16
	title           *uint16
	flags           uint32
	fileOffset      uint16
	fileExtension   uint16
	defaultExt      *uint16
	custData        uintptr
	hook            uintptr
	templateName    *uint16
	reserved        uintptr
	reserved2       uint32
	flagsEx         uint32
}

const (
	ofnOverwritePrompt = 0x00000002
	ofnHideReadOnly    = 0x00000004
	ofnNoChangeDir     = 0x00000008
	ofnPathMustExist   = 0x00000800
	ofnFileMustExist   = 0x00001000
	ofnExplorer        = 0x00080000
)

var (
	comdlg32            = syscall.NewLazyDLL("comdlg32.dll")
	procGetOpenFileName = comdlg32.NewProc("GetOpenFileNameW")
	procGetSaveFileName = comdlg32.NewProc("GetSaveFileNameW")
	procCommDlgExtError = comdlg32.NewProc("CommDlgExtendedError")
)

const fileBufLen = 4096

func open(title string) (string, error) {
	title16, _ := syscall.UTF16PtrFromString(title)
	filter, _ := syscall.UTF16PtrFromString("所有文件\x00*.*\x00")
	buf := make([]uint16, fileBufLen)
	ofn := openFileName{
		owner:       0,
		filter:      filter,
		filterIndex: 1,
		file:        &buf[0],
		maxFile:     fileBufLen,
		title:       title16,
		flags:       ofnExplorer | ofnFileMustExist | ofnPathMustExist | ofnHideReadOnly | ofnNoChangeDir,
		structSize:  uint32(unsafe.Sizeof(openFileName{})),
	}
	ok, err := callDialog(procGetOpenFileName, &ofn)
	if err != nil || !ok {
		return "", err
	}
	return syscall.UTF16ToString(buf), nil
}

func save(title, defaultName string) (string, error) {
	title16, _ := syscall.UTF16PtrFromString(title)
	filter, _ := syscall.UTF16PtrFromString("所有文件\x00*.*\x00")
	buf := make([]uint16, fileBufLen)
	if name := syscall.StringToUTF16(defaultName); len(name) < fileBufLen && len(defaultName) > 0 {
		copy(buf, name) // 已含结尾 NUL
	}
	ofn := openFileName{
		owner:       0,
		filter:      filter,
		filterIndex: 1,
		file:        &buf[0],
		maxFile:     fileBufLen,
		title:       title16,
		flags:       ofnExplorer | ofnOverwritePrompt | ofnPathMustExist | ofnHideReadOnly | ofnNoChangeDir,
		structSize:  uint32(unsafe.Sizeof(openFileName{})),
	}
	ok, err := callDialog(procGetSaveFileName, &ofn)
	if err != nil || !ok {
		return "", err
	}
	return syscall.UTF16ToString(buf), nil
}

// callDialog 调用对话框:返回 true 表示已选择,false 且 err 为 nil 表示用户取消。
func callDialog(proc *syscall.LazyProc, ofn *openFileName) (bool, error) {
	r, _, _ := proc.Call(uintptr(unsafe.Pointer(ofn)))
	if r != 0 {
		return true, nil
	}
	code, _, _ := procCommDlgExtError.Call()
	if code == 0 {
		return false, nil // 用户取消
	}
	return false, fmt.Errorf("filedialog: 系统对话框失败(代码 0x%x)", code)
}
