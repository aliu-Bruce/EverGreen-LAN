// Package elevate 负责"以管理员权限启动"这一件事:
// 查询当前进程的权限,并在支持的系统上以指定参数拉起新进程。
// 平台差异全部收在本包,build tag 分文件;其它包只看到三个函数。
package elevate
