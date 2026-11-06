use std::path::PathBuf;

use evergreen_lan_core::handshake::Role;
use evergreen_lan_core::InviteCode;
use evergreen_lan_room::{Room, RoomConfig, RoomError};
use evergreen_lan_tun::TunError;
use tauri::State;

use crate::state::AppState;

/// 首页展示的环境探测结果。
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppStatus {
    pub app_version: String,
    pub admin: bool,
    pub wintun_present: bool,
    pub adapter_up: bool,
    pub platform: String,
    pub core_ready: bool,
}

/// UI 渲染的单个对等节点。
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerView {
    pub name: String,
    pub virtual_ip: String,
    pub role: String,
    pub endpoint: String,
    pub rtt_ms: Option<f64>,
}

/// UI 渲染的当前房间。
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RoomView {
    pub room_name: String,
    pub invite: String,
    pub fingerprint: String,
    pub hosting: bool,
    pub virtual_ip: String,
    pub peers: Vec<PeerView>,
    pub candidates: Vec<String>,
    /// 是否至少有一个候选地址可从本网络外部访问。
    pub reachable: bool,
    /// 是否存在运营商级 NAT 的候选地址。
    pub cgnat: bool,
    /// 入站防火墙规则是否创建成功；`None` 表示本机不是托管方。
    pub firewall_ok: Option<bool>,
}

impl RoomView {
    fn from_room(room: &Room) -> Self {
        let peers = room
            .peers()
            .into_iter()
            .map(|peer| PeerView {
                name: peer.name.clone(),
                virtual_ip: peer.ip_string(),
                role: match peer.role {
                    Role::Host => "host".to_string(),
                    Role::Guest => "guest".to_string(),
                },
                endpoint: peer.endpoint.to_string(),
                rtt_ms: peer.rtt_ms.map(f64::from),
            })
            .collect();

        Self {
            room_name: room.invite.name.clone(),
            invite: room.invite.encode().unwrap_or_default(),
            fingerprint: room.invite.fingerprint(),
            hosting: room.hosting,
            virtual_ip: format_ip(room.virtual_ip),
            peers,
            candidates: room.invite.candidates.clone(),
            reachable: room
                .invite
                .endpoints()
                .iter()
                .any(|addr| evergreen_lan_core::stun::is_routable(addr.ip())),
            cgnat: room.invite.endpoints().iter().any(|addr| {
                evergreen_lan_core::stun::is_cgnat(match addr.ip() {
                    std::net::IpAddr::V4(v4) => v4,
                    std::net::IpAddr::V6(_) => std::net::Ipv4Addr::UNSPECIFIED,
                })
            }),
            firewall_ok: room.firewall_ok,
        }
    }
}

