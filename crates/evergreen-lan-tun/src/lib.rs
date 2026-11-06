//! 对 [Wintun](https://www.wintun.net/) 驱动的一层薄封装。
//!
//! Wintun 是 WireGuard for Windows 使用的、经过签名的精简 TUN 驱动。
//! 它提供第三层适配器：读写原始 IPv4 报文，完全不涉及
//! 以太网帧。
//!
//! 两条硬性事实决定了本 crate 的形态：
//!
//! * 创建适配器需要**管理员**权限，缺少权限时 Windows 会报告一条
//!   笼统的 "access denied"，因此 [`TunError::NeedsAdmin`]
//!   负责把它转换为 UI 可以展示的信息；
//! * `wintun.dll` 在**运行时**加载，因此应用可以在缺少驱动的情况下
//!   启动并报告该问题，而不是启动失败。
//!
//! `WintunReceivePacket` 同一时刻只能由一个线程调用，
//! `WintunAllocateSendPacket`/`WintunSendPacket` 也是如此。[`Session`]
//! 因此暴露的是 `&self` 方法，但必须由单个读取任务驱动。

use std::path::PathBuf;

/// 虚拟适配器在 Windows 中的名称。
pub const ADAPTER_NAME: &str = "EverGreen LAN";
/// `Get-NetAdapter` 显示的隧道类型。
pub const TUNNEL_TYPE: &str = "EverGreen";

/// Wintun 层产生的错误。
#[derive(Debug, thiserror::Error)]
pub enum TunError {
    /// 未能找到 `wintun.dll`。
    #[error(
        "wintun.dll was not found; it ships with EverGreen LAN and must sit beside the executable"
    )]
    DriverMissing,
    /// `wintun.dll` 存在，但无法加载或缺少导出符号。
    #[error("wintun.dll could not be loaded: {0}")]
    DriverLoad(String),
    /// 适配器创建被拒绝；进程未提权。
    #[error("creating the virtual adapter requires administrator rights")]
    NeedsAdmin,
    /// 一次 Wintun 调用失败。
    #[error("wintun call `{call}` failed: {source}")]
    Api {
        /// 失败函数的名称。
        call: &'static str,
        /// 底层的 Windows 错误。
        #[source]
        source: std::io::Error,
    },
    /// 适配器名称不被 Wintun 接受。
    #[error("invalid adapter name: {0}")]
    InvalidName(String),
    /// 会话环形缓冲区容量不在驱动支持的范围内。
    #[error("invalid ring capacity {0}")]
    InvalidCapacity(u32),
    /// 报文大于驱动可接受的大小。
    #[error("packet of {0} bytes is too large for the adapter")]
    PacketTooLarge(usize),
}

/// 本 crate 的结果别名。
pub type Result<T> = std::result::Result<T, TunError>;

/// 已加载驱动的摘要，用于 UI 诊断。
#[derive(Debug, Clone)]
pub struct DriverInfo {
    /// DLL 的加载路径。
    pub path: PathBuf,
    /// Wintun 报告的驱动版本。
    pub version: u32,
}

#[cfg(windows)]
mod imp {
    use std::ffi::c_void;
    use std::path::PathBuf;
    use std::sync::{Arc, OnceLock};

    use libloading::Library;

    use super::{DriverInfo, Result, TunError};
    use super::{ADAPTER_NAME, TUNNEL_TYPE};

    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_ALREADY_EXISTS: u32 = 183;
    const WINTUN_MIN_RING_CAPACITY: u32 = 0x20000;
    const WINTUN_MAX_RING_CAPACITY: u32 = 0x400_0000;

    /// 默认环形缓冲区：4 MiB，足以应对突发流量较多的局域网会话。
    pub const DEFAULT_RING_CAPACITY: u32 = 0x40_0000;

    /// 驱动能够交给调用方的最大报文。
    pub const MAX_PACKET: usize = 65_535 + 64;

    #[repr(C)]
    struct Guid {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [u8; 8],
    }

