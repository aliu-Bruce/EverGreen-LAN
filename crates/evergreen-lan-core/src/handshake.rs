//! 对等会话之间基于 Noise 的双向认证。
//!
//! 每个会话都使用 `Noise_IKpsk0_25519_ChaChaPoly_BLAKE2s`：
//!
//! * `IK` 让访客获得密码学证明：对端持有邀请码中的静态密钥，同时让主机
//!   获知访客的静态密钥。IK 是**两条消息**的模式（先是 `<- s`，然后是
//!   `-> e, es, s, ss` 和 `<- e, ee, se`）。
//! * `psk0` 在第一条消息之前混入房间密钥，因此主机在执行昂贵运算之前
//!   就会拒绝任何并非来自邀请码持有者的数据报。
//! * 房间 id 用作 Noise 的 prologue，把会话绑定到一个房间。
//!
//! 本模块只暴露纯粹的握手状态机。通过 UDP 驱动它（重传、超时）的实现
//! 位于 [`crate::tunnel`]。

use snow::params::NoiseParams;
use snow::{Builder, HandshakeState, TransportState};

use crate::{Error, Result};

/// Noise 模式字符串：IK，房间密钥在第 0 个位置混入。
pub const NOISE_PATTERN: &str = "Noise_IKpsk0_25519_ChaChaPoly_BLAKE2s";

/// X25519 密钥与房间密钥的长度。
pub const KEY_LEN: usize = 32;

/// 每条 Noise 消息末尾附带的 AES-GCM/ChaChaPoly 认证标签长度。
pub const TAG_LEN: usize = 16;

/// 单条握手消息的上界。IK 消息远小于 200 字节。
const MAX_HANDSHAKE_MESSAGE: usize = 1024;

/// 握手属于连接的哪一端。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// 创建房间并发布邀请码的对端。
    Host,
    /// 粘贴邀请码并向主机拨号的对端。
    Guest,
}

/// 本机长期使用的 X25519 身份。
///
/// 密钥对在重启之间保持稳定，以便对端识别同一台机器，
/// 并使虚拟地址的分配保持可预测。
#[derive(Clone, PartialEq, Eq)]
pub struct StaticIdentity {
    private: [u8; KEY_LEN],
    public: [u8; KEY_LEN],
}

impl std::fmt::Debug for StaticIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 绝不打印私钥部分。
        f.debug_struct("StaticIdentity")
            .field("public", &hex::encode(self.public))
            .finish()
    }
}

impl StaticIdentity {
    /// 生成新的随机身份。
    pub fn generate() -> Result<Self> {
        let params = noise_params()?;
        let keypair = Builder::new(params).generate_keypair()?;
        Self::from_parts(&keypair.private, &keypair.public)
    }

    /// 从持久化的字节重建身份。
    pub fn from_parts(private: &[u8], public: &[u8]) -> Result<Self> {
        if private.len() != KEY_LEN || public.len() != KEY_LEN {
            return Err(Error::Crypto(format!(
                "expected {KEY_LEN}-byte keys, got private={} public={}",
                private.len(),
                public.len()
            )));
        }
        if private.iter().all(|b| *b == 0) || public.iter().all(|b| *b == 0) {
            return Err(Error::Crypto("identity key must not be all zeroes".into()));
        }
        let mut priv_arr = [0u8; KEY_LEN];
        let mut pub_arr = [0u8; KEY_LEN];
        priv_arr.copy_from_slice(private);
        pub_arr.copy_from_slice(public);
        Ok(Self {
            private: priv_arr,
            public: pub_arr,
        })
    }

    /// 用于持久化的原始私钥。须谨慎处理。
    pub fn private_bytes(&self) -> &[u8; KEY_LEN] {
        &self.private
    }

    /// 原始公钥。
    pub fn public_bytes(&self) -> [u8; KEY_LEN] {
        self.public
    }

    /// 公钥的小写十六进制表示。
    pub fn public_hex(&self) -> String {
        hex::encode(self.public)
    }
}

fn noise_params() -> Result<NoiseParams> {
    NOISE_PATTERN
        .parse::<NoiseParams>()
        .map_err(|e| Error::Crypto(format!("bad noise pattern: {e}")))
}

/// 进行中的 Noise 握手的其中一端。
pub struct Handshake {
    state: HandshakeState,
    role: Role,
}