fn format_ip(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

/// 缺少特权时给用户的下一步动作。
fn needs_admin_hint() -> String {
    #[cfg(windows)]
    {
        "创建虚拟网卡需要管理员权限。请关闭程序，右键以管理员身份重新启动。".to_string()
    }
    #[cfg(target_os = "macos")]
    {
        "创建虚拟网卡需要 root 权限。请在终端执行：sudo /Applications/EverGreen\\ LAN.app/Contents/MacOS/evergreen-lan"
            .to_string()
    }
    #[cfg(target_os = "linux")]
    {
        "创建虚拟网卡需要 root 权限。请用 sudo 启动本程序，或安装 polkit 后使用提权重启。"
            .to_string()
    }
}

/// 缺少虚拟网卡后端时给用户的下一步动作。
fn missing_backend_hint() -> String {
    #[cfg(windows)]
    {
        "找不到 wintun.dll。请运行 scripts\\fetch-wintun.ps1 获取驱动，或重新安装程序。".to_string()
    }
    #[cfg(target_os = "macos")]
    {
        "无法打开 utun 设备。macOS 需要 root 权限才能创建虚拟网卡。".to_string()
    }
    #[cfg(target_os = "linux")]
    {
        "找不到 /dev/net/tun。请确认内核已加载 tun 模块：sudo modprobe tun".to_string()
    }
}

/// 把房间错误转换为可以据此采取行动的说明。
fn explain(err: RoomError) -> String {
    match err {
        RoomError::Adapter(TunError::NeedsAdmin) => needs_admin_hint(),
        RoomError::Adapter(TunError::DriverMissing) => missing_backend_hint(),
        RoomError::Adapter(TunError::DriverLoad(message)) => {
            format!("wintun.dll 无法加载：{message}")
        }
        RoomError::Adapter(other) => format!("虚拟网卡不可用：{other}"),
        RoomError::Route(err) => format!("配置地址或路由失败：{err}"),
        RoomError::NoAnswer => "主机没有回应我们的加入请求。".to_string(),
        RoomError::Core(evergreen_lan_core::Error::Timeout) => {
            "没有收到主机回应。请确认：主机仍在房间里、邀请码是最新的、双方的防火墙允许 UDP。\
             已尝试的地址记录在日志里。"
                .to_string()
        }
        RoomError::Core(evergreen_lan_core::Error::Invite(message)) => {
            format!("邀请码无效：{message}")
        }
        RoomError::Core(err) => format!("协议错误：{err}"),
        RoomError::Io(err) => format!("网络错误：{err}"),
    }
}

/// 探测当前环境，供首页显示。
#[tauri::command]
pub async fn app_status(state: State<'_, AppState>) -> Result<AppStatus, String> {
    let busy = state.room().await.is_some();
    Ok(AppStatus {
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        admin: is_admin(),
        wintun_present: wintun_present(),
        adapter_up: busy,
        platform: std::env::consts::OS.to_string(),
        core_ready: true,
    })
}

/// 创建并托管一个房间。
#[tauri::command]
pub async fn create_room(name: String, state: State<'_, AppState>) -> Result<RoomView, String> {
    let mut guard = state.room().await;
    if guard.is_some() {
        return Err("已有房间在运行，请先退出。".to_string());
    }

    let config = RoomConfig::new(name, state.identity());
    let room = Room::host(config).await.map_err(explain)?;
    let view = RoomView::from_room(&room);
    *guard = Some(room);
    Ok(view)
}

/// 通过邀请码加入房间。
#[tauri::command]
pub async fn join_room(code: String, state: State<'_, AppState>) -> Result<RoomView, String> {
    let invite = InviteCode::decode(&code).map_err(|err| format!("邀请码无效：{err}"))?;
    let mut guard = state.room().await;
    if guard.is_some() {
        return Err("已有房间在运行，请先退出。".to_string());
    }

    let name = std::env::var("USERNAME").unwrap_or_else(|_| "玩家".to_string());
    let room = Room::join(RoomConfig::new(name, state.identity()), invite)
        .await
        .map_err(explain)?;
    let view = RoomView::from_room(&room);
    *guard = Some(room);
    Ok(view)
}

/// 退出当前房间并拆除全部资源。
#[tauri::command]
pub async fn leave_room(state: State<'_, AppState>) -> Result<(), String> {
    let mut guard = state.room().await;
    if let Some(room) = guard.take() {
        room.shutdown().await;
    }
    Ok(())
}

/// 轮询当前房间状态；没有房间时返回 `null`。
#[tauri::command]
pub async fn room_state(state: State<'_, AppState>) -> Result<Option<RoomView>, String> {
    let guard = state.room().await;
    Ok(guard.as_ref().map(RoomView::from_room))
}

/// 以管理员身份重新启动本程序。
#[tauri::command]
pub fn relaunch_elevated() -> Result<(), String> {
    #[cfg(windows)]
    {
        let exe = std::env::current_exe().map_err(|err| format!("无法定位程序：{err}"))?;
        let args: Vec<String> = std::env::args().skip(1).collect();
        let code = elevate(&exe, &args);
        if code > 32 {
            std::process::exit(0);
        }
        Err(format!("以管理员身份启动失败（ShellExecute 返回 {code}）"))
    }
    #[cfg(target_os = "linux")]
    {
        let exe = std::env::current_exe().map_err(|err| format!("无法定位程序：{err}"))?;
        std::process::Command::new("pkexec")
            .arg(&exe)
            .spawn()
            .map(|_| ())
            .map_err(|err| format!("无法通过 pkexec 提权：{err}。请在终端用 sudo 启动。"))
    }
    #[cfg(target_os = "macos")]
    {
        let exe = std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "evergreen-lan".to_string());
        Err(format!("macOS 无法从应用内提权，请在终端执行：sudo {exe}"))
    }
}

