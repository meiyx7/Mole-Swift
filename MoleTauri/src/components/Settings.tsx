import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';

export default function Settings() {
  const [version, setVersion] = useState('...');

  useEffect(() => {
    invoke<{stdout: string}>('get_mole_version').then(res => {
      setVersion(res.stdout.trim());
    }).catch(() => setVersion('未知'));
  }, []);

  return (
    <div className="page">
      <div className="page-header">
        <h1>⚙️ 设置</h1>
        <p className="page-desc">关于和配置</p>
      </div>

      <div className="card">
        <h3>关于</h3>
        <div className="settings-row">
          <span className="settings-label">应用名称</span>
          <span className="settings-value">Mole</span>
        </div>
        <div className="settings-row">
          <span className="settings-label">GUI 版本</span>
          <span className="settings-value">0.2.0 (Tauri)</span>
        </div>
        <div className="settings-row">
          <span className="settings-label">CLI 版本</span>
          <span className="settings-value">{version}</span>
        </div>
        <div className="settings-row">
          <span className="settings-label">框架</span>
          <span className="settings-value">Tauri + React</span>
        </div>
      </div>

      <div className="card">
        <h3>链接</h3>
        <div className="settings-row">
          <span className="settings-label">GitHub</span>
          <a href="https://github.com/tw93/Mole" target="_blank" rel="noreferrer" className="settings-link">
            tw93/Mole
          </a>
        </div>
      </div>
    </div>
  );
}
