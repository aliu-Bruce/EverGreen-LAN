//! 房间邀请码。
//!
//! [`InviteCode`] 构成了 EverGreen LAN 的整个控制面。它由主机生成，
//! 通过带外方式（聊天消息、二维码、文本文件）交给访客，并包含访客
//! 尝试建立直连所需的全部信息：
//!
//! * Noise 握手使用的房间标识符与预共享密钥；
//! * 主机的静态公钥（供访客认证主机）；
//! * 主机的候选传输地址（LAN 与公网/STUN 端点）。
//!
//! 解码或使用邀请码时不查询任何服务器。密钥直接嵌在邀请码中，
//! 因此邀请码*本身*就是能力凭证：其性质等同于密码。

use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Error, Result, HOST_VIRTUAL_IP};

/// 每个邀请码的文本前缀。
pub const INVITE_PREFIX: &str = "EGL1-";

/// 当前的邀请码格式版本。
pub const INVITE_VERSION: u8 = 1;

/// 房间显示名的最大字节长度。
pub const MAX_NAME_LEN: usize = 48;

/// 邀请码携带的候选端点最大数量。
pub const MAX_CANDIDATES: usize = 16;

/// 解压后载荷的硬性上限，用于化解解压炸弹。
const MAX_DECOMPRESSED: u64 = 8 * 1024;

/// 可分享的房间描述。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InviteCode {
    /// 格式版本，当前为 [`INVITE_VERSION`]。
    pub version: u8,
    /// 随机的 128 位房间标识符。
    pub room_id: [u8; 16],
    /// 人类可读的房间名称。
    pub name: String,
    /// 256 位房间密钥；同时用作 Noise 预共享密钥。
    pub psk: [u8; 32],
    /// 主机的静态 X25519 公钥。
    pub host_pub: [u8; 32],
    /// 主机在虚拟子网内的地址。
    pub host_ip: [u8; 4],
    /// 主机的候选 `ip:port` 端点，按优劣排序。
    pub candidates: Vec<String>,
    /// 邀请码创建时的 Unix 时间戳（秒）。
    pub created_at: u64,
}

impl InviteCode {
    /// 用随机 id 和密钥创建新的房间邀请码。
    pub fn new(
        name: impl Into<String>,
        host_pub: [u8; 32],
        candidates: Vec<String>,
    ) -> Result<Self> {
        let mut room_id = [0u8; 16];
        let mut psk = [0u8; 32];
        random_fill(&mut room_id);
        random_fill(&mut psk);
        Self::with_secrets(name, host_pub, candidates, room_id, psk, now_unix())
    }

    /// 创建使用调用方所给密钥的邀请码。适用于测试以及
    /// 跨重启恢复房间。
    pub fn with_secrets(
        name: impl Into<String>,
        host_pub: [u8; 32],
        candidates: Vec<String>,
        room_id: [u8; 16],
        psk: [u8; 32],
        created_at: u64,
    ) -> Result<Self> {
        let invite = Self {
            version: INVITE_VERSION,
            room_id,
            name: name.into(),
            psk,
            host_pub,
            host_ip: HOST_VIRTUAL_IP,
            candidates,
            created_at,
        };
        invite.validate()?;
        Ok(invite)
    }

    /// 检查解码后的邀请码必须满足的每一项不变量。
    pub fn validate(&self) -> Result<()> {
        if self.version != INVITE_VERSION {
            return Err(Error::Invite("unsupported invite version"));
        }
        if self.name.len() > MAX_NAME_LEN {
            return Err(Error::Invite("room name is too long"));
        }
        if self.candidates.len() > MAX_CANDIDATES {
            return Err(Error::Invite("too many candidate endpoints"));
        }
        if self.candidates.is_empty() {
            return Err(Error::Invite("invite carries no endpoints"));
        }
        for c in &self.candidates {
            if parse_endpoint(c).is_none() {
                return Err(Error::Invite("candidate endpoint is not a valid ip:port"));
            }
        }
        if self.host_ip != HOST_VIRTUAL_IP {
            return Err(Error::Invite("unexpected host virtual address"));
        }
        if self.room_id.iter().all(|b| *b == 0) {
            return Err(Error::Invite("room id must not be all zeroes"));
        }
        if self.psk.iter().all(|b| *b == 0) {
            return Err(Error::Invite("room secret must not be all zeroes"));
        }
        if self.host_pub.iter().all(|b| *b == 0) {
            return Err(Error::Invite("host public key must not be all zeroes"));
        }
        Ok(())
    }

    /// 序列化、压缩并编码邀请码以便分享。
    pub fn encode(&self) -> Result<String> {
        use std::io::Write;
        let raw = bincode::serialize(self)
            .map_err(|e| Error::Codec(format!("cannot serialise invite: {e}")))?;
        let mut enc = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
        enc.write_all(&raw)
            .map_err(|e| Error::Compression(e.to_string()))?;
        let packed = enc
            .finish()
            .map_err(|e| Error::Compression(e.to_string()))?;
        Ok(format!("{INVITE_PREFIX}{}", URL_SAFE_NO_PAD.encode(packed)))
    }

