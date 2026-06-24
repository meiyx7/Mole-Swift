// Purge 页：项目构建产物清理
// 使用 Rust 原生扫描器 scanPurge，按项目分组展示，支持拖放路径
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { Card, CardHeader, Button, Badge, Checkbox, EmptyState, Spinner, Modal, StatTile } from '../components/ui';
import { scanPurge, trashPaths, writeLog, type PurgeArtifact, type PurgeScanResult } from '../lib/cli';
import { purge as t, common } from '../lib/i18n';
import { formatBytes, formatBytesShort } from '../lib/format';

const ARTIFACT_COLORS: Record<string, string> = {
  node_modules: 'accent',
  target: 'info',
  build: 'warn',
  dist: 'purple',
  '.gradle': 'default',
  __pycache__: 'info',
  '.venv': 'accent',
  venv: 'accent',
  '.next': 'warn',
  out: 'default',
  bin: 'default',
  DerivedData: 'info',
};

function artifactTone(type: string): 'default' | 'good' | 'warn' | 'critical' | 'info' | 'accent' | 'purple' {
  const c = ARTIFACT_COLORS[type];
  if (c === 'accent' || c === 'info' || c === 'warn' || c === 'critical' || c === 'good' || c === 'purple' || c === 'default') return c;
  return 'default';
}

interface ProjectGroup {
  path: string;
  artifacts: PurgeArtifact[];
  totalSize: number;
}

