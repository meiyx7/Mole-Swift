// Optimize 页：三步流程（选择任务 → 执行 → 完成）
// 使用 runOptimizeStreaming 流式执行 mo optimize，支持白名单管理
import { useState, useCallback, useMemo } from 'react';
import { Card, CardHeader, Button, Badge, Toggle, Checkbox, Steps, Banner, EmptyState, Spinner, ConsoleOutput } from '../components/ui';
import { runOptimizeStreaming, writeLog, type StreamingLine } from '../lib/cli';
import { optimize as t, common } from '../lib/i18n';

type Step = 1 | 2 | 3;

// 系统默认白名单项 — 这些是系统目录/模式，不允许删除
const DEFAULT_WHITELIST: readonly string[] = [
  'com.apple.*',
  '/System/Library/*',
  '~/Library/Preferences/com.apple.*',
];

interface OptimizeTask {
  id: string;
  name: string;
  description: string;
  icon: string;
}

export default function OptimizePage() {
  const [step, setStep] = useState<Step>(1);
  const [dryRun, setDryRun] = useState(true);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [executing, setExecuting] = useState(false);
  const [consoleLines, setConsoleLines] = useState<StreamingLine[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [appliedCount, setAppliedCount] = useState(0);
  const [whitelist, setWhitelist] = useState<string[]>([...DEFAULT_WHITELIST]);
  const [whitelistInput, setWhitelistInput] = useState('');

  const tasks: OptimizeTask[] = useMemo(() => [
    { id: 'rebuild-db', name: t.rebuildDB(), description: 'Rebuild Launch Services and database indexes', icon: '🗄️' },
    { id: 'reset-network', name: t.resetNetwork(), description: 'Reset network configuration and DNS cache', icon: '🌐' },
    { id: 'refresh-ui', name: t.refreshUI(), description: 'Restart WindowServer and refresh UI', icon: '🖥️' },
    { id: 'rebuild-spotlight', name: t.rebuildSpotlight(), description: 'Reindex Spotlight search database', icon: '🔍' },
    { id: 'clear-crash-logs', name: t.clearCrashLogs(), description: 'Remove crash reporter logs', icon: '📋' },
    { id: 'clear-swap', name: t.clearSwap(), description: 'Purge inactive swap memory', icon: '💾' },
  ], []);

  const toggleTask = useCallback((id: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const selectAll = () => setSelected(new Set(tasks.map((task) => task.id)));
  const deselectAll = () => setSelected(new Set());

  const addWhitelist = () => {
    const pattern = whitelistInput.trim();
    if (pattern && !whitelist.includes(pattern)) {
      setWhitelist([...whitelist, pattern]);
      setWhitelistInput('');
    }
  };

  const removeWhitelist = (pattern: string) => {
    // 系统默认白名单项不允许删除
    if (DEFAULT_WHITELIST.includes(pattern)) return;
    setWhitelist(whitelist.filter((p) => p !== pattern));
  };

  const isDefaultWhitelist = (pattern: string) => DEFAULT_WHITELIST.includes(pattern);

  const startOptimize = useCallback(async () => {
    setStep(2);
    setExecuting(true);
    setError(null);
    setConsoleLines([]);
    setAppliedCount(0);
    writeLog('info', `优化执行开始 (dryRun=${dryRun}, ${selected.size} 个任务)`).catch(() => {});
    try {
      const result = await runOptimizeStreaming(dryRun, (line: StreamingLine) => {
        setConsoleLines((prev) => [...prev, line]);
      });
      if (!result.success) {
        const errMsg = result.stderr || 'Optimize failed';
        setError(errMsg);
        writeLog('error', `优化执行失败: ${errMsg}`).catch(() => {});
      } else {
        setAppliedCount(selected.size);
        setStep(3);
        writeLog('info', `优化执行完成，已应用 ${selected.size} 个任务`).catch(() => {});
      }
    } catch (e: any) {
      const msg = e?.message ?? String(e);
      setError(msg);
      writeLog('error', `优化执行异常: ${msg}`).catch(() => {});
    } finally {
      setExecuting(false);
    }
  }, [dryRun, selected.size]);

  const reset = () => {
    setStep(1);
    setConsoleLines([]);
    setError(null);
    setAppliedCount(0);
  };

  return (
    <div className="page page-wide optimize-page">
      {/* 步骤指示器 */}
      <Card variant="glass">
        <Steps
          current={step}
          labels={[t.tasks(), common.execute(), common.done()]}
        />
      </Card>

      {/* Step 1: 选择任务 */}
      {step === 1 && (
        <>
          <Card variant="glass">
            <CardHeader
              title={t.tasks()}
              subtitle={t.taskList()}
              action={<Badge tone="info">{t.applied(selected.size)}</Badge>}
            />
            <div className="optimize-options">
              <Toggle
                checked={dryRun}
                onChange={setDryRun}
                label={common.dryRun()}
                description={common.dryRunDesc()}
              />
            </div>
            <div className="optimize-task-actions">
              <Button variant="ghost" size="sm" onClick={selectAll}>{common.selectAll()}</Button>
              <Button variant="ghost" size="sm" onClick={deselectAll}>{common.deselectAll()}</Button>
            </div>
            <div className="optimize-tasks-grid">
              {tasks.map((task) => (
                <TaskCard
                  key={task.id}
                  task={task}
                  checked={selected.has(task.id)}
                  onToggle={() => toggleTask(task.id)}
                />
              ))}
            </div>
          </Card>

          {/* 白名单管理 */}
          <Card variant="glass">
            <CardHeader
              title={common.whitelist()}
              subtitle={t.systemHealth()}
              action={<Badge tone="accent">{whitelist.length}</Badge>}
            />
            <div className="optimize-whitelist-input">
              <input
                className="whitelist-input"
                type="text"
                value={whitelistInput}
                onChange={(e) => setWhitelistInput(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') addWhitelist(); }}
                placeholder="com.example.* or /path/*"
              />
              <Button variant="secondary" size="sm" onClick={addWhitelist} disabled={!whitelistInput.trim()}>
                +
              </Button>
            </div>
            {whitelist.length > 0 ? (
              <div className="optimize-whitelist-list">
                {whitelist.map((pattern) => {
                  const isDefault = isDefaultWhitelist(pattern);
                  return (
                    <div key={pattern} className="whitelist-row">
                      <span className="whitelist-pattern" title={pattern}>{pattern}</span>
                      {isDefault ? (
                        <span title="系统默认，不可删除" style={{ fontSize: 12 }}>🔒</span>
                      ) : (
                        <button className="icon-btn" onClick={() => removeWhitelist(pattern)} aria-label={common.remove()}>✕</button>
                      )}
                    </div>
                  );
                })}
              </div>
            ) : (
              <EmptyState
                icon="🛡️"
                title={common.noData()}
                description="No whitelist patterns configured"
              />
            )}
          </Card>

          {error && (
            <Banner tone="error" title={common.error()}>{error}</Banner>
          )}

          <div className="optimize-step1-actions">
            <Button
              variant="primary"
              size="lg"
              onClick={startOptimize}
              disabled={selected.size === 0}
            >
              {dryRun ? common.preview() : common.execute()}
            </Button>
          </div>
        </>
      )}

      {/* Step 2: 执行中 */}
      {step === 2 && (
        <Card variant="glass">
          <CardHeader
            title={common.executing()}
            action={executing ? <Spinner size="sm" /> : <Badge tone="good">{common.done()}</Badge>}
          />
          {consoleLines.length > 0 ? (
            <ConsoleOutput lines={consoleLines} maxLines={500} />
          ) : (
            <div className="optimize-executing">
              <Spinner size="md" />
              <span>{common.executing()}...</span>
            </div>
          )}
          {error && (
            <Banner tone="error" title={common.error()}>{error}</Banner>
          )}
          {!executing && error && (
            <div className="optimize-step2-actions">
              <Button variant="ghost" onClick={reset}>{common.back()}</Button>
              <Button variant="primary" onClick={startOptimize}>{common.retry()}</Button>
            </div>
          )}
        </Card>
      )}

      {/* Step 3: 完成 */}
      {step === 3 && (
        <Card variant="glass">
          <div className="optimize-complete">
            <div className="optimize-complete-icon">✓</div>
            <h2>{common.done()}</h2>
            <p className="optimize-complete-summary">
              {t.applied(appliedCount)}
            </p>
            <div className="optimize-complete-actions">
              <Button variant="primary" onClick={reset}>{common.done()}</Button>
            </div>
          </div>
        </Card>
      )}
    </div>
  );
}

function TaskCard({ task, checked, onToggle }: { task: OptimizeTask; checked: boolean; onToggle: () => void }) {
  return (
    <Card variant="compact" tone={checked ? 'info-soft' : 'default'} className="optimize-task-card">
      <div className="optimize-task-row" onClick={onToggle}>
        <Checkbox checked={checked} onChange={() => onToggle()} />
        <span className="optimize-task-icon">{task.icon}</span>
        <div className="optimize-task-info">
          <span className="optimize-task-name">{task.name}</span>
          <span className="optimize-task-desc">{task.description}</span>
        </div>
      </div>
    </Card>
  );
}
