mod commands;
mod state;

use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use state::AppState;
use tauri::Manager;

/// 构建并运行 EverGreen LAN 桌面应用。
pub fn run() {
    init_tracing();

    tauri::Builder::default()
        .setup(|app| {
            // 安装程序会把 wintun.dll 放在资源目录，该目录不一定与可执行文件同级。
            if let Ok(dir) = app.path().resource_dir() {
                let candidate = dir.join("wintun.dll");
                if candidate.is_file() {
                    // SAFETY：在主线程上、任何房间创建之前设置。
                    unsafe { std::env::set_var("EVERGREEN_LAN_WINTUN_DLL", &candidate) };
                    tracing::info!(path = %candidate.display(), "已使用随包分发的 wintun.dll");
                }
            }
            tracing::info!(version = env!("CARGO_PKG_VERSION"), "应用启动");
            Ok(())
        })
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            commands::app_status,
            commands::create_room,
            commands::join_room,
            commands::leave_room,
            commands::room_state,
            commands::relaunch_elevated,
            commands::log_file_path,
            commands::open_log_folder,
            commands::open_url,
            commands::parse_theme_json,
        ])
        .run(tauri::generate_context!())
        .expect("无法启动 EverGreen LAN");
}

/// 日志目录：`%LOCALAPPDATA%\EverGreenLAN\logs`。
///
/// 与身份文件放在同一父目录下，便于用户一次性找到全部本地状态。
pub fn log_directory() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("EverGreenLAN")
        .join("logs")
}

/// 日志文件路径。
pub fn log_file_path() -> PathBuf {
    log_directory().join("evergreen-lan.log")
}

/// 装配日志：写入文件，开发构建下同时 mirror 到 stdout。
///
/// 打包后的程序是 GUI 子系统，stdout 会被丢弃；没有文件日志时，防火墙规则、
/// 握手失败、超时等信息全部不可见。
fn init_tracing() {
    use tracing_subscriber::EnvFilter;

    let filter =
        EnvFilter::try_from_env("EVERGREEN_LAN_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    let mirror_stdout = cfg!(debug_assertions);
    let writer = match open_log_file() {
        Some(file) => LogMaker {
            inner: LogWriter {
                file: Arc::new(Mutex::new(file)),
                mirror_stdout,
            },
        },
        None => {
            // 日志文件不可写时退回 stdout，至少不阻断启动。
            let _ = tracing_subscriber::fmt()
                .with_env_filter(filter)
                .with_target(false)
                .try_init();
            return;
        }
    };

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .with_ansi(false)
        .with_writer(writer)
        .try_init();
}

/// 打开日志文件，必要时先做一次轮转。
fn open_log_file() -> Option<std::fs::File> {
    let dir = log_directory();
    std::fs::create_dir_all(&dir).ok()?;

    let path = log_file_path();
    rotate_if_large(&path);

    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .ok()
}

/// 单个日志文件超过 2 MiB 时轮转为 `.1`，避免无限增长。
fn rotate_if_large(path: &PathBuf) {
    const LIMIT: u64 = 2 * 1024 * 1024;
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if meta.len() < LIMIT {
        return;
    }
    let rotated = path.with_extension("log.1");
    let _ = std::fs::remove_file(&rotated);
    let _ = std::fs::rename(path, rotated);
}

#[derive(Clone)]
struct LogMaker {
    inner: LogWriter,
}

impl<'a> tracing_subscriber::fmt::writer::MakeWriter<'a> for LogMaker {
    type Writer = LogWriter;

    fn make_writer(&'a self) -> Self::Writer {
        self.inner.clone()
    }
}

/// 同时写入日志文件与 stdout 的 writer。
#[derive(Clone)]
struct LogWriter {
    file: Arc<Mutex<std::fs::File>>,
    mirror_stdout: bool,
}

impl Write for LogWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let written = match self.file.lock() {
            Ok(mut file) => file.write(buf)?,
            Err(poisoned) => poisoned.into_inner().write(buf)?,
        };
        if self.mirror_stdout {
            let _ = std::io::stdout().write_all(buf);
        }
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if let Ok(mut file) = self.file.lock() {
            let _ = file.flush();
        }
        Ok(())
    }
}
