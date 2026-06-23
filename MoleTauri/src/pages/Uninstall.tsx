// Uninstall 页：应用卸载
// 加载应用列表，支持搜索/排序/多选，流式执行卸载
import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardHeader, Button, Badge, Checkbox, EmptyState, Spinner, Modal, ConsoleOutput } from '../components/ui';
import { listApps, runUninstallStreaming, type AppListEntry, type StreamingLine } from '../lib/cli';
import { uninstall as t, common } from '../lib/i18n';
import { formatBytes, formatKB, formatRelativeTime } from '../lib/format';

type SortMode = 'size' | 'date' | 'name';

const ICON_COLORS = ['#22d3ee', '#a78bfa', '#f472b6', '#34d399', '#fbbf24', '#60a5fa', '#fb7185', '#4ade80'];

function iconColor(name: string): string {
  const code = name ? name.charCodeAt(0) : 0;
  return ICON_COLORS[code % ICON_COLORS.length];
}

function sourceMeta(source: string): { tone: 'accent' | 'info' | 'default'; label: string } {
  switch (source) {
    case 'brew': return { tone: 'accent', label: t.brew() };
    case 'appstore': return { tone: 'info', label: t.appStore() };
    default: return { tone: 'default', label: t.manual() };
  }
}

function appKey(app: AppListEntry): string {
  return app.uninstall_name || app.name || app.path;
}

export default function UninstallPage() {
  const [apps, setApps] = useState<AppListEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<SortMode>('size');
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
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  }, []);

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
    switch (sort) {
      case 'size':
        sorted.sort((a, b) => b.size_kb - a.size_kb);
        break;
      case 'date':
        sorted.sort((a, b) => b.last_used_epoch - a.last_used_epoch);
        break;
      case 'name':
        sorted.sort((a, b) => a.name.localeCompare(b.name));
        break;
    }
    return sorted;
  }, [apps, search, sort]);

  const selectedApps = useMemo(() => {
    return apps.filter((a) => selected.has(appKey(a)));
  }, [apps, selected]);

  const selectedSizeKb = useMemo(() => {
    return selectedApps.reduce((s, a) => s + a.size_kb, 0);
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
            <Button size="sm" variant="ghost" onClick={selectAll} disabled={loading || executing}>
              {common.selectAll()}
            </Button>
            <Button size="sm" variant="ghost" onClick={deselectAll} disabled={selected.size === 0 || executing}>
              {common.deselectAll()}
            </Button>
            <Button size="sm" variant="ghost" onClick={loadApps} disabled={loading || executing}>
              {common.refresh()}
            </Button>
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
            description={error}
            action={<Button variant="primary" onClick={loadApps}>{common.retry()}</Button>}
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

      {/* 应用卡片网格 */}
      {!loading && !error && filteredApps.length > 0 && (
        <div
          className="uninstall-grid"
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
            gap: '12px',
          }}
        >
          {filteredApps.map((app) => {
            const key = appKey(app);
            const isChecked = selected.has(key);
            const meta = sourceMeta(app.source);
            return (
              <Card key={key} variant="glass" className={`uninstall-card ${isChecked ? 'selected' : ''}`}>
                <div className="uninstall-card-top">
                  <Checkbox checked={isChecked} onChange={() => toggleSelect(key)} />
                  <div
                    className="uninstall-app-icon"
                    style={{
                      width: 36,
                      height: 36,
                      borderRadius: 8,
                      background: iconColor(app.name),
                      color: '#0b0f17',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontWeight: 700,
                      fontSize: 18,
                      flexShrink: 0,
                    }}
                  >
                    {(app.name || '?').charAt(0).toUpperCase()}
                  </div>
                  <div className="uninstall-card-name" title={app.name}>
                    {app.name}
                  </div>
                </div>
                <div className="uninstall-card-size">
                  {formatBytes(app.size_kb * 1024)}
                </div>
                <div className="uninstall-card-meta">
                  <Badge tone={meta.tone}>{meta.label}</Badge>
                  <span className="uninstall-card-date">
                    {t.lastUsed()}: {formatRelativeTime(app.last_used_epoch)}
                  </span>
                </div>
              </Card>
            );
          })}
        </div>
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

      {/* 底部操作栏 */}
      {selected.size > 0 && (
        <div
          className="uninstall-action-bar"
          style={{
            position: 'sticky',
            bottom: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 12,
            padding: '12px 16px',
          }}
        >
          <div className="uninstall-action-info">
            <Badge tone="accent">{t.selected(selected.size)}</Badge>
            <span className="uninstall-action-size">{formatKB(selectedSizeKb)}</span>
          </div>
          <div className="uninstall-action-buttons">
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
          </div>
        </div>
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
              <span className="uninstall-confirm-size">{formatBytes(app.size_kb * 1024)}</span>
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
