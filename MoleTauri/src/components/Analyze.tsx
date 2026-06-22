import { useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

interface AnalyzeEntry {
  name: string;
  path: string;
  size: number;
  is_dir: boolean;
  insight?: boolean;
  cleanable?: boolean;
  last_access?: string;
}

interface AnalyzeResult {
  path: string;
  entries: AnalyzeEntry[];
  total_size: number;
  total_files?: number;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export default function Analyze() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<AnalyzeResult | null>(null);
  const [pathStack, setPathStack] = useState<{name: string; path: string}[]>([]);
  const [error, setError] = useState<string | null>(null);

  const currentPath = pathStack.length > 0 ? pathStack[pathStack.length - 1].path : null;

  const scan = async (path?: string) => {
    setLoading(true);
    setError(null);
    try {
      const res = await invoke<string>('run_analyze', { path: path || null });
      const data = JSON.parse(res) as AnalyzeResult;
      setResult(data);
    } catch (e) {
      setError(String(e));
    }
    setLoading(false);
  };

  const drill = async (entry: AnalyzeEntry) => {
    if (!entry.is_dir) return;
    setPathStack([...pathStack, { name: entry.name, path: entry.path }]);
    await scan(entry.path);
  };

  const goBack = async (level: number) => {
    const newPathStack = pathStack.slice(0, level);
    setPathStack(newPathStack);
    await scan(newPathStack.length > 0 ? newPathStack[newPathStack.length - 1].path : undefined);
  };

  const sorted = result?.entries.slice().sort((a, b) => b.size - a.size) || [];
  const max = sorted.length > 0 ? sorted[0].size : 1;

  return (
    <div className="page">
      <div className="page-header">
        <h1>📊 磁盘分析</h1>
        <p className="page-desc">可视化查看空间占用情况</p>
      </div>

      {pathStack.length > 0 && (
        <div className="breadcrumb">
          <button className="breadcrumb-item" onClick={() => goBack(0)}>🏠 主目录</button>
          {pathStack.map((item, i) => (
            <span key={i}>
              <span className="breadcrumb-sep">›</span>
              <button className="breadcrumb-item" onClick={() => goBack(i + 1)}>
                {item.name}
              </button>
            </span>
          ))}
        </div>
      )}

      {!result && !loading && (
        <div className="card center">
          <button className="btn btn-primary btn-lg" onClick={() => scan()}>
            🔍 扫描主目录
          </button>
          <p className="hint">分析 Mac 上的空间占用情况</p>
        </div>
      )}

      {loading && (
        <div className="card center">
          <div className="spinner"></div>
          <p>正在扫描...</p>
        </div>
      )}

      {error && (
        <div className="card error-card">
          <p>❌ {error}</p>
          <button className="btn btn-primary" onClick={() => scan()}>重试</button>
        </div>
      )}

      {result && !loading && (
        <>
          <div className="summary-bar">
            <span>共 {result.entries.length} 项</span>
            <span>总大小 {formatSize(result.total_size)}</span>
            <button className="btn btn-sm" onClick={() => scan(currentPath || undefined)}>
              🔄 刷新
            </button>
          </div>

          <div className="card">
            <div className="entry-list">
              {sorted.map(entry => (
                <div
                  key={entry.path}
                  className={`entry-row ${entry.is_dir ? 'dir' : 'file'} ${entry.cleanable ? 'cleanable' : ''} ${entry.insight ? 'insight' : ''}`}
                  onClick={() => drill(entry)}
                >
                  <div className="entry-icon">
                    {entry.is_dir ? '📁' : '📄'}
                  </div>
                  <div className="entry-info">
                    <span className="entry-name">{entry.name}</span>
                    <div className="entry-bar-bg">
                      <div
                        className="entry-bar"
                        style={{ width: `${(entry.size / max) * 100}%` }}
                      ></div>
                    </div>
                  </div>
                  <div className="entry-meta">
                    <span className="entry-size">{formatSize(entry.size)}</span>
                    <span className="entry-pct">
                      {(entry.size / result.total_size * 100).toFixed(1)}%
                    </span>
                    {entry.is_dir && <span className="entry-arrow">›</span>}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
