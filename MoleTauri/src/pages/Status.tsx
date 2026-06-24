// Status 页：实时健康仪表盘
// 调用 mo status --json，展示健康评分、CPU/内存/磁盘/网络/电池/温度/进程
//
// 字段名严格匹配 cmd/status/metrics.go 的 JSON 输出：
// - uptime 是字符串，uptime_seconds 是数值
// - network 是数组（每个网卡一项），取第一个活跃接口
// - network_history 是 { rx_history: [], tx_history: [] }
// - disks[] 无 free 字段（需用 total-used 计算），无 name（用 mount）
// - gpu 是数组
// - cpu 有 load1/load5/load15 而非 load_avg 数组
import { useState, useEffect, useCallback, useRef } from 'react';
import { Card, CardHeader, Button, Badge, StatTile, KVList, Spinner, EmptyState } from '../components/ui';
import { RingGauge, LineChart } from '../components/charts';
import { runStatusJson, type StatusSnapshot } from '../lib/cli';
import { status as t, common } from '../lib/i18n';
import { formatBytes, formatBytesShort, formatNumber, asArray, asNumber } from '../lib/format';
import { writeLog } from '../lib/cli';

const REFRESH_INTERVAL = 5000;
const NET_HISTORY_MAX = 60; // 前端累积最多 60 个点（5 分钟）

