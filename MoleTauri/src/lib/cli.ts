// Tauri invoke 封装层
// 所有与 Rust 后端的交互都通过这里，提供类型安全

import { invoke, Channel } from '@tauri-apps/api/core';

// ---- 共享类型 ----

export interface CommandOutput {
  success: boolean;
  stdout: string;
  stderr: string;
  exit_code: number;
}

export interface UpdateInfo {
  version: string;
  download_url: string;
  notes: string;
}

// Analyze
export interface AnalyzeEntry {
  name: string;
  path: string;
  size: number;
  is_dir: boolean;
  insight?: boolean;
  cleanable?: boolean;
  last_access?: string;
}

export interface AnalyzeFileEntry {
  name: string;
  path: string;
  size: number;
}

export interface AnalyzeResult {
  path: string;
  overview: boolean;
  entries: AnalyzeEntry[];
  large_files?: AnalyzeFileEntry[];
  total_size: number;
  total_files?: number;
}

// Status (简化版，实际 schema 更大，按需取用)
export interface StatusSnapshot {
  collected_at: string;
  host: string;
  platform: string;
  uptime: number;
  hardware?: {
    model?: string;
    chip?: string;
    cores?: number;
  };
  health_score?: number;
  cpu?: {
    usage: number;
    per_core?: number[];
    p_core_count?: number;
    e_core_count?: number;
    load_avg?: number[];
  };
  gpu?: {
    usage?: number;
    name?: string;
  };
  memory?: {
    total: number;
    used: number;
    cached?: number;
    pressure?: string;
    swap_total?: number;
    swap_used?: number;
  };
  disks?: Array<{
    name: string;
    mount: string;
    total: number;
    free: number;
    used: number;
    type?: string;
  }>;
  trash_size?: number;
  network?: {
    interface?: string;
    ip?: string;
    download_speed: number;
    upload_speed: number;
    total_downloaded?: number;
    total_uploaded?: number;
  };
  network_history?: Array<{
    download: number;
    upload: number;
    ts: number;
  }>;
  batteries?: Array<{
    name: string;
    charge: number;
    charging: boolean;
    plugged: boolean;
    cycles?: number;
    condition?: string;
    time_remaining?: number;
  }>;
  thermal?: {
    cpu_temp?: number;
    gpu_temp?: number;
    fan_speed?: number;
    system_power?: number;
  };
  top_processes?: Array<{
    pid: number;
    name: string;
    cpu: number;
    memory: number;
  }>;
}

// Uninstall
export interface AppListEntry {
  name: string;
  bundle_id: string;
  source: string;
  uninstall_name: string;
  path: string;
  size: string;
  size_kb: number;
  last_used_epoch: number;
}

// Purge
export interface PurgeArtifact {
  path: string;
  size: number;
  artifact_type: string;
  project_path: string;
  age_days: number;
}

export interface PurgeScanResult {
  artifacts: PurgeArtifact[];
  total_size: number;
  total_count: number;
  scan_paths: string[];
}

// Installer
export interface InstallerFile {
  path: string;
  name: string;
  size: number;
  source: string;
  file_type: string;
  is_installer_zip: boolean;
}

export interface InstallerScanResult {
  files: InstallerFile[];
  total_size: number;
  total_count: number;
}

// History
export interface HistoryActions {
  removed: number;
  trashed: number;
  skipped: number;
  failed: number;
  rebuilt: number;
  other: number;
}

export interface HistorySession {
  command: string;
  started_at: string;
  ended_at: string;
  items: number;
  size: string;
  operation_count: number;
  actions: HistoryActions;
}

export interface HistoryDeletion {
  timestamp: string;
  mode: string;
  status: string;
  size_kb?: number;
  path: string;
}

export interface HistoryLogs {
  operations: string;
  deletions: string;
}

export interface HistoryResult {
  logs: HistoryLogs;
  limit: number;
  sessions: HistorySession[];
  deletions: HistoryDeletion[];
}

// ---- CLI 命令封装 ----

export async function checkCli(): Promise<boolean> {
  try {
    return await invoke<boolean>('check_cli');
  } catch {
    return false;
  }
}

export async function getMoleVersion(): Promise<string> {
  const res = await invoke<CommandOutput>('get_mole_version');
  return res.stdout.trim();
}

export async function runClean(dryRun: boolean, verbose: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_clean', { dryRun, verbose });
}

export async function runAnalyze(path?: string): Promise<AnalyzeResult> {
  const res = await invoke<CommandOutput>('run_analyze', { path: path || null });
  if (!res.success) throw new Error(res.stderr || 'Analyze failed');
  return JSON.parse(res.stdout);
}

export async function runStatus(json: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_status', { json });
}

export async function runStatusJson(): Promise<StatusSnapshot> {
  const res = await invoke<CommandOutput>('run_status', { json: true });
  if (!res.success) throw new Error(res.stderr || 'Status failed');
  return JSON.parse(res.stdout);
}

