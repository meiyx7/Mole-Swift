import { useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

interface CleanResult {
  success: boolean;
  stdout: string;
  stderr: string;
}

export default function Clean() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<CleanResult | null>(null);
  const [dryRun, setDryRun] = useState(true);
  const [verbose, setVerbose] = useState(false);

  const runClean = async () => {
    setLoading(true);
    setResult(null);
    try {
      const res = await invoke<CleanResult>('run_clean', { dryRun, verbose });
      setResult(res);
    } catch (e) {
      setResult({ success: false, stdout: '', stderr: String(e) });
    }
    setLoading(false);
  };

  return (
    <div className="page">
      <div className="page-header">
        <h1>🧹 深度清理</h1>
        <p className="page-desc">清理系统缓存、浏览器缓存、开发工具缓存等</p>
      </div>

      <div className="card">
        <div className="card-header">
          <h3>清理选项</h3>
        </div>
        <div className="options">
          <label className="toggle">
            <input type="checkbox" checked={dryRun} onChange={e => setDryRun(e.target.checked)} />
            <span>预览模式（不实际删除）</span>
          </label>
          <label className="toggle">
            <input type="checkbox" checked={verbose} onChange={e => setVerbose(e.target.checked)} />
            <span>详细输出</span>
          </label>
        </div>
        <button
          className={`btn ${dryRun ? 'btn-primary' : 'btn-danger'}`}
          onClick={runClean}
          disabled={loading}
        >
          {loading ? '执行中...' : dryRun ? '🔍 预览清理' : '🗑️ 开始清理'}
        </button>
      </div>

      {result && (
        <div className={`card result-card ${result.success ? 'success' : 'error'}`}>
          <h3>{result.success ? '✅ 执行完成' : '❌ 执行失败'}</h3>
          <pre className="output">{result.stdout || result.stderr}</pre>
        </div>
      )}

      <div className="card info-card">
        <h3>💡 说明</h3>
        <ul>
          <li>清理范围包括：浏览器缓存、系统日志、开发工具缓存等</li>
          <li>建议先使用预览模式查看将要清理的内容</li>
          <li>清理操作会将文件移至废纸篓，可随时恢复</li>
        </ul>
      </div>
    </div>
  );
}
