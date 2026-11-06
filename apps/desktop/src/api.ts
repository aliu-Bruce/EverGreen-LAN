import { invoke } from "@tauri-apps/api/core";

export type Role = "host" | "guest";

export interface Peer {
  name: string;
  virtualIp: string;
  role: Role;
  endpoint: string;
  rttMs: number | null;
}

export interface RoomView {
  roomName: string;
  invite: string;
  fingerprint: string;
  hosting: boolean;
  virtualIp: string;
  peers: Peer[];
  candidates: string[];
  reachable: boolean;
  /** 主机在运营商级 NAT 后面，直连基本不可能。 */
  cgnat: boolean;
  firewallOk: boolean | null;
}

export interface AppStatus {
  appVersion: string;
  admin: boolean;
  wintunPresent: boolean;
  adapterUp: boolean;
  platform: string;
  coreReady: boolean;
}

/** 用户自定义主题，来自 `%APPDATA%\EverGreenLAN\themes\*.json`。 */
export interface CustomTheme {
  id: string;
  name: string;
  hint: string;
  mode: "light" | "dark";
  vars: Record<string, string>;
}

/** 单个主题文件的读取失败原因。 */
const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

/** Rust 命令的类型化封装；不在 Tauri 环境中时抛出明确的错误。 */
async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (!inTauri) {
    throw new Error("当前在浏览器中预览，桌面功能不可用。请用 `npm run desktop` 启动。");
  }
  return invoke<T>(command, args);
}

export const api = {
  isDesktop: inTauri,
  status: () => call<AppStatus>("app_status"),
  createRoom: (name: string) => call<RoomView>("create_room", { name }),
  joinRoom: (code: string) => call<RoomView>("join_room", { code }),
  leaveRoom: () => call<void>("leave_room"),
  roomState: () => call<RoomView | null>("room_state"),
  relaunchElevated: () => call<void>("relaunch_elevated"),
  logFilePath: () => call<string>("log_file_path"),
  openLogFolder: () => call<void>("open_log_folder"),
  openUrl: (url: string) => call<void>("open_url", { url }),
  copyText: (text: string) => call<void>("copy_text", { text }),
  pasteText: () => call<string>("paste_text"),
  parseTheme: (raw: string, fileName?: string) =>
    call<CustomTheme>("parse_theme_json", { raw, fileName: fileName ?? null }),
};