impl Handshake {
    /// 访客端：从邀请码中得知主机的静态公钥。
    pub fn guest(
        identity: &StaticIdentity,
        host_pub: &[u8; KEY_LEN],
        psk: &[u8; KEY_LEN],
        room_id: &[u8; 16],
    ) -> Result<Self> {
        let params = noise_params()?;
        let builder = Builder::new(params)
            .local_private_key(&identity.private)
            .map_err(|e| Error::Crypto(format!("local key rejected: {e}")))?;
        let builder = builder
            .psk(0, psk)
            .map_err(|e| Error::Crypto(format!("psk rejected: {e}")))?;
        let builder = builder
            .prologue(room_id)
            .map_err(|e| Error::Crypto(format!("prologue rejected: {e}")))?;
        let builder = builder
            .remote_public_key(host_pub)
            .map_err(|e| Error::Crypto(format!("host key rejected: {e}")))?;
        let state = builder.build_initiator()?;
        Ok(Self {
            state,
            role: Role::Guest,
        })
    }

    /// 主机端：在握手过程中得知访客的静态密钥。
    pub fn host(
        identity: &StaticIdentity,
        psk: &[u8; KEY_LEN],
        room_id: &[u8; 16],
    ) -> Result<Self> {
        let params = noise_params()?;
        let builder = Builder::new(params)
            .local_private_key(&identity.private)
            .map_err(|e| Error::Crypto(format!("local key rejected: {e}")))?;
        let builder = builder
            .psk(0, psk)
            .map_err(|e| Error::Crypto(format!("psk rejected: {e}")))?;
        let builder = builder
            .prologue(room_id)
            .map_err(|e| Error::Crypto(format!("prologue rejected: {e}")))?;
        let state = builder.build_responder()?;
        Ok(Self {
            state,
            role: Role::Host,
        })
    }

    /// 该握手属于哪一端。
    pub fn role(&self) -> Role {
        self.role
    }

