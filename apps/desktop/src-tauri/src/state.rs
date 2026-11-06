use std::path::PathBuf;
use std::sync::Arc;

use evergreen_lan_core::handshake::StaticIdentity;
use evergreen_lan_room::Room;
use tokio::sync::Mutex;

/// 进程级应用状态，由所有 Tauri 命令共享。
pub struct AppState {
    identity: Arc<StaticIdentity>,
    room: Mutex<Option<Room>>,
}

impl AppState {
    /// 构造状态，同时加载或生成持久化的静态身份。
    pub fn new() -> Self {
        let identity = match load_identity() {
            Ok(id) => id,
            Err(err) => {
                tracing::warn!(%err, "无法载入身份文件，改为生成新身份");
                let id = StaticIdentity::generate().expect("生成身份");
                if let Err(err) = save_identity(&id) {
                    tracing::warn!(%err, "无法保存身份文件");
                }
                id
            }
        };
        tracing::info!(public_key = %identity.public_hex(), "身份已就绪");

        Self {
            identity: Arc::new(identity),
            room: Mutex::new(None),
        }
    }

    /// 本机的长期 Noise 身份。
    pub fn identity(&self) -> Arc<StaticIdentity> {
        Arc::clone(&self.identity)
    }

    /// 当前房间（如果存在）。
    pub async fn room(&self) -> tokio::sync::MutexGuard<'_, Option<Room>> {
        self.room.lock().await
    }
}

fn config_dir() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("EverGreenLAN")
}

fn identity_path() -> PathBuf {
    config_dir().join("identity.json")
}

#[derive(serde::Serialize, serde::Deserialize)]
struct IdentityFile {
    private: String,
    public: String,
}

fn load_identity() -> Result<StaticIdentity, Box<dyn std::error::Error>> {
    let path = identity_path();
    if !path.is_file() {
        let id = StaticIdentity::generate()?;
        save_identity(&id)?;
        return Ok(id);
    }
    let raw = std::fs::read_to_string(&path)?;
    let file: IdentityFile = serde_json::from_str(&raw)?;
    let private = hex::decode(file.private)?;
    let public = hex::decode(file.public)?;
    Ok(StaticIdentity::from_parts(&private, &public)?)
}

fn save_identity(id: &StaticIdentity) -> Result<(), Box<dyn std::error::Error>> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let file = IdentityFile {
        private: hex::encode(id.private_bytes()),
        public: hex::encode(id.public_bytes()),
    };
    let json = serde_json::to_string_pretty(&file)?;
    std::fs::write(identity_path(), json)?;
    Ok(())
}