    type CreateAdapterFn =
        unsafe extern "system" fn(*const u16, *const u16, *const Guid) -> *mut c_void;
    type OpenAdapterFn = unsafe extern "system" fn(*const u16) -> *mut c_void;
    type CloseAdapterFn = unsafe extern "system" fn(*mut c_void);
    type GetAdapterLuidFn = unsafe extern "system" fn(*mut c_void, *mut u64);
    type StartSessionFn = unsafe extern "system" fn(*mut c_void, u32) -> *mut c_void;
    type EndSessionFn = unsafe extern "system" fn(*mut c_void);
    type GetReadWaitEventFn = unsafe extern "system" fn(*mut c_void) -> *mut c_void;
    type ReceivePacketFn = unsafe extern "system" fn(*mut c_void, *mut u32) -> *mut u8;
    type ReleaseReceivePacketFn = unsafe extern "system" fn(*mut c_void, *const u8);
    type AllocateSendPacketFn = unsafe extern "system" fn(*mut c_void, u32) -> *mut u8;
    type SendPacketFn = unsafe extern "system" fn(*mut c_void, *const u8);
    type DriverVersionFn = unsafe extern "system" fn() -> u32;

    unsafe extern "system" {
        fn WaitForSingleObject(handle: *mut c_void, milliseconds: u32) -> u32;
    }

    const WAIT_OBJECT_0: u32 = 0;

    struct Api {
        create_adapter: CreateAdapterFn,
        open_adapter: OpenAdapterFn,
        close_adapter: CloseAdapterFn,
        get_adapter_luid: GetAdapterLuidFn,
        start_session: StartSessionFn,
        end_session: EndSessionFn,
        get_read_wait_event: GetReadWaitEventFn,
        receive_packet: ReceivePacketFn,
        release_receive_packet: ReleaseReceivePacketFn,
        allocate_send_packet: AllocateSendPacketFn,
        send_packet: SendPacketFn,
        driver_version: DriverVersionFn,
    }

    /// 已加载的驱动。只要仍有适配器或会话存活，它就保持存活。
    pub struct Driver {
        _lib: Library,
        api: Api,
        info: DriverInfo,
    }

    // 加载完成后，函数指针与库句柄均不可变。
    unsafe impl Send for Driver {}
    unsafe impl Sync for Driver {}

    impl Driver {
        fn load() -> Result<Arc<Driver>> {
            let mut attempts: Vec<PathBuf> = Vec::new();
            // 显式覆盖优先：打包后的应用把该变量指向
            // 随资源目录分发的 `wintun.dll`，该文件不一定
            // 位于可执行文件旁边。
            if let Some(explicit) = std::env::var_os("EVERGREEN_LAN_WINTUN_DLL") {
                attempts.push(PathBuf::from(explicit));
            }
            if let Ok(exe) = std::env::current_exe() {
                if let Some(dir) = exe.parent() {
                    attempts.push(dir.join("wintun.dll"));
                }
            }
            if let Some(sys) = std::env::var_os("SystemRoot") {
                attempts.push(PathBuf::from(sys).join("System32").join("wintun.dll"));
            }
            if let Some(pf) = std::env::var_os("ProgramFiles") {
                attempts.push(PathBuf::from(pf).join("WireGuard").join("wintun.dll"));
            }
            attempts.push(PathBuf::from("wintun.dll"));

            let mut last: Option<String> = None;
            for path in attempts {
                let is_bare_name = path.to_string_lossy() == "wintun.dll";
                if !is_bare_name && !path.is_file() {
                    continue;
                }
                match load_from(&path) {
                    Ok(driver) => {
                        tracing::info!(
                            path = %driver.info.path.display(),
                            version = driver.info.version,
                            "wintun 驱动已加载"
                        );
                        return Ok(Arc::new(driver));
                    }
                    Err(err) => last = Some(err.to_string()),
                }
            }
            Err(TunError::DriverLoad(last.unwrap_or_else(|| {
                "no wintun.dll beside the executable, in System32, or on PATH".into()
            })))
        }
    }