    /// 生成下一条握手消息。
    ///
    /// IK 的调用顺序：访客写，主机读后写，访客读后写，主机读。
    pub fn write_message(&mut self) -> Result<Vec<u8>> {
        let mut buf = vec![0u8; MAX_HANDSHAKE_MESSAGE];
        let n = self.state.write_message(&[], &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// 消费来自对端的一条握手消息。
    pub fn read_message(&mut self, message: &[u8]) -> Result<()> {
        if message.is_empty() || message.len() > MAX_HANDSHAKE_MESSAGE {
            return Err(Error::Protocol(format!(
                "handshake message has implausible length {}",
                message.len()
            )));
        }
        let mut payload = vec![0u8; MAX_HANDSHAKE_MESSAGE];
        self.state.read_message(message, &mut payload)?;
        Ok(())
    }

    /// 双方是否已交换全部消息。
    pub fn is_finished(&self) -> bool {
        self.state.is_handshake_finished()
    }

    /// 对端的静态公钥，在已知之后可用。
    pub fn remote_static(&self) -> Option<[u8; KEY_LEN]> {
        self.state.get_remote_static().and_then(|k| {
            if k.len() == KEY_LEN {
                let mut out = [0u8; KEY_LEN];
                out.copy_from_slice(k);
                Some(out)
            } else {
                None
            }
        })
    }

    /// 切换到加密传输模式。握手未完成时失败。
    pub fn into_transport(self) -> Result<TransportState> {
        if !self.is_finished() {
            return Err(Error::Protocol("handshake is not finished".into()));
        }
        self.state
            .into_transport_mode()
            .map_err(|e| Error::Crypto(format!("cannot enter transport mode: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Pair {
        guest: Handshake,
        host: Handshake,
        guest_id: StaticIdentity,
        host_id: StaticIdentity,
    }

    fn pair() -> Pair {
        let host_id = StaticIdentity::generate().unwrap();
        let guest_id = StaticIdentity::generate().unwrap();
        let psk = [42u8; KEY_LEN];
        let room = [7u8; 16];
        let host = Handshake::host(&host_id, &psk, &room).unwrap();
        let guest = Handshake::guest(&guest_id, &host_id.public_bytes(), &psk, &room).unwrap();
        Pair {
            guest,
            host,
            guest_id,
            host_id,
        }
    }

    #[test]
    fn full_ik_handshake_succeeds() {
        let mut p = pair();

        let m1 = p.guest.write_message().unwrap();
        p.host.read_message(&m1).unwrap();

        let m2 = p.host.write_message().unwrap();
        p.guest.read_message(&m2).unwrap();

        assert!(p.guest.is_finished());
        assert!(p.host.is_finished());

        assert_eq!(p.host.remote_static().unwrap(), p.guest_id.public_bytes());
        assert_eq!(p.guest.remote_static().unwrap(), p.host_id.public_bytes());

        let mut gt = p.guest.into_transport().unwrap();
        let mut ht = p.host.into_transport().unwrap();

        let mut ct = vec![0u8; 64];
        let n = gt.write_message(b"hello forest", &mut ct).unwrap();
        ct.truncate(n);

        let mut pt = vec![0u8; 64];
        let m = ht.read_message(&ct, &mut pt).unwrap();
        pt.truncate(m);
        assert_eq!(&pt, b"hello forest");
    }

    #[test]
    fn wrong_psk_fails() {
        let host_id = StaticIdentity::generate().unwrap();
        let guest_id = StaticIdentity::generate().unwrap();
        let room = [1u8; 16];
        let mut host = Handshake::host(&host_id, &[1u8; KEY_LEN], &room).unwrap();
        let mut guest =
            Handshake::guest(&guest_id, &host_id.public_bytes(), &[2u8; KEY_LEN], &room).unwrap();

        let m1 = guest.write_message().unwrap();
        // psk0 在消息 1 之前就绑定了密钥，因此主机会直接拒绝。
        assert!(host.read_message(&m1).is_err());
    }

    #[test]
    fn wrong_host_key_fails() {
        let host_id = StaticIdentity::generate().unwrap();
        let impostor = StaticIdentity::generate().unwrap();
        let guest_id = StaticIdentity::generate().unwrap();
        let psk = [5u8; KEY_LEN];
        let room = [2u8; 16];

        let mut host = Handshake::host(&host_id, &psk, &room).unwrap();
        let mut guest = Handshake::guest(&guest_id, &impostor.public_bytes(), &psk, &room).unwrap();

        let m1 = guest.write_message().unwrap();
        // 访客用冒充者的密钥封装了消息 1，因此真正的主机无法
        // 解密：攻击者无法冒充主机。
        assert!(host.read_message(&m1).is_err());
    }

    #[test]
    fn mismatched_room_fails() {
        let host_id = StaticIdentity::generate().unwrap();
        let guest_id = StaticIdentity::generate().unwrap();
        let psk = [3u8; KEY_LEN];
        let mut host = Handshake::host(&host_id, &psk, &[1u8; 16]).unwrap();
        let mut guest =
            Handshake::guest(&guest_id, &host_id.public_bytes(), &psk, &[2u8; 16]).unwrap();

        let m1 = guest.write_message().unwrap();
        assert!(host.read_message(&m1).is_err());
    }

    #[test]
    fn transport_rejects_tampering() {
        let mut p = pair();
        let m1 = p.guest.write_message().unwrap();
        p.host.read_message(&m1).unwrap();
        let m2 = p.host.write_message().unwrap();
        p.guest.read_message(&m2).unwrap();

        let mut gt = p.guest.into_transport().unwrap();
        let mut ht = p.host.into_transport().unwrap();

        let mut ct = vec![0u8; 64];
        let n = gt.write_message(b"payload", &mut ct).unwrap();
        ct.truncate(n);
        let last = ct.len() - 1;
        ct[last] ^= 0xff;

        let mut pt = vec![0u8; 64];
        assert!(ht.read_message(&ct, &mut pt).is_err());
    }

    #[test]
    fn identity_roundtrips() {
        let id = StaticIdentity::generate().unwrap();
        let again = StaticIdentity::from_parts(id.private_bytes(), &id.public_bytes()).unwrap();
        assert_eq!(id, again);
        assert_eq!(id.public_hex().len(), 64);
    }

    #[test]
    fn identity_rejects_bad_input() {
        assert!(StaticIdentity::from_parts(&[0u8; 31], &[1u8; 32]).is_err());
        assert!(StaticIdentity::from_parts(&[0u8; 32], &[1u8; 32]).is_err());
    }
}
