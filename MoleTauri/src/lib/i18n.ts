// 双语国际化：中文/英文
// 用法：t('中文', 'English') 根据当前语言返回

export type Lang = 'zh' | 'en';

let currentLang: Lang = 'zh';

export function setLang(lang: Lang) {
  currentLang = lang;
  localStorage.setItem('mole-lang', lang);
}

export function getLang(): Lang {
  const saved = localStorage.getItem('mole-lang') as Lang | null;
  if (saved) {
    currentLang = saved;
  }
  return currentLang;
}

export function t(zh: string, en: string): string {
  return currentLang === 'zh' ? zh : en;
}

// 导航分组
export const nav = {
  overview: () => t('概览', 'Overview'),
  cleanup: () => t('清理', 'Cleanup'),
  management: () => t('管理', 'Management'),
  system: () => t('系统', 'System'),
};

// 功能页标题
export const titles = {
  status: () => t('状态', 'Status'),
  analyze: () => t('分析', 'Analyze'),
  clean: () => t('清理', 'Clean'),
  optimize: () => t('优化', 'Optimize'),
  purge: () => t('项目清理', 'Purge'),
  installer: () => t('安装包', 'Installer'),
  uninstall: () => t('卸载', 'Uninstall'),
  history: () => t('历史', 'History'),
  settings: () => t('设置', 'Settings'),
};

export const subtitles = {
  status: () => t('系统健康状态实时监控', 'Real-time system health monitoring'),
  analyze: () => t('磁盘空间可视化分析', 'Visual disk space analysis'),
  clean: () => t('深度清理系统缓存与残留', 'Deep clean system caches and leftovers'),
  optimize: () => t('系统维护与优化任务', 'System maintenance and optimization'),
  purge: () => t('项目构建产物清理', 'Project build artifact cleanup'),
  installer: () => t('安装包文件发现与清理', 'Installer file discovery and cleanup'),
  uninstall: () => t('安全卸载应用及残留', 'Safely uninstall apps and leftovers'),
  history: () => t('操作历史与删除审计', 'Operation history and deletion audit'),
  settings: () => t('应用配置与关于', 'App configuration and about'),
};

// 通用
export const common = {
  scan: () => t('扫描', 'Scan'),
  scanning: () => t('扫描中', 'Scanning'),
  preview: () => t('预览', 'Preview'),
  previewing: () => t('预览中', 'Previewing'),
  execute: () => t('执行', 'Execute'),
  executing: () => t('执行中', 'Executing'),
  cancel: () => t('取消', 'Cancel'),
  confirm: () => t('确认', 'Confirm'),
  delete: () => t('删除', 'Delete'),
  remove: () => t('移除', 'Remove'),
  refresh: () => t('刷新', 'Refresh'),
  retry: () => t('重试', 'Retry'),
  selectAll: () => t('全选', 'Select All'),
  deselectAll: () => t('取消全选', 'Deselect All'),
  invert: () => t('反选', 'Invert'),
  search: () => t('搜索', 'Search'),
  filter: () => t('筛选', 'Filter'),
  sort: () => t('排序', 'Sort'),
  close: () => t('关闭', 'Close'),
  back: () => t('返回', 'Back'),
  next: () => t('下一步', 'Next'),
  done: () => t('完成', 'Done'),
  loading: () => t('加载中', 'Loading'),
  noData: () => t('暂无数据', 'No data'),
  error: () => t('错误', 'Error'),
  success: () => t('成功', 'Success'),
  warning: () => t('警告', 'Warning'),
  info: () => t('信息', 'Info'),
  total: () => t('总计', 'Total'),
  size: () => t('大小', 'Size'),
  path: () => t('路径', 'Path'),
  name: () => t('名称', 'Name'),
  type: () => t('类型', 'Type'),
  date: () => t('日期', 'Date'),
  status: () => t('状态', 'Status'),
  actions: () => t('操作', 'Actions'),
  items: () => t('项', 'items'),
  categories: () => t('类别', 'categories'),
  potentialSpace: () => t('可回收空间', 'Potential space'),
  freedSpace: () => t('已释放空间', 'Freed space'),
  freeSpace: () => t('可用空间', 'Free space'),
  dryRun: () => t('预览模式', 'Dry run'),
  dryRunDesc: () => t('仅预览，不实际删除', 'Preview only, no deletions'),
  permanent: () => t('永久删除', 'Permanent'),
  permanentDesc: () => t('不可恢复，跳过废纸篓', 'Irreversible, bypasses Trash'),
  verbose: () => t('详细输出', 'Verbose'),
  whitelist: () => t('白名单', 'Whitelist'),
  protected: () => t('受保护', 'Protected'),
  skipped: () => t('已跳过', 'Skipped'),
  nothingToClean: () => t('无需清理', 'Nothing to clean'),
  cliUnavailable: () => t('CLI 不可用', 'CLI unavailable'),
  cliUnavailableDesc: () => t('请先安装 mole CLI', 'Please install mole CLI first'),
  reveal: () => t('在 Finder 中显示', 'Reveal in Finder'),
  copyPath: () => t('复制路径', 'Copy Path'),
  moveToTrash: () => t('移到废纸篓', 'Move to Trash'),
  quickLook: () => t('快速查看', 'Quick Look'),
};

