//! 设备层的测试替身。
//!
//! 公开暴露（不位于 `#[cfg(test)]` 之后），以便桌面应用和
//! 未来的集成测试无需驱动即可运行一个 room。

use std::time::Duration;

use tokio::sync::mpsc;

use crate::device::DeviceChannels;

/// 完全驻留在内存中的虚拟适配器。
pub struct MockDevice {
    /// 注入一个数据包，如同操作系统发出的一样。
    pub inbound: mpsc::Sender<Vec<u8>>,
    /// room 希望写入适配器的数据包。
    pub outbound: mpsc::Receiver<Vec<u8>>,
}

impl MockDevice {
    /// 将设备拆分为两个方向。
    pub fn new() -> (Self, DeviceChannels) {
        let (inbound, from_device) = mpsc::channel(64);
        let (to_device, outbound) = mpsc::channel(64);
        (
            Self { inbound, outbound },
            DeviceChannels {
                from_device,
                to_device,
            },
        )
    }

    /// 模拟操作系统发送了 `packet`。
    pub async fn inject(&self, packet: Vec<u8>) {
        self.inbound
            .send(packet)
            .await
            .expect("room 已停止读取设备");
    }

    /// 等待 room 希望交给操作系统的数据包。
    pub async fn next(&mut self) -> Option<Vec<u8>> {
        tokio::time::timeout(Duration::from_secs(3), self.outbound.recv())
            .await
            .ok()
            .flatten()
    }

    /// 断言在 `window` 时间内没有数据到达。
    pub async fn expect_silence(&mut self, window: Duration) -> bool {
        tokio::time::timeout(window, self.outbound.recv())
            .await
            .is_err()
    }
}

impl Default for MockDevice {
    fn default() -> Self {
        Self::new().0
    }
}
