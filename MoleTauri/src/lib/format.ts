// 字节/时间/数字格式化工具

/// 把任意值安全转为数组。非数组（含 null/undefined/对象/字符串）返回 []。
/// 用于防御 `mo status --json` 返回的字段类型与预期不符时 `.map()` 崩溃。
export function asArray<T>(v: unknown): T[] {
  return Array.isArray(v) ? v : [];
}

/// 安全取数组指定下标元素，越界或非数组时返回 fallback。
export function arrayGet<T>(v: unknown, idx: number, fallback: T): T {
  if (!Array.isArray(v)) return fallback;
  const item = v[idx];
  return item === undefined ? fallback : (item as T);
}

/// 安全取数值，非数字返回 fallback。
export function asNumber(v: unknown, fallback = 0): number {
  if (typeof v === 'number' && !isNaN(v)) return v;
  if (typeof v === 'string') {
    const n = parseFloat(v);
    return isNaN(n) ? fallback : n;
  }
  return fallback;
}

export function formatBytes(bytes: number, decimals = 1): string {
  if (bytes === 0 || bytes == null) return '0 B';
  if (bytes < 0) return '-' + formatBytes(-bytes, decimals);
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(k)), sizes.length - 1);
  const val = bytes / Math.pow(k, i);
  // 大单位用 2 位小数，小单位用 1 位
  const d = i >= 2 ? 2 : decimals;
  return `${val.toFixed(d)} ${sizes[i]}`;
}

export function formatBytesShort(bytes: number): string {
  if (bytes === 0 || bytes == null) return '0';
  const k = 1024;
  const sizes = ['B', 'K', 'M', 'G', 'T', 'P'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(k)), sizes.length - 1);
  const val = bytes / Math.pow(k, i);
  return `${val.toFixed(i >= 2 ? 1 : 0)}${sizes[i]}`;
}

export function formatKB(kb: number): string {
  return formatBytes(kb * 1024);
}

export function formatNumber(n: number): string {
  return n.toLocaleString('en-US');
}

export function formatPercent(value: number, total: number, decimals = 1): string {
  if (total === 0) return '0%';
  return `${((value / total) * 100).toFixed(decimals)}%`;
}

export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds.toFixed(0)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  if (m < 60) return `${m}m ${s}s`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return `${h}h ${rm}m`;
}

export function formatUptime(seconds: number): string {
  if (seconds == null || isNaN(seconds) || seconds < 0) return '—';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function formatRelativeTime(epoch: number): string {
  if (!epoch || epoch === 0) return '—';
  const now = Date.now() / 1000;
  const diff = now - epoch;
  if (diff < 0) return '刚刚';
  if (diff < 60) return '刚刚';
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)} 天前`;
  if (diff < 86400 * 30) return `${Math.floor(diff / (86400 * 7))} 周前`;
  if (diff < 86400 * 365) return `${Math.floor(diff / (86400 * 30))} 个月前`;
  return `${Math.floor(diff / (86400 * 365))} 年前`;
}

export function formatDateTime(iso: string): string {
  if (!iso) return '—';
  try {
    const d = new Date(iso);
    return d.toLocaleString('zh-CN', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return iso;
  }
}

export function formatTime(iso: string): string {
  if (!iso) return '—';
  try {
    const d = new Date(iso);
    return d.toLocaleTimeString('zh-CN', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
  } catch {
    return iso;
  }
}

// 颜色辅助：根据使用率返回状态色
export function usageColor(percent: number): string {
  if (percent >= 90) return 'critical';
  if (percent >= 70) return 'warn';
  return 'good';
}

// 颜色辅助：根据清理大小返回颜色
export function sizeColor(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) return 'good'; // >= 1GB
  if (bytes >= 100 * 1024 * 1024) return 'accent'; // >= 100MB
  return 'secondary';
}

/// 解析人类可读的大小字符串（如 "12.3MB", "1.5GB", "456KB"）为字节数。
/// 用于 size_kb 为 0 时回退解析 size 字符串。
export function parseSizeString(s: string): number {
  if (!s) return 0;
  const m = s.match(/([\d.]+)\s*(TB|GB|MB|KB|B)/i);
  if (!m) return 0;
  const val = parseFloat(m[1]);
  const unit = m[2].toUpperCase();
  const mult: Record<string, number> = {
    B: 1,
    KB: 1024,
    MB: 1024 * 1024,
    GB: 1024 * 1024 * 1024,
    TB: 1024 * 1024 * 1024 * 1024,
  };
  return Math.round(val * (mult[unit] || 1));
}