export async function runOptimize(dryRun: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_optimize', { dryRun });
}

export async function runUninstall(dryRun: boolean, permanent?: boolean, nonInteractive?: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_uninstall', { dryRun, permanent, nonInteractive });
}

export async function runPurge(dryRun: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_purge', { dryRun });
}

export async function runInstaller(dryRun: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_installer', { dryRun });
}

export async function runHistory(json: boolean, limit: number): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_history', { json, limit });
}

export async function runHistoryJson(limit: number): Promise<HistoryResult> {
  const res = await invoke<CommandOutput>('run_history', { json: true, limit });
  if (!res.success) throw new Error(res.stderr || 'History failed');
  return JSON.parse(res.stdout);
}

export async function runTouchid(action: string, dryRun: boolean): Promise<CommandOutput> {
  return invoke<CommandOutput>('run_touchid', { action, dryRun });
}

export async function listApps(): Promise<AppListEntry[]> {
  const res = await invoke<CommandOutput>('list_apps');
  if (!res.success) throw new Error(res.stderr || 'List apps failed');
  try {
    return JSON.parse(res.stdout);
  } catch {
    return [];
  }
}

// ---- 原生扫描器 ----

export async function scanPurge(paths?: string[]): Promise<PurgeScanResult> {
  return invoke<PurgeScanResult>('scan_purge', { paths: paths || null });
}

export async function scanInstaller(): Promise<InstallerScanResult> {
  return invoke<InstallerScanResult>('scan_installer');
}

// ---- Trash 路由 ----

export async function trashPaths(paths: string[]): Promise<number> {
  return invoke<number>('trash_paths', { paths });
}

export async function validatePath(path: string): Promise<string> {
  return invoke<string>('validate_path_cmd', { path });
}

// ---- 流式命令 ----

export interface StreamingLine {
  text: string;
  type: 'info' | 'success' | 'warn' | 'error' | 'accent' | 'dim' | 'section';
}

export async function runCleanStreaming(
  dryRun: boolean,
  verbose: boolean,
  onLine: (line: StreamingLine) => void
): Promise<CommandOutput> {
  const channel = new Channel<string>();
  channel.onmessage = (raw) => onLine(classifyLine(raw));
  return invoke<CommandOutput>('run_clean_streaming', {
    dryRun,
    verbose,
    onLine: channel,
  });
}

export async function runOptimizeStreaming(
  dryRun: boolean,
  onLine: (line: StreamingLine) => void
): Promise<CommandOutput> {
  const channel = new Channel<string>();
  channel.onmessage = (raw) => onLine(classifyLine(raw));
  return invoke<CommandOutput>('run_optimize_streaming', {
    dryRun,
    onLine: channel,
  });
}

export async function runUninstallStreaming(
  dryRun: boolean,
  permanent: boolean,
  nonInteractive: boolean,
  onLine: (line: StreamingLine) => void
): Promise<CommandOutput> {
  const channel = new Channel<string>();
  channel.onmessage = (raw) => onLine(classifyLine(raw));
  return invoke<CommandOutput>('run_uninstall_streaming', {
    dryRun,
    permanent,
    nonInteractive,
    onLine: channel,
  });
}

// ---- 工具函数 ----

export async function openFinder(path: string): Promise<void> {
  await invoke('open_finder', { path });
}

export async function copyToClipboard(text: string): Promise<void> {
  await invoke('copy_to_clipboard', { text });
}

export async function checkForUpdate(): Promise<UpdateInfo | null> {
  try {
    return await invoke<UpdateInfo>('check_for_update');
  } catch {
    return null;
  }
}

export async function downloadAndInstall(url: string): Promise<string> {
  return invoke<string>('download_and_install', { url });
}

export async function restartApp(): Promise<void> {
  await invoke('restart_app');
}

// ---- 行分类器（给流式输出着色）----

export function classifyLine(raw: string): StreamingLine {
  const line = raw.replace(/\x1b\[[0-9;]*m/g, '').trimEnd(); // 剥离 ANSI 颜色
  if (!line) return { text: '', type: 'dim' };

  // Section 头：➤ 或 ━━━
  if (/^[━─=]{3,}/.test(line) || /➤|▸|▶/.test(line)) {
    return { text: line, type: 'section' };
  }
  // 成功
  if (/✓|✔|success|complete/i.test(line)) {
    return { text: line, type: 'success' };
  }
  // 警告
  if (/⚠|warning|⚠️|skipped|跳过/i.test(line)) {
    return { text: line, type: 'warn' };
  }
  // 错误
  if (/✗|✘|error|failed|错误/i.test(line)) {
    return { text: line, type: 'error' };
  }
  // dry-run 标记
  if (/dry|预览|◇|◎/i.test(line)) {
    return { text: line, type: 'accent' };
  }
  // 暗淡（空行、提示）
  if (/^\s*$|^  [a-z]/i.test(line) && line.length < 60) {
    return { text: line, type: 'dim' };
  }
  return { text: line, type: 'info' };
}
