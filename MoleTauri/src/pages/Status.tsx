// Status 页：实时健康仪表盘
// 调用 mo status --json，展示健康评分、CPU/内存/磁盘/网络/电池/温度/进程
//
// 注意：`mo status --json` 的实际输出字段类型可能与 TypeScript 接口定义不完全
// 一致（某些字段可能缺失、为 null、或为对象而非数组）。所有 `.map()` 调用和
// 数值访问都通过 asArray / asNumber / arrayGet 做防御，避免 "L.map is not a
// function" 之类的运行时崩溃导致白屏。
import { useState, useEffect, useCallback } from 'react';
import { Card, CardHeader, Button, Badge, StatTile, KVList, Spinner, EmptyState } from '../components/ui';
import { RingGauge, LineChart } from '../components/charts';
import { runStatusJson, type StatusSnapshot } from '../lib/cli';
import { status as t, common } from '../lib/i18n';
import { formatBytes, formatBytesShort, formatUptime, formatNumber, asArray, asNumber, arrayGet } from '../lib/format';
import { writeLog } from '../lib/cli';

const REFRESH_INTERVAL = 5000;

export default function StatusPage() {
  const [snapshot, setSnapshot] = useState<StatusSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);

  const fetchStatus = useCallback(async () => {
    try {
      const data = await runStatusJson();
      setSnapshot(data);
      setError(null);
    } catch (e: any) {
      const msg = e?.message ?? String(e);
      setError(msg);
      // 写入应用日志，方便在日志页面查看首页报错原因
      writeLog('error', `Status 页面加载失败: ${msg}`).catch(() => {});
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  useEffect(() => {
    if (!autoRefresh) return;
    const timer = setInterval(fetchStatus, REFRESH_INTERVAL);
    return () => clearInterval(timer);
  }, [autoRefresh, fetchStatus]);

  if (loading && !snapshot) {
    return (
      <div className="page page-wide">
        <div className="status-loading">
          <Spinner size="lg" />
          <span>{common.loading()}</span>
        </div>
      </div>
    );
  }

  if (error && !snapshot) {
    return (
      <div className="page page-wide">
        <EmptyState
          icon="⚠️"
          title={common.error()}
          description={error}
          action={<Button variant="primary" onClick={fetchStatus}>{common.retry()}</Button>}
        />
      </div>
    );
  }

  if (!snapshot) return null;

  // 所有字段访问都做防御：数值用 asNumber，数组用 asArray，数组元素用 arrayGet。
  const healthScore = asNumber(snapshot.health_score, 0);
  const cpuUsage = asNumber(snapshot.cpu?.usage, 0);
  const memTotal = asNumber(snapshot.memory?.total, 0);
  const memUsed = asNumber(snapshot.memory?.used, 0);
  const memPercent = memTotal > 0 ? (memUsed / memTotal) * 100 : 0;
  const memPressure = snapshot.memory?.pressure ?? 'normal';
  const uptime = asNumber(snapshot.uptime, 0);

  // 网络历史折线（防御：network_history 可能不是数组）
  const netHistory = asArray<{ download: number; upload: number; ts: number }>(snapshot.network_history);
  const downloadSeries = netHistory.map((h) => asNumber(h?.download, 0));
  const uploadSeries = netHistory.map((h) => asNumber(h?.upload, 0));
  const netLabels = netHistory.map((_, i) => {
    if (netHistory.length === 0) return '';
    const idx = Math.max(0, netHistory.length - 1 - i);
    return `-${idx}s`;
  }).reverse();

  // load_avg 防御
  const loadAvg = asArray<number>(snapshot.cpu?.load_avg);
  const load1 = arrayGet(loadAvg, 0, 0);
  const load5 = arrayGet(loadAvg, 1, 0);
  const load15 = arrayGet(loadAvg, 2, 0);

  // 磁盘 / 电池 / 进程列表防御
  const disks = asArray<any>(snapshot.disks);
  const batteries = asArray<any>(snapshot.batteries);
  const topProcesses = asArray<any>(snapshot.top_processes);

  return (
    <div className="page page-wide status-page">
      {/* 顶部操作栏 */}
      <div className="status-toolbar">
        <div className="status-toolbar-left">
          <Badge tone="info">{snapshot.host || '—'}</Badge>
          <Badge tone="default">{snapshot.platform || '—'}</Badge>
          {snapshot.hardware?.chip && <Badge tone="accent">{snapshot.hardware.chip}</Badge>}
          <span className="status-uptime">
            {t.uptime()}: <strong>{formatUptime(uptime)}</strong>
          </span>
        </div>
        <div className="status-toolbar-right">
          <label className="status-autorefresh">
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={(e) => setAutoRefresh(e.target.checked)}
            />
            <span>Auto · 5s</span>
          </label>
          <Button size="sm" variant="ghost" onClick={fetchStatus}>
            {common.refresh()}
          </Button>
        </div>
      </div>

      {/* 第一行：三大健康环 */}
      <div className="status-rings-row">
        <Card variant="glass" className="status-ring-card">
          <CardHeader title={t.healthScore()} subtitle={snapshot.collected_at} />
          <div className="status-ring-body">
            <RingGauge
              value={healthScore}
              max={100}
              size="lg"
              tone="auto"
              label="SCORE"
              subText={healthScore >= 80 ? t.normal() : healthScore >= 50 ? 'Fair' : 'Poor'}
            />
            <div className="status-ring-meta">
              <p className="status-ring-desc">
                {healthScore >= 80
                  ? '系统状态良好，无需干预'
                  : healthScore >= 50
                  ? '部分指标偏高，建议关注'
                  : '多项指标异常，建议优化'}
              </p>
            </div>
          </div>
        </Card>

        <Card variant="glass" className="status-ring-card">
          <CardHeader title={t.cpu()} subtitle={snapshot.hardware?.model} />
          <div className="status-ring-body">
            <RingGauge
              value={cpuUsage}
              max={100}
              tone="auto"
              label="CPU"
              centerText={`${cpuUsage.toFixed(0)}%`}
              subText={`${asNumber(snapshot.hardware?.cores, 0)} cores`}
            />
            <div className="status-ring-meta">
              {loadAvg.length > 0 && (
                <KVList
                  items={[
                    { label: 'Load 1m', value: load1.toFixed(2) },
                    { label: 'Load 5m', value: load5.toFixed(2) },
                    { label: 'Load 15m', value: load15.toFixed(2) },
                  ]}
                />
              )}
            </div>
          </div>
        </Card>

        <Card variant="glass" className="status-ring-card">
          <CardHeader title={t.memory()} subtitle={t.memoryPressure()} />
          <div className="status-ring-body">
            <RingGauge
              value={memPercent}
              max={100}
              tone="auto"
              label="MEM"
              centerText={`${memPercent.toFixed(0)}%`}
              subText={memPressure}
            />
            <div className="status-ring-meta">
              <KVList
                items={[
                  { label: 'Used', value: formatBytes(memUsed) },
                  { label: 'Total', value: formatBytes(memTotal) },
                  { label: 'Cached', value: formatBytes(asNumber(snapshot.memory?.cached, 0)) },
                ]}
              />
            </div>
          </div>
        </Card>
      </div>

      {/* 第二行：网络 + 磁盘 */}
      <div className="status-grid-2">
        <Card variant="glass">
          <CardHeader
            title={t.network()}
            subtitle={snapshot.network?.interface ?? ''}
            action={
              <div className="status-net-stats">
                <Badge tone="good">↓ {formatBytesShort(asNumber(snapshot.network?.download_speed, 0))}/s</Badge>
                <Badge tone="info">↑ {formatBytesShort(asNumber(snapshot.network?.upload_speed, 0))}/s</Badge>
              </div>
            }
          />
          <div className="status-chart-wrap">
            {netHistory.length > 1 ? (
              <LineChart
                series={[
                  { name: 'Download', color: 'var(--good)', points: downloadSeries },
                  { name: 'Upload', color: 'var(--accent)', points: uploadSeries },
                ]}
                labels={netLabels}
                height={180}
                area
                grid
                unit="/s"
              />
            ) : (
              <EmptyState title={common.noData()} description="等待网络历史数据" />
            )}
          </div>
          {snapshot.network?.ip && (
            <div className="status-net-ip">
              IP: <code>{snapshot.network.ip}</code>
              {snapshot.network.total_downloaded != null && (
                <span> · ↓ {formatBytes(asNumber(snapshot.network.total_downloaded, 0))}</span>
              )}
              {snapshot.network.total_uploaded != null && (
                <span> · ↑ {formatBytes(asNumber(snapshot.network.total_uploaded, 0))}</span>
              )}
            </div>
          )}
        </Card>

        <Card variant="glass">
          <CardHeader title={t.disk()} subtitle={`${disks.length} volumes`} />
          <div className="status-disks">
            {disks.map((disk, i) => {
              const total = asNumber(disk?.total, 0);
              const used = asNumber(disk?.used, 0);
              const free = asNumber(disk?.free, 0);
              const usedPct = total > 0 ? (used / total) * 100 : 0;
              return (
                <div key={i} className="status-disk-item">
                  <div className="status-disk-header">
                    <span className="status-disk-name">{disk?.name ?? '—'}</span>
                    <Badge tone={usedPct > 85 ? 'critical' : usedPct > 70 ? 'warn' : 'good'}>
                      {usedPct.toFixed(0)}%
                    </Badge>
                  </div>
                  <div className="status-disk-bar">
                    <div
                      className={`status-disk-fill ${usedPct > 85 ? 'critical' : usedPct > 70 ? 'warn' : 'good'}`}
                      style={{ width: `${usedPct}%` }}
                    />
                  </div>
                  <div className="status-disk-meta">
                    <span>{formatBytes(used)} / {formatBytes(total)}</span>
                    <span className="status-disk-free">{formatBytes(free)} free</span>
                  </div>
                </div>
              );
            })}
            {asNumber(snapshot.trash_size, 0) > 0 && (
              <div className="status-trash-row">
                <span>{t.trash()}</span>
                <Badge tone="warn">{formatBytes(asNumber(snapshot.trash_size, 0))}</Badge>
              </div>
            )}
          </div>
        </Card>
      </div>

      {/* 第三行：电池 + 温度 */}
      <div className="status-grid-2">
        <Card variant="glass">
          <CardHeader title={t.battery()} subtitle={t.batteryHealth()} />
          <div className="status-batteries">
            {batteries.map((bat, i) => {
              const charge = asNumber(bat?.charge, 0);
              return (
                <div key={i} className="status-battery-item">
                  <RingGauge
                    value={charge}
                    max={100}
                    size="sm"
                    tone={charge < 20 ? 'critical' : charge < 50 ? 'warn' : 'success'}
                    centerText={`${charge.toFixed(0)}%`}
                  />
                  <div className="status-battery-meta">
                    <div className="status-battery-name">
                      {bat?.name ?? 'Battery'}
                      <Badge tone={bat?.plugged ? 'info' : bat?.charging ? 'good' : 'default'}>
                        {bat?.plugged ? t.plugged() : bat?.charging ? t.charging() : t.discharging()}
                      </Badge>
                    </div>
                    <KVList
                      items={[
                        { label: t.cycles(), value: bat?.cycles != null ? String(bat.cycles) : '—' },
                        { label: t.condition(), value: bat?.condition ?? '—' },
                      ]}
                    />
                  </div>
                </div>
              );
            })}
            {batteries.length === 0 && (
              <EmptyState title={common.noData()} description="无电池信息" />
            )}
          </div>
        </Card>

        <Card variant="glass">
          <CardHeader title={t.thermal()} subtitle={snapshot.gpu?.name} />
          <div className="status-thermal-grid">
            <StatTile
              label={t.cpu()}
              value={snapshot.thermal?.cpu_temp != null ? `${asNumber(snapshot.thermal.cpu_temp, 0).toFixed(0)}°C` : '—'}
            />
            <StatTile
              label={t.gpu()}
              value={snapshot.thermal?.gpu_temp != null ? `${asNumber(snapshot.thermal.gpu_temp, 0).toFixed(0)}°C` : '—'}
            />
            <StatTile
              label={t.fanSpeed()}
              value={snapshot.thermal?.fan_speed != null ? `${formatNumber(asNumber(snapshot.thermal.fan_speed, 0))} RPM` : '—'}
            />
            <StatTile
              label="Power"
              value={snapshot.thermal?.system_power != null ? `${asNumber(snapshot.thermal.system_power, 0).toFixed(1)}W` : '—'}
            />
            {snapshot.gpu?.usage != null && (
              <StatTile
                label="GPU Usage"
                value={`${asNumber(snapshot.gpu.usage, 0).toFixed(0)}%`}
              />
            )}
          </div>
        </Card>
      </div>

      {/* 第四行：Top 进程 */}
      <Card variant="glass">
        <CardHeader title={t.topProcesses()} subtitle={`${topProcesses.length} active`} />
        <div className="status-process-table">
          <div className="status-process-head">
            <span>{t.pid()}</span>
            <span>{t.process()}</span>
            <span className="num">{t.cpuShort()}</span>
            <span className="num">{t.memShort()}</span>
          </div>
          {topProcesses.map((p, i) => {
            const cpu = asNumber(p?.cpu, 0);
            const memory = asNumber(p?.memory, 0);
            return (
              <div key={i} className="status-process-row">
                <span className="status-pid">{p?.pid ?? '—'}</span>
                <span className="status-pname">{p?.name ?? '—'}</span>
                <span className="num">
                  <span className="status-bar-inline">
                    <span
                      className={`status-bar-fill ${cpu > 50 ? 'critical' : cpu > 20 ? 'warn' : 'good'}`}
                      style={{ width: `${Math.min(100, cpu)}%` }}
                    />
                  </span>
                  {cpu.toFixed(1)}%
                </span>
                <span className="num">{formatBytes(memory)}</span>
              </div>
            );
          })}
          {topProcesses.length === 0 && (
            <EmptyState title={common.noData()} />
          )}
        </div>
      </Card>
    </div>
  );
}
