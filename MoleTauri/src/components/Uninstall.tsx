import { useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

export default function Uninstall() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<{success: boolean; stdout: string; stderr: string} | null>(null);
  const [dryRun, setDryRun] = useState(true);

  const runUninstall = async () => {
    setLoading(true);
    setResult(null);
    try {
      const res = await invoke<{success: boolean; stdout: string; stderr: string}>('run_uninstall', { dryRun });
      setResult(res);
    } catch (e) {
      setResult({ success: false, stdout: '', stderr: String(e) });
    }
    setLoading(false);
  };

  return (
    <div className="page">
      <div className="page-header">
        <h1>🗑️ 应用卸载</h1>
        <p className="page-desc">安全卸载应用程序及相关残留</p>
      </div>

      <div className="card">
        <div className="options">
          <label className="toggle">
            <input type="checkbox" checked={dryRun} onChange={e => setDryRun(e.target.checked)} />
            <span>预览模式</span>
          </label>
        </div>
        <button
          className={`btn ${dryRun ? 'btn-primary' : 'btn-danger'}`}
          onClick={runUninstall}
          disabled={loading}
        >
          {loading ? '执行中...' : dryRun ? '🔍 预览卸载' : '🗑️ 开始卸载'}
        </button>
      </div>

      {result && (
        <div className={`card result-card ${result.success ? 'success' : 'error'}`}>
          <h3>{result.success ? '✅ 执行完成' : '❌ 执行失败'}</h3>
          <pre className="output">{result.stdout || result.stderr}</pre>
        </div>
      )}
    </div>
  );
}
