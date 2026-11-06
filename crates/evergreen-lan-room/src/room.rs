//! room：一个 UDP socket、多个 Noise 会话、一个虚拟适配器。

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;

use evergreen_lan_core::frame::Frame;
use evergreen_lan_core::handshake::{Handshake, Role, StaticIdentity};
use evergreen_lan_core::ipv4::{self, DestKind, Ipv4Header, MINECRAFT_LAN_MULTICAST};
use evergreen_lan_core::router::{accept_incoming, route_outgoing, Routing};
use evergreen_lan_core::session::PeerSession;
use evergreen_lan_core::{stun, tunnel, InviteCode, TUNNEL_MTU, VIRTUAL_SUBNET};
use evergreen_lan_route::VirtualInterface;
use evergreen_lan_tun::{Adapter, ADAPTER_NAME};

use crate::device::DeviceChannels;

/// 每个 peer 被 ping 的间隔。
const PING_INTERVAL: Duration = Duration::from_secs(10);
/// peer 超过该时长未发出任何消息即视为离线。
const PEER_TIMEOUT: Duration = Duration::from_secs(45);

/// 完成握手但还没发 Hello 的连接能存活多久。
///
/// 访客每次点「加入」都会新建 socket，失败后旧连接会以不同源端口留在主机表里。
/// 之前它们要等满 45 秒才消失，界面看起来像「一大堆用户」。握手阶段没有实际
/// 流量，给 8 秒足够完成 Hello，超时就清掉。
const HALF_OPEN_TIMEOUT: Duration = Duration::from_secs(8);
/// 虚拟网络的前缀长度。
const VIRTUAL_PREFIX: u8 = 16;