export default function StatusPage() {
  const [snapshot, setSnapshot] = useState<StatusSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);

  // 前端网络历史累积 — CLI 是一次性命令，每次调用只有 1 个历史点，
  // 需要在前端跨刷新周期累积 rx/tx 速率用于绘制折线图。
  const netRxHistRef = useRef<number[]>([]);
  const netTxHistRef = useRef<number[]>([]);

  const fetchStatus = useCallback(async () => {
    try {
      const data = await runStatusJson();
      setSnapshot(data);
      setError(null);

      // 累积网络历史：CLI 一次性输出只有当前快照，前端跨刷新累积
      // 只统计有 IP 的物理接口（排除虚拟/VPN/loopback）
      const nets = asArray<any>(data.network).filter((n) => {
        const ip = n?.ip;
        return ip && typeof ip === 'string' && ip.trim() !== '';
      });
      if (nets.length > 0) {
        let totalRx = 0;
        let totalTx = 0;
        for (const n of nets) {
          totalRx += asNumber(n?.rx_rate_mbs, 0);
          totalTx += asNumber(n?.tx_rate_mbs, 0);
        }
        netRxHistRef.current.push(totalRx);
        netTxHistRef.current.push(totalTx);
        if (netRxHistRef.current.length > NET_HISTORY_MAX) {
          netRxHistRef.current.shift();
          netTxHistRef.current.shift();
        }
      }
    } catch (e: any) {
      const msg = e?.message ?? String(e);
      setError(msg);
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

  // ---- 数据提取（匹配实际 CLI JSON 字段名）----
  const healthScore = asNumber(snapshot.health_score, 0);
  const cpuUsage = asNumber(snapshot.cpu?.usage, 0);
  const memTotal = asNumber(snapshot.memory?.total, 0);
  const memUsed = asNumber(snapshot.memory?.used, 0);
  const memPercent = memTotal > 0 ? (memUsed / memTotal) * 100 : asNumber(snapshot.memory?.used_percent, 0);
  const memPressure = snapshot.memory?.pressure ?? 'normal';
  const uptimeSec = asNumber(snapshot.uptime_seconds, 0);

  // CPU load（CLI 输出 load1/load5/load15 而非 load_avg 数组）
  const load1 = asNumber(snapshot.cpu?.load1, 0);
  const load5 = asNumber(snapshot.cpu?.load5, 0);
  const load15 = asNumber(snapshot.cpu?.load15, 0);
  const hasLoad = snapshot.cpu?.load1 != null;

  // 网络：CLI 输出为数组，过滤只保留有 IP 的物理接口（排除虚拟/VPN/loopback）
  const allNetInterfaces = asArray<any>(snapshot.network);
  const netInterfaces = allNetInterfaces.filter((n) => {
    const ip = n?.ip;
    return ip && typeof ip === 'string' && ip.trim() !== '';
  });
  // 汇总所有有效接口的速率用于右上角 Badge 和图表
  let totalDlMbs = 0;
  let totalUlMbs = 0;
  for (const n of netInterfaces) {
    totalDlMbs += asNumber(n?.rx_rate_mbs, 0);
    totalUlMbs += asNumber(n?.tx_rate_mbs, 0);
  }
  const dlBytesPerSec = totalDlMbs * 1024 * 1024;
  const ulBytesPerSec = totalUlMbs * 1024 * 1024;

  // 网络历史：使用前端累积的历史数据（CLI 一次性命令无法跨调用保持历史）
  const rxHistory = netRxHistRef.current;
  const txHistory = netTxHistRef.current;
  const hasNetHistory = rxHistory.length > 1;
  const netLabels = rxHistory.length > 0
    ? rxHistory.map((_, i) => {
        const idx = Math.max(0, rxHistory.length - 1 - i);
        return `-${idx * (REFRESH_INTERVAL / 1000)}s`;
      }).reverse()
    : [];

  // GPU：CLI 输出为数组，取第一个
  const gpus = asArray<any>(snapshot.gpu);
  const primaryGpu = gpus.length > 0 ? gpus[0] : null;

  // 磁盘 / 电池 / 进程
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
          {snapshot.hardware?.cpu_model && <Badge tone="accent">{snapshot.hardware.cpu_model}</Badge>}
          <span className="status-uptime">
            {t.uptime()}: <strong>{snapshot.uptime || `${uptimeSec}s`}</strong>
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
                {snapshot.health_score_msg || (healthScore >= 80
                  ? '系统状态良好，无需干预'
                  : healthScore >= 50
                  ? '部分指标偏高，建议关注'
                  : '多项指标异常，建议优化')}
              </p>
              {/* 健康评分颜色标识 */}
              <div className="status-health-legend">
                <span className="status-health-leg-item"><span className="status-health-dot good" />{healthScore >= 80 ? '● ' : ''}{t.normal()} ≥80</span>
                <span className="status-health-leg-item"><span className="status-health-dot warn" />Fair 50-79</span>
                <span className="status-health-leg-item"><span className="status-health-dot critical" />Poor &lt;50</span>
              </div>
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
              subText={`${asNumber(snapshot.cpu?.core_count, 0)} cores`}
            />
            <div className="status-ring-meta">
              {hasLoad && (
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
            subtitle={netInterfaces.map((n) => n?.name).filter(Boolean).join(', ') || '—'}
            action={
              <div className="status-net-stats">
                <Badge tone="good">↓ {formatBytesShort(dlBytesPerSec)}/s</Badge>
                <Badge tone="info">↑ {formatBytesShort(ulBytesPerSec)}/s</Badge>
              </div>
            }
          />
          <div className="status-chart-wrap">
            {hasNetHistory ? (
              <LineChart
                series={[
                  { name: 'Download', color: 'var(--good)', points: rxHistory },
                  { name: 'Upload', color: 'var(--info)', points: txHistory },
                ]}
                labels={netLabels}
                height={180}
                area
                grid
                unit="MB/s"
              />
            ) : (
              <EmptyState title={common.noData()} description="等待网络历史数据（自动刷新累积）" />
            )}
          </div>
          {/* 所有网络接口列表 */}
          {netInterfaces.length > 0 && (
            <div className="status-net-interfaces">
              {netInterfaces.map((n, i) => {
                const name = n?.name ?? '—';
                const ip = n?.ip ?? '';
                const rx = asNumber(n?.rx_rate_mbs, 0) * 1024 * 1024;
                const tx = asNumber(n?.tx_rate_mbs, 0) * 1024 * 1024;
                return (
                  <div key={i} className="status-net-iface">
                    <span className="status-net-iface-name">{name}</span>
                    {ip && <code className="status-net-iface-ip">{ip}</code>}
                    <span className="status-net-iface-rate">
                      <span className="status-net-iface-dl">↓{formatBytesShort(rx)}/s</span>
                      <span className="status-net-iface-ul">↑{formatBytesShort(tx)}/s</span>
                    </span>
                  </div>
                );
              })}
            </div>
          )}
        </Card>

        <Card variant="glass">
          <CardHeader title={t.disk()} subtitle={`${disks.length} volumes`} />
          <div className="status-disks">
            {disks.map((disk, i) => {
              const total = asNumber(disk?.total, 0);
              const used = asNumber(disk?.used, 0);
              // CLI 不输出 free，用 total - used 计算
              const free = total > used ? total - used : 0;
              const usedPct = asNumber(disk?.used_percent, 0) || (total > 0 ? (used / total) * 100 : 0);
              const diskName = disk?.mount || disk?.device || '—';
              return (
                <div key={i} className="status-disk-item">
                  <div className="status-disk-header">
                    <span className="status-disk-name">{diskName}</span>
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
          <CardHeader title={t.thermal()} subtitle={primaryGpu?.name} />
          {snapshot.thermal && (snapshot.thermal.cpu_temp != null || snapshot.thermal.gpu_temp != null || snapshot.thermal.fan_speed != null || snapshot.thermal.system_power != null) ? (
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
              {primaryGpu?.usage != null && (
                <StatTile
                  label="GPU Usage"
                  value={`${asNumber(primaryGpu.usage, 0).toFixed(0)}%`}
                />
              )}
            </div>
          ) : (
            <EmptyState icon="🌡️" title={common.noData()} description="温度传感器数据不可用，可能需要额外权限或第三方工具支持" />
          )}
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
            const memory = asNumber(p?.memory_bytes ?? p?.memory, 0);
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