    fn load_from(path: &PathBuf) -> Result<Driver> {
        // SAFETY: 加载任意 DLL 本身即不安全；此处只接受来自已知位置的
        // 已签名 Wintun 驱动，并且每个导出符号都会在库被保存之前
        // 复制为带类型的函数指针。
        unsafe {
            let lib = Library::new(path)
                .map_err(|e| TunError::DriverLoad(format!("{}: {e}", path.display())))?;

            macro_rules! sym {
                ($name:literal) => {
                    *lib.get::<*const c_void>($name).map_err(|e| {
                        TunError::DriverLoad(format!(
                            "{}: {e}",
                            String::from_utf8_lossy($name).trim_end_matches('\0')
                        ))
                    })?
                };
            }
            // 先以不透明指针的形式取出每个导出符号，再 transmute
            // 为带类型的签名。这样宏保持简单，借用的
            // 生命周期也较短。
            let create_adapter: CreateAdapterFn =
                std::mem::transmute(sym!(b"WintunCreateAdapter\0"));
            let open_adapter: OpenAdapterFn = std::mem::transmute(sym!(b"WintunOpenAdapter\0"));
            let close_adapter: CloseAdapterFn = std::mem::transmute(sym!(b"WintunCloseAdapter\0"));
            let get_adapter_luid: GetAdapterLuidFn =
                std::mem::transmute(sym!(b"WintunGetAdapterLUID\0"));
            let start_session: StartSessionFn = std::mem::transmute(sym!(b"WintunStartSession\0"));
            let end_session: EndSessionFn = std::mem::transmute(sym!(b"WintunEndSession\0"));
            let get_read_wait_event: GetReadWaitEventFn =
                std::mem::transmute(sym!(b"WintunGetReadWaitEvent\0"));
            let receive_packet: ReceivePacketFn =
                std::mem::transmute(sym!(b"WintunReceivePacket\0"));
            let release_receive_packet: ReleaseReceivePacketFn =
                std::mem::transmute(sym!(b"WintunReleaseReceivePacket\0"));
            let allocate_send_packet: AllocateSendPacketFn =
                std::mem::transmute(sym!(b"WintunAllocateSendPacket\0"));
            let send_packet: SendPacketFn = std::mem::transmute(sym!(b"WintunSendPacket\0"));
            let driver_version: DriverVersionFn =
                std::mem::transmute(sym!(b"WintunGetRunningDriverVersion\0"));

            let api = Api {
                create_adapter,
                open_adapter,
                close_adapter,
                get_adapter_luid,
                start_session,
                end_session,
                get_read_wait_event,
                receive_packet,
                release_receive_packet,
                allocate_send_packet,
                send_packet,
                driver_version,
            };

            let version = (api.driver_version)();
            Ok(Driver {
                _lib: lib,
                api,
                info: DriverInfo {
                    path: path.clone(),
                    version,
                },
            })
        }
    }

