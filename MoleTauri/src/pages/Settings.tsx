// Settings 页：关于、语言、主题、更新、链接
import { useState, useEffect, useCallback } from 'react';
import { getVersion } from '@tauri-apps/api/app';
import { Card, CardHeader, Button, Badge, KVList, Spinner, Banner } from '../components/ui';
import { useTheme } from '../lib/theme';
import {
  getMoleVersion,
  checkForUpdate,
  downloadAndInstall,
  restartApp,
  checkCli,
  type UpdateInfo,
} from '../lib/cli';
import { settings as t, common, setLang, getLang, type Lang } from '../lib/i18n';

type UpdateStatus =
  | 'idle'
  | 'checking'
  | 'upToDate'
  | 'available'
  | 'downloading'
  | 'ready'
  | 'error';

export default function SettingsPage() {
  const { theme, setTheme } = useTheme();
  const [lang, setLangState] = useState<Lang>(getLang());
  const [appVersion, setAppVersion] = useState('...');
  const [cliVersion, setCliVersion] = useState('...');
  const [cliAvailable, setCliAvailable] = useState<boolean | null>(null);
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>('idle');
  const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
  const [updateError, setUpdateError] = useState('');

  // 加载应用版本、CLI 版本与可用性
  useEffect(() => {
    getVersion()
      .then((v) => setAppVersion(v || '—'))
      .catch(() => setAppVersion('—'));
    getMoleVersion()
      .then((v) => setCliVersion(v || '—'))
      .catch(() => setCliVersion('—'));
    checkCli().then(setCliAvailable).catch(() => setCliAvailable(false));
  }, []);

  // 监听语言变更（来自 TopBar 或本页）
  useEffect(() => {
    const handler = () => setLangState(getLang());
    window.addEventListener('mole-lang-change', handler);
    return () => window.removeEventListener('mole-lang-change', handler);
  }, []);

  const changeLang = (next: Lang) => {
    if (next === lang) return;
    setLang(next);
    setLangState(next);
    window.dispatchEvent(new Event('mole-lang-change'));
  };

  const handleCheckUpdate = useCallback(async () => {
    setUpdateStatus('checking');
    setUpdateError('');
    setUpdateInfo(null);
    try {
      const info = await checkForUpdate();
      if (info) {
        setUpdateInfo(info);
        setUpdateStatus('available');
      } else {
        setUpdateStatus('upToDate');
      }
    } catch (e) {
      setUpdateError(e instanceof Error ? e.message : String(e));
      setUpdateStatus('error');
    }
  }, []);

  const handleDownload = useCallback(async () => {
    if (!updateInfo) return;
    setUpdateStatus('downloading');
    setUpdateError('');
    try {
      // download_and_install 现在在应用内完成下载+解压+替换+重启，
      // 成功时进程会 exit(0)，不会返回；返回则说明出错。
      const result = await downloadAndInstall(updateInfo.download_url);
      // 如果走到这里，说明没有自动退出（可能是测试模式或出错）
      setUpdateStatus('ready');
      void result;
    } catch (e) {
      setUpdateError(e instanceof Error ? e.message : String(e));
      setUpdateStatus('error');
    }
  }, [updateInfo]);

  const handleRestart = useCallback(async () => {
    try {
      await restartApp();
    } catch {
      /* ignore */
    }
  }, []);

  const openLink = (url: string) => {
    window.open(url, '_blank', 'noopener,noreferrer');
  };

  const links = [
    { label: t.github(), url: 'https://github.com/tw93/Mole' },
    { label: t.documentation(), url: 'https://github.com/tw93/Mole#readme' },
    { label: t.reportIssue(), url: 'https://github.com/tw93/Mole/issues/new' },
    { label: t.cliHelp(), url: 'https://github.com/tw93/Mole/blob/main/README.md' },
  ];

  return (
    <div className="page settings-page" style={{ maxWidth: 720 }}>
      {/* 语言 */}
      <Card variant="glass">
        <CardHeader title={t.language()} icon="🌐" />
        <div className="flex gap-2">
          <Button
            variant={lang === 'zh' ? 'primary' : 'secondary'}
            onClick={() => changeLang('zh')}
          >
            中
          </Button>
          <Button
            variant={lang === 'en' ? 'primary' : 'secondary'}
            onClick={() => changeLang('en')}
          >
            EN
          </Button>
        </div>
      </Card>

      {/* 主题 */}
      <Card variant="glass">
        <CardHeader title={t.theme()} icon="🎨" />
        <div className="flex gap-2">
          <Button
            variant={theme === 'dark' ? 'primary' : 'secondary'}
            onClick={() => setTheme('dark')}
          >
            {t.dark()}
          </Button>
          <Button
            variant={theme === 'light' ? 'primary' : 'secondary'}
            onClick={() => setTheme('light')}
          >
            {t.light()}
          </Button>
        </div>
      </Card>

      {/* 更新 */}
      <Card variant="glass">
        <CardHeader
          title={t.update()}
          icon="🔄"
          action={
            <Button
              size="sm"
              variant="secondary"
              onClick={handleCheckUpdate}
              disabled={updateStatus === 'checking' || updateStatus === 'downloading'}
            >
              {updateStatus === 'checking' ? t.checking() : t.checkUpdate()}
            </Button>
          }
        />
        {updateStatus === 'checking' && (
          <div className="flex items-center gap-2">
            <Spinner size="sm" />
            <span>{t.checking()}...</span>
          </div>
        )}
        {updateStatus === 'upToDate' && (
          <Banner tone="success" icon="✓">
            {t.upToDate()}
          </Banner>
        )}
        {updateStatus === 'available' && updateInfo && (
          <Banner
            tone="info"
            icon="🎉"
            title={t.newVersion(updateInfo.version)}
            action={
              <Button size="sm" variant="primary" onClick={handleDownload}>
                {t.download()}
              </Button>
            }
          >
            {updateInfo.notes || undefined}
          </Banner>
        )}
        {updateStatus === 'downloading' && (
          <div className="flex items-center gap-2">
            <Spinner size="sm" />
            <span>{t.downloading()}...（下载完成后将自动安装并重启）</span>
          </div>
        )}
        {updateStatus === 'ready' && (
          <Banner
            tone="success"
            icon="✓"
            title={`${t.install()} ✓`}
            action={
              <Button size="sm" variant="primary" onClick={handleRestart}>
                {t.restart()}
              </Button>
            }
          />
        )}
        {updateStatus === 'error' && (
          <Banner tone="error" icon="⚠️" title={common.error()}>
            {updateError}
          </Banner>
        )}
      </Card>

      {/* 关于 */}
      <Card variant="glass">
        <CardHeader title={t.about()} icon="ℹ️" />
        <KVList
          items={[
            { label: t.appName(), value: 'Mole' },
            { label: t.guiVersion(), value: appVersion },
            {
              label: t.cliVersion(),
              value: (
                <span className="flex items-center gap-2">
                  <span>{cliVersion}</span>
                  {cliAvailable === false && (
                    <Badge tone="critical">{common.cliUnavailable()}</Badge>
                  )}
                </span>
              ),
            },
            { label: t.framework(), value: 'Tauri + React' },
            { label: t.cliPath(), value: <code>mo</code> },
          ]}
        />
        <div className="mt-2">
          <Badge tone="info">{t.minCliVersion()}</Badge>
        </div>
      </Card>

      {/* 链接 */}
      <Card variant="glass">
        <CardHeader title={t.links()} icon="🔗" />
        <div className="flex flex-col gap-2">
          {links.map((link) => (
            <button
              key={link.url}
              type="button"
              onClick={() => openLink(link.url)}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                width: '100%',
                padding: '10px 12px',
                background: 'transparent',
                border: '1px solid var(--border)',
                borderRadius: 'var(--radius-sm)',
                cursor: 'pointer',
                color: 'var(--text-primary)',
                fontSize: '13px',
                fontFamily: 'inherit',
              }}
            >
              <span>{link.label}</span>
              <span style={{ color: 'var(--text-tertiary)' }}>↗</span>
            </button>
          ))}
        </div>
      </Card>
    </div>
  );
}