/// room 层产生的错误。
#[derive(Debug, thiserror::Error)]
pub enum RoomError {
    /// 无法创建或打开 Wintun 适配器。
    #[error("virtual adapter unavailable: {0}")]
    Adapter(#[from] evergreen_lan_tun::TunError),
    /// 无法配置地址或路由。
    #[error("network configuration failed: {0}")]
    Route(#[from] evergreen_lan_route::RouteError),
    /// 协议核心报告了错误。
    #[error("protocol error: {0}")]
    Core(#[from] evergreen_lan_core::Error),
    /// socket 操作失败。
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    /// 主机始终未确认本机已加入 room。
    #[error("the host did not accept the connection")]
    NoAnswer,
}

/// 在 UI 中展示的 peer。
#[derive(Debug, Clone, PartialEq)]
pub struct PeerInfo {
    /// peer 公布的显示名称。
    pub name: String,
    /// 虚拟子网内的地址。
    pub virtual_ip: [u8; 4],
    /// 该 peer 是否托管 room。
    pub role: Role,
    /// 该 peer 可达的 UDP 端点。
    pub endpoint: SocketAddr,
    /// 最近一次测得的往返时延。
    pub rtt_ms: Option<f32>,
}

impl PeerInfo {
    /// [`PeerInfo::virtual_ip`] 的点分十进制形式。
    pub fn ip_string(&self) -> String {
        format!(
            "{}.{}.{}.{}",
            self.virtual_ip[0], self.virtual_ip[1], self.virtual_ip[2], self.virtual_ip[3]
        )
    }
}

/// 值得告知 UI 的事件。
#[derive(Debug, Clone)]
pub enum RoomEvent {
    /// 某个 peer 完成加入并获得了地址。
    PeerJoined(PeerInfo),
    /// 某个 peer 离开或超时。
    PeerLeft([u8; 4]),
    /// 往返时延发生变化。
    Updated,
    /// room 已关闭。
    Closed,
}

/// room 的启动配置。
pub struct RoomConfig {
    /// 本 peer 的显示名称。
    pub name: String,
    /// 本机的长期身份。
    pub identity: Arc<StaticIdentity>,
    /// 隧道 socket 绑定的地址。生产环境使用 `0.0.0.0:0`，
    /// 测试中使用 `127.0.0.1:0`。
    pub bind: SocketAddr,
    /// 用于发现公网端点的 STUN 服务器。为空即禁用。
    pub stun_servers: Vec<String>,
}

impl RoomConfig {
    /// 桌面 peer 的合理默认值。
    pub fn new(name: impl Into<String>, identity: Arc<StaticIdentity>) -> Self {
        Self {
            name: name.into(),
            identity,
            bind: "0.0.0.0:0".parse().expect("合法的绑定地址"),
            stun_servers: stun::DEFAULT_STUN_SERVERS
                .iter()
                .map(|s| s.to_string())
                .collect(),
        }
    }
}

/// 生命周期必须长于 hub 的操作系统资源。
///
/// 有意保持不透明：只有 [`Room::host`] 与 [`Room::join`] 能构造它，
/// 二者将其保留在 hub 任务内部，以保证拆除顺序正确。
pub struct Resources {
    // 声明在最前，使路由先于适配器消失而被移除。
    _iface: VirtualInterface,
    _adapter: Adapter,
}

/// hub 内部的一个在线 peer。
struct PeerRuntime {
    session: PeerSession,
    endpoint: SocketAddr,
    ip: Option<[u8; 4]>,
    name: String,
    role: Role,
}

impl PeerRuntime {
    fn info(&self, ip: [u8; 4]) -> PeerInfo {
        PeerInfo {
            name: self.name.clone(),
            virtual_ip: ip,
            role: self.role,
            endpoint: self.endpoint,
            rtt_ms: self.session.rtt.map(|d| d.as_secs_f32() * 1000.0),
        }
    }
}

/// 一个运行中的 room。
///
/// 丢弃该值会拆除 room：路由被还原、适配器被关闭，
/// 并向各 peer 发送告别消息。
pub struct Room {
    /// 其他机器加入所需的邀请码。
    pub invite: InviteCode,
    /// 本机在虚拟子网内的地址。
    pub virtual_ip: [u8; 4],
    /// 隧道监听的 UDP 端口。
    pub local_port: u16,
    /// 本机是否托管 room。
    pub hosting: bool,
    /// 入站防火墙规则是否创建成功。
    ///
    /// `None` 表示本机不是托管方，或该结果尚不可用；`Some(false)` 表示规则
    /// 创建失败，此时其他玩家发往虚拟适配器的数据包可能被防火墙丢弃。
    pub firewall_ok: Option<bool>,
    peers: Arc<Mutex<Vec<PeerInfo>>>,
    events: broadcast::Sender<RoomEvent>,
    shutdown: watch::Sender<bool>,
    task: JoinHandle<()>,
}

/// 主机监听的固定 UDP 端口。
///
/// 端口如果每次启动都随机，旧邀请码就会「看起来正常但永远连不上」——
/// 客户端会把握手发到一个没人监听的端口。固定端口让邀请码在重启后依然有效，
/// 也便于在路由器上做端口映射。
pub const HOST_PORT: u16 = 39271;

impl Room {
    /// 创建 room 并开始接受访客。
    pub async fn host(cfg: RoomConfig) -> Result<Self, RoomError> {
        let adapter = Adapter::create(ADAPTER_NAME)?;
        let session = adapter.start_session()?;
        // macOS 的 utun 名称由内核分配，必须用实际名称配置地址与路由。
        let device = adapter.name().to_string();
        let mut iface = VirtualInterface::configure(
            &device,
            evergreen_lan_core::HOST_VIRTUAL_IP,
            VIRTUAL_PREFIX,
            TUNNEL_MTU as u16,
        )?;
        // 否则 Windows 会把 Minecraft 发现组发往物理网卡。
        iface.add_route(MINECRAFT_LAN_MULTICAST, 32)?;

        // 没有入站规则时，防火墙会静默丢弃好友发往虚拟适配器的流量。
        // 尽力而为：失败只会损失可用性，但结果要能显示给用户。
        let firewall_ok = match std::env::current_exe() {
            Ok(exe) => {
                let program = exe.to_string_lossy();
                match evergreen_lan_route::allow_firewall(&program, "EverGreen LAN") {
                    Ok(()) => true,
                    Err(err) => {
                        tracing::warn!(%err, "无法添加防火墙规则");
                        false
                    }
                }
            }
            Err(err) => {
                tracing::warn!(%err, "无法获取自身路径，跳过防火墙规则");
                false
            }
        };

        let device = crate::device::spawn_tun(session);
        let resources = Resources {
            _iface: iface,
            _adapter: adapter,
        };
        let mut room = Self::host_with(cfg, device, Some(resources)).await?;
        room.firewall_ok = Some(firewall_ok);
        Ok(room)
    }

    /// 在调用方提供的设备上创建 room（用于测试或自定义适配器）。
    pub async fn host_with(
        cfg: RoomConfig,
        device: DeviceChannels,
        resources: Option<Resources>,
    ) -> Result<Self, RoomError> {
        // 测试会显式指定 127.0.0.1:0，此时保持随机端口，避免并行用例抢占；
        // 生产环境的默认绑定是 0.0.0.0:0，改用固定端口让邀请码可复用。
        let socket = if cfg.bind.ip().is_unspecified() && cfg.bind.port() == 0 {
            match UdpSocket::bind(("0.0.0.0", HOST_PORT)).await {
                Ok(socket) => socket,
                Err(err) => {
                    tracing::warn!(%err, port = HOST_PORT, "固定端口被占用，改用临时端口");
                    UdpSocket::bind(cfg.bind).await?
                }
            }
        } else {
            UdpSocket::bind(cfg.bind).await?
        };

        let candidates = gather_candidates(&socket, &cfg).await;
        let invite = InviteCode::new(cfg.name.clone(), cfg.identity.public_bytes(), candidates)?;

        Self::spawn(
            cfg,
            invite,
            Role::Host,
            socket,
            evergreen_lan_core::HOST_VIRTUAL_IP,
            Vec::new(),
            device,
            resources,
        )
        .await
    }

    /// 加入由 `invite` 描述的 room。
    pub async fn join(cfg: RoomConfig, invite: InviteCode) -> Result<Self, RoomError> {
        let negotiated = negotiate(&cfg, &invite).await?;
        let ip = negotiated.virtual_ip;

        let adapter = Adapter::create(ADAPTER_NAME)?;
        let session = adapter.start_session()?;
        let mut iface =
            VirtualInterface::configure(adapter.name(), ip, VIRTUAL_PREFIX, TUNNEL_MTU as u16)?;
        iface.add_route(MINECRAFT_LAN_MULTICAST, 32)?;

        // 访客同样可能被连（例如主机加入访客开的局域网世界），
        // 因此两边都要放行虚拟网段。
        if let Ok(exe) = std::env::current_exe() {
            if let Err(err) =
                evergreen_lan_route::allow_firewall(&exe.to_string_lossy(), "EverGreen LAN")
            {
                tracing::warn!(%err, "无法添加防火墙规则");
            }
        }

        let device = crate::device::spawn_tun(session);
        let resources = Resources {
            _iface: iface,
            _adapter: adapter,
        };

        Self::spawn(
            cfg,
            invite,
            Role::Guest,
            negotiated.socket,
            ip,
            negotiated.initial_peers,
            device,
            Some(resources),
        )
        .await
    }

    /// 在调用方提供的设备上加入 room。
    pub async fn join_with(
        cfg: RoomConfig,
        invite: InviteCode,
        device: DeviceChannels,
    ) -> Result<Self, RoomError> {
        let negotiated = negotiate(&cfg, &invite).await?;
        let ip = negotiated.virtual_ip;
        Self::spawn(
            cfg,
            invite,
            Role::Guest,
            negotiated.socket,
            ip,
            negotiated.initial_peers,
            device,
            None,
        )
        .await
    }

    /// 当前 peer 的快照（不含本机）。
    pub fn peers(&self) -> Vec<PeerInfo> {
        self.peers.lock().map(|p| p.clone()).unwrap_or_default()
    }

    /// 订阅 room 的生命周期事件。
    pub fn subscribe(&self) -> broadcast::Receiver<RoomEvent> {
        self.events.subscribe()
    }

    /// 拆除 room 并等待 hub 结束。
    pub async fn shutdown(mut self) {
        let _ = self.shutdown.send(true);
        let _ = (&mut self.task).await;
        let _ = self.events.send(RoomEvent::Closed);
    }

    #[allow(clippy::too_many_arguments)]
    async fn spawn(
        cfg: RoomConfig,
        invite: InviteCode,
        role: Role,
        socket: UdpSocket,
        own_ip: [u8; 4],
        initial_peers: Vec<PeerRuntime>,
        device: DeviceChannels,
        resources: Option<Resources>,
    ) -> Result<Self, RoomError> {
        let local_port = socket.local_addr()?.port();
        let peers = Arc::new(Mutex::new(Vec::new()));
        let (events, _) = broadcast::channel(64);
        let (shutdown, shutdown_rx) = watch::channel(false);

        let hub = Hub {
            hosting: role == Role::Host,
            own_ip,
            name: cfg.name.clone(),
            socket,
            invite: invite.clone(),
            identity: cfg.identity,
            peers_by_addr: HashMap::new(),
            peers_by_ip: HashMap::new(),
            initial_peers,
            device,
            snapshot: peers.clone(),
            events: events.clone(),
            shutdown: shutdown_rx,
            _resources: resources,
        };

        hub.publish();
        let task = tokio::spawn(async move {
            hub.run().await;
        });

        Ok(Self {
            invite,
            virtual_ip: own_ip,
            local_port,
            hosting: role == Role::Host,
            firewall_ok: None,
            peers,
            events,
            shutdown,
            task,
        })
    }
}

impl Drop for Room {
    fn drop(&mut self) {
        // 尽力而为：若 `shutdown()` 未被等待，则请求 hub 停止。
        let _ = self.shutdown.send(true);
    }
}

struct Negotiated {
    socket: UdpSocket,
    virtual_ip: [u8; 4],
    initial_peers: Vec<PeerRuntime>,
}

/// 在改动操作系统之前拨号主机并商定虚拟地址。
async fn negotiate(cfg: &RoomConfig, invite: &InviteCode) -> Result<Negotiated, RoomError> {
    let socket = UdpSocket::bind(cfg.bind).await?;
    let endpoints = invite.endpoints();
    let connected = tunnel::dial(
        &socket,
        &endpoints,
        &cfg.identity,
        &invite.host_pub,
        &invite.psk,
        &invite.room_id,
    )
    .await?;

    let mut session = connected.session;
    let hello = Frame::Hello {
        ip: [0, 0, 0, 0],
        role: Role::Guest,
        name: cfg.name.clone(),
    };

    let mut buf = vec![0u8; 2048];
    let mut assigned: Option<[u8; 4]> = None;
    let mut host_name = String::new();

    // Hello/HelloAck 交换会重试，因为握手到达时主机可能仍在
    // 完成自身的初始化。
    for _ in 0..12 {
        let datagram = session.seal(&hello)?;
        socket.send_to(&datagram, connected.endpoint).await?;

        let deadline = tokio::time::Instant::now() + Duration::from_millis(400);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await {
                Ok(Ok((n, from))) => {
                    if from != connected.endpoint {
                        continue;
                    }
                    match session.open(&buf[..n]) {
                        Ok(Frame::HelloAck { ip, name }) => {
                            assigned = Some(ip);
                            host_name = name;
                            break;
                        }
                        Ok(_) | Err(_) => continue,
                    }
                }
                Ok(Err(_)) => break,
                Err(_) => break,
            }
        }
        if assigned.is_some() {
            break;
        }
    }

    let virtual_ip = assigned.ok_or(RoomError::NoAnswer)?;
    if !VIRTUAL_SUBNET.contains(virtual_ip) {
        return Err(RoomError::NoAnswer);
    }

    let host = PeerRuntime {
        session,
        endpoint: connected.endpoint,
        ip: Some(evergreen_lan_core::HOST_VIRTUAL_IP),
        name: host_name,
        role: Role::Host,
    };

    Ok(Negotiated {
        socket,
        virtual_ip,
        initial_peers: vec![host],
    })
}

/// 构建邀请码携带的候选地址列表。
async fn gather_candidates(socket: &UdpSocket, cfg: &RoomConfig) -> Vec<String> {
    let local = match socket.local_addr() {
        Ok(addr) => addr,
        Err(_) => return vec!["127.0.0.1:1".to_string()],
    };
    let port = local.port();

    // 绑定到特定地址（测试，或用户选定的网卡）意味着 socket 只能在该地址被
    // 访问；绑定到 0.0.0.0 则表示
    // “公布本机实际拥有的地址”。
    let mut candidates = if local.ip().is_unspecified() {
        lan_candidates(port)
    } else {
        vec![local.to_string()]
    };

    if !cfg.stun_servers.is_empty() {
        let servers: Vec<&str> = cfg.stun_servers.iter().map(|s| s.as_str()).collect();
        let mapped = stun::discover(socket, &servers, Duration::from_millis(700)).await;
        for addr in mapped {
            let text = addr.to_string();
            if !candidates.contains(&text) {
                candidates.push(text);
            }
        }
    }

    if candidates.is_empty() {
        candidates.push(format!("127.0.0.1:{port}"));
    }
    candidates
}

/// 好友可能拨通的全部本机 IPv4 地址。
fn lan_candidates(port: u16) -> Vec<String> {
    let interfaces = match if_addrs::get_if_addrs() {
        Ok(interfaces) => interfaces,
        Err(err) => {
            tracing::warn!(%err, "无法枚举网络接口");
            return Vec::new();
        }
    };

    let mut out: Vec<String> = interfaces
        .into_iter()
        .filter(|iface| iface.name != ADAPTER_NAME)
        .filter_map(|iface| match iface.addr.ip() {
            IpAddr::V4(v4) if usable_v4(v4) => Some(format!("{v4}:{port}")),
            _ => None,
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

/// 某个地址是否值得告知 peer。
fn usable_v4(ip: Ipv4Addr) -> bool {
    !ip.is_loopback()
        && !ip.is_link_local()
        && !ip.is_unspecified()
        && !ip.is_broadcast()
        && !VIRTUAL_SUBNET.contains(ip.octets())
        && !is_benchmarking(ip)
}

/// `198.18.0.0/15` 是为基准测试保留的地址段，但代理 TUN 驱动（Clash、
/// Surge 等）会把它当作虚假地址分配出去。公布其中某个地址会把好友
/// 引向一个只存在于本机的地址，因此这类地址在生成邀请码时
/// 会被过滤掉。
fn is_benchmarking(ip: Ipv4Addr) -> bool {
    let [first, second, ..] = ip.octets();
    first == 198 && (second == 18 || second == 19)
}

struct Hub {
    hosting: bool,
    own_ip: [u8; 4],
    name: String,
    socket: UdpSocket,
    invite: InviteCode,
    identity: Arc<StaticIdentity>,
    peers_by_addr: HashMap<SocketAddr, PeerRuntime>,
    peers_by_ip: HashMap<[u8; 4], SocketAddr>,
    initial_peers: Vec<PeerRuntime>,
    device: DeviceChannels,
    snapshot: Arc<Mutex<Vec<PeerInfo>>>,
    events: broadcast::Sender<RoomEvent>,
    shutdown: watch::Receiver<bool>,
    _resources: Option<Resources>,
}

impl Hub {
    async fn run(mut self) {
        for peer in std::mem::take(&mut self.initial_peers) {
            self.insert_peer(peer);
        }
        self.publish();

        let mut buf = vec![0u8; 2048];
        let mut ticker = tokio::time::interval(PING_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                changed = self.shutdown.changed() => {
                    if changed.is_err() || *self.shutdown.borrow() {
                        break;
                    }
                }
                received = self.socket.recv_from(&mut buf) => {
                    match received {
                        Ok((n, from)) => self.on_datagram(&buf[..n], from).await,
                        Err(err) => tracing::trace!(%err, "接收失败"),
                    }
                }
                packet = self.device.from_device.recv() => {
                    match packet {
                        Some(packet) => self.route_outgoing(packet).await,
                        None => break,
                    }
                }
                _ = ticker.tick() => self.on_tick().await,
            }
        }

        self.say_goodbye().await;
        let _ = self.events.send(RoomEvent::Closed);
        tracing::debug!("room 中枢已停止");
    }

    async fn on_datagram(&mut self, data: &[u8], from: SocketAddr) {
        if self.peers_by_addr.contains_key(&from) {
            let opened = self
                .peers_by_addr
                .get_mut(&from)
                .and_then(|peer| peer.session.open(data).ok());
            if let Some(frame) = opened {
                self.handle_frame(from, frame).await;
            }
        } else if self.hosting {
            self.accept_handshake(data, from).await;
        }
    }

    async fn accept_handshake(&mut self, data: &[u8], from: SocketAddr) {
        let mut handshake = match Handshake::host(
            self.identity.as_ref(),
            &self.invite.psk,
            &self.invite.room_id,
        ) {
            Ok(handshake) => handshake,
            Err(err) => {
                tracing::warn!(%err, "无法开始握手");
                return;
            }
        };
        if handshake.read_message(data).is_err() {
            return;
        }
        let reply = match handshake.write_message() {
            Ok(reply) => reply,
            Err(err) => {
                tracing::warn!(%err, "无法应答握手");
                return;
            }
        };
        // 该回复携带主机密钥的唯一副本：丢失它会让访客不得不完整重连，
        // 因此该回复会被发送不止一次。
        for _ in 0..3 {
            let _ = self.socket.send_to(&reply, from).await;
        }

        let Some(remote_static) = handshake.remote_static() else {
            return;
        };
        let transport = match handshake.into_transport() {
            Ok(transport) => transport,
            Err(err) => {
                tracing::warn!(%err, "握手未能完成");
                return;
            }
        };

        let peer = PeerRuntime {
            session: PeerSession::new(transport, from, remote_static),
            endpoint: from,
            ip: None,
            name: String::new(),
            role: Role::Guest,
        };
        tracing::debug!(%from, "已接受访客握手");
        self.insert_peer(peer);
    }

    async fn handle_frame(&mut self, from: SocketAddr, frame: Frame) {
        match frame {
            Frame::Ip(packet) => {
                if accept_incoming(&packet, &VIRTUAL_SUBNET, self.own_ip) {
                    // 发往本机或某个组的数据包属于本地协议栈，
                    // 发往其他 peer 的数据包则不属于：
                    // 在这里注入它，会让主机自身的路由表去转发
                    // 某个本应只是被转交过去的数据包。
                    if self.is_for_me(&packet)
                        && self.device.to_device.send(packet.clone()).await.is_err()
                    {
                        tracing::debug!("设备写入端已关闭");
                    }
                    self.relay(from, packet).await;
                }
            }
            Frame::Ping(seq) => self.send_frame(from, &Frame::Pong(seq)).await,
            Frame::Pong(seq) => {
                let updated = self
                    .peers_by_addr
                    .get_mut(&from)
                    .map(|peer| peer.session.handle_pong(seq).is_some())
                    .unwrap_or(false);
                if updated {
                    self.publish();
                    let _ = self.events.send(RoomEvent::Updated);
                }
            }
            Frame::Hello { ip: _, role, name } => {
                if !self.hosting {
                    return;
                }
                self.register_hello(from, role, name).await;
            }
            Frame::HelloAck { .. } => {}
            Frame::Bye(reason) => {
                tracing::debug!(%from, %reason, "对端发送了告别消息");
                self.remove_peer(from);
            }
        }
    }

    /// 来自 peer 的数据包是否属于本机协议栈。
    fn is_for_me(&self, packet: &[u8]) -> bool {
        let Some(header) = Ipv4Header::parse(packet) else {
            return false;
        };
        if header.dst == self.own_ip {
            return true;
        }
        !matches!(
            ipv4::classify(header.dst, &VIRTUAL_SUBNET),
            DestKind::Unicast
        )
    }

    /// 将访客的数据包转发到 room 的其余成员。
    ///
    /// room 是星形结构：访客只与主机保持会话。若没有这层中继，
    /// 两个访客将完全看不到彼此的局域网游戏，因为双方都无法
    /// 直接寻址对方。同时转发广播组和发往其他访客的单播，
    /// 可使星形结构表现得像一台共享交换机。
    async fn relay(&mut self, from: SocketAddr, packet: Vec<u8>) {
        if !self.hosting {
            return;
        }
        match route_outgoing(&packet, &VIRTUAL_SUBNET, self.own_ip) {
            Routing::Broadcast => {
                let targets: Vec<SocketAddr> = self
                    .peers_by_addr
                    .keys()
                    .copied()
                    .filter(|addr| *addr != from)
                    .collect();
                for addr in targets {
                    self.send_frame(addr, &Frame::Ip(packet.clone())).await;
                }
            }
            Routing::ToPeer(ip) => {
                if let Some(addr) = self.peers_by_ip.get(&ip).copied() {
                    if addr != from {
                        self.send_frame(addr, &Frame::Ip(packet)).await;
                    }
                }
            }
            Routing::Drop(reason) => {
                tracing::trace!(reason = reason.as_str(), "不转发该数据包");
            }
        }
    }

    async fn register_hello(&mut self, from: SocketAddr, role: Role, name: String) {
        let existing = self.peers_by_addr.get(&from).and_then(|peer| peer.ip);
        let assigned = match existing {
            Some(ip) => ip,
            None => {
                let Some(ip) = self.allocate_ip() else {
                    tracing::warn!(%from, "room 已满");
                    self.remove_peer(from);
                    return;
                };
                if let Some(peer) = self.peers_by_addr.get_mut(&from) {
                    peer.ip = Some(ip);
                    peer.name = name.clone();
                    peer.role = role;
                }
                self.peers_by_ip.insert(ip, from);
                ip
            }
        };

        if let Some(peer) = self.peers_by_addr.get_mut(&from) {
            if peer.name.is_empty() {
                peer.name = name;
            }
        }

        let ack = Frame::HelloAck {
            ip: assigned,
            name: self.name.clone(),
        };
        self.send_frame(from, &ack).await;

        self.publish();
        if let Some(peer) = self.peers_by_addr.get(&from) {
            let _ = self.events.send(RoomEvent::PeerJoined(peer.info(assigned)));
        }
    }

    async fn route_outgoing(&mut self, packet: Vec<u8>) {
        match route_outgoing(&packet, &VIRTUAL_SUBNET, self.own_ip) {
            Routing::ToPeer(ip) => {
                if let Some(addr) = self.peers_by_ip.get(&ip).copied() {
                    self.send_frame(addr, &Frame::Ip(packet)).await;
                } else if let Some(gateway) = self.gateway() {
                    // 访客只与主机保持会话。子网内其他任何目标都交给
                    // 主机，由主机中继——就像交换机本会直接
                    // 送达那样。
                    self.send_frame(gateway, &Frame::Ip(packet)).await;
                }
            }
            Routing::Broadcast => {
                // 复制：每个 peer 都必须收到自己的副本，正是这一点
                // 使 Minecraft 的 224.0.2.60 公告能够到达整个 room。
                let targets: Vec<SocketAddr> = self.peers_by_addr.keys().copied().collect();
                for addr in targets {
                    self.send_frame(addr, &Frame::Ip(packet.clone())).await;
                }
            }
            Routing::Drop(reason) => {
                tracing::trace!(
                    reason = reason.as_str(),
                    len = packet.len(),
                    "dropped outgoing packet"
                );
            }
        }
    }

    /// 能替本机路由的 peer：本机是访客时即为主机。
    fn gateway(&self) -> Option<SocketAddr> {
        if self.hosting {
            return None;
        }
        self.peers_by_addr
            .values()
            .find(|peer| peer.role == Role::Host)
            .map(|peer| peer.endpoint)
    }

    async fn on_tick(&mut self) {
        let now = Instant::now();
        let addrs: Vec<SocketAddr> = self.peers_by_addr.keys().copied().collect();

        for addr in addrs {
            let (idle, half_open) = match self.peers_by_addr.get(&addr) {
                Some(peer) => (
                    now.duration_since(peer.session.last_recv_at),
                    peer.ip.is_none(),
                ),
                None => (Duration::ZERO, false),
            };

            let limit = if half_open {
                HALF_OPEN_TIMEOUT
            } else {
                PEER_TIMEOUT
            };

            if idle > limit {
                tracing::info!(%addr, ?idle, "对端超时");
                self.remove_peer(addr);
                continue;
            }

            let ping = self
                .peers_by_addr
                .get_mut(&addr)
                .map(|peer| peer.session.begin_ping());
            if let Some(ping) = ping {
                self.send_frame(addr, &ping).await;
            }
        }
    }

    async fn say_goodbye(&mut self) {
        let targets: Vec<SocketAddr> = self.peers_by_addr.keys().copied().collect();
        for addr in targets {
            if let Some(peer) = self.peers_by_addr.get_mut(&addr) {
                if let Ok(datagram) = peer.session.goodbye("room closed") {
                    let _ = self.socket.send_to(&datagram, addr).await;
                }
            }
        }
        self.peers_by_addr.clear();
        self.peers_by_ip.clear();
        self.publish();
    }

    async fn send_frame(&mut self, addr: SocketAddr, frame: &Frame) {
        let datagram = self
            .peers_by_addr
            .get_mut(&addr)
            .and_then(|peer| peer.session.seal(frame).ok());
        if let Some(datagram) = datagram {
            let _ = self.socket.send_to(&datagram, addr).await;
        }
    }

    fn insert_peer(&mut self, peer: PeerRuntime) {
        if let Some(ip) = peer.ip {
            self.peers_by_ip.insert(ip, peer.endpoint);
        }
        self.peers_by_addr.insert(peer.endpoint, peer);
    }

    fn remove_peer(&mut self, addr: SocketAddr) {
        if let Some(peer) = self.peers_by_addr.remove(&addr) {
            if let Some(ip) = peer.ip {
                self.peers_by_ip.remove(&ip);
                let _ = self.events.send(RoomEvent::PeerLeft(ip));
            }
            self.publish();
        }
    }

    fn allocate_ip(&self) -> Option<[u8; 4]> {
        // .1 是主机，.0 和 .255 是网络地址/广播地址。
        (2u8..254).find_map(|last| {
            let candidate = [10, 66, 0, last];
            if self.peers_by_ip.contains_key(&candidate) {
                None
            } else {
                Some(candidate)
            }
        })
    }

    fn publish(&self) {
        let mut peers: Vec<PeerInfo> = self
            .peers_by_addr
            .values()
            .filter_map(|peer| peer.ip.map(|ip| peer.info(ip)))
            .collect();
        peers.sort_by_key(|peer| peer.virtual_ip);
        if let Ok(mut guard) = self.snapshot.lock() {
            *guard = peers;
        }
    }
}

/// 供测试与诊断使用的便捷函数：从 `src` 发出、
/// 发往发现组的 Minecraft“对局域网开放”数据包。
pub fn minecraft_ping(src: [u8; 4], motd: &str, port: u16) -> Vec<u8> {
    let mut payload = format!("[MOTD]{motd}[/MOTD][AD]{port}[/AD]").into_bytes();
    payload.shrink_to_fit();
    evergreen_lan_core::router::synthetic_udp_packet(
        src,
        MINECRAFT_LAN_MULTICAST,
        4445,
        4445,
        &payload,
    )
}

#[cfg(test)]
mod tests_support {
    use super::*;
    use crate::testing::MockDevice;
    use evergreen_lan_core::router::synthetic_udp_packet;

    pub(super) fn config(name: &str) -> RoomConfig {
        let identity = Arc::new(StaticIdentity::generate().expect("identity"));
        let mut cfg = RoomConfig::new(name, identity);
        cfg.bind = "127.0.0.1:0".parse().expect("loopback");
        // 公共 STUN 服务器会带来真实延迟并产生公网候选地址。
        cfg.stun_servers.clear();
        cfg
    }

    pub(super) async fn start_host() -> (Room, MockDevice) {
        let (device, channels) = MockDevice::new();
        let room = Room::host_with(config("host"), channels, None)
            .await
            .expect("host room");
        (room, device)
    }

    pub(super) async fn start_guest(host: &Room, name: &str) -> (Room, MockDevice) {
        let (device, channels) = MockDevice::new();
        let room = Room::join_with(config(name), host.invite.clone(), channels)
            .await
            .expect("guest room");
        (room, device)
    }
}

#[cfg(test)]
mod tests {
    use super::tests_support::*;
    use super::*;
    use crate::testing::MockDevice;
    use evergreen_lan_core::router::synthetic_udp_packet;

    #[tokio::test]
    async fn unicast_packet_reaches_the_guest() {
        let (host, mut host_device) = start_host().await;
        let (guest, mut guest_device) = start_guest(&host, "guest").await;

        let packet = synthetic_udp_packet(
            host.virtual_ip,
            guest.virtual_ip,
            40000,
            25565,
            b"hello guest",
        );
        host_device.inject(packet.clone()).await;

        let received = guest_device
            .next()
            .await
            .expect("guest should receive the packet");
        assert_eq!(received, packet);
    }

    #[tokio::test]
    async fn guest_answer_reaches_the_host() {
        let (host, mut host_device) = start_host().await;
        let (guest, mut guest_device) = start_guest(&host, "guest").await;

        let packet = synthetic_udp_packet(
            guest.virtual_ip,
            host.virtual_ip,
            25565,
            40000,
            b"hello host",
        );
        guest_device.inject(packet.clone()).await;

        let received = host_device
            .next()
            .await
            .expect("host should receive the packet");
        assert_eq!(received, packet);
    }

    #[tokio::test]
    async fn minecraft_discovery_reaches_every_guest() {
        let (host, mut host_device) = start_host().await;
        let (_first, mut first_device) = start_guest(&host, "alice").await;
        let (_second, mut second_device) = start_guest(&host, "bob").await;

        let announcement = minecraft_ping(host.virtual_ip, "host world", 25565);
        host_device.inject(announcement.clone()).await;

        assert_eq!(
            first_device.next().await.expect("alice receives discovery"),
            announcement
        );
        assert_eq!(
            second_device.next().await.expect("bob receives discovery"),
            announcement
        );
    }

    #[tokio::test]
    async fn guest_announcement_reaches_the_host() {
        let (host, mut host_device) = start_host().await;
        let (guest, mut guest_device) = start_guest(&host, "guest").await;

        let announcement = minecraft_ping(guest.virtual_ip, "guest world", 25565);
        guest_device.inject(announcement.clone()).await;

        assert_eq!(
            host_device.next().await.expect("host receives discovery"),
            announcement
        );
    }

    #[tokio::test]
    async fn internet_traffic_never_enters_the_room() {
        let (host, mut host_device) = start_host().await;
        let (_guest, mut guest_device) = start_guest(&host, "guest").await;

        let escape =
            synthetic_udp_packet(host.virtual_ip, [8, 8, 8, 8], 40000, 443, b"not allowed");
        host_device.inject(escape).await;

        assert!(
            guest_device
                .expect_silence(Duration::from_millis(250))
                .await,
            "a packet addressed outside the virtual subnet must not be forwarded"
        );
    }

    #[tokio::test]
    async fn address_to_self_is_not_forwarded() {
        let (host, mut host_device) = start_host().await;
        let (_guest, mut guest_device) = start_guest(&host, "guest").await;

        let loopback = synthetic_udp_packet(host.virtual_ip, host.virtual_ip, 40000, 40000, b"me");
        host_device.inject(loopback).await;

        assert!(
            guest_device
                .expect_silence(Duration::from_millis(250))
                .await
        );
    }

    #[tokio::test]
    async fn host_assigns_sequential_addresses_and_tracks_names() {
        let (host, _host_device) = start_host().await;
        let (_first, _first_device) = start_guest(&host, "alice").await;
        let (_second, _second_device) = start_guest(&host, "bob").await;

        // 主机只从 Hello 中获知名称，访客会在 join 返回前发送它，
        // 但仍需给 hub 一点时间完成发布。
        tokio::time::sleep(Duration::from_millis(80)).await;

        let mut peers = host.peers();
        peers.sort_by_key(|peer| peer.virtual_ip);
        assert_eq!(peers.len(), 2, "both guests should be tracked");
        assert_eq!(peers[0].virtual_ip, [10, 66, 0, 2]);
        assert_eq!(peers[1].virtual_ip, [10, 66, 0, 3]);
        assert_eq!(peers[0].name, "alice");
        assert_eq!(peers[1].name, "bob");
        assert_eq!(peers[0].role, Role::Guest);
    }

    #[tokio::test]
    async fn guest_learns_its_address_and_the_host() {
        let (host, _host_device) = start_host().await;
        let (guest, _guest_device) = start_guest(&host, "guest").await;

        assert_eq!(guest.virtual_ip, [10, 66, 0, 2]);
        assert!(VIRTUAL_SUBNET.contains(guest.virtual_ip));
        assert_ne!(guest.virtual_ip, host.virtual_ip);
        assert!(!guest.hosting);
        assert!(host.hosting);
    }

    #[tokio::test]
    async fn room_refuses_a_wrong_invitation() {
        let (_host, _host_device) = start_host().await;
        let mut other = config("other");
        other.bind = "127.0.0.1:0".parse().unwrap();
        let (_, channels) = MockDevice::new();

        // 指向无人监听端口的邀请码必须失败，而不是永久挂起。
        let mut bogus = InviteCode::new("bogus", [7u8; 32], vec!["127.0.0.1:1".to_string()])
            .expect("valid invite");
        bogus.psk = [9u8; 32];

        // 必须留足握手预算：Windows 会因为 ICMP 端口不可达立刻返回，
        // 而 Unix 要等满 DIAL_ATTEMPTS × DIAL_ATTEMPT_TIMEOUT 才会报超时。
        let result = tokio::time::timeout(
            Duration::from_secs(20),
            Room::join_with(other, bogus, channels),
        )
        .await;
        assert!(
            matches!(result, Ok(Err(_))),
            "joining a dead room must fail"
        );
    }
}

/// 对公布地址的过滤是纯逻辑，值得直接测试。
#[cfg(test)]
mod candidate_tests {
    use super::*;

    #[test]
    fn public_and_private_addresses_are_usable() {
        assert!(usable_v4("192.168.1.23".parse().unwrap()));
        assert!(usable_v4("10.1.2.3".parse().unwrap()));
        assert!(usable_v4("172.20.1.1".parse().unwrap()));
        assert!(usable_v4("203.0.113.7".parse().unwrap()));
    }

    #[test]
    fn junk_addresses_are_not_usable() {
        assert!(!usable_v4("127.0.0.1".parse().unwrap()), "loopback");
        assert!(!usable_v4("169.254.10.20".parse().unwrap()), "link local");
        assert!(!usable_v4("0.0.0.0".parse().unwrap()), "unspecified");
        assert!(!usable_v4("10.66.0.1".parse().unwrap()), "our own adapter");
    }

    #[test]
    fn proxy_fake_addresses_are_not_advertised() {
        // Clash 风格的 TUN 设备会分配这类地址；好友永远无法访问它们。
        assert!(is_benchmarking("198.18.0.1".parse().unwrap()));
        assert!(is_benchmarking("198.19.255.254".parse().unwrap()));
        assert!(!usable_v4("198.18.0.1".parse().unwrap()));
        assert!(!usable_v4("198.19.3.4".parse().unwrap()));
        // 198.20.x 是正常的公网网段，不能被过滤。
        assert!(!is_benchmarking("198.20.0.1".parse().unwrap()));
        assert!(usable_v4("198.20.0.1".parse().unwrap()));
    }
}

/// room 是星形结构，因此主机必须中继。缺少这些测试，两个访客
/// 将永远看不到彼此的局域网游戏。
#[cfg(test)]
mod relay_tests {
    use super::tests_support::*;
    use super::*;
    use evergreen_lan_core::router::synthetic_udp_packet;

    #[tokio::test]
    async fn guest_announcement_reaches_another_guest() {
        let (host, _host_device) = start_host().await;
        let (alice, mut alice_device) = start_guest(&host, "alice").await;
        let (_bob, mut bob_device) = start_guest(&host, "bob").await;

        let announcement = minecraft_ping(alice.virtual_ip, "alice world", 25565);
        alice_device.inject(announcement.clone()).await;

        assert_eq!(
            bob_device
                .next()
                .await
                .expect("bob should see alice's game"),
            announcement,
            "the host must relay guest broadcast to other guests"
        );
    }

    #[tokio::test]
    async fn guest_can_reach_another_guest_directly() {
        let (host, _host_device) = start_host().await;
        let (alice, mut alice_device) = start_guest(&host, "alice").await;
        let (bob, mut bob_device) = start_guest(&host, "bob").await;

        let packet =
            synthetic_udp_packet(alice.virtual_ip, bob.virtual_ip, 40000, 25565, b"hi bob");
        alice_device.inject(packet.clone()).await;

        assert_eq!(
            bob_device.next().await.expect("bob should receive"),
            packet,
            "unicast between two guests must be relayed by the host"
        );
    }

    #[tokio::test]
    async fn host_does_not_loop_a_packet_back_to_its_sender() {
        let (host, mut host_device) = start_host().await;
        let (_alice, mut alice_device) = start_guest(&host, "alice").await;

        let announcement = minecraft_ping([10, 66, 0, 2], "alice world", 25565);
        alice_device.inject(announcement).await;

        // 主机自身必须看到它（主机既是中继者也是参与者）……
        assert!(host_device.next().await.is_some(), "host should receive");
        // ……但发送方不应收到自己广播的回声。
        assert!(
            alice_device
                .expect_silence(Duration::from_millis(250))
                .await,
            "a relayed packet must never return to its sender"
        );
    }
}