    fn driver() -> Result<Arc<Driver>> {
        static DRIVER: OnceLock<std::result::Result<Arc<Driver>, String>> = OnceLock::new();
        match DRIVER.get_or_init(|| Driver::load().map_err(|e| e.to_string())) {
            Ok(driver) => Ok(driver.clone()),
            Err(message) => {
                if message.contains("not found") {
                    Err(TunError::DriverMissing)
                } else {
                    Err(TunError::DriverLoad(message.clone()))
                }
            }
        }
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn check_name(name: &str) -> Result<()> {
        if name.is_empty() || name.len() > 128 {
            return Err(TunError::InvalidName(format!(
                "length must be 1..=128, got {}",
                name.len()
            )));
        }
        Ok(())
    }

    /// 第三层适配器，可与操作系统之间收发 IPv4 报文。
    pub struct Adapter {
        driver: Arc<Driver>,
        handle: *mut c_void,
        luid: u64,
        name: String,
    }

    // 适配器句柄按文档说明可安全地用于多个线程。
    unsafe impl Send for Adapter {}
    unsafe impl Sync for Adapter {}

    impl Adapter {
        /// 创建 EverGreen LAN 适配器（需要提权）。
        pub fn create(name: &str) -> Result<Self> {
            Self::create_with(name, TUNNEL_TYPE)
        }

        /// 使用显式指定的隧道类型创建适配器。
        ///
        /// 如果适配器已经存在——例如崩溃的实例，或应用的另一个副本——
        /// 则改为打开它而不是报错，因为残留的适配器
        /// 属于可恢复情况，不应成为拒绝工作的理由。
        pub fn create_with(name: &str, tunnel_type: &str) -> Result<Self> {
            check_name(name)?;
            let driver = driver()?;
            let name_w = wide(name);
            let tunnel_w = wide(tunnel_type);
            // SAFETY: 两个字符串都以 NUL 结尾，且存活时间长于该调用；
            // 传入空 GUID 表示让 Wintun 自行生成一个。
            let handle = unsafe {
                (driver.api.create_adapter)(name_w.as_ptr(), tunnel_w.as_ptr(), std::ptr::null())
            };
            if handle.is_null() {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) {
                    return Err(TunError::NeedsAdmin);
                }
                if err.raw_os_error() == Some(ERROR_ALREADY_EXISTS as i32) {
                    tracing::warn!(name, "适配器已存在，改为接管");
                    return Self::open(name);
                }
                return Err(TunError::Api {
                    call: "WintunCreateAdapter",
                    source: err,
                });
            }
            Self::finish(driver, handle, name)
        }

        /// 按名称附加到已有的适配器。
        pub fn open(name: &str) -> Result<Self> {
            check_name(name)?;
            let driver = driver()?;
            let name_w = wide(name);
            // SAFETY: `name_w` 以 NUL 结尾，且存活时间长于该调用。
            let handle = unsafe { (driver.api.open_adapter)(name_w.as_ptr()) };
            if handle.is_null() {
                return Err(TunError::Api {
                    call: "WintunOpenAdapter",
                    source: std::io::Error::last_os_error(),
                });
            }
            Self::finish(driver, handle, name)
        }

        fn finish(driver: Arc<Driver>, handle: *mut c_void, name: &str) -> Result<Self> {
            let mut luid: u64 = 0;
            // SAFETY: `handle` 是有效适配器，`luid` 可写。
            unsafe { (driver.api.get_adapter_luid)(handle, &mut luid) };
            tracing::debug!(name, luid = format!("{luid:#x}"), "适配器就绪");
            Ok(Self {
                driver,
                handle,
                luid,
                name: name.to_string(),
            })
        }

        /// 打开该适配器时使用的名称。
        pub fn name(&self) -> &str {
            &self.name
        }

        /// 适配器的本地唯一标识符，用于路由表项。
        pub fn luid(&self) -> u64 {
            self.luid
        }

        /// 驱动元数据。
        pub fn driver_info(&self) -> &DriverInfo {
            &self.driver.info
        }

        /// 打开一个报文环形会话。
        pub fn start_session(&self) -> Result<Session> {
            self.start_session_with(DEFAULT_RING_CAPACITY)
        }

        /// 以显式指定的容量打开报文环形会话。
        pub fn start_session_with(&self, capacity: u32) -> Result<Session> {
            if !(WINTUN_MIN_RING_CAPACITY..=WINTUN_MAX_RING_CAPACITY).contains(&capacity) {
                return Err(TunError::InvalidCapacity(capacity));
            }
            // SAFETY: 适配器句柄在 `self` 的生命周期内始终有效。
            let handle = unsafe { (self.driver.api.start_session)(self.handle, capacity) };
            if handle.is_null() {
                return Err(TunError::Api {
                    call: "WintunStartSession",
                    source: std::io::Error::last_os_error(),
                });
            }
            // SAFETY: `handle` 是活动会话。
            let event = unsafe { (self.driver.api.get_read_wait_event)(handle) };
            Ok(Session {
                driver: self.driver.clone(),
                handle,
                read_event: event,
            })
        }
    }

    impl Drop for Adapter {
        fn drop(&mut self) {
            // SAFETY: 该句柄由本适配器持有，并且只关闭一次。
            unsafe { (self.driver.api.close_adapter)(self.handle) };
            tracing::debug!(name = %self.name, "适配器已关闭");
        }
    }

    /// 原始 IPv4 报文的双向流。
    ///
    /// 按约定为单线程：`receive` 与 `send` 由同一个任务驱动。
    pub struct Session {
        driver: Arc<Driver>,
        handle: *mut c_void,
        read_event: *mut c_void,
    }

    unsafe impl Send for Session {}

    impl Session {
        /// 报文可用时被置位的事件的原始句柄。
        pub fn read_event(&self) -> *mut c_void {
            self.read_event
        }

        /// 阻塞直到有报文可用或超时。
        ///
        /// 会话可读时返回 `true`。
        pub fn wait_readable(&self, timeout_ms: u32) -> bool {
            // SAFETY: `read_event` 是本会话的有效可等待句柄。
            let rc = unsafe { WaitForSingleObject(self.read_event, timeout_ms) };
            rc == WAIT_OBJECT_0
        }

