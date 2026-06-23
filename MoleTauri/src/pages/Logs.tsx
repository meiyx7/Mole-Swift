// Logs 页：应用运行日志查看器
// 读取 Rust 后端写入的日志文件，支持搜索、级别过滤、自动刷新
import { useState, useEffect, useCallback, useRef } from 'react';
import { Button, Badge, Spinner } from '../components/ui';
import { readAppLog, clearAppLog, appLogPath, copyToClipboard } from '../lib/cli';
import { common } from '../lib/i18n';

type LogLevel = 'all' | 'info' | 'warn' | 'error' | 'debug' | 'trace';

interface LogLine {
  raw: string;
  level: string;
  time: string;
  message: string;
}

/// 解析单行日志：`[2026-06-23 12:00:00] [INFO] message`
function parseLogLine(raw: string): LogLine {
  const match = raw.match(/^\[([^\]]+)\]\s*\[([A-Z]+)\]\s*(.*)$/);
  if (match) {
    return { raw, time: match[1], level: match[2], message: match[3] };
  }
  return { raw, time: '', level: '', message: raw };
}

function levelClass(level: string): string {
  switch (level.toUpperCase()) {
    case 'ERROR': return 'log-level-error';
    case 'WARN': return 'log-level-warn';
    case 'DEBUG': return 'log-level-debug';
    case 'TRACE': return 'log-level-trace';
    default: return 'log-level-info';
  }
}

const LEVEL_FILTERS: LogLevel[] = ['all', 'info', 'warn', 'error', 'debug'];

export default function LogsPage() {
  const [logText, setLogText] = useState('');
  const [logPath, setLogPath] = useState('');
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [activeLevel, setActiveLevel] = useState<LogLevel>('all');
  const [autoRefresh, setAutoRefresh] = useState(true);
  const viewerRef = useRef<HTMLDivElement>(null);
  const [copied, setCopied] = useState(false);

  const fetchLogs = useCallback(async () => {
    try {
      const text = await readAppLog(500);
      setLogText(text);
    } catch {
      // 静默失败
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchLogs();
    appLogPath().then(setLogPath).catch(() => {});
  }, [fetchLogs]);

  useEffect(() => {
    if (!autoRefresh) return;
    const timer = setInterval(fetchLogs, 3000);
    return () => clearInterval(timer);
  }, [autoRefresh, fetchLogs]);

  // 自动滚动到底部
  useEffect(() => {
    if (viewerRef.current) {
      viewerRef.current.scrollTop = viewerRef.current.scrollHeight;
    }
  }, [logText]);

  const handleClear = useCallback(async () => {
    try {
      await clearAppLog();
      setLogText('');
    } catch {
      // ignore
    }
  }, []);

  const handleCopy = useCallback(async () => {
    try {
      await copyToClipboard(logText);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // ignore
    }
  }, [logText]);

  // 解析 + 过滤
  const lines: LogLine[] = logText
    .split('\n')
    .filter((l) => l.trim())
    .map(parseLogLine);

  const filtered = lines.filter((line) => {
    if (activeLevel !== 'all' && line.level.toUpperCase() !== activeLevel.toUpperCase()) {
      return false;
    }
    if (search && !line.raw.toLowerCase().includes(search.toLowerCase())) {
      return false;
    }
    return true;
  });

  const errorCount = lines.filter((l) => l.level.toUpperCase() === 'ERROR').length;
  const warnCount = lines.filter((l) => l.level.toUpperCase() === 'WARN').length;

  return (
    <div className="page logs-page">
      {/* 工具栏 */}
      <div className="logs-toolbar">
        <div className="logs-toolbar-left">
          <input
            className="logs-search"
            type="text"
            placeholder="搜索日志..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <div style={{ display: 'flex', gap: 4 }}>
            {LEVEL_FILTERS.map((lvl) => (
              <button
                key={lvl}
                className={`logs-filter-btn ${activeLevel === lvl ? 'active' : ''}`}
                onClick={() => setActiveLevel(lvl)}
              >
                {lvl.toUpperCase()}
              </button>
            ))}
          </div>
        </div>
        <div className="logs-toolbar-right">
          {errorCount > 0 && <Badge tone="critical">ERROR {errorCount}</Badge>}
          {warnCount > 0 && <Badge tone="warn">WARN {warnCount}</Badge>}
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 12, color: 'var(--text-secondary)' }}>
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={(e) => setAutoRefresh(e.target.checked)}
            />
            Auto · 3s
          </label>
          <Button size="sm" variant="ghost" onClick={fetchLogs}>
            {common.refresh()}
          </Button>
          <Button size="sm" variant="ghost" onClick={handleCopy}>
            {copied ? '✓' : '复制'}
          </Button>
          <Button size="sm" variant="danger" onClick={handleClear}>
            清空
          </Button>
        </div>
      </div>

      {/* 日志路径 */}
      {logPath && (
        <div style={{ fontSize: 11, color: 'var(--text-tertiary)', fontFamily: 'var(--font-mono)' }}>
          📄 {logPath}
        </div>
      )}

      {/* 日志查看器 */}
      <div className="logs-viewer" ref={viewerRef}>
        {loading ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, color: 'var(--text-tertiary)' }}>
            <Spinner size="sm" />
            <span>{common.loading()}</span>
          </div>
        ) : filtered.length === 0 ? (
          <div className="logs-empty">
            {logText ? '没有匹配的日志' : '暂无日志'}
          </div>
        ) : (
          filtered.map((line, i) => (
            <div key={i} className="logs-line">
              {line.time && <span className="log-time">[{line.time}]</span>}{' '}
              {line.level && <span className={levelClass(line.level)}>[{line.level}]</span>}{' '}
              <span className={levelClass(line.level)}>{line.message}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
