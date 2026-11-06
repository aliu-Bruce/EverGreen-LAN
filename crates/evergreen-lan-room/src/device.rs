//! 数据包路径的两端。
//!
//! hub 从不直接与 Wintun 通信，而是通过两个通道交互：
//!
//! * `from_device` — 操作系统要发送的数据包，
//! * `to_device` — 隧道要注入的数据包。
//!
//! 正是这层间接，使整个数据平面无需适配器、驱动或管理员权限
//! 即可测试：测试把同样的通道接到一个 mock 上，
//! 而不接触任何真实设备。

use tokio::sync::mpsc;

/// hub 用于访问虚拟适配器的通道。
pub struct DeviceChannels {
    /// 从适配器读取、待路由到 peer 的数据包。
    pub from_device: mpsc::Receiver<Vec<u8>>,
    /// 待写入适配器的数据包。
    pub to_device: mpsc::Sender<Vec<u8>>,
}

/// 每个设备队列的深度。1024 个数据包约为 1.2 MB 的缓冲流量，
/// 远超链路在需要反压之前所需的量。
const QUEUE: usize = 1024;

/// 在专用线程上驱动一个 Wintun 会话。
///
/// Wintun 的接收 API 是阻塞等待，其发送 API 不可与自身并发，
/// 因此单个线程在 10 ms 循环中处理两个方向。
pub fn spawn_tun(session: evergreen_lan_tun::Session) -> DeviceChannels {
    let (from_device_tx, from_device) = mpsc::channel::<Vec<u8>>(QUEUE);
    let (to_device, mut to_device_rx) = mpsc::channel::<Vec<u8>>(QUEUE);

    std::thread::Builder::new()
        .name("evergreen-lan-tun".into())
        .spawn(move || {
            loop {
                // 入站：排空适配器已排队的全部数据。
                if session.wait_readable(10) {
                    loop {
                        match session.receive() {
                            Ok(Some(packet)) => {
                                if from_device_tx.blocking_send(packet).is_err() {
                                    tracing::debug!("hub 已退出，TUN 读取线程停止");
                                    return;
                                }
                            }
                            Ok(None) => break,
                            Err(err) => {
                                tracing::error!(%err, "TUN 接收失败");
                                return;
                            }
                        }
                    }
                }

                // 出站：推送隧道产生的数据。
                loop {
                    match to_device_rx.try_recv() {
                        Ok(packet) => {
                            if let Err(err) = session.send(&packet) {
                                tracing::warn!(%err, "TUN 发送失败");
                            }
                        }
                        Err(mpsc::error::TryRecvError::Empty) => break,
                        Err(mpsc::error::TryRecvError::Disconnected) => {
                            tracing::debug!("hub 已退出，TUN 写入线程停止");
                            return;
                        }
                    }
                }
            }
        })
        .expect("无法启动 TUN 线程");

    DeviceChannels {
        from_device,
        to_device,
    }
}