        /// 取出下一个报文（如果有排队）。
        pub fn receive(&self) -> Result<Option<Vec<u8>>> {
            let mut size: u32 = 0;
            // SAFETY: `handle` 是活动会话，且 `size` 可写。
            let packet = unsafe { (self.driver.api.receive_packet)(self.handle, &mut size) };
            if packet.is_null() {
                return Ok(None);
            }
            let size = size as usize;
            if size > MAX_PACKET {
                // SAFETY: 收到的每个报文都必须释放。
                unsafe { (self.driver.api.release_receive_packet)(self.handle, packet) };
                return Err(TunError::PacketTooLarge(size));
            }
            // SAFETY: 驱动保证 `packet` 处有 `size` 个可读字节。
            let bytes = unsafe { std::slice::from_raw_parts(packet, size) }.to_vec();
            // SAFETY: 报文在复制完成后只释放一次。
            unsafe { (self.driver.api.release_receive_packet)(self.handle, packet) };
            Ok(Some(bytes))
        }

        /// 将一个报文排队，交由 OS 网络栈发送。
        pub fn send(&self, packet: &[u8]) -> Result<()> {
            if packet.len() > MAX_PACKET {
                return Err(TunError::PacketTooLarge(packet.len()));
            }
            // SAFETY: `handle` 是活动会话。
            let buffer =
                unsafe { (self.driver.api.allocate_send_packet)(self.handle, packet.len() as u32) };
            if buffer.is_null() {
                return Err(TunError::Api {
                    call: "WintunAllocateSendPacket",
                    source: std::io::Error::last_os_error(),
                });
            }
            // SAFETY: 驱动保证有 `packet.len()` 个可写字节。
            unsafe {
                std::ptr::copy_nonoverlapping(packet.as_ptr(), buffer, packet.len());
                (self.driver.api.send_packet)(self.handle, buffer);
            }
            Ok(())
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            // SAFETY: 会话句柄由此处持有，并且只结束一次。
            unsafe { (self.driver.api.end_session)(self.handle) };
        }
    }

    /// 是否存在可加载的驱动；不会创建适配器。
    pub fn driver_info() -> Option<DriverInfo> {
        driver().ok().map(|d| d.info.clone())
    }

    /// 便捷常量，调用方无需硬编码名称。
    pub const fn adapter_name() -> &'static str {
        ADAPTER_NAME
    }
}

#[cfg(unix)]
mod imp {
    //! Unix 实现：macOS 走 `utun`，Linux 走 `/dev/net/tun`。
    //!
    //! 两者都是「打开一个字符设备 / 控制套接字，然后直接读写 IP 报文」的模型，
    //! 与 Wintun 的环形缓冲不同，因此没有 `Session` 句柄，只有一份文件描述符。
    //! macOS 的 utun 在报文前带一个 4 字节地址族头，这里统一在读写时处理。

    use std::ffi::CString;
    use std::os::unix::io::RawFd;
    use std::path::PathBuf;

    use libc::{c_char, c_int, c_short, c_ulong, c_void};

    use super::{DriverInfo, Result, TunError};

    /// 与 Wintun 保持同一量级的默认缓冲；utun 用不到，保留以对齐接口。
    pub const DEFAULT_RING_CAPACITY: u32 = 0x40_0000;

    /// 单条报文的上限。
    pub const MAX_PACKET: usize = 65_535 + 64;

    /// macOS utun 的地址族头长度（big-endian AF_INET）。
    const UTUN_HEADER: usize = 4;

    /// 打开后的虚拟网卡。
    pub struct Adapter {
        name: String,
        fd: RawFd,
        info: DriverInfo,
    }

    impl Adapter {
        /// 创建网卡；已存在同名设备时等价于打开它。
        pub fn create(name: &str) -> Result<Self> {
            Self::open(name)
        }

        /// 打开虚拟网卡。
        ///
        /// Linux 会按 `name` 申请设备名，macOS 由内核分配 `utunN`。
        pub fn open(name: &str) -> Result<Self> {
            let (fd, actual) = platform::open_device(name)?;
            platform::set_nonblocking(fd)?;
            Ok(Self {
                name: actual,
                fd,
                info: DriverInfo {
                    path: PathBuf::from(platform::DEVICE_PATH),
                    // 非驱动版本号；界面只用来判断「是否可用」。
                    version: 1,
                },
            })
        }

        /// 内核实际分配的名称。
        pub fn name(&self) -> &str {
            &self.name
        }

        /// Windows 的适配器 LUID；Unix 没有对应概念。
        pub fn luid(&self) -> u64 {
            0
        }

        /// 当前网卡所用的后端信息。
        pub fn driver_info(&self) -> &DriverInfo {
            &self.info
        }