export default function PurgePage() {
  const [result, setResult] = useState<PurgeScanResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [extraPaths, setExtraPaths] = useState<string[]>([]);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const doScan = useCallback(async (paths?: string[]) => {
    setLoading(true);
    setError(null);
    setSelected(new Set());
    writeLog('info', '清理产物扫描开始').catch(() => {});
    try {
      const data = await scanPurge(paths);
      setResult(data);
      writeLog('info', `清理产物扫描完成，共 ${data.total_count} 项`).catch(() => {});
    } catch (e: any) {
      setError(e?.message ?? String(e));
      writeLog('error', `清理产物扫描失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    doScan();
  }, [doScan]);

  // 按项目路径分组
  const groups = useMemo<ProjectGroup[]>(() => {
    if (!result) return [];
    const map = new Map<string, ProjectGroup>();
    for (const a of result.artifacts) {
      if (!map.has(a.project_path)) {
        map.set(a.project_path, { path: a.project_path, artifacts: [], totalSize: 0 });
      }
      const g = map.get(a.project_path)!;
      g.artifacts.push(a);
      g.totalSize += a.size;
    }
    // 每组内按大小降序
    for (const g of map.values()) {
      g.artifacts.sort((a, b) => b.size - a.size);
    }
    // 组间按总大小降序
    return Array.from(map.values()).sort((a, b) => b.totalSize - a.totalSize);
  }, [result]);

  const selectedArtifacts = useMemo(() => {
    if (!result) return [];
    return result.artifacts.filter((a) => selected.has(a.path));
  }, [result, selected]);

  const selectedSize = useMemo(() => {
    return selectedArtifacts.reduce((s, a) => s + a.size, 0);
  }, [selectedArtifacts]);

  const toggleSelect = (path: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const toggleGroup = (group: ProjectGroup) => {
    const allSelected = group.artifacts.every((a) => selected.has(a.path));
    setSelected((prev) => {
      const next = new Set(prev);
      if (allSelected) {
        group.artifacts.forEach((a) => next.delete(a.path));
      } else {
        group.artifacts.forEach((a) => next.add(a.path));
      }
      return next;
    });
  };

  const selectAll = () => {
    if (!result) return;
    setSelected(new Set(result.artifacts.map((a) => a.path)));
  };

  const deselectAll = () => setSelected(new Set());

  const handleDelete = async () => {
    setConfirmOpen(false);
    setDeleting(true);
    setToast(null);
    const count = selectedArtifacts.length;
    writeLog('info', `清理产物删除开始，${count} 项`).catch(() => {});
    try {
      const paths = selectedArtifacts.map((a) => a.path);
      const deleted = await trashPaths(paths, 'purge');
      setToast(t.purged(deleted, formatBytes(selectedSize)));
      setSelected(new Set());
      writeLog('info', '清理产物删除完成').catch(() => {});
      await doScan(extraPaths.length > 0 ? extraPaths : undefined);
    } catch (e: any) {
      setToast(`清理失败: ${e?.message ?? e}`);
      writeLog('error', `清理产物删除失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setDeleting(false);
    }
  };

  // 拖放处理
  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const files = Array.from(e.dataTransfer.files);
    const dirs = files
      .filter((f) => f.type === '' || f.name.startsWith('/'))
      .map((f) => (f as any).path || f.name)
      .filter((p: string): p is string => Boolean(p));
    if (dirs.length > 0) {
      const newPaths = [...extraPaths, ...dirs];
      setExtraPaths(newPaths);
      doScan(newPaths);
    }
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? []);
    const dirs = files.map((f) => (f as any).path || f.name).filter(Boolean);
    if (dirs.length > 0) {
      const newPaths = [...extraPaths, ...dirs];
      setExtraPaths(newPaths);
      doScan(newPaths);
    }
  };

  const removePath = (p: string) => {
    const newPaths = extraPaths.filter((x) => x !== p);
    setExtraPaths(newPaths);
    doScan(newPaths.length > 0 ? newPaths : undefined);
  };

  return (
    <div className="page page-wide purge-page">
      {/* 工具栏 */}
      <div className="purge-toolbar">
        <div className="purge-toolbar-left">
          <Button variant="primary" size="sm" onClick={() => doScan(extraPaths.length > 0 ? extraPaths : undefined)} disabled={loading}>
            {loading ? common.scanning() : t.scanProjects()}
          </Button>
          {result && result.scan_paths.length > 0 && (
            <Badge tone="default">{t.scanPaths()}: {result.scan_paths.length}</Badge>
          )}
        </div>
        <div className="purge-toolbar-right">
          {result && result.artifacts.length > 0 && (
            <>
              <Button size="sm" variant="ghost" onClick={selectAll}>{common.selectAll()}</Button>
              <Button size="sm" variant="ghost" onClick={deselectAll}>{common.deselectAll()}</Button>
            </>
          )}
        </div>
      </div>

      {/* 拖放区 */}
      <div
        className={`dropzone ${dragOver ? 'active' : ''}`}
        onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
        onDragLeave={() => setDragOver(false)}
        onDrop={handleDrop}
        onClick={() => fileInputRef.current?.click()}
      >
        <input
          ref={fileInputRef}
          type="file"
          // @ts-expect-error webkitdirectory is non-standard
          webkitdirectory=""
          directory=""
          multiple
          style={{ display: 'none' }}
          onChange={handleFileSelect}
        />
        <div className="dropzone-icon">📁</div>
        <div className="dropzone-text">{t.dropHere()}</div>
        <div className="dropzone-hint">{t.dropHint()}</div>
      </div>

      {/* 额外扫描路径列表 */}
      {extraPaths.length > 0 && (
        <Card variant="compact">
          <CardHeader title={t.configurePaths()} subtitle={`${extraPaths.length} paths`} />
          <div className="purge-paths-list">
            {extraPaths.map((p) => (
              <div key={p} className="purge-path-item">
                <code className="purge-path-code">{p}</code>
                <Button size="sm" variant="ghost" onClick={() => removePath(p)}>✕</Button>
              </div>
            ))}
          </div>
        </Card>
      )}

      {/* 汇总统计 */}
      {result && (
        <div className="purge-stats">
          <StatTile
            label={t.artifacts()}
            value={String(result.total_count)}
          />
          <StatTile
            label={common.total()}
            value={formatBytes(result.total_size)}
          />
          <StatTile
            label={common.items()}
            value={String(selected.size)}
          />
          <StatTile
            label={common.size()}
            value={formatBytes(selectedSize)}
          />
        </div>
      )}

      {/* 加载/错误状态 */}
      {loading && !result && (
        <Card>
          <div className="purge-loading">
            <Spinner size="md" />
            <span>{t.scanning()}</span>
          </div>
        </Card>
      )}

      {error && !loading && (
        <Card>
          <EmptyState
            icon="⚠️"
            title={common.error()}
            description={error}
            action={<Button variant="primary" onClick={() => doScan(extraPaths)}>{common.retry()}</Button>}
          />
        </Card>
      )}

      {/* 项目分组列表 */}
      {result && !loading && groups.length > 0 && (
        <div className="purge-groups">
          {groups.map((group, gi) => {
            const groupAllSelected = group.artifacts.every((a) => selected.has(a.path));
            const groupSomeSelected = group.artifacts.some((a) => selected.has(a.path));
            return (
              <Card key={gi} variant="glass" className="purge-group-card">
                <CardHeader
                  title={
                    <span className="purge-group-title">
                      <Checkbox
                        checked={groupAllSelected}
                        onChange={() => toggleGroup(group)}
                        className={groupSomeSelected && !groupAllSelected ? 'partial' : ''}
                      />
                      <code className="purge-group-path" title={group.path}>{group.path}</code>
                    </span>
                  }
                  subtitle={`${group.artifacts.length} artifacts · ${formatBytes(group.totalSize)}`}
                />
                <div className="purge-artifact-list">
                  {group.artifacts.map((a, ai) => {
                    const isRecent = a.age_days < 7;
                    const checked = selected.has(a.path);
                    return (
                      <div key={ai} className={`purge-artifact-row ${checked ? 'selected' : ''}`}>
                        <span className="purge-artifact-check">
                          <Checkbox checked={checked} onChange={() => toggleSelect(a.path)} />
                        </span>
                        <span className="purge-artifact-name" title={a.path}>
                          {a.path.replace(group.path, '.')}
                        </span>
                        <Badge tone={artifactTone(a.artifact_type)}>{a.artifact_type}</Badge>
                        {isRecent ? (
                          <span title={t.recentDesc()}><Badge tone="warn">{t.recent()}</Badge></span>
                        ) : (
                          <Badge tone="default">{t.ageDays(a.age_days)}</Badge>
                        )}
                        <span className="purge-artifact-size">{formatBytesShort(a.size)}</span>
                      </div>
                    );
                  })}
                </div>
              </Card>
            );
          })}
        </div>
      )}

      {/* 空状态 */}
      {result && !loading && groups.length === 0 && !error && (
        <Card>
          <EmptyState
            icon="✨"
            title={t.noArtifacts()}
            description="没有找到可清理的构建产物"
          />
        </Card>
      )}

      {/* 底部选择栏 */}
      {selected.size > 0 && (
        <div className="purge-select-bar">
          <div className="select-bar-info">
            <Badge tone="accent">{t.selected(selected.size, formatBytes(selectedSize))}</Badge>
          </div>
          <div className="select-bar-actions">
            <Button variant="ghost" size="sm" onClick={deselectAll}>{common.cancel()}</Button>
            <Button
              variant="danger"
              size="sm"
              onClick={() => setConfirmOpen(true)}
              disabled={deleting}
            >
              {deleting ? common.executing() : t.purgeSelected()}
            </Button>
          </div>
        </div>
      )}

      {/* Toast */}
      {toast && (
        <div className="purge-toast" onClick={() => setToast(null)}>
          {toast}
        </div>
      )}

      {/* 确认对话框 */}
      <Modal
        open={confirmOpen}
        onClose={() => setConfirmOpen(false)}
        title={t.purgeConfirm(selected.size, formatBytes(selectedSize))}
        footer={
          <>
            <Button variant="ghost" onClick={() => setConfirmOpen(false)}>{common.cancel()}</Button>
            <Button variant="danger" onClick={handleDelete}>{common.confirm()}</Button>
          </>
        }
      >
        <p className="modal-warn-text">{common.moveToTrash()}</p>
        <div className="modal-entry-preview">
          {selectedArtifacts.slice(0, 10).map((a, i) => (
            <div key={i} className="modal-entry-row">
              <span className="modal-entry-name">{a.path.split('/').pop()}</span>
              <Badge tone={artifactTone(a.artifact_type)}>{a.artifact_type}</Badge>
              <span className="modal-entry-size">{formatBytesShort(a.size)}</span>
            </div>
          ))}
          {selectedArtifacts.length > 10 && (
            <div className="modal-entry-more">... +{selectedArtifacts.length - 10} more</div>
          )}
        </div>
      </Modal>
    </div>
  );
}
