//! 手动验证探针：创建一个真实 room 并报告操作系统的行为。
//!
//! 该程序需以管理员权限运行，以检查无法进行单元测试的部分：
//!
//! ```powershell
//! Start-Process target\debug\host_probe.exe -Verb RunAs -ArgumentList "artifacts\probe.log"
//! ```
//!
//! 它写出日志文件而不是 stdout，因为提权进程无法
//! 继承非提权进程的控制台。

use std::sync::Arc;
use std::time::Duration;

use evergreen_lan_core::handshake::StaticIdentity;
use evergreen_lan_room::{Room, RoomConfig};

fn main() {
    let log_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "probe.log".to_string());

    let mut log = String::new();
    log.push_str("EverGreen LAN host probe\n");
    log.push_str(&format!("admin={}\n", is_admin()));

    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            log.push_str(&format!("FAIL runtime: {err}\n"));
            let _ = std::fs::write(&log_path, log);
            return;
        }
    };

    runtime.block_on(async {
        let identity = Arc::new(StaticIdentity::generate().expect("identity"));
        let mut config = RoomConfig::new("probe", identity);
        // 保持探针离线：此处只关注操作系统一侧。
        config.stun_servers.clear();

        match Room::host(config).await {
            Ok(room) => {
                let invite = room.invite.encode().unwrap_or_default();
                log.push_str("OK adapter created\n");
                log.push_str(&format!("virtual_ip={}\n", dotted(room.virtual_ip)));
                log.push_str(&format!("udp_port={}\n", room.local_port));
                log.push_str(&format!("candidates={:?}\n", room.invite.candidates));
                log.push_str(&format!("invite_len={}\n", invite.len()));
                log.push_str(&format!("fingerprint={}\n", room.invite.fingerprint()));
                let _ = std::fs::write(&log_path, &log);

                // 保持适配器打开足够长的时间，以便外部观察者
                // 通过 netsh 查询到地址与路由。
                tokio::time::sleep(Duration::from_secs(12)).await;
                room.shutdown().await;
                log.push_str("SHUTDOWN clean\n");
            }
            Err(err) => {
                log.push_str(&format!("FAIL {err}\n"));
            }
        }
    });

    let _ = std::fs::write(&log_path, log);
}

fn dotted(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

#[cfg(windows)]
fn is_admin() -> bool {
    unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
}

#[cfg(not(windows))]
fn is_admin() -> bool {
    false
}
