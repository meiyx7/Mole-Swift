// Installer 页：安装包文件发现与清理
// 调用 Rust 原生扫描器 scanInstaller，按来源分组展示，多选 Trash 删除
import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardHeader, Button, Badge, Checkbox, EmptyState, Spinner, Modal, StatTile } from '../components/ui';
import { scanInstaller, trashPaths, writeLog, type InstallerFile, type InstallerScanResult } from '../lib/cli';
import { installer as t, common } from '../lib/i18n';
import { formatBytes, formatBytesShort } from '../lib/format';

const SOURCE_ORDER = [
  'downloads',
  'desktop',
  'documents',
  'library',
  'shared',
  'homebrew',
  'icloud',
  'mail',
  'telegram',
] as const;

// 文件类型徽章配色：dmg=accent, pkg=info, iso=warn, xip=purple, zip=default
const FILE_TYPE_TONE: Record<string, 'accent' | 'info' | 'warn' | 'purple' | 'default'> = {
  dmg: 'accent',
  pkg: 'info',
  iso: 'warn',
  xip: 'purple',
  zip: 'default',
};

const FILE_TYPE_ICON: Record<string, string> = {
  dmg: '💿',
  pkg: '📦',
  iso: '📀',
  xip: '🗜️',
  zip: '🗜️',
};

