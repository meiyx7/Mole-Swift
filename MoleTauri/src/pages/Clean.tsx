// Clean 页：三步流程（选项预览 → 审阅 → 执行）
// 使用 PreviewParser 解析 mo clean --dry-run 流式输出
import { useState, useRef, useCallback } from 'react';
import { Card, CardHeader, Button, Badge, Toggle, Checkbox, Steps, Banner, EmptyState, Spinner, ConsoleOutput, StatTile } from '../components/ui';
import { runCleanStreaming, runClean, type StreamingLine } from '../lib/cli';
import { PreviewParser, type PreviewSection, type PreviewSummary } from '../lib/previewParser';
import { clean as t, common } from '../lib/i18n';
import { formatBytes } from '../lib/format';

type Step = 1 | 2 | 3 | 4;

export default function CleanPage() {
  const [step, setStep] = useState<Step>(1);
  const [dryRun, setDryRun] = useState(true);
  const [verbose, setVerbose] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [executing, setExecuting] = useState(false);
  const [sections, setSections] = useState<PreviewSection[]>([]);
  const [summary, setSummary] = useState<PreviewSummary | null>(null);
  const [consoleLines, setConsoleLines] = useState<StreamingLine[]>([]);
  const [execLines, setExecLines] = useState<StreamingLine[]>([]);
  const [error, setError] = useState<string | null>(null);
  const parserRef = useRef(new PreviewParser());

  const startPreview = useCallback(async () => {
    setStep(2);
    setPreviewing(true);
    setError(null);
    setSections([]);
    setSummary(null);
    setConsoleLines([]);
    parserRef.current.reset();

    try {
      const result = await runCleanStreaming(dryRun, verbose, (line: StreamingLine) => {
        parserRef.current.feed(line);
        setConsoleLines((prev) => [...prev, line]);
        // 每 10 行刷新一次 sections，避免过度渲染
        if (parserRef.current.sections.length % 5 === 0) {
          const r = parserRef.current.getResult();
          setSections([...r.sections]);
          if (r.summary) setSummary(r.summary);
        }
      });
      // 最终刷新
      const r = parserRef.current.getResult();
      setSections(r.sections);
      setSummary(r.summary);
      if (!result.success) {
        setError(result.stderr || 'Preview failed');
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setPreviewing(false);
    }
  }, [dryRun, verbose]);

  const startClean = useCallback(async () => {
    setStep(3);
    setExecuting(true);
    setError(null);
    setExecLines([]);
    try {
      const result = await runClean(false, verbose);
      if (result.stdout) {
        result.stdout.split('\n').forEach((text) => {
          if (text.trim()) {
            setExecLines((prev) => [...prev, { text, type: 'stdout' as const }]);
          }
        });
      }
      if (result.stderr) {
        result.stderr.split('\n').forEach((text) => {
          if (text.trim()) {
            setExecLines((prev) => [...prev, { text, type: 'stderr' as const }]);
          }
        });
      }
      if (!result.success) {
        setError(result.stderr || 'Clean failed');
      } else {
        setStep(4);
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setExecuting(false);
    }
  }, [verbose]);

  const reset = () => {
    setStep(1);
    setSections([]);
    setSummary(null);
    setConsoleLines([]);
    setExecLines([]);
    setError(null);
    parserRef.current.reset();
  };

  const totalItems = sections.reduce((s, sec) => s + sec.entries.filter((e) => e.kind === 'wouldClean').length, 0);
  const hasContent = sections.some((s) => s.hasContent);

  return (
    <div className="page page-wide clean-page">
      {/* 步骤指示器 */}
      <Card variant="glass">
        <Steps
          current={step}
          labels={[t.step1(), t.step2(), t.step3(), t.step4()]}
        />
      </Card>

      {/* Step 1: 选项 */}
      {step === 1 && (
        <Card variant="glass">
          <CardHeader title={t.step1()} subtitle={common.dryRunDesc()} />
          <div className="clean-options">
            <div className="clean-option-row">
              <Toggle
                checked={dryRun}
                onChange={setDryRun}
                label={common.dryRun()}
                description={common.dryRunDesc()}
              />
            </div>
            <div className="clean-option-row">
              <Toggle
                checked={verbose}
                onChange={setVerbose}
                label={common.verbose()}
                description="Show detailed output"
              />
            </div>
          </div>
          <div className="clean-step1-actions">
            <Button variant="primary" size="lg" onClick={startPreview}>
              {t.startPreview()}
            </Button>
          </div>
        </Card>
      )}

      {/* Step 2: 审阅 */}
      {step === 2 && (
        <>
          {/* 汇总 */}
          {summary && (
            <div className="clean-summary-row">
              <StatTile
                label={common.potentialSpace()}
                value={summary.totalSizeText || formatBytes(summary.totalSize)}
              />
              <StatTile
                label={common.items()}
                value={String(summary.items || totalItems)}
              />
              <StatTile
                label={common.categories()}
                value={String(summary.categories || sections.length)}
              />
              {summary.freeSpaceNow && (
                <StatTile
                  label={common.freeSpace()}
                  value={summary.freeSpaceNow}
                />
              )}
            </div>
          )}

          {/* 风险提示 */}
          {hasContent && (
            <Banner tone="info" title={t.sections()}>
              <span className="clean-banner-text">
                {t.itemsToClean(totalItems)}
                {summary?.totalSizeText && ` · ${t.potentialSpace(summary.totalSizeText)}`}
              </span>
            </Banner>
          )}

          {/* Section 卡片网格 */}
          {sections.length > 0 ? (
            <div className="clean-sections-grid">
              {sections.map((sec, i) => (
                <CleanSectionCard key={i} section={sec} />
              ))}
            </div>
          ) : !previewing && !error ? (
            <Card>
              <EmptyState
                icon="✨"
                title={t.noCleanable()}
                description="系统已经很干净"
              />
            </Card>
          ) : null}

          {/* 流式控制台 */}
          {(previewing || consoleLines.length > 0) && (
            <Card variant="glass">
              <CardHeader
                title="Console"
                action={previewing ? <Spinner size="sm" /> : undefined}
              />
              <ConsoleOutput lines={consoleLines} maxLines={300} />
            </Card>
          )}

          {/* 错误 */}
          {error && (
            <Banner tone="error" title={common.error()}>
              {error}
            </Banner>
          )}

          {/* 操作栏 */}
          <div className="clean-step2-actions">
            <Button variant="ghost" onClick={reset}>{common.back()}</Button>
            <Button
              variant="primary"
              size="lg"
              onClick={startClean}
              disabled={previewing || !hasContent || executing}
            >
              {previewing ? common.previewing() : t.startClean()}
            </Button>
          </div>
        </>
      )}

      {/* Step 3: 执行中 */}
      {step === 3 && (
        <Card variant="glass">
          <CardHeader
            title={t.step3()}
            action={executing ? <Spinner size="sm" /> : <Badge tone="good">{common.done()}</Badge>}
          />
          {execLines.length > 0 ? (
            <ConsoleOutput lines={execLines} maxLines={500} />
          ) : (
            <div className="clean-executing">
              <Spinner size="md" />
              <span>{common.executing()}...</span>
            </div>
          )}
          {error && (
            <Banner tone="error" title={common.error()}>{error}</Banner>
          )}
        </Card>
      )}

      {/* Step 4: 完成 */}
      {step === 4 && (
        <Card variant="glass">
          <div className="clean-complete">
            <div className="clean-complete-icon">✓</div>
            <h2>{t.cleanComplete()}</h2>
            {summary && (
              <p className="clean-complete-summary">
                {t.freedSpace(summary.totalSizeText || formatBytes(summary.totalSize))}
              </p>
            )}
            <div className="clean-complete-actions">
              <Button variant="primary" onClick={reset}>{common.done()}</Button>
            </div>
          </div>
        </Card>
      )}
    </div>
  );
}

function CleanSectionCard({ section }: { section: PreviewSection }) {
  const [expanded, setExpanded] = useState(false);
  const cleanEntries = section.entries.filter((e) => e.kind === 'wouldClean');
  const showEntries = expanded ? cleanEntries : cleanEntries.slice(0, 5);

  return (
    <Card variant="compact" tone={section.hasContent ? 'info-soft' : 'default'}>
      <div className="clean-section-header" onClick={() => setExpanded(!expanded)}>
        <span className="clean-section-name">{section.name}</span>
        <div className="clean-section-meta">
          {section.hasContent ? (
            <>
              <Badge tone="info">{cleanEntries.length} items</Badge>
              {section.totalSize > 0 && (
                <Badge tone="accent">{formatBytes(section.totalSize)}</Badge>
              )}
            </>
          ) : (
            <Badge tone="good">{common.nothingToClean()}</Badge>
          )}
          <span className={`clean-section-chevron ${expanded ? 'open' : ''}`}>▾</span>
        </div>
      </div>
      {expanded && showEntries.length > 0 && (
        <div className="clean-section-entries">
          {showEntries.map((entry, i) => (
            <div key={i} className="clean-entry-row">
              <span className={`clean-entry-risk risk-${entry.risk}`} />
              <span className="clean-entry-desc" title={entry.path}>{entry.description}</span>
              {entry.sizeText && <span className="clean-entry-size">{entry.sizeText}</span>}
            </div>
          ))}
          {cleanEntries.length > 5 && !expanded && (
            <div className="clean-entry-more">+{cleanEntries.length - 5} more</div>
          )}
        </div>
      )}
    </Card>
  );
}