// 步骤
export const steps = {
  scan: () => t('扫描', 'Scan'),
  review: () => t('审阅', 'Review'),
  execute: () => t('执行', 'Execute'),
  done: () => t('完成', 'Done'),
};

// 状态页
export const status = {
  healthScore: () => t('健康评分', 'Health Score'),
  cpu: () => t('处理器', 'CPU'),
  cpuUsage: () => t('CPU 使用率', 'CPU Usage'),
  memory: () => t('内存', 'Memory'),
  memoryPressure: () => t('内存压力', 'Memory Pressure'),
  disk: () => t('磁盘', 'Disk'),
  diskUsage: () => t('磁盘使用', 'Disk Usage'),
  network: () => t('网络', 'Network'),
  throughput: () => t('吞吐量', 'Throughput'),
  battery: () => t('电池', 'Battery'),
  batteryHealth: () => t('电池健康', 'Battery Health'),
  gpu: () => t('图形处理器', 'GPU'),
  thermal: () => t('温度', 'Thermal'),
  bluetooth: () => t('蓝牙', 'Bluetooth'),
  topProcesses: () => t('活跃进程', 'Top Processes'),
  process: () => t('进程', 'Process'),
  pid: () => t('PID', 'PID'),
  cpuShort: () => t('CPU', 'CPU'),
  memShort: () => t('内存', 'Mem'),
  uptime: () => t('运行时间', 'Uptime'),
  trash: () => t('废纸篓', 'Trash'),
  fanSpeed: () => t('风扇转速', 'Fan Speed'),
  powerSource: () => t('电源', 'Power Source'),
  charging: () => t('充电中', 'Charging'),
  discharging: () => t('使用电池', 'On Battery'),
  plugged: () => t('已接通电源', 'Plugged In'),
  cycles: () => t('循环次数', 'Cycles'),
  condition: () => t('状况', 'Condition'),
  normal: () => t('正常', 'Normal'),
  serviceRecommended: () => t('建议维修', 'Service Recommended'),
};

// 分析页
export const analyze = {
  scanHome: () => t('扫描主目录', 'Scan Home'),
  scanOverview: () => t('概览扫描', 'Overview Scan'),
  scanPath: () => t('扫描目录', 'Scan Directory'),
  home: () => t('主目录', 'Home'),
  entries: () => t('条目', 'Entries'),
  totalSize: () => t('总大小', 'Total Size'),
  totalFiles: () => t('文件总数', 'Total Files'),
  largeFiles: () => t('大文件', 'Large Files'),
  breakdown: () => t('空间分布', 'Breakdown'),
  treemap: () => t('矩形图', 'Treemap'),
  list: () => t('列表', 'List'),
  cleanable: () => t('可清理', 'Cleanable'),
  insight: () => t('洞察', 'Insight'),
  lastAccess: () => t('最后访问', 'Last Access'),
  selected: () => t('已选', 'Selected'),
  deleteSelected: () => t('删除已选', 'Delete Selected'),
  deleteConfirm: (n: number, size: string) =>
    t(`确认将 ${n} 项（共 ${size}）移到废纸篓？`, `Move ${n} items (${size}) to Trash?`),
  deleted: (n: number) => t(`已删除 ${n} 项`, `Deleted ${n} items`),
  enterPath: () => t('输入路径或拖放目录', 'Enter path or drop directory'),
};

// 清理页
export const clean = {
  step1: () => t('选择选项并预览', 'Choose options and preview'),
  step2: () => t('审阅清理项', 'Review items to clean'),
  step3: () => t('执行清理', 'Execute cleanup'),
  step4: () => t('清理完成', 'Cleanup complete'),
  sections: () => t('清理类别', 'Cleanup Categories'),
  itemsFound: (n: number) => t(`找到 ${n} 项`, `${n} items found`),
  itemsToClean: (n: number) => t(`将清理 ${n} 项`, `${n} items to clean`),
  potentialSpace: (s: string) => t(`可回收 ${s}`, `Potential ${s}`),
  freedSpace: (s: string) => t(`已释放 ${s}`, `Freed ${s}`),
  startPreview: () => t('开始预览', 'Start Preview'),
  startClean: () => t('开始清理', 'Start Clean'),
  cleanComplete: () => t('清理完成', 'Cleanup Complete'),
  noCleanable: () => t('系统已经很干净', 'System is already clean'),
  riskHigh: () => t('高风险', 'High Risk'),
  riskMedium: () => t('中风险', 'Medium Risk'),
  riskLow: () => t('低风险', 'Low Risk'),
  riskHighDesc: () => t('系统文件或需要管理员权限', 'System files or requires admin'),
  riskMediumDesc: () => t('安装包或应用数据', 'Installer or app data'),
  riskLowDesc: () => t('缓存日志，可自动重建', 'Cache/logs, auto-regenerated'),
};