export default function InstallerPage() {
  const [result, setResult] = useState<InstallerScanResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  const doScan = useCallback(async () => {
    setLoading(true);
    setError(null);
    setSelected(new Set());
    setToast(null);
    writeLog('info', '安装包扫描开始').catch(() => {});
    try {
      const data = await scanInstaller();
      setResult(data);
      writeLog('info', `安装包扫描完成，共 ${data.total_count} 项`).catch(() => {});
    } catch (e: any) {
      setError(e?.message ?? String(e));
      writeLog('error', `安装包扫描失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    doScan();
  }, [doScan]);

  // 按来源分组，组内按大小降序
  const grouped = useMemo(() => {
    const map = new Map<string, InstallerFile[]>();
    if (!result) return map;
    for (const f of result.files) {
      const arr = map.get(f.source) ?? [];
      arr.push(f);
      map.set(f.source, arr);
    }
    for (const arr of map.values()) {
      arr.sort((a, b) => b.size - a.size);
    }
    return map;
  }, [result]);

  const orderedSources = useMemo<string[]>(() => {
    const present = new Set(grouped.keys());
    const ordered: string[] = SOURCE_ORDER.filter((s) => present.has(s));
    // 未知来源兜底放到末尾
    for (const s of present) {
      if (!ordered.includes(s)) ordered.push(s);
    }
    return ordered;
  }, [grouped]);

  const selectedFiles = useMemo(() => {
    if (!result) return [];
    return result.files.filter((f) => selected.has(f.path));
  }, [result, selected]);

  const selectedSize = useMemo(
    () => selectedFiles.reduce((s, f) => s + f.size, 0),
    [selectedFiles],
  );

  const toggleSelect = (path: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const selectAll = () => {
    if (!result) return;
    setSelected(new Set(result.files.map((f) => f.path)));
  };

  const deselectAll = () => setSelected(new Set());

  const toggleSource = (source: string) => {
    const files = grouped.get(source) ?? [];
    if (files.length === 0) return;
    const allSelected = files.every((f) => selected.has(f.path));
    setSelected((prev) => {
      const next = new Set(prev);
      if (allSelected) {
        for (const f of files) next.delete(f.path);
      } else {
        for (const f of files) next.add(f.path);
      }
      return next;
    });
  };

  const handleDelete = async () => {
    if (selectedFiles.length === 0) return;
    setConfirmOpen(false);
    setDeleting(true);
    setToast(null);
    const count = selectedFiles.length;
    const size = selectedSize;
    writeLog('info', `安装包删除开始，${count} 项`).catch(() => {});
    try {
      const paths = selectedFiles.map((f) => f.path);
      await trashPaths(paths);
      setToast(t.deleted(count, formatBytes(size)));
      setSelected(new Set());
      writeLog('info', '安装包删除完成').catch(() => {});
      await doScan();
    } catch (e: any) {
      setToast(`${common.error()}: ${e?.message ?? e}`);
      writeLog('error', `安装包删除失败/异常: ${e?.message ?? String(e)}`).catch(() => {});
    } finally {
      setDeleting(false);
    }
  };

  const totalCount = result?.total_count ?? 0;
  const totalSize = result?.total_size ?? 0;
  const hasFiles = !!result && result.files.length > 0;

  return (
    <div className="page page-wide installer-page">
      {/* 工具栏 */}
      <div className="installer-toolbar">
        <div className="installer-toolbar-left">
          <Button variant="primary" size="sm" onClick={doScan} disabled={loading}>
            {loading ? t.scanning() : t.scanInstallers()}
          </Button>
          <Button variant="ghost" size="sm" onClick={doScan} disabled={loading}>
            {common.refresh()}
          </Button>
        </div>
        <div className="installer-toolbar-right">
          {hasFiles && (
            <>
              <Button size="sm" variant="ghost" onClick={selectAll} disabled={loading}>
                {common.selectAll()}
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={deselectAll}
                disabled={loading || selected.size === 0}
              >
                {common.deselectAll()}
              </Button>
            </>
          )}
        </div>
      </div>

      {/* 汇总统计 */}
      {result && (
        <div className="installer-stats">
          <StatTile label={t.files()} value={String(totalCount)} />
          <StatTile label={common.total()} value={formatBytes(totalSize)} />
          <StatTile label={common.items()} value={String(selected.size)} />
          <StatTile label={common.size()} value={formatBytes(selectedSize)} />
        </div>
      )}

      {/* 首次加载 */}
      {loading && !result && (
        <Card>
          <div className="installer-loading">
            <Spinner size="md" />
            <span>{t.scanning()}</span>
          </div>
        </Card>
      )}

      {/* 刷新中（已有结果） */}
      {loading && result && (
        <Card variant="glass">
          <CardHeader title={t.scanning()} action={<Spinner size="sm" />} />
        </Card>
      )}

      {/* 错误 */}
      {error && !loading && (
        <Card>
          <EmptyState
            icon="⚠️"
            title={common.error()}
            description={error}
            action={<Button variant="primary" onClick={doScan}>{common.retry()}</Button>}
          />
        </Card>
      )}

      {/* 空状态 */}
      {result && !loading && !error && !hasFiles && (
        <Card>
          <EmptyState
            icon="📦"
            title={t.noFiles()}
          />
        </Card>
      )}

      {/* 分组列表 */}
      {hasFiles && !loading && (
        <div className="installer-groups">
          {orderedSources.map((source) => (
            <InstallerSourceGroup
              key={source}
              source={source}
              files={grouped.get(source) ?? []}
              selected={selected}
              onToggle={toggleSelect}
              onToggleSource={toggleSource}
            />
          ))}
        </div>
      )}

      {/* 底部选择栏 */}
      {selected.size > 0 && (
        <div className="installer-select-bar">
          <div className="select-bar-info">
            <Badge tone="accent">{t.selected(selected.size, formatBytes(selectedSize))}</Badge>
          </div>
          <div className="select-bar-actions">
            <Button variant="ghost" size="sm" onClick={deselectAll} disabled={deleting}>
              {common.cancel()}
            </Button>
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
      {toast && (
        <div className="installer-toast" onClick={() => setToast(null)}>
          {toast}
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
          {selectedFiles.slice(0, 10).map((f, i) => (
            <div key={i} className="modal-entry-row">
              <span className="modal-entry-name">{f.name}</span>
              <span className="modal-entry-size">{formatBytesShort(f.size)}</span>
            </div>
          ))}
          {selectedFiles.length > 10 && (
            <div className="modal-entry-more">... +{selectedFiles.length - 10} more</div>
          )}
        </div>
      </Modal>
    </div>
  );
}

function InstallerSourceGroup({
  source,
  files,
  selected,
  onToggle,
  onToggleSource,
}: {
  source: string;
  files: InstallerFile[];
  selected: Set<string>;
  onToggle: (path: string) => void;
  onToggleSource: (source: string) => void;
}) {
  const [expanded, setExpanded] = useState(true);
  const totalSize = files.reduce((s, f) => s + f.size, 0);
  const selectedCount = files.filter((f) => selected.has(f.path)).length;
  const allSelected = files.length > 0 && selectedCount === files.length;
  const sourceLabel = sourceLabelFor(source);

  return (
    <Card variant="compact">
      <div className="installer-group-header" onClick={() => setExpanded((v) => !v)}>
        <span className="installer-group-check">
          <Checkbox checked={allSelected} onChange={() => onToggleSource(source)} />
        </span>
        <span className="installer-group-name">{sourceLabel}</span>
        <div className="installer-group-meta">
          <Badge tone="info">{files.length} {common.items()}</Badge>
          <Badge tone="accent">{formatBytes(totalSize)}</Badge>
          {selectedCount > 0 && <Badge tone="good">{selectedCount}</Badge>}
          <span className={`installer-chevron ${expanded ? 'open' : ''}`}>▾</span>
        </div>
      </div>
      {expanded && (
        <div className="installer-file-list">
          {files.map((f, i) => (
            <InstallerFileRow
              key={i}
              file={f}
              checked={selected.has(f.path)}
              onToggle={() => onToggle(f.path)}
            />
          ))}
        </div>
      )}
    </Card>
  );
}

function InstallerFileRow({
  file,
  checked,
  onToggle,
}: {
  file: InstallerFile;
  checked: boolean;
  onToggle: () => void;
}) {
  const ft = file.file_type;
  const tone = FILE_TYPE_TONE[ft] ?? 'default';
  const ftLabel = fileTypeLabel(ft);
  const ftIcon = FILE_TYPE_ICON[ft] ?? '📄';

  return (
    <div className={`installer-file-row ${checked ? 'selected' : ''}`}>
      <span className="col-check">
        <Checkbox checked={checked} onChange={onToggle} />
      </span>
      <span className="col-name" title={file.path}>
        <span className="installer-file-icon">{ftIcon}</span>
        <span className="installer-file-name">{file.name}</span>
        {file.is_installer_zip && <Badge tone="info" className="entry-badge">installer</Badge>}
      </span>
      <span className="col-type">
        <Badge tone={tone}>{ftLabel}</Badge>
      </span>
      <span className="col-path" title={file.path}>{file.path}</span>
      <span className="col-size">{formatBytes(file.size)}</span>
    </div>
  );
}

function sourceLabelFor(source: string): string {
  switch (source) {
    case 'downloads': return t.sources.downloads();
    case 'desktop': return t.sources.desktop();
    case 'documents': return t.sources.documents();
    case 'library': return t.sources.library();
    case 'shared': return t.sources.shared();
    case 'homebrew': return t.sources.homebrew();
    case 'icloud': return t.sources.icloud();
    case 'mail': return t.sources.mail();
    case 'telegram': return t.sources.telegram();
    default: return source;
  }
}

function fileTypeLabel(ft: string): string {
  switch (ft) {
    case 'dmg': return t.fileTypes.dmg();
    case 'pkg': return t.fileTypes.pkg();
    case 'iso': return t.fileTypes.iso();
    case 'xip': return t.fileTypes.xip();
    case 'zip': return t.fileTypes.zip();
    default: return ft.toUpperCase();
  }
}
