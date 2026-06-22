import { useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

export default function Status() {
  const [loading, setLoading] = useState(false);
  const [output, setOutput] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const checkStatus = async () => {
    setLoading(true);
    setError(null);
    setOutput(null);
    try {
      const res = await invoke<{success: boolean; stdout: string; stderr: string}>('run_status', { json: false });
      if (res.success) {
        setOutput(res.stdout);
      } else {
        setError(res.stderr || '命令执行失败');
      }
    } catch (e) {
      setError(String(e));
    }
    setLoading(false);
  };

  return (
    <div className="page">
      <div className="page-header">
        <h1>💓 状态检查</h1>
        <p className="page-desc">检查系统健康状态</p>
      </div>

      <div className="card center">
        <button className="btn btn-primary btn-lg" onClick={checkStatus} disabled={loading}>
          {loading ? '检查中...' : '🔍 开始检查'}
        </button>
      </div>

      {error && (
        <div className="card error-card">
          <p>❌ {error}</p>
        </div>
      )}

      {output && (
        <div className="card">
          <h3>检查结果</h3>
          <pre className="output">{output}</pre>
        </div>
      )}
    </div>
  );
}
