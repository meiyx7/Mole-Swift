// 侧边栏：四分组导航（概览 / 清理 / 管理 / 系统）
import { nav, titles } from '../lib/i18n';
import type { Page } from '../App';

interface SidebarProps {
  current: Page;
  onNavigate: (page: Page) => void;
}

interface NavItem {
  id: Page;
  label: () => string;
  icon: string;
  badge?: string;
}

interface NavGroup {
  title: string;
  items: NavItem[];
}

const groups: NavGroup[] = [
  {
    title: nav.overview(),
    items: [
      { id: 'status', label: titles.status, icon: 'activity' },
      { id: 'analyze', label: titles.analyze, icon: 'compass' },
    ],
  },
  {
    title: nav.cleanup(),
    items: [
      { id: 'clean', label: titles.clean, icon: 'broom' },
      { id: 'purge', label: titles.purge, icon: 'cube' },
      { id: 'installer', label: titles.installer, icon: 'package' },
    ],
  },
  {
    title: nav.management(),
    items: [
      { id: 'uninstall', label: titles.uninstall, icon: 'trash' },
      { id: 'optimize', label: titles.optimize, icon: 'bolt' },
      { id: 'history', label: titles.history, icon: 'clock' },
    ],
  },
  {
    title: nav.system(),
    items: [
      { id: 'settings', label: titles.settings, icon: 'gear' },
    ],
  },
];

// SVG 图标（24x24，stroke 风格，无外部依赖）
function Icon({ name }: { name: string }) {
  const icons: Record<string, JSX.Element> = {
    activity: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
      </svg>
    ),
    compass: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="10" />
        <polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76" />
      </svg>
    ),
    broom: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M19.4 14.5L16.7 11.8L19.4 9.1L14.9 4.6L12.2 7.3M14.5 19.4L9 14M5.5 5.5L9 9M14.5 19.4L19.4 14.5L16.7 11.8M14.5 19.4L9 14M9 14L4.6 18.4M9 14L12.2 7.3M12.2 7.3L7.3 12.2" />
      </svg>
    ),
    cube: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
        <polyline points="3.27 6.96 12 12.01 20.73 6.96" />
        <line x1="12" y1="22.08" x2="12" y2="12" />
      </svg>
    ),
    package: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <line x1="16.5" y1="9.4" x2="7.5" y2="4.21" />
        <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
        <polyline points="3.27 6.96 12 12.01 20.73 6.96" />
        <line x1="12" y1="22.08" x2="12" y2="12" />
      </svg>
    ),
    trash: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <polyline points="3 6 5 6 21 6" />
        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      </svg>
    ),
    bolt: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />
      </svg>
    ),
    clock: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="10" />
        <polyline points="12 6 12 12 16 14" />
      </svg>
    ),
    gear: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="3" />
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
      </svg>
    ),
  };
  return <span className="nav-icon">{icons[name] ?? icons.activity}</span>;
}

export default function Sidebar({ current, onNavigate }: SidebarProps) {
  return (
    <aside className="sidebar">
      {/* 品牌 */}
      <div className="sidebar-brand">
        <div className="brand-mark">
          <svg viewBox="0 0 32 32" className="brand-svg">
            <defs>
              <linearGradient id="brand-grad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stopColor="var(--accent)" />
                <stop offset="100%" stopColor="var(--accent-2)" />
              </linearGradient>
            </defs>
            <circle cx="16" cy="16" r="14" fill="url(#brand-grad)" opacity="0.15" />
            <path
              d="M10 12 Q10 8 14 8 Q16 8 16 10 Q16 8 18 8 Q22 8 22 12 L22 20 Q22 22 20 22 L12 22 Q10 22 10 20 Z"
              fill="url(#brand-grad)"
            />
            <circle cx="13" cy="14" r="1.2" fill="var(--bg-base)" />
            <circle cx="19" cy="14" r="1.2" fill="var(--bg-base)" />
          </svg>
        </div>
        <div className="brand-text">
          <span className="brand-name">Mole</span>
          <span className="brand-tag">macOS Workshop</span>
        </div>
      </div>

      {/* 导航分组 */}
      <nav className="sidebar-nav">
        {groups.map((group, gi) => (
          <div key={gi} className="nav-group">
            <div className="nav-group-title">{group.title}</div>
            {group.items.map((item) => {
              const active = current === item.id;
              return (
                <button
                  key={item.id}
                  className={`nav-item ${active ? 'nav-item-active' : ''}`}
                  onClick={() => onNavigate(item.id)}
                >
                  <Icon name={item.icon} />
                  <span className="nav-label">{item.label()}</span>
                  {active && <span className="nav-active-dot" />}
                </button>
              );
            })}
          </div>
        ))}
      </nav>

      {/* 底部版本号 */}
      <div className="sidebar-footer">
        <span className="sidebar-version">v1.0.0 · Tauri</span>
      </div>
    </aside>
  );
}