        /// 打开一个报文会话。
        pub fn start_session(&self) -> Result<Session> {
            self.start_session_with(DEFAULT_RING_CAPACITY)
        }

        /// 打开一个报文会话；`capacity` 在 Unix 上没有意义。
        pub fn start_session_with(&self, _capacity: u32) -> Result<Session> {
            // SAFETY：fd 有效，dup 返回一个新的描述符由 Session 独占。
            let fd = unsafe { libc::dup(self.fd) };
            if fd < 0 {
                return Err(platform::last_error());
            }
            Ok(Session {
                fd,
                prefix: platform::HAS_FAMILY_HEADER,
            })
        }
    }

    impl Drop for Adapter {
        fn drop(&mut self) {
            // SAFETY：fd 由本结构独占，只关闭一次。
            unsafe { libc::close(self.fd) };
        }
    }

    /// 一份可读写的报文会话。
    pub struct Session {
        fd: RawFd,
        /// 报文前是否带 4 字节地址族头（macOS 需要）。
        prefix: bool,
    }

    impl Session {
        /// 等待可读；超时返回 `false`。
        pub fn wait_readable(&self, timeout_ms: u32) -> bool {
            let mut pollfd = libc::pollfd {
                fd: self.fd,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY：pollfd 已正确初始化，数组长度为 1。
            let ready = unsafe { libc::poll(&mut pollfd, 1, timeout_ms as c_int) };
            ready > 0
        }

        /// 读取一个报文；没有数据时返回 `Ok(None)`。
        pub fn receive(&self) -> Result<Option<Vec<u8>>> {
            let mut buffer = vec![0u8; MAX_PACKET];
            // SAFETY：缓冲区长度与传入长度一致，fd 在会话存活期间有效。
            let read =
                unsafe { libc::read(self.fd, buffer.as_mut_ptr() as *mut c_void, buffer.len()) };
            if read < 0 {
                return match platform::would_block() {
                    true => Ok(None),
                    false => Err(platform::last_error()),
                };
            }
            if read == 0 {
                return Ok(None);
            }

            let read = read as usize;
            if self.prefix {
                if read <= UTUN_HEADER {
                    return Ok(None);
                }
                let mut packet = buffer[UTUN_HEADER..read].to_vec();
                // utun 可能回传 IPv6 报文，本程序只处理 IPv4。
                if buffer[UTUN_HEADER] >> 4 != 4 {
                    packet.clear();
                    return Ok(None);
                }
                return Ok(Some(packet));
            }

            buffer.truncate(read);
            Ok(Some(buffer))
        }

        /// 写入一个报文。
        pub fn send(&self, packet: &[u8]) -> Result<()> {
            if packet.len() > MAX_PACKET {
                return Err(TunError::PacketTooLarge(packet.len()));
            }

            let written = if self.prefix {
                // macOS：前置 big-endian AF_INET(2)。
                let mut framed = Vec::with_capacity(UTUN_HEADER + packet.len());
                framed.extend_from_slice(&[0, 0, 0, 2]);
                framed.extend_from_slice(packet);
                // SAFETY：缓冲区长度与传入长度一致。
                unsafe { libc::write(self.fd, framed.as_ptr() as *const c_void, framed.len()) }
            } else {
                // SAFETY：缓冲区长度与传入长度一致。
                unsafe { libc::write(self.fd, packet.as_ptr() as *const c_void, packet.len()) }
            };

            if written < 0 {
                return Err(platform::last_error());
            }
            Ok(())
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            // SAFETY：fd 由本会话独占，只关闭一次。
            unsafe { libc::close(self.fd) };
        }
    }

    /// 是否存在可用的虚拟网卡后端。
    pub fn driver_info() -> Option<DriverInfo> {
        platform::available().then(|| DriverInfo {
            path: PathBuf::from(platform::DEVICE_PATH),
            version: 1,
        })
    }

    /// 该平台可用的网卡名称；实际名称由 `Adapter::name` 给出。
    pub const fn adapter_name() -> &'static str {
        platform::DEFAULT_NAME
    }

    /// 把任意名称整理成合法的接口名。
    ///
    /// Linux 的接口名不能超过 15 字节且不允许空格，macOS 的名称由内核决定。
    pub fn sanitize_name(name: &str) -> String {
        let mut out: String = name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect();
        out = out.trim_matches('-').to_string();
        if out.is_empty() {
            out = "evergreen".to_string();
        }
        out.truncate(15);
        out
    }

