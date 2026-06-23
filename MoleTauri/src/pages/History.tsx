// History 页：操作历史与删除审计
// 调用 mo history --json，以时间线展示会话与删除记录
import { useState, useEffect, useCallback } from 'react';
import { Card, Button, Badge, EmptyState, Spinner, StatTile, KVList } from '../components/ui';
import { runHistoryJson, type HistoryResult, type HistorySession, type HistoryDeletion } from '../lib/cli';
import { history as t, common } from '../lib/i18n';
import { formatKB, formatDateTime, formatRelativeTime } from '../lib/format';

const HISTORY_LIMIT = 50;

// Badge tone 类型，与 ui.tsx Badge tone 对齐
type BadgeTone = 'default' | 'good' | 'warn' | 'critical' | 'info' | 'accent' | 'purple';

// 模式 → Badge tone 映射
const MODE_TONE: Record<string, BadgeTone> = {
  removed: 'critical',
  trashed: 'warn',
  skipped: 'default',
  failed: 'critical',
  rebuilt: 'info',
  other: 'default',
};

function modeTone(mode: string): BadgeTone {
  return MODE_TONE[mode] ?? 'default';
}

export default function HistoryPage() {
  const [result, setResult] = useState<HistoryResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());

  const fetchHistory = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await runHistoryJson(HISTORY_LIMIT);
      setResult(data);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchHistory();
  }, [fetchHistory]);

  const toggle = (id: number) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // 加载中（首次）
  if (loading && !result) {
    return (
      <div className="page page-wide history-page">
        <div className="history-loading">
          <Spinner size="lg" />
          <span>{common.loading()}</span>
        </div>
      </div>
    );
  }

  // 加载失败（首次）
  if (error && !result) {
    return (
      <div className="page page-wide history-page">
        <Card>
          <EmptyState
            icon="⚠️"
            title={common.error()}
            description={error}
            action={<Button variant="primary" onClick={fetchHistory}>{common.retry()}</Button>}
          />
        </Card>
      </div>
    );
  }

  // 无历史记录
  if (!result || result.sessions.length === 0) {
    return (
      <div className="page page-wide history-page">
        <Card>
          <EmptyState
            icon="📋"
            title={t.noHistory()}
            description={t.sessions()}
          />
        </Card>
      </div>
    );
  }

  const totalSessions = result.sessions.length;
  const totalItems = result.sessions.reduce((s, sess) => s + (sess.items ?? 0), 0);
  const totalSizeKB = result.sessions.reduce((s, sess) => {
    // size 是字符串如 "1.23GB"，尝试解析为 KB 近似值
    const m = sess.size?.match(/([\d.]+)\s*(GB|MB|KB|B|TB)/i);
    if (!m) return s;
    const val = parseFloat(m[1]);
    const unit = m[2].toUpperCase();
    const mult: Record<string, number> = { B: 1/1024, KB: 1, MB: 1024, GB: 1024*1024, TB: 1024*1024*1024 };
    return s + val * (mult[unit] || 0);
  }, 0);

  return (
    <div className="page page-wide history-page">
      {/* 汇总统计 */}
      <div className="history-stats-row">
        <StatTile
          label={t.sessions()}
          value={t.totalSessions(totalSessions)}
        />
        <StatTile
          label={t.deletions()}
          value={t.totalItems(totalItems)}
        />
        <StatTile
          label={common.total()}
          value={t.totalSpace(formatKB(totalSizeKB))}
        />
      </div>

      {/* 会话时间线 */}
      <div className="history-timeline">
        {result.sessions.map((session, i) => (
          <HistorySessionCard
            key={i}
            session={session}
            expanded={expanded.has(i)}
            onToggle={() => toggle(i)}
            isLast={i === result.sessions.length - 1}
          />
        ))}
      </div>

      {/* 顶层删除记录（如果存在） */}
      {result.deletions && result.deletions.length > 0 && (
        <Card variant="glass">
          <div className="history-deletions-section-title">{t.deletions()}</div>
          <div className="history-deletions-table">
            <div className="history-deletion-head">
              <span className="col-ts">{t.timestamp()}</span>
              <span className="col-path">{t.pathCol()}</span>
              <span className="col-mode">{t.mode()}</span>
              <span className="col-status">{t.statusCol()}</span>
              <span className="col-size">{common.size()}</span>
            </div>
            {result.deletions.slice(0, 100).map((d, j) => (
              <HistoryDeletionRow key={j} deletion={d} />
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}

function HistorySessionCard({
  session,
  expanded,
  onToggle,
  isLast,
}: {
  session: HistorySession;
  expanded: boolean;
  onToggle: () => void;
  isLast: boolean;
}) {
  const actions = session.actions;
  const actionEntries: Array<{ key: string; label: string; value: number; tone: BadgeTone }> = [
    { key: 'removed', label: t.removed(), value: actions.removed, tone: 'critical' },
    { key: 'trashed', label: t.trashed(), value: actions.trashed, tone: 'warn' },
    { key: 'skipped', label: t.skipped(), value: actions.skipped, tone: 'default' },
    { key: 'failed', label: t.failed(), value: actions.failed, tone: 'critical' },
    { key: 'rebuilt', label: t.rebuilt(), value: actions.rebuilt, tone: 'info' },
    { key: 'other', label: t.other(), value: actions.other, tone: 'default' },
  ];
  const activeActions = actionEntries.filter((a) => a.value > 0);
  const startedEpoch = session.started_at ? new Date(session.started_at).getTime() / 1000 : 0;

  return (
    <div className={`history-timeline-item ${isLast ? 'last' : ''}`}>
      <div className="history-timeline-rail">
        <span className={`history-timeline-dot ${expanded ? 'open' : ''}`} />
        {!isLast && <span className="history-timeline-line" />}
      </div>
      <Card variant="glass" className="history-session-card">
        <div className="history-session-header" onClick={onToggle}>
          <div className="history-session-main">
            <div className="history-session-title">
              <Badge tone="accent">{session.command}</Badge>
              {startedEpoch > 0 && (
                <span className="history-session-relative">{formatRelativeTime(startedEpoch)}</span>
              )}
            </div>
            <div className="history-session-meta">
              <span className="history-session-time">
                {formatDateTime(session.started_at)} → {formatDateTime(session.ended_at)}
              </span>
            </div>
          </div>
          <div className="history-session-actions">
            {activeActions.map((a) => (
              <Badge key={a.key} tone={a.tone}>
                {a.label} {a.value}
              </Badge>
            ))}
            <span className={`history-session-chevron ${expanded ? 'open' : ''}`}>▾</span>
          </div>
        </div>

        {expanded && (
          <div className="history-session-body">
            <div className="history-session-kv">
              <KVList
                items={[
                  { label: t.command(), value: <code>{session.command}</code> },
                  { label: t.started(), value: formatDateTime(session.started_at) },
                  { label: t.ended(), value: formatDateTime(session.ended_at) },
                  { label: common.items(), value: String(session.items ?? 0) },
                  { label: common.size(), value: session.size ?? '—' },
                  { label: t.operations(), value: activeActions.map((a) => `${a.label}:${a.value}`).join(' · ') || '0' },
                ]}
              />
            </div>
          </div>
        )}
      </Card>
    </div>
  );
}

function HistoryDeletionRow({ deletion }: { deletion: HistoryDeletion }) {
  return (
    <div className="history-deletion-row">
      <span className="col-ts">{formatDateTime(deletion.timestamp)}</span>
      <span className="col-path history-deletion-path" title={deletion.path}>
        <code>{deletion.path}</code>
      </span>
      <span className="col-mode">
        <Badge tone={modeTone(deletion.mode)}>{deletion.mode}</Badge>
      </span>
      <span className="col-status">{deletion.status || '—'}</span>
      <span className="col-size">
        {deletion.size_kb != null ? formatKB(deletion.size_kb) : '—'}
      </span>
    </div>
  );
}
