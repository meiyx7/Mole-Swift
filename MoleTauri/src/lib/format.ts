// 字节/时间/数字格式化工具

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