#[cfg(windows)]
fn elevate(exe: &std::path::Path, args: &[String]) -> isize {
    use std::os::windows::ffi::OsStrExt;

    fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
        value.encode_wide().chain(std::iter::once(0)).collect()
    }

    let verb = wide(std::ffi::OsStr::new("runas"));
    let file = wide(exe.as_os_str());
    let mut parameter_buffer: Vec<u16> = args.join(" ").encode_utf16().collect();
    parameter_buffer.push(0);

    // SAFETY：两个字符串都以 NUL 结尾，且存活时间长于该调用；
    // 参数字符串在调用期间同样保持存活。
    unsafe {
        windows_sys::Win32::UI::Shell::ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            parameter_buffer.as_ptr(),
            std::ptr::null(),
            windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        ) as isize
    }
}

#[cfg(windows)]
fn is_admin() -> bool {
    // SAFETY：IsUserAnAdmin 不接受参数，只读取当前令牌。
    unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
}

#[cfg(unix)]
fn is_admin() -> bool {
    // SAFETY：geteuid 不接受参数，只读取当前进程的有效用户 ID。
    unsafe { libc::geteuid() == 0 }
}

/// 是否存在可加载的 Wintun 驱动。
///
/// 此处实际加载 DLL，而不只是检查文件：驱动「存在但无法加载」的情况，
/// 否则只会在首次创建房间时才暴露。
fn wintun_present() -> bool {
    if evergreen_lan_tun::driver_info().is_some() {
        return true;
    }
    // 退回到路径探测，使 UI 能区分「未安装」与「存在但无法加载」。
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("wintun.dll"));
        }
    }
    if let Some(sys) = std::env::var_os("SystemRoot") {
        candidates.push(PathBuf::from(sys).join("System32").join("wintun.dll"));
    }
    if let Some(pf) = std::env::var_os("ProgramFiles") {
        candidates.push(PathBuf::from(pf).join("WireGuard").join("wintun.dll"));
    }
    candidates.iter().any(|path| path.is_file())
}

/* ------------------------------------------------------------ 外部链接 */

/// 用系统默认浏览器打开一个链接。
///
/// 只接受 https，避免把任意字符串交给系统的 URL 处理器。
#[tauri::command]
pub fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("只允许打开 https 链接".to_string());
    }

    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;

        fn wide(value: &str) -> Vec<u16> {
            std::ffi::OsStr::new(value)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect()
        }

        let verb = wide("open");
        let target = wide(&url);
        // SAFETY：两个字符串均以 NUL 结尾，且在调用期间保持存活。
        let code = unsafe {
            windows_sys::Win32::UI::Shell::ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                target.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
            ) as isize
        };
        if code > 32 {
            return Ok(());
        }
        Err(format!("无法打开浏览器（ShellExecute 返回 {code}）"))
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&url)
            .spawn()
            .map(|_| ())
            .map_err(|err| format!("无法打开浏览器：{err}"))
    }

    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open")
            .arg(&url)
            .spawn()
            .map(|_| ())
            .map_err(|err| format!("无法打开浏览器：{err}"))
    }
}

/* ---------------------------------------------------------------- 日志 */

/// 日志文件的绝对路径。
#[tauri::command]
pub fn log_file_path() -> String {
    crate::log_file_path().display().to_string()
}

/// 在资源管理器中定位日志文件，便于用户与维护者查看失败原因。
#[tauri::command]
pub fn open_log_folder() -> Result<(), String> {
    let path = crate::log_file_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| format!("无法创建日志目录：{err}"))?;
    }
    reveal(&path)
}

/// 在资源管理器中选中文件；文件不存在时打开其所在目录。
fn reveal(path: &std::path::Path) -> Result<(), String> {
    let mut command = std::process::Command::new("explorer");
    if path.is_file() {
        command.arg(format!("/select,{}", path.display()));
    } else {
        let dir = path.parent().ok_or_else(|| "无效路径".to_string())?;
        command.arg(dir);
    }
    command
        .spawn()
        .map_err(|err| format!("无法打开资源管理器：{err}"))?;
    Ok(())
}