    #[cfg(target_os = "linux")]
    mod platform {
        //! Linux：`/dev/net/tun` + `TUNSETIFF`，无报文头。

        use super::*;

        pub const DEVICE_PATH: &str = "/dev/net/tun";
        pub const DEFAULT_NAME: &str = "evergreen0";
        pub const HAS_FAMILY_HEADER: bool = false;

        const IFF_TUN: c_short = 0x0001;
        const IFF_NO_PI: c_short = 0x1000;
        const TUNSETIFF: c_ulong = 0x4004_54ca;
        const IFNAMSIZ: usize = 16;

        #[repr(C)]
        struct IfReq {
            name: [c_char; IFNAMSIZ],
            flags: c_short,
            padding: [u8; 22],
        }

        pub fn open_device(name: &str) -> Result<(RawFd, String)> {
            let path = CString::new(DEVICE_PATH).expect("设备路径不含 NUL");
            // SAFETY：路径是有效的 C 字符串。
            let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
            if fd < 0 {
                return Err(last_error());
            }

            let requested = if name.is_empty() {
                super::sanitize_name(DEFAULT_NAME)
            } else {
                super::sanitize_name(name)
            };

            let mut req = IfReq {
                name: [0; IFNAMSIZ],
                flags: IFF_TUN | IFF_NO_PI,
                padding: [0; 22],
            };
            for (slot, byte) in req.name.iter_mut().zip(requested.as_bytes()) {
                *slot = *byte as c_char;
            }

            // SAFETY：ifreq 布局与内核约定一致，fd 来自上面的 open。
            if unsafe { libc::ioctl(fd, TUNSETIFF, &mut req) } < 0 {
                let err = last_error();
                // SAFETY：fd 由本函数持有。
                unsafe { libc::close(fd) };
                return Err(err);
            }

            let actual = req
                .name
                .iter()
                .take_while(|c| **c != 0)
                .map(|c| *c as u8 as char)
                .collect::<String>();

            Ok((fd, actual))
        }

        pub fn set_nonblocking(fd: RawFd) -> Result<()> {
            // SAFETY：fcntl 只读写本 fd 的标志位。
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 {
                return Err(last_error());
            }
            // SAFETY：同上。
            if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
                return Err(last_error());
            }
            Ok(())
        }

        pub fn available() -> bool {
            std::path::Path::new(DEVICE_PATH).exists()
        }

        pub fn would_block() -> bool {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            errno == libc::EAGAIN || errno == libc::EWOULDBLOCK
        }