// 卸载页
export const uninstall = {
  appList: () => t('应用列表', 'App List'),
  installedApps: (n: number) => t(`已安装 ${n} 个应用`, `${n} apps installed`),
  selected: (n: number) => t(`已选 ${n} 个`, `${n} selected`),
  uninstallSelected: () => t('卸载已选', 'Uninstall Selected'),
  uninstallConfirm: (n: number, size: string) =>
    t(`确认卸载 ${n} 个应用（共 ${size}）？此操作不可撤销。`, `Uninstall ${n} apps (${size})? This cannot be undone.`),
  uninstalled: (n: number) => t(`已卸载 ${n} 个应用`, `Uninstalled ${n} apps`),
  sortBy: () => t('排序方式', 'Sort by'),
  sortSize: () => t('按大小', 'By Size'),
  sortDate: () => t('按使用时间', 'By Last Used'),
  sortName: () => t('按名称', 'By Name'),
  lastUsed: () => t('最后使用', 'Last Used'),
  source: () => t('来源', 'Source'),
  brew: () => t('Homebrew', 'Homebrew'),
  appStore: () => t('App Store', 'App Store'),
  manual: () => t('手动安装', 'Manual'),
  noApps: () => t('未找到应用', 'No apps found'),
  loadingApps: () => t('正在加载应用列表', 'Loading app list'),
};

// 优化页
export const optimize = {
  tasks: () => t('优化任务', 'Optimization Tasks'),
  taskList: () => t('任务列表', 'Task List'),
  rebuildDB: () => t('重建数据库', 'Rebuild Databases'),
  resetNetwork: () => t('重置网络', 'Reset Network'),
  refreshUI: () => t('刷新界面', 'Refresh UI'),
  rebuildSpotlight: () => t('重建 Spotlight 索引', 'Rebuild Spotlight'),
  clearCrashLogs: () => t('清理崩溃日志', 'Clear Crash Logs'),
  clearSwap: () => t('清理交换空间', 'Clear Swap'),
  applied: (n: number) => t(`已应用 ${n} 项优化`, `Applied ${n} optimizations`),
  systemHealth: () => t('系统健康', 'System Health'),
  ramUsage: () => t('内存使用', 'RAM Usage'),
  diskUsage: () => t('磁盘使用', 'Disk Usage'),
};

// Purge 页
export const purge = {
  scanProjects: () => t('扫描项目', 'Scan Projects'),
  scanning: () => t('正在扫描项目产物', 'Scanning project artifacts'),
  artifacts: () => t('构建产物', 'Build Artifacts'),
  artifactsFound: (n: number, size: string) => t(`找到 ${n} 个产物（${size}）`, `${n} artifacts (${size})`),
  selected: (n: number, size: string) => t(`已选 ${n} 个（${size}）`, `${n} selected (${size})`),
  purgeSelected: () => t('清理已选', 'Purge Selected'),
  purgeConfirm: (n: number, size: string) =>
    t(`确认清理 ${n} 个构建产物（${size}）？`, `Purge ${n} build artifacts (${size})?`),
  purged: (n: number, size: string) => t(`已清理 ${n} 个产物，释放 ${size}`, `Purged ${n} artifacts, freed ${size}`),
  noArtifacts: () => t('未找到构建产物', 'No build artifacts found'),
  projectPath: () => t('项目路径', 'Project Path'),
  artifactType: () => t('产物类型', 'Artifact Type'),
  ageDays: (d: number) => t(`${d} 天前`, `${d} days ago`),
  recent: () => t('近期', 'Recent'),
  recentDesc: () => t('7 天内修改，不建议清理', 'Modified within 7 days, not recommended'),
  scanPaths: () => t('扫描路径', 'Scan Paths'),
  configurePaths: () => t('配置扫描路径', 'Configure Scan Paths'),
  dropHere: () => t('拖放目录到此处', 'Drop directories here'),
  dropHint: () => t('或点击选择路径', 'or click to select paths'),
};

