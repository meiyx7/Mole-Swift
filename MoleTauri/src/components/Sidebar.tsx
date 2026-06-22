interface SidebarProps {
  current: string;
  onNavigate: (page: any) => void;
}

const menuItems = [
  { id: 'clean', label: '清理', icon: '🧹', desc: '深度清理' },
  { id: 'analyze', label: '分析', icon: '📊', desc: '磁盘分析' },
  { id: 'status', label: '状态', icon: '💓', desc: '健康检查' },
  { id: 'optimize', label: '优化', icon: '⚡', desc: '系统优化' },
  { id: 'uninstall', label: '卸载', icon: '🗑️', desc: '应用卸载' },
];

export default function Sidebar({ current, onNavigate }: SidebarProps) {
  return (
    <nav className="sidebar">
      <div className="sidebar-header">
        <div className="logo">🐭</div>
        <span className="logo-text">Mole</span>
      </div>

      <div className="sidebar-menu">
        {menuItems.map(item => (
          <button
            key={item.id}
            className={`menu-item ${current === item.id ? 'active' : ''}`}
            onClick={() => onNavigate(item.id)}
          >
            <span className="menu-icon">{item.icon}</span>
            <div className="menu-text">
              <span className="menu-label">{item.label}</span>
              <span className="menu-desc">{item.desc}</span>
            </div>
          </button>
        ))}
      </div>

      <div className="sidebar-footer">
        <button
          className={`menu-item ${current === 'settings' ? 'active' : ''}`}
          onClick={() => onNavigate('settings')}
        >
          <span className="menu-icon">⚙️</span>
          <div className="menu-text">
            <span className="menu-label">设置</span>
          </div>
        </button>
      </div>
    </nav>
  );
}