        pub fn last_error() -> TunError {
            let err = std::io::Error::last_os_error();
            match err.raw_os_error() {
                Some(libc::EPERM) | Some(libc::EACCES) => TunError::NeedsAdmin,
                Some(libc::ENOENT) => TunError::DriverMissing,
                _ => TunError::DriverLoad(err.to_string()),
            }
        }
    }

    #[cfg(target_os = "macos")]
    mod platform {
        //! macOS：`utun` 控制套接字，报文前有 4 字节地址族头。

        use super::*;

        pub const DEVICE_PATH: &str = "utun";
        pub const DEFAULT_NAME: &str = "utun";
        pub const HAS_FAMILY_HEADER: bool = true;

        const AF_SYSTEM: c_int = 32;
        const AF_SYS_CONTROL: u16 = 2;
        const SYSPROTO_CONTROL: c_int = 2;
        const UTUN_OPT_IFNAME: c_int = 2;
        const CTLIOCGINFO: c_ulong = 0xc064_4e03;

        #[repr(C)]
        struct CtlInfo {
            ctl_id: u32,
            ctl_name: [c_char; 96],
        }

        #[repr(C)]
        struct SockaddrCtl {
            sc_len: u8,
            sc_family: u8,
            ss_sysaddr: u16,
            sc_id: u32,
            sc_unit: u32,
            sc_reserved: [u32; 5],
        }

        pub fn open_device(_name: &str) -> Result<(RawFd, String)> {
            // SAFETY：socket 参数固定，失败只会返回 -1。
            let fd = unsafe { libc::socket(AF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
            if fd < 0 {
                return Err(last_error());
            }

            let mut info = CtlInfo {
                ctl_id: 0,
                ctl_name: [0; 96],
            };
            for (slot, byte) in info.ctl_name.iter_mut().zip(UTUN_CONTROL.as_bytes()) {
                *slot = *byte as c_char;
            }

            // SAFETY：结构体布局与 Apple 的 ctl_info 一致。
            if unsafe { libc::ioctl(fd, CTLIOCGINFO, &mut info) } < 0 {
                let err = last_error();
                // SAFETY：fd 由本函数持有。
                unsafe { libc::close(fd) };
                return Err(err);
            }

            let address = SockaddrCtl {
                sc_len: std::mem::size_of::<SockaddrCtl>() as u8,
                sc_family: AF_SYSTEM as u8,
                ss_sysaddr: AF_SYS_CONTROL,
                sc_id: info.ctl_id,
                sc_unit: 0,
                sc_reserved: [0; 5],
            };

            // SAFETY：sockaddr_ctl 是连接内核控制模块要求的地址格式。
            let connected = unsafe {
                libc::connect(
                    fd,
                    &address as *const SockaddrCtl as *const libc::sockaddr,
                    std::mem::size_of::<SockaddrCtl>() as libc::socklen_t,
                )
            };
            if connected < 0 {
                let err = last_error();
                // SAFETY：fd 由本函数持有。
                unsafe { libc::close(fd) };
                return Err(err);
            }

            let mut buffer = [0u8; 32];
            let mut length = buffer.len() as libc::socklen_t;
            // SAFETY：缓冲区与长度都与内核约定一致。
            if unsafe {
                libc::getsockopt(
                    fd,
                    SYSPROTO_CONTROL,
                    UTUN_OPT_IFNAME,
                    buffer.as_mut_ptr() as *mut c_void,
                    &mut length,
                )
            } < 0
            {
                let err = last_error();
                // SAFETY：fd 由本函数持有。
                unsafe { libc::close(fd) };
                return Err(err);
            }

            let actual = buffer
                .iter()
                .take_while(|byte| **byte != 0)
                .map(|byte| *byte as char)
                .collect::<String>();

            Ok((fd, actual))
        }

        pub fn set_nonblocking(fd: RawFd) -> Result<()> {
            // SAFETY：fcntl 只读写本 fd 的标志位。
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 {
                return Err(last_error());
            }
            // SAFETY：同上。
            if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
                return Err(last_error());
            }
            Ok(())
        }

        pub fn available() -> bool {
            // utun 是内核模块，能建 socket 即视为可用。
            // SAFETY：socket 调用只做可用性探测。
            let fd = unsafe { libc::socket(AF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
            if fd < 0 {
                return false;
            }
            // SAFETY：fd 由本函数持有。
            unsafe { libc::close(fd) };
            true
        }

        pub fn would_block() -> bool {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            errno == libc::EAGAIN || errno == libc::EWOULDBLOCK
        }

        pub fn last_error() -> TunError {
            let err = std::io::Error::last_os_error();
            match err.raw_os_error() {
                Some(libc::EPERM) | Some(libc::EACCES) => TunError::NeedsAdmin,
                Some(libc::ENOENT) => TunError::DriverMissing,
                _ => TunError::DriverLoad(err.to_string()),
            }
        }

        const UTUN_CONTROL: &str = "com.apple.net.utun_control";
    }

    #[cfg(test)]
    mod tests {
        use super::sanitize_name;

        #[test]
        fn interface_names_are_short_and_legal() {
            assert_eq!(sanitize_name("EverGreen LAN"), "evergreen-lan");
            assert_eq!(sanitize_name(""), "evergreen");
            assert_eq!(sanitize_name("a/b c"), "a-b-c");
            assert!(sanitize_name(&"x".repeat(40)).len() <= 15);
        }
    }
}

pub use imp::{adapter_name, driver_info, Adapter, Session, DEFAULT_RING_CAPACITY, MAX_PACKET};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_driver_state_without_panicking() {
        // 在未安装 Wintun 的 CI 机器上为 None；在开发机上为 Some。
        let info = driver_info();
        println!("driver info: {info:?}");
    }

    #[test]
    fn adapter_name_is_stable() {
        #[cfg(windows)]
        assert_eq!(adapter_name(), "EverGreen LAN");
        // Unix 的名称只是建议值：Linux 受 15 字符上限约束，macOS 由内核分配。
        #[cfg(unix)]
        assert!(!adapter_name().is_empty());
    }
}