// Installer 页
export const installer = {
  scanInstallers: () => t('扫描安装包', 'Scan Installers'),
  scanning: () => t('正在扫描安装包文件', 'Scanning installer files'),
  files: () => t('安装包文件', 'Installer Files'),
  filesFound: (n: number, size: string) => t(`找到 ${n} 个文件（${size}）`, `${n} files (${size})`),
  selected: (n: number, size: string) => t(`已选 ${n} 个（${size}）`, `${n} selected (${size})`),
  deleteSelected: () => t('删除已选', 'Delete Selected'),
  deleteConfirm: (n: number, size: string) =>
    t(`确认删除 ${n} 个安装包（${size}）？`, `Delete ${n} installers (${size})?`),
  deleted: (n: number, size: string) => t(`已删除 ${n} 个文件，释放 ${size}`, `Deleted ${n} files, freed ${size}`),
  noFiles: () => t('未找到安装包', 'No installer files found'),
  sources: {
    downloads: () => t('下载', 'Downloads'),
    desktop: () => t('桌面', 'Desktop'),
    documents: () => t('文档', 'Documents'),
    library: () => t('资源库', 'Library'),
    shared: () => t('共享', 'Shared'),
    homebrew: () => t('Homebrew', 'Homebrew'),
    icloud: () => t('iCloud', 'iCloud'),
    mail: () => t('邮件', 'Mail'),
    telegram: () => t('Telegram', 'Telegram'),
  },
  fileTypes: {
    dmg: () => t('磁盘映像', 'Disk Image'),
    pkg: () => t('安装包', 'Package'),
    iso: () => t('ISO 镜像', 'ISO Image'),
    xip: () => t('XIP 归档', 'XIP Archive'),
    zip: () => t('压缩包', 'ZIP Archive'),
  },
};

// 历史页
export const history = {
  sessions: () => t('操作会话', 'Sessions'),
  deletions: () => t('删除记录', 'Deletions'),
  totalSessions: (n: number) => t(`共 ${n} 次会话`, `${n} sessions`),
  totalItems: (n: number) => t(`${n} 个项目`, `${n} items`),
  totalSpace: (s: string) => t(`共 ${s}`, `${s} total`),
  command: () => t('命令', 'Command'),
  started: () => t('开始时间', 'Started'),
  ended: () => t('结束时间', 'Ended'),
  duration: () => t('耗时', 'Duration'),
  operations: () => t('操作', 'Operations'),
  removed: () => t('已删除', 'Removed'),
  trashed: () => t('已废弃', 'Trashed'),
  skipped: () => t('已跳过', 'Skipped'),
  failed: () => t('失败', 'Failed'),
  rebuilt: () => t('已重建', 'Rebuilt'),
  other: () => t('其他', 'Other'),
  noHistory: () => t('暂无历史记录', 'No history yet'),
  logFiles: () => t('日志文件', 'Log Files'),
  timestamp: () => t('时间戳', 'Timestamp'),
  mode: () => t('模式', 'Mode'),
  statusCol: () => t('状态', 'Status'),
  pathCol: () => t('路径', 'Path'),
};

// 设置页
export const settings = {
  about: () => t('关于', 'About'),
  appName: () => t('应用名称', 'App Name'),
  guiVersion: () => t('界面版本', 'GUI Version'),
  cliVersion: () => t('CLI 版本', 'CLI Version'),
  framework: () => t('框架', 'Framework'),
  cliPath: () => t('CLI 路径', 'CLI Path'),
  language: () => t('语言', 'Language'),
  chinese: () => t('中文', 'Chinese'),
  english: () => t('英文', 'English'),
  theme: () => t('主题', 'Theme'),
  dark: () => t('深色', 'Dark'),
  light: () => t('浅色', 'Light'),
  update: () => t('更新', 'Update'),
  checkUpdate: () => t('检查更新', 'Check for Updates'),
  checking: () => t('检查中', 'Checking'),
  upToDate: () => t('已是最新版本', 'Up to date'),
  newVersion: (v: string) => t(`发现新版本 ${v}`, `New version ${v} available`),
  download: () => t('下载', 'Download'),
  downloading: () => t('下载中', 'Downloading'),
  install: () => t('安装', 'Install'),
  installing: () => t('安装中', 'Installing'),
  restart: () => t('重启应用', 'Restart App'),
  links: () => t('链接', 'Links'),
  github: () => t('GitHub 仓库', 'GitHub Repository'),
  documentation: () => t('文档', 'Documentation'),
  reportIssue: () => t('反馈问题', 'Report Issue'),
  cliHelp: () => t('CLI 帮助', 'CLI Help'),
  minCliVersion: () => t('需要 CLI ≥ 1.43.1', 'Requires CLI ≥ 1.43.1'),
};