/* ---------------------------------------------------------- 自定义主题 */

/// 主题文件的当前版本号。
const THEME_SCHEMA_VERSION: u32 = 1;

/// 允许自定义主题覆盖的变量（键不带 `--` 前缀）。
///
/// 白名单而非全量开放：主题文件来自本机，但仍应限制作用面，
/// 以免值里出现 `url(...)` 之类会触发额外网络请求或破坏布局的内容。
const THEME_VARS: &[&str] = &[
    "bg",
    "bg-deep",
    "ink",
    "ink-soft",
    "ink-faint",
    "rule",
    "rule-strong",
    "accent",
    "accent-ink",
    "alert",
    "grain",
    "text-scale",
    "radius",
    "font-body",
    "font-mono",
    "display-font",
    "display-cjk",
    "display-weight",
    "display-tracking",
    "display-leading",
    "display-size",
];

/// 必须按颜色校验的变量。
const THEME_COLOR_VARS: &[&str] = &[
    "bg",
    "bg-deep",
    "ink",
    "ink-soft",
    "ink-faint",
    "rule",
    "rule-strong",
    "accent",
    "accent-ink",
    "alert",
];

/// 用户自定义主题。
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomTheme {
    /// 取自文件名，用于持久化选择。
    pub id: String,
    pub name: String,
    pub hint: String,
    /// `light` 或 `dark`，用于设置 `color-scheme` 与强调色调整方向。
    pub mode: String,
    pub vars: std::collections::BTreeMap<String, String>,
}

#[derive(serde::Deserialize)]
struct ThemeFile {
    #[serde(default, rename = "schemaVersion")]
    schema_version: Option<u32>,
    name: String,
    #[serde(default)]
    hint: String,
    #[serde(default)]
    mode: Option<String>,
    vars: std::collections::BTreeMap<String, String>,
}

/// 解析并校验一份主题 JSON。
///
/// 解析在 Rust 侧完成：校验逻辑只有一处，且被单元测试覆盖。主题本身由前端
/// 保存在本地存储中，不落盘到目录，因此不存在「导入后文件去哪了」的问题。
#[tauri::command]
pub fn parse_theme_json(raw: String, file_name: Option<String>) -> Result<CustomTheme, String> {
    let id = file_name
        .as_deref()
        .and_then(|name| name.rsplit_once('.').map(|(stem, _)| stem))
        .unwrap_or("custom")
        .to_string();
    parse_theme(&id, &raw)
}

/// 解析并校验单个主题文件。
///
/// 未知变量键被忽略而不是报错：新增变量后，旧主题仍应可用。
fn parse_theme(id: &str, raw: &str) -> Result<CustomTheme, String> {
    // 部分编辑器（含记事本）保存 UTF-8 时会写入 BOM，serde_json 不接受它。
    let raw = raw.trim_start_matches('\u{feff}');
    let file: ThemeFile =
        serde_json::from_str(raw).map_err(|err| format!("JSON 解析失败：{err}"))?;

    if let Some(version) = file.schema_version {
        if version != THEME_SCHEMA_VERSION {
            return Err(format!(
                "暂不支持 schemaVersion {version}，当前版本为 {THEME_SCHEMA_VERSION}"
            ));
        }
    }

    let name = file.name.trim();
    if name.is_empty() {
        return Err("缺少主题名称（name）".to_string());
    }
    if name.chars().count() > 24 {
        return Err("主题名称过长，最多 24 个字符".to_string());
    }

    let mode = match file.mode.as_deref().unwrap_or("light") {
        "light" => "light",
        "dark" => "dark",
        other => return Err(format!("mode 只能是 light 或 dark，收到 `{other}`")),
    };

    if file.vars.is_empty() {
        return Err("缺少 vars".to_string());
    }

    let mut vars = std::collections::BTreeMap::new();
    for (key, value) in file.vars {
        if !THEME_VARS.contains(&key.as_str()) {
            continue;
        }
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        if value.chars().count() > 200 {
            return Err(format!("{key} 的值超过 200 个字符"));
        }
        let lowered = value.to_ascii_lowercase();
        if lowered.contains("url(") || lowered.contains("@import") {
            return Err(format!("{key} 含有不允许的内容（url 或 @import）"));
        }
        if THEME_COLOR_VARS.contains(&key.as_str()) && !is_css_color(value) {
            return Err(format!("{key} 不是有效的颜色值：`{value}`"));
        }
        vars.insert(key, value.to_string());
    }

    if !vars.contains_key("bg") || !vars.contains_key("ink") {
        return Err("缺少必需的 bg 或 ink".to_string());
    }

    Ok(CustomTheme {
        id: id.to_string(),
        name: name.to_string(),
        hint: file.hint.trim().to_string(),
        mode: mode.to_string(),
        vars,
    })
}

