import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';

interface UpdateInfo {
  version: string;
  download_url: string;
  notes: string;
}

export default function UpdateChecker() {
  const [currentVersion] = useState('0.2.0');
  const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
  const [checking, setChecking] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [status, setStatus] = useState<string>('');
  const [error, setError] = useState<string>('');

  const checkUpdate = async () => {
    setChecking(true);
    setError('');
    setUpdateInfo(null);
    try {
      const info = await invoke<UpdateInfo>('check_for_update', { currentVersion });
      setUpdateInfo(info);
    } catch (e) {
      setError(String(e));
    }
    setChecking(false);
  };

  const downloadUpdate = async () => {
    if (!updateInfo) return;
    setDownloading(true);
    setStatus('正在下载...');
    try {
      const appPath = await invoke<string>('download_and_install', { url: updateInfo.download_url });
      setStatus(`安装完成: ${appPath}`);
      // Prompt restart
      if (confirm('更新完成，是否立即重启应用？')) {
        await invoke('restart_app');
      }
    } catch (e) {
      setError(String(e));
    }
    setDownloading(false);
  };

  useEffect(() => {
    checkUpdate();
  }, []);

  return (
    <div className="update-banner">
      {checking && <span className="update-text">检查更新中...</span>}
      {error && !updateInfo && <span className="update-text muted">{error}</span>}
      {updateInfo && (
        <div className="update-content">
          <span className="update-text">
            🎉 发现新版本 v{updateInfo.version}
          </span>
          <button
            className="btn btn-sm btn-primary"
            onClick={downloadUpdate}
            disabled={downloading}
          >
            {downloading ? status : '立即更新'}
          </button>
        </div>
      )}
      {!checking && !updateInfo && !error && (
        <span className="update-text muted">✓ 已是最新版本</span>
      )}
    </div>
  );
}
