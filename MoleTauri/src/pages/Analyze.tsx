// Analyze 页：磁盘空间可视化分析
// 调用 mo analyze --json，展示 Treemap + 列表 + 大文件 + 多选 Trash 删除
import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardHeader, Button, Badge, Checkbox, EmptyState, Spinner, Modal } from '../components/ui';
import { Treemap, type TreemapNode } from '../components/charts';
import { runAnalyze, trashPaths, writeLog, type AnalyzeResult, type AnalyzeEntry } from '../lib/cli';
import { analyze as t, common } from '../lib/i18n';
import { formatBytes, formatBytesShort, formatRelativeTime } from '../lib/format';

type ViewMode = 'treemap' | 'list';

export default function AnalyzePage() {
  const [result, setResult] = useState<AnalyzeResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<ViewMode>('treemap');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [path, setPath] = useState('');
  const [breadcrumb, setBreadcrumb] = useState<string[]>([]);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteResult, setDeleteResult] = useState<string | null>(null);

  const doScan = useCallback(async (scanPath?: string) => {
    setLoading(true);
    setError(null);
    setSelected(new Set());
    writeLog('info', `磁盘分析开始: ${scanPath ?? ''}`).catch(() => {});
    try {
      const data = await runAnalyze(scanPath);
      setResult(data);
      setBreadcrumb(data.path ? data.path.split('/').filter(Boolean) : []);
      writeLog('info', `磁盘分析完成: ${data.path ?? scanPath ?? ''}`).catch(() => {});
    } catch (e: any) {
      setError(e?.message ?? String(e));
      writeLog('error', `磁盘分析失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    doScan();
  }, [doScan]);

  const treemapRoot = useMemo<TreemapNode>(() => {
    if (!result) return { name: 'root', value: 0, children: [] };
    const children: TreemapNode[] = result.entries.map((e) => ({
      name: e.name,
      value: e.size,
      path: e.path,
      isDir: e.is_dir,
      color: e.cleanable ? '#22d3ee' : e.insight ? '#fbbf24' : undefined,
    }));
    return {
      name: result.path || 'root',
      value: result.total_size,
      children,
      path: result.path,
    };
  }, [result]);

  const selectedEntries = useMemo(() => {
    if (!result) return [];
    return result.entries.filter((e) => selected.has(e.path));
  }, [result, selected]);

  const selectedSize = useMemo(() => {
    return selectedEntries.reduce((s, e) => s + e.size, 0);
  }, [selectedEntries]);

  const toggleSelect = (entryPath: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(entryPath)) next.delete(entryPath);
      else next.add(entryPath);
      return next;
    });
  };

  const selectAll = () => {
    if (!result) return;
    setSelected(new Set(result.entries.map((e) => e.path)));
  };

  const deselectAll = () => setSelected(new Set());

  const handleDelete = async () => {
    if (selectedEntries.length === 0) return;
    setConfirmOpen(false);
    setDeleting(true);
    setDeleteResult(null);
    const count = selectedEntries.length;
    writeLog('info', `磁盘分析删除开始，${count} 项`).catch(() => {});
    try {
      const paths = selectedEntries.map((e) => e.path);
      const deleted = await trashPaths(paths);
      setDeleteResult(`已删除 ${deleted} 项（${formatBytes(selectedSize)}）`);
      setSelected(new Set());
      writeLog('info', '磁盘分析删除完成').catch(() => {});
      // 重新扫描
      await doScan(result?.path);
    } catch (e: any) {
      setDeleteResult(`删除失败: ${e?.message ?? e}`);
      writeLog('error', `磁盘分析删除失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setDeleting(false);
    }
  };

  return (
    <div className="page page-wide analyze-page">
      {/* 工具栏 */}
      <div className="analyze-toolbar">
        <div className="analyze-toolbar-left">
          <input
            className="analyze-path-input"
            placeholder={t.enterPath()}
            value={path}
            onChange={(e) => setPath(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && doScan(path)}
          />
          <Button variant="primary" size="sm" onClick={() => doScan(path)}>
            {t.scanPath()}
          </Button>
          <Button variant="ghost" size="sm" onClick={() => doScan()}>
            {t.scanOverview()}
          </Button>
        </div>
        <div className="analyze-toolbar-right">
          <div className="view-switch">
            <button
              className={`view-btn ${view === 'treemap' ? 'active' : ''}`}
              onClick={() => setView('treemap')}
            >
              {t.treemap()}
            </button>
            <button
              className={`view-btn ${view === 'list' ? 'active' : ''}`}
              onClick={() => setView('list')}
            >
              {t.list()}
            </button>
          </div>
        </div>
      </div>

      {/* 汇总卡片 */}
      {result && (
        <div className="analyze-stats">
          <Card variant="compact">
            <div className="analyze-stat">
              <span className="analyze-stat-label">{t.totalSize()}</span>
              <span className="analyze-stat-value">{formatBytes(result.total_size)}</span>
            </div>
          </Card>
          <Card variant="compact">
            <div className="analyze-stat">
              <span className="analyze-stat-label">{t.entries()}</span>
              <span className="analyze-stat-value">{result.entries.length}</span>
            </div>
          </Card>
          {result.total_files != null && (
            <Card variant="compact">
              <div className="analyze-stat">
                <span className="analyze-stat-label">{t.totalFiles()}</span>
                <span className="analyze-stat-value">{result.total_files.toLocaleString()}</span>
              </div>
            </Card>
          )}
          {result.large_files && result.large_files.length > 0 && (
            <Card variant="compact">
              <div className="analyze-stat">
                <span className="analyze-stat-label">{t.largeFiles()}</span>
                <span className="analyze-stat-value">{result.large_files.length}</span>
              </div>
            </Card>
          )}
        </div>
      )}

      {/* 加载/错误状态 */}
      {loading && (
        <Card>
          <div className="analyze-loading">
            <Spinner size="md" />
            <span>{common.loading()}</span>
          </div>
        </Card>
      )}

      {error && !loading && (
        <Card>
          <EmptyState
            icon="⚠️"
            title={common.error()}
            description={error}
            action={<Button variant="primary" onClick={() => doScan(path)}>{common.retry()}</Button>}
          />
        </Card>
      )}

      {/* 主视图 */}
      {result && !loading && (
        <>
          {view === 'treemap' ? (
            <Card variant="glass">
              <CardHeader
                title={t.breakdown()}
                action={
                  <div className="analyze-legend">
                    <span className="legend-item">
                      <span className="legend-dot" style={{ background: '#22d3ee' }} />
                      {t.cleanable()}
                    </span>
                    <span className="legend-item">
                      <span className="legend-dot" style={{ background: '#fbbf24' }} />
                      {t.insight()}
                    </span>
                    <span className="legend-item">
                      <span className="legend-dot" style={{ background: '#4ade80' }} />
                      {common.total()}
                    </span>
                  </div>
                }
              />
              <Treemap
                root={treemapRoot}
                height={360}
                breadcrumb={breadcrumb}
                onSelect={(node) => {
                  if (node.isDir && node.path) {
                    doScan(node.path);
                  }
                }}
                minWeight={result.total_size * 0.005}
              />
            </Card>
          ) : (
            <Card variant="glass">
              <CardHeader
                title={t.list()}
                action={
                  <div className="analyze-list-actions">
                    <Button size="sm" variant="ghost" onClick={selectAll}>{common.selectAll()}</Button>
                    <Button size="sm" variant="ghost" onClick={deselectAll}>{common.deselectAll()}</Button>
                  </div>
                }
              />
              <div className="analyze-list">
                <div className="analyze-list-head">
                  <span className="col-check" />
                  <span className="col-name">{common.name()}</span>
                  <span className="col-size">{common.size()}</span>
                  <span className="col-type">{common.type()}</span>
                  <span className="col-access">{t.lastAccess()}</span>
                </div>
                {result.entries.map((entry, i) => (
                  <AnalyzeRow
                    key={i}
                    entry={entry}
                    checked={selected.has(entry.path)}
                    onToggle={() => toggleSelect(entry.path)}
                  />
                ))}
              </div>
            </Card>
          )}

          {/* 大文件卡片 */}
          {result.large_files && result.large_files.length > 0 && (
            <Card variant="glass">
              <CardHeader title={t.largeFiles()} subtitle={`${result.large_files.length} files`} />
              <div className="analyze-large-files">
                {result.large_files.slice(0, 20).map((f, i) => (
                  <div key={i} className="analyze-large-file">
                    <span className="large-file-name">{f.name}</span>
                    <span className="large-file-path" title={f.path}>{f.path}</span>
                    <Badge tone="warn">{formatBytes(f.size)}</Badge>
                  </div>
                ))}
              </div>
            </Card>
          )}
        </>
      )}

      {/* 底部选择栏 */}
      {selected.size > 0 && (
        <div className="analyze-select-bar">
          <div className="select-bar-info">
            <Badge tone="accent">{t.selected()} {selected.size}</Badge>
            <span className="select-bar-size">{formatBytes(selectedSize)}</span>
          </div>
          <div className="select-bar-actions">
            <Button variant="ghost" size="sm" onClick={deselectAll}>{common.cancel()}</Button>
            <Button
              variant="danger"
              size="sm"
              onClick={() => setConfirmOpen(true)}
              disabled={deleting}
            >
              {deleting ? common.executing() : t.deleteSelected()}
            </Button>
          </div>
        </div>
      )}

      {/* 删除结果提示 */}
      {deleteResult && (
        <div className="analyze-toast" onClick={() => setDeleteResult(null)}>
          {deleteResult}
        </div>
      )}

      {/* 确认对话框 */}
      <Modal
        open={confirmOpen}
        onClose={() => setConfirmOpen(false)}
        title={t.deleteConfirm(selected.size, formatBytes(selectedSize))}
        footer={
          <>
            <Button variant="ghost" onClick={() => setConfirmOpen(false)}>{common.cancel()}</Button>
            <Button variant="danger" onClick={handleDelete}>{common.confirm()}</Button>
          </>
        }
      >
        <p className="modal-warn-text">
          {common.moveToTrash()} — {t.deleteConfirm(selected.size, formatBytes(selectedSize))}
        </p>
        <div className="modal-entry-preview">
          {selectedEntries.slice(0, 10).map((e, i) => (
            <div key={i} className="modal-entry-row">
              <span className="modal-entry-name">{e.name}</span>
              <span className="modal-entry-size">{formatBytesShort(e.size)}</span>
            </div>
          ))}
          {selectedEntries.length > 10 && (
            <div className="modal-entry-more">... +{selectedEntries.length - 10} more</div>
          )}
        </div>
      </Modal>
    </div>
  );
}

function AnalyzeRow({ entry, checked, onToggle }: { entry: AnalyzeEntry; checked: boolean; onToggle: () => void }) {
  return (
    <div className={`analyze-list-row ${checked ? 'selected' : ''}`}>
      <span className="col-check">
        <Checkbox checked={checked} onChange={onToggle} />
      </span>
      <span className="col-name" title={entry.path}>
        <span className="entry-icon">{entry.is_dir ? '📁' : '📄'}</span>
        {entry.name}
        {entry.cleanable && <Badge tone="info" className="entry-badge">{t.cleanable()}</Badge>}
        {entry.insight && <Badge tone="warn" className="entry-badge">{t.insight()}</Badge>}
      </span>
      <span className="col-size">{formatBytes(entry.size)}</span>
      <span className="col-type">{entry.is_dir ? 'Dir' : 'File'}</span>
      <span className="col-access">{entry.last_access ? formatRelativeTime(new Date(entry.last_access).getTime() / 1000) : '—'}</span>
    </div>
  );
}