    /// 解析由 [`InviteCode::encode`] 生成的邀请码。
    ///
    /// 空白字符（包括聊天客户端插入的换行）会被忽略。
    pub fn decode(text: &str) -> Result<Self> {
        use std::io::Read;

        let cleaned: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let body = cleaned
            .strip_prefix(INVITE_PREFIX)
            .ok_or(Error::Invite("missing EGL1- prefix"))?;
        if body.is_empty() {
            return Err(Error::Invite("invite body is empty"));
        }
        let packed = URL_SAFE_NO_PAD.decode(body)?;
        let mut dec = flate2::read::ZlibDecoder::new(&packed[..]).take(MAX_DECOMPRESSED);
        let mut raw = Vec::new();
        dec.read_to_end(&mut raw)
            .map_err(|e| Error::Compression(e.to_string()))?;
        if raw.is_empty() {
            return Err(Error::Compression("empty payload".into()));
        }
        let invite: InviteCode = bincode::deserialize(&raw)
            .map_err(|e| Error::Codec(format!("cannot deserialise invite: {e}")))?;
        invite.validate()?;
        Ok(invite)
    }

    /// 解析为套接字地址的候选端点。
    pub fn endpoints(&self) -> Vec<SocketAddr> {
        self.candidates
            .iter()
            .filter_map(|c| parse_endpoint(c))
            .collect()
    }

    /// 房间的简短可核对指纹，例如 `A1B2C3`。
    ///
    /// 双方必须看到相同的值；用户可借此在语音中确认双方
    /// 粘贴的是同一个邀请码。
    pub fn fingerprint(&self) -> String {
        let mut h = Sha256::new();
        h.update(self.room_id);
        h.update(self.psk);
        let digest = h.finalize();
        hex::encode_upper(&digest[..3])
    }

    /// 邀请码的年龄（秒）；遇到时钟偏差时饱和为零。
    pub fn age_secs(&self) -> u64 {
        now_unix().saturating_sub(self.created_at)
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn random_fill(buf: &mut [u8]) {
    use rand::RngCore;
    rand::thread_rng().fill_bytes(buf);
}

/// 解析字面量 `ip:port` 端点。有意拒绝主机名：邀请码必须
/// 无需任何网络或服务器即可解析。
fn parse_endpoint(s: &str) -> Option<SocketAddr> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    s.parse::<std::net::SocketAddr>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> InviteCode {
        InviteCode::with_secrets(
            "Forest Friends",
            [7u8; 32],
            vec!["192.168.1.20:25565".into(), "203.0.113.9:41234".into()],
            [3u8; 16],
            [9u8; 32],
            1_700_000_000,
        )
        .expect("sample invite")
    }

    #[test]
    fn roundtrip() {
        let inv = sample();
        let text = inv.encode().unwrap();
        assert!(text.starts_with(INVITE_PREFIX));
        let back = InviteCode::decode(&text).unwrap();
        assert_eq!(back, inv);
    }

    #[test]
    fn tolerates_whitespace_and_newlines() {
        let inv = sample();
        let text = inv.encode().unwrap();
        let spaced = format!("  {}\n\t{}  ", &text[..30], &text[30..]);
        let back = InviteCode::decode(&spaced).unwrap();
        assert_eq!(back, inv);
    }

    #[test]
    fn rejects_missing_prefix() {
        assert!(InviteCode::decode("hello").is_err());
        assert!(InviteCode::decode("").is_err());
        assert!(InviteCode::decode(INVITE_PREFIX).is_err());
    }

    #[test]
    fn rejects_garbage_body() {
        assert!(InviteCode::decode("EGL1-!!!!").is_err());
        assert!(InviteCode::decode("EGL1-Zm9vYmFy").is_err());
    }

    #[test]
    fn rejects_future_version() {
        let mut inv = sample();
        inv.version = 99;
        let text = inv.encode().unwrap();
        assert!(matches!(InviteCode::decode(&text), Err(Error::Invite(_))));
    }

    #[test]
    fn rejects_bad_candidates() {
        let bad = InviteCode::with_secrets(
            "x",
            [1u8; 32],
            vec!["example.com:25565".into()],
            [1u8; 16],
            [1u8; 32],
            0,
        );
        assert!(bad.is_err());

        let empty = InviteCode::with_secrets("x", [1u8; 32], vec![], [1u8; 16], [1u8; 32], 0);
        assert!(empty.is_err());

        let too_many = InviteCode::with_secrets(
            "x",
            [1u8; 32],
            (0..20).map(|i| format!("10.0.0.{}:1000", i)).collect(),
            [1u8; 16],
            [1u8; 32],
            0,
        );
        assert!(too_many.is_err());
    }

    #[test]
    fn rejects_long_name() {
        let long = "a".repeat(MAX_NAME_LEN + 1);
        assert!(InviteCode::with_secrets(
            long,
            [1u8; 32],
            vec!["1.2.3.4:5".into()],
            [1u8; 16],
            [1u8; 32],
            0
        )
        .is_err());
    }

    #[test]
    fn fingerprint_is_stable_and_room_specific() {
        let a = sample();
        let b = sample();
        assert_eq!(a.fingerprint(), b.fingerprint());
        assert_eq!(a.fingerprint().len(), 6);

        let mut c = sample();
        c.psk = [8u8; 32];
        assert_ne!(a.fingerprint(), c.fingerprint());
    }

    #[test]
    fn encode_is_compact() {
        let text = sample().encode().unwrap();
        assert!(
            text.len() < 400,
            "invite unexpectedly long: {} chars",
            text.len()
        );
    }

    #[test]
    fn age_handles_future_timestamps() {
        let mut inv = sample();
        inv.created_at = u64::MAX;
        assert_eq!(inv.age_secs(), 0);
    }
}
