// 顶栏：页面标题 + 主题切换 + 语言切换 + CLI 状态
import { useState, useEffect } from 'react';
import { useTheme } from '../lib/theme';
import { getLang, titles, subtitles } from '../lib/i18n';
import { checkCli } from '../lib/cli';
import type { Page } from '../App';

interface TopBarProps {
  page: Page;
}

export default function TopBar({ page }: TopBarProps) {
  const { theme, toggleTheme } = useTheme();
  const [lang, setLangState] = useState(getLang());
  const [cliOk, setCliOk] = useState<boolean | null>(null);

  useEffect(() => {
    checkCli().then(setCliOk).catch(() => setCliOk(false));
  }, []);

  useEffect(() => {
    const handler = () => setLangState(getLang());
    window.addEventListener('mole-lang-change', handler);
    return () => window.removeEventListener('mole-lang-change', handler);
  }, []);

  const switchLang = (l: 'zh' | 'en') => {
    import('../lib/i18n').then(({ setLang }) => {
      setLang(l);
      window.dispatchEvent(new Event('mole-lang-change'));
    });
  };

  const title = titles[page]?.() ?? page;
  const subtitle = subtitles[page]?.() ?? '';

  return (
    <header className="topbar">
      <div className="topbar-left">
        <h1 className="topbar-title">{title}</h1>
        {subtitle && <span className="topbar-subtitle">{subtitle}</span>}
      </div>

      <div className="topbar-right">
        {/* CLI 状态指示 */}
        <div className={`topbar-cli ${cliOk === null ? '' : cliOk ? 'ok' : 'err'}`}>
          <span className="cli-dot" />
          <span className="cli-label">
            {cliOk === null ? 'CLI…' : cliOk ? 'CLI' : 'CLI Off'}
          </span>
        </div>

        {/* 语言切换 */}
        <div className="lang-switch">
          <button
            className={`lang-btn ${lang === 'zh' ? 'active' : ''}`}
            onClick={() => switchLang('zh')}
          >
            中
          </button>
          <button
            className={`lang-btn ${lang === 'en' ? 'active' : ''}`}
            onClick={() => switchLang('en')}
          >
            EN
          </button>
        </div>

        {/* 主题切换 */}
        <button
          className="icon-btn theme-toggle"
          onClick={toggleTheme}
          title={theme === 'dark' ? 'Switch to Light' : 'Switch to Dark'}
        >
          {theme === 'dark' ? (
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="4" />
              <line x1="12" y1="2" x2="12" y2="4" />
              <line x1="12" y1="20" x2="12" y2="22" />
              <line x1="4.93" y1="4.93" x2="6.34" y2="6.34" />
              <line x1="17.66" y1="17.66" x2="19.07" y2="19.07" />
              <line x1="2" y1="12" x2="4" y2="12" />
              <line x1="20" y1="12" x2="22" y2="12" />
              <line x1="4.93" y1="19.07" x2="6.34" y2="17.66" />
              <line x1="17.66" y1="6.34" x2="19.07" y2="4.93" />
            </svg>
          ) : (
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
            </svg>
          )}
        </button>
      </div>
    </header>
  );
}
