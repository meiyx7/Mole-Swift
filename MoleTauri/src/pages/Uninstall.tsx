// Uninstall 页：应用卸载
// 加载应用列表，支持搜索/排序/多选，流式执行卸载
import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardHeader, Button, Badge, Checkbox, EmptyState, Spinner, Modal, ConsoleOutput } from '../components/ui';
import { listApps, runUninstallStreaming, writeLog, copyToClipboard, type AppListEntry, type StreamingLine } from '../lib/cli';
import { uninstall as t, common } from '../lib/i18n';
import { formatBytes, formatKB, formatRelativeTime, parseSizeString } from '../lib/format';

type SortMode = 'size' | 'date' | 'name';
type SortDir = 'asc' | 'desc';

const ICON_COLORS = ['#22d3ee', '#a78bfa', '#f472b6', '#34d399', '#fbbf24', '#60a5fa', '#fb7185', '#4ade80'];

function iconColor(name: string): string {
  const code = name ? name.charCodeAt(0) : 0;
  return ICON_COLORS[code % ICON_COLORS.length];
}

function sourceMeta(source: string): { tone: 'accent' | 'info' | 'default'; label: string } {
  // CLI 返回的 source 值是 "App" / "Homebrew"，也兼容历史值 "brew" / "appstore"
  const s = (source || '').toLowerCase();
  if (s === 'brew' || s === 'homebrew') return { tone: 'accent', label: t.brew() };
  if (s === 'appstore' || s === 'app store') return { tone: 'info', label: t.appStore() };
  return { tone: 'default', label: t.manual() };
}

function appKey(app: AppListEntry): string {
  return app.uninstall_name || app.name || app.path;
}

/// 获取应用的有效字节数：优先用 size_kb，为 0 时回退解析 size 字符串。
function appSizeBytes(app: AppListEntry): number {
  if (app.size_kb > 0) return app.size_kb * 1024;
  if (app.size && app.size !== 'N/A' && app.size !== 'Unknown') {
    return parseSizeString(app.size);
  }
  return 0;
}

