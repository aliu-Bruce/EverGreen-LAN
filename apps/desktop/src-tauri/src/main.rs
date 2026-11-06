// 避免 release 构建在 Windows 上多出额外的控制台窗口。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    evergreen_lan_lib::run();
}
