import { useState, useEffect } from 'react';
import { ThemeProvider } from './lib/theme';
import { getLang, setLang, nav, titles } from './lib/i18n';
import Sidebar from './components/Sidebar';
import TopBar from './components/TopBar';
import StatusPage from './pages/Status';
import AnalyzePage from './pages/Analyze';
import CleanPage from './pages/Clean';
import OptimizePage from './pages/Optimize';
import UninstallPage from './pages/Uninstall';
import PurgePage from './pages/Purge';
import InstallerPage from './pages/Installer';
import HistoryPage from './pages/History';
import SettingsPage from './pages/Settings';

export type Page =
  | 'status'
  | 'analyze'
  | 'clean'
  | 'optimize'
  | 'uninstall'
  | 'purge'
  | 'installer'
  | 'history'
  | 'settings';

function Shell() {
  const [page, setPage] = useState<Page>('status');
  const [, forceUpdate] = useState({});

  // 语言切换时强制重渲染
  useEffect(() => {
    const handler = () => forceUpdate({});
    window.addEventListener('mole-lang-change', handler);
    return () => window.removeEventListener('mole-lang-change', handler);
  }, []);

  const renderPage = () => {
    switch (page) {
      case 'status': return <StatusPage />;
      case 'analyze': return <AnalyzePage />;
      case 'clean': return <CleanPage />;
      case 'optimize': return <OptimizePage />;
      case 'uninstall': return <UninstallPage />;
      case 'purge': return <PurgePage />;
      case 'installer': return <InstallerPage />;
      case 'history': return <HistoryPage />;
      case 'settings': return <SettingsPage />;
      default: return <StatusPage />;
    }
  };

  return (
    <div className="app-shell">
      <Sidebar current={page} onNavigate={setPage} />
      <div className="app-body">
        <TopBar page={page} />
        <main className="app-main">
          {renderPage()}
        </main>
      </div>
    </div>
  );
}

export default function App() {
  // 初始化语言
  useEffect(() => {
    getLang();
  }, []);

  return (
    <ThemeProvider>
      <Shell />
    </ThemeProvider>
  );
}

// 暴露给 TopBar 使用的语言切换 helper
export function changeLang(lang: 'zh' | 'en') {
  setLang(lang);
  window.dispatchEvent(new Event('mole-lang-change'));
}

export { nav, titles };