export default function UninstallPage() {
  const [apps, setApps] = useState<AppListEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [errorCopied, setErrorCopied] = useState(false);
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<SortMode>('size');
  const [sortDir, setSortDir] = useState<SortDir>('desc');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [executing, setExecuting] = useState(false);
  const [consoleLines, setConsoleLines] = useState<StreamingLine[]>([]);
  const [resultMsg, setResultMsg] = useState<string | null>(null);

  const loadApps = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const list = await listApps();
      setApps(list);
      writeLog('info', `卸载页面加载应用列表成功，共 ${list.length} 个应用`).catch(() => {});
    } catch (e: any) {
      const msg = e?.message ?? String(e);
      setError(msg);
      writeLog('error', `卸载页面加载应用列表失败: ${msg}`).catch(() => {});
    } finally {
      setLoading(false);
    }
  }, []);

  const copyError = useCallback(async () => {
    if (!error) return;
    try {
      await copyToClipboard(error);
      setErrorCopied(true);
      setTimeout(() => setErrorCopied(false), 2000);
    } catch {
      // ignore
    }
  }, [error]);

  useEffect(() => {
    loadApps();
  }, [loadApps]);

  const filteredApps = useMemo(() => {
    const q = search.trim().toLowerCase();
    let list = apps;
    if (q) {
      list = list.filter((a) => a.name.toLowerCase().includes(q));
    }
    const sorted = [...list];
    const dir = sortDir === 'asc' ? 1 : -1;
    switch (sort) {
      case 'size':
        sorted.sort((a, b) => (appSizeBytes(a) - appSizeBytes(b)) * dir);
        break;
      case 'date':
        // epoch 为 0 的（无使用记录）在倒序时排到末尾，正序时排到开头
        sorted.sort((a, b) => (a.last_used_epoch - b.last_used_epoch) * dir);
        break;
      case 'name':
        sorted.sort((a, b) => a.name.localeCompare(b.name) * dir);
        break;
    }
    return sorted;
  }, [apps, search, sort, sortDir]);

  const selectedApps = useMemo(() => {
    return apps.filter((a) => selected.has(appKey(a)));
  }, [apps, selected]);

  const selectedSizeKb = useMemo(() => {
    return selectedApps.reduce((s, a) => s + Math.round(appSizeBytes(a) / 1024), 0);
  }, [selectedApps]);

  const toggleSelect = (key: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const selectAll = () => {
    setSelected(new Set(filteredApps.map(appKey)));
  };

  const deselectAll = () => setSelected(new Set());

  const confirmUninstall = useCallback(async () => {
    setConfirmOpen(false);
    setExecuting(true);
    setResultMsg(null);
    setConsoleLines([]);
    const count = selectedApps.length;
    try {
      const result = await runUninstallStreaming(false, false, true, (line: StreamingLine) => {
        setConsoleLines((prev) => [...prev, line]);
      });
      if (result.success) {
        setResultMsg(t.uninstalled(count));
        setSelected(new Set());
        await loadApps();
      } else {
        setResultMsg(result.stderr || result.stdout || common.error());
      }
    } catch (e: any) {
      setResultMsg(e?.message ?? String(e));
    } finally {
      setExecuting(false);
    }
  }, [selectedApps.length, loadApps]);

  return (
    <div className="page page-wide uninstall-page">
      {/* 工具栏 */}
      <Card variant="glass">
        <div className="uninstall-toolbar">
          <div className="uninstall-toolbar-left">
            <input
              className="uninstall-search-input"
              type="text"
              placeholder={common.search()}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
            {apps.length > 0 && (
              <Badge tone="info">{t.installedApps(apps.length)}</Badge>
            )}
          </div>
          <div className="uninstall-toolbar-right">
            <label className="uninstall-sort-label">
              {t.sortBy()}
              <select
                className="uninstall-sort-select"
                value={sort}
                onChange={(e) => setSort(e.target.value as SortMode)}
              >
                <option value="size">{t.sortSize()}</option>
                <option value="date">{t.sortDate()}</option>
                <option value="name">{t.sortName()}</option>
              </select>
            </label>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))}
              disabled={loading || executing}
              title={sortDir === 'asc' ? t.sortAsc() : t.sortDesc()}
            >
              {sortDir === 'asc' ? '↑' : '↓'}
            </Button>
            <Button size="sm" variant="ghost" onClick={selectAll} disabled={loading || executing}>
              {common.selectAll()}
            </Button>
            <Button size="sm" variant="ghost" onClick={deselectAll} disabled={selected.size === 0 || executing}>
              {common.deselectAll()}
            </Button>
            <Button size="sm" variant="ghost" onClick={loadApps} disabled={loading || executing}>
              {common.refresh()}
            </Button>
            {selected.size > 0 && (
              <>
                <span className="uninstall-toolbar-sep" />
                <Badge tone="accent">{t.selected(selected.size)}</Badge>
                <span className="uninstall-action-size">{formatKB(selectedSizeKb)}</span>
                <Button variant="ghost" size="sm" onClick={deselectAll} disabled={executing}>
                  {common.cancel()}
                </Button>
                <Button
                  variant="danger"
                  size="sm"
                  onClick={() => setConfirmOpen(true)}
                  disabled={executing}
                >
                  {executing ? common.executing() : t.uninstallSelected()}
                </Button>
              </>
            )}
          </div>
        </div>
      </Card>

      {/* 加载中 */}
      {loading && (
        <Card>
          <div className="uninstall-loading">
            <Spinner size="md" />
            <span>{t.loadingApps()}</span>
          </div>
        </Card>
      )}

      {/* 错误 */}
      {error && !loading && (
        <Card>
          <EmptyState
            icon="⚠️"
            title={common.error()}
            description={
              <div style={{ textAlign: 'left', width: '100%' }}>
                <pre style={{
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-all',
                  fontSize: 12,
                  fontFamily: 'var(--font-mono)',
                  color: 'var(--text-secondary)',
                  maxHeight: 300,
                  overflow: 'auto',
                  margin: '8px 0',
                }}>
                  {error}
                </pre>
              </div>
            }
            action={
              <div style={{ display: 'flex', gap: 8 }}>
                <Button variant="primary" onClick={loadApps}>{common.retry()}</Button>
                <Button variant="ghost" onClick={copyError}>
                  {errorCopied ? '✓ 已复制' : '复制错误信息'}
                </Button>
              </div>
            }
          />
        </Card>
      )}

      {/* 空状态 */}
      {!loading && !error && apps.length === 0 && (
        <Card>
          <EmptyState
            icon="📦"
            title={t.noApps()}
            description={common.noData()}
          />
        </Card>
      )}

      {/* 搜索无结果 */}
      {!loading && !error && apps.length > 0 && filteredApps.length === 0 && (
        <Card>
          <EmptyState
            icon="🔍"
            title={t.noApps()}
            description={search}
          />
        </Card>
      )}

      {/* 应用列表（紧凑表格样式） */}
      {!loading && !error && filteredApps.length > 0 && (
        <Card variant="glass" className="uninstall-list-card">
          {/* 表头 */}
          <div className="uninstall-list-header">
            <span className="uninstall-list-check-col"></span>
            <span className="uninstall-list-name-col">{t.appName()}</span>
            <span className="uninstall-list-size-col">{t.size()}</span>
            <span className="uninstall-list-source-col">{t.source()}</span>
            <span className="uninstall-list-date-col">{t.lastUsed()}</span>
          </div>
          {/* 行 */}
          {filteredApps.map((app) => {
            const key = appKey(app);
            const isChecked = selected.has(key);
            const meta = sourceMeta(app.source);
            // size 显示：优先用 size_kb 计算，为 0 时回退到 CLI 的 size 字符串
            const sizeDisplay =
              app.size_kb > 0
                ? formatBytes(app.size_kb * 1024)
                : app.size && app.size !== 'N/A'
                ? app.size
                : '—';
            return (
              <div
                key={key}
                className={`uninstall-list-row ${isChecked ? 'selected' : ''}`}
                onClick={() => toggleSelect(key)}
              >
                <span className="uninstall-list-check-col">
                  <Checkbox checked={isChecked} onChange={() => toggleSelect(key)} />
                </span>
                <span className="uninstall-list-name-col">
                  <span
                    className="uninstall-app-icon-sm"
                    style={{
                      background: iconColor(app.name),
                      color: '#0b0f17',
                    }}
                  >
                    {(app.name || '?').charAt(0).toUpperCase()}
                  </span>
                  <span className="uninstall-list-name" title={app.name}>{app.name}</span>
                </span>
                <span className="uninstall-list-size-col">{sizeDisplay}</span>
                <span className="uninstall-list-source-col">
                  <Badge tone={meta.tone}>{meta.label}</Badge>
                </span>
                <span className="uninstall-list-date-col">
                  {formatRelativeTime(app.last_used_epoch)}
                </span>
              </div>
            );
          })}
        </Card>
      )}

      {/* 控制台输出 */}
      {(executing || consoleLines.length > 0) && (
        <Card variant="glass">
          <CardHeader
            title={executing ? common.executing() : common.done()}
            action={executing ? <Spinner size="sm" /> : undefined}
          />
          <ConsoleOutput lines={consoleLines} maxLines={500} />
        </Card>
      )}

      {/* 结果提示 */}
      {resultMsg && !executing && (
        <Card variant="glass">
          <div className="uninstall-result">{resultMsg}</div>
        </Card>
      )}

      {/* 确认对话框 */}
      <Modal
        open={confirmOpen}
        onClose={() => setConfirmOpen(false)}
        title={t.uninstallConfirm(selected.size, formatKB(selectedSizeKb))}
        footer={
          <>
            <Button variant="ghost" onClick={() => setConfirmOpen(false)}>{common.cancel()}</Button>
            <Button variant="danger" onClick={confirmUninstall}>{common.confirm()}</Button>
          </>
        }
      >
        <div className="uninstall-confirm-list">
          {selectedApps.slice(0, 10).map((app) => (
            <div key={appKey(app)} className="uninstall-confirm-row">
              <span className="uninstall-confirm-name">{app.name}</span>
              <span className="uninstall-confirm-size">
                {app.size_kb > 0 ? formatBytes(app.size_kb * 1024) : (app.size && app.size !== 'N/A' ? app.size : '—')}
              </span>
            </div>
          ))}
          {selectedApps.length > 10 && (
            <div className="uninstall-confirm-more">... +{selectedApps.length - 10}</div>
          )}
        </div>
      </Modal>
    </div>
  );
}