/// 是否是可接受的 CSS 颜色写法：十六进制、rgb(a)、hsl(a)。
fn is_css_color(value: &str) -> bool {
    let value = value.trim();
    if let Some(hex) = value.strip_prefix('#') {
        return matches!(hex.len(), 3 | 4 | 6 | 8) && hex.chars().all(|c| c.is_ascii_hexdigit());
    }
    let lowered = value.to_ascii_lowercase();
    (lowered.starts_with("rgb(")
        || lowered.starts_with("rgba(")
        || lowered.starts_with("hsl(")
        || lowered.starts_with("hsla("))
        && lowered.ends_with(')')
}

#[cfg(test)]
mod theme_tests {
    use super::*;

    const MINIMAL: &str = r##"{
        "schemaVersion": 1,
        "name": "海盐",
        "hint": "冷蓝",
        "mode": "light",
        "vars": { "bg": "#eef3f6", "ink": "#0d1b24", "accent": "#1f6f8b" }
    }"##;

    #[test]
    fn parses_a_valid_theme() {
        let theme = parse_theme("sea-salt", MINIMAL).expect("应当解析成功");
        assert_eq!(theme.id, "sea-salt");
        assert_eq!(theme.name, "海盐");
        assert_eq!(theme.mode, "light");
        assert_eq!(theme.vars.get("bg").map(String::as_str), Some("#eef3f6"));
    }

    #[test]
    fn requires_background_and_text() {
        let raw = r##"{ "name": "x", "vars": { "bg": "#fff" } }"##;
        assert!(parse_theme("x", raw).is_err());
    }

    #[test]
    fn rejects_unknown_schema_version() {
        let raw =
            r##"{ "schemaVersion": 2, "name": "x", "vars": { "bg": "#fff", "ink": "#000" } }"##;
        let err = parse_theme("x", raw).unwrap_err();
        assert!(err.contains("schemaVersion"), "{err}");
    }

    #[test]
    fn rejects_invalid_colors() {
        let raw = r##"{ "name": "x", "vars": { "bg": "not-a-color", "ink": "#000" } }"##;
        let err = parse_theme("x", raw).unwrap_err();
        assert!(err.contains("bg"), "{err}");
    }

    #[test]
    fn accepts_rgba_and_ignores_unknown_keys() {
        let raw = r##"{
            "name": "x",
            "vars": {
                "bg": "#ffffff",
                "ink": "#111111",
                "rule": "rgba(0,0,0,0.14)",
                "unknown-token": "whatever"
            }
        }"##;
        let theme = parse_theme("x", raw).expect("应当解析成功");
        assert!(theme.vars.contains_key("rule"));
        assert!(!theme.vars.contains_key("unknown-token"));
    }

    #[test]
    fn rejects_url_values() {
        let raw = r##"{
            "name": "x",
            "vars": { "bg": "#fff", "ink": "#000", "font-body": "url(http://example.com/a.woff)" }
        }"##;
        let err = parse_theme("x", raw).unwrap_err();
        assert!(err.contains("不允许"), "{err}");
    }

    #[test]
    fn rejects_unknown_mode() {
        let raw = r##"{ "name": "x", "mode": "sepia", "vars": { "bg": "#fff", "ink": "#000" } }"##;
        assert!(parse_theme("x", raw).is_err());
    }

    #[test]
    fn tolerates_a_byte_order_mark() {
        // 记事本等编辑器会在文件开头写入 BOM，解析时必须忽略。
        let raw = concat!(
            "\u{feff}",
            r##"{ "name": "x", "vars": { "bg": "#fff", "ink": "#000" } }"##
        );
        assert!(parse_theme("x", raw).is_ok());
    }
}
