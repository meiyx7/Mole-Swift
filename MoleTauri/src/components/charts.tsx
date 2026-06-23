// SVG 图表组件：RingGauge / LineChart / Treemap
// 纯 SVG 实现，无外部图表库依赖，主题通过 CSS 变量继承。
import { useMemo, useState } from 'react';

// ===========================================================================
// RingGauge：环形仪表盘
// 用途：Status 健康评分、CPU/内存占用率
// ===========================================================================
export interface RingGaugeProps {
  /** 当前值（0..max） */
  value: number;
  /** 最大值，默认 100 */
  max?: number;
  /** 半径（px），默认 56 */
  radius?: number;
  /** 描边宽度，默认 10 */
  stroke?: number;
  /** 中心标题（小字） */
  label?: string;
  /** 中心数值（大字），不传则自动用 value/max */
  centerText?: string;
  /** 中心副标题 */
  subText?: string;
  /** 色调：accent(品牌绿) / success / warn / critical / auto(按值变色) */
  tone?: 'accent' | 'success' | 'warn' | 'critical' | 'auto';
  /** 是否显示刻度 */
  showTicks?: boolean;
  /** 尺寸：sm/md/lg */
  size?: 'sm' | 'md' | 'lg';
}

export function RingGauge({
  value,
  max = 100,
  radius = 56,
  stroke = 10,
  label,
  centerText,
  subText,
  tone = 'accent',
  showTicks = false,
  size = 'md',
}: RingGaugeProps) {
  const clamped = Math.max(0, Math.min(max, value));
  const ratio = max > 0 ? clamped / max : 0;
  const diameter = radius * 2;
  const circumference = 2 * Math.PI * radius;
  // 从顶部开始，顺时针填充
  const offset = circumference * (1 - ratio);

  // auto 色调：根据比例自动切换
  const resolvedTone =
    tone === 'auto'
      ? ratio < 0.5
        ? 'success'
        : ratio < 0.8
        ? 'warn'
        : 'critical'
      : tone;

  const sizePx = size === 'sm' ? diameter + stroke : size === 'lg' ? diameter + stroke + 40 : diameter + stroke + 20;
  const fontSize = size === 'sm' ? 18 : size === 'lg' ? 32 : 24;

  // 刻度
  const ticks = useMemo(() => {
    if (!showTicks) return [];
    const arr: { x1: number; y1: number; x2: number; y2: number }[] = [];
    const tickCount = 12;
    const inner = radius + stroke / 2 + 2;
    const outer = inner + 4;
    for (let i = 0; i < tickCount; i++) {
      const angle = (i / tickCount) * Math.PI * 2 - Math.PI / 2;
      arr.push({
        x1: radius + Math.cos(angle) * inner,
        y1: radius + Math.sin(angle) * inner,
        x2: radius + Math.cos(angle) * outer,
        y2: radius + Math.sin(angle) * outer,
      });
    }
    return arr;
  }, [radius, stroke, showTicks]);

  return (
    <div
      className={`ring-gauge ring-gauge-${resolvedTone} ring-gauge-${size}`}
      style={{ width: sizePx, height: sizePx }}
    >
      <svg width={sizePx} height={sizePx} viewBox={`0 0 ${sizePx} ${sizePx}`}>
        <g transform={`translate(${(sizePx - diameter) / 2 - stroke / 2}, ${(sizePx - diameter) / 2 - stroke / 2})`}>
          {/* 背景轨道 */}
          <circle
            cx={radius}
            cy={radius}
            r={radius}
            fill="none"
            strokeWidth={stroke}
            className="ring-gauge-track"
          />
          {/* 进度弧 */}
          <circle
            cx={radius}
            cy={radius}
            r={radius}
            fill="none"
            strokeWidth={stroke}
            strokeLinecap="round"
            strokeDasharray={circumference}
            strokeDashoffset={offset}
            transform={`rotate(-90 ${radius} ${radius})`}
            className="ring-gauge-progress"
          />
          {/* 刻度 */}
          {ticks.map((t, i) => (
            <line key={i} x1={t.x1} y1={t.y1} x2={t.x2} y2={t.y2} className="ring-gauge-tick" />
          ))}
        </g>
        {/* 中心文字 */}
        <text
          x={sizePx / 2}
          y={sizePx / 2}
          textAnchor="middle"
          dominantBaseline="central"
          className="ring-gauge-value"
          style={{ fontSize }}
        >
          {centerText ?? `${Math.round(ratio * 100)}`}
        </text>
        {label && (
          <text
            x={sizePx / 2}
            y={sizePx / 2 - fontSize / 2 - 6}
            textAnchor="middle"
            className="ring-gauge-label"
          >
            {label}
          </text>
        )}
        {subText && (
          <text
            x={sizePx / 2}
            y={sizePx / 2 + fontSize / 2 + 12}
            textAnchor="middle"
            className="ring-gauge-sub"
          >
            {subText}
          </text>
        )}
      </svg>
    </div>
  );
}

// ===========================================================================
// LineChart：折线图
// 用途：Status 网络历史、CPU/内存趋势
// ===========================================================================
export interface LineSeries {
  name: string;
  color?: string;
  points: number[];
}

export interface LineChartProps {
  series: LineSeries[];
  /** x 轴标签 */
  labels?: string[];
  /** y 轴最大值（不传则自动） */
  yMax?: number;
  /** y 轴最小值（不传则 0） */
  yMin?: number;
  /** 宽度，默认 100% */
  width?: number | string;
  /** 高度，默认 160 */
  height?: number;
  /** 是否显示网格 */
  grid?: boolean;
  /** 是否显示面积填充 */
  area?: boolean;
  /** 是否显示图例 */
  legend?: boolean;
  /** y 轴单位 */
  unit?: string;
}

export function LineChart({
  series,
  labels,
  yMax,
  yMin = 0,
  width = '100%',
  height = 160,
  grid = true,
  area = true,
  legend = true,
  unit,
}: LineChartProps) {
  const padding = { top: 12, right: 12, bottom: labels ? 22 : 8, left: 36 };
  const w = 480; // viewBox 宽度，实际宽度由 CSS 控制
  const h = height;
  const innerW = w - padding.left - padding.right;
  const innerH = h - padding.top - padding.bottom;

  // 计算 y 范围
  const allPoints = series.flatMap((s) => s.points);
  const dataMax = allPoints.length > 0 ? Math.max(...allPoints) : 1;
  const max = yMax ?? Math.ceil(dataMax * 1.1);
  const min = yMin;
  const range = max - min || 1;

  const pointCount = Math.max(...series.map((s) => s.points.length), 0);
  const xStep = pointCount > 1 ? innerW / (pointCount - 1) : 0;

  const toX = (i: number) => padding.left + i * xStep;
  const toY = (v: number) => padding.top + innerH - ((v - min) / range) * innerH;

  // 网格线（4 条横线）
  const gridLines = [0, 0.25, 0.5, 0.75, 1].map((r) => {
    const y = padding.top + innerH - r * innerH;
    const v = min + r * range;
    return { y, v };
  });

  return (
    <div className="line-chart" style={{ width }}>
      <svg width="100%" height={h} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
        {/* 网格 */}
        {grid &&
          gridLines.map((g, i) => (
            <g key={i}>
              <line
                x1={padding.left}
                y1={g.y}
                x2={w - padding.right}
                y2={g.y}
                className="chart-grid-line"
              />
              <text x={padding.left - 6} y={g.y + 3} textAnchor="end" className="chart-axis-label">
                {formatTick(g.v)}
                {unit && i === 0 ? unit : ''}
              </text>
            </g>
          ))}

        {/* x 轴标签 */}
        {labels &&
          labels.map((lab, i) => {
            if (pointCount === 0) return null;
            // 只显示首/中/尾，避免拥挤
            const showIdx = [0, Math.floor(pointCount / 2), pointCount - 1];
            if (!showIdx.includes(i)) return null;
            return (
              <text
                key={i}
                x={toX(i)}
                y={h - 6}
                textAnchor={i === 0 ? 'start' : i === pointCount - 1 ? 'end' : 'middle'}
                className="chart-axis-label"
              >
                {lab}
              </text>
            );
          })}

        {/* 折线 + 面积 */}
        {series.map((s, si) => {
          if (s.points.length === 0) return null;
          const linePath = s.points
            .map((v, i) => `${i === 0 ? 'M' : 'L'} ${toX(i)} ${toY(v)}`)
            .join(' ');
          const areaPath =
            s.points.length > 1
              ? `${linePath} L ${toX(s.points.length - 1)} ${padding.top + innerH} L ${toX(0)} ${padding.top + innerH} Z`
              : '';
          return (
            <g key={si}>
              {area && areaPath && (
                <path d={areaPath} className={`chart-area chart-area-${si}`} fill={s.color ?? 'var(--accent)'} />
              )}
              <path
                d={linePath}
                fill="none"
                stroke={s.color ?? 'var(--accent)'}
                strokeWidth={2}
                strokeLinejoin="round"
                strokeLinecap="round"
                className="chart-line"
              />
              {/* 数据点 */}
              {s.points.map((v, i) => (
                <circle
                  key={i}
                  cx={toX(i)}
                  cy={toY(v)}
                  r={2.5}
                  fill={s.color ?? 'var(--accent)'}
                  className="chart-point"
                />
              ))}
            </g>
          );
        })}
      </svg>
      {legend && series.length > 0 && (
        <div className="chart-legend">
          {series.map((s, i) => (
            <span key={i} className="chart-legend-item">
              <span className="chart-legend-dot" style={{ background: s.color ?? 'var(--accent)' }} />
              {s.name}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function formatTick(v: number): string {
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  if (Number.isInteger(v)) return String(v);
  return v.toFixed(1);
}

// ===========================================================================
// Treemap：矩形树图
// 用途：Analyze 磁盘空间分布可视化
// 算法：Squarified Treemap（参考 MoleApp/Components/TreemapView.swift）
// ===========================================================================
export interface TreemapNode {
  /** 节点名称 */
  name: string;
  /** 权重（字节数） */
  value: number;
  /** 子节点（有子节点时 value 可省略，自动求和） */
  children?: TreemapNode[];
  /** 原始路径（用于点击下钻） */
  path?: string;
  /** 是否为目录 */
  isDir?: boolean;
  /** 自定义颜色（不传则按 hash 自动分配） */
  color?: string;
}

export interface TreemapProps {
  /** 根节点 */
  root: TreemapNode;
  /** 宽度，默认 100% */
  width?: number | string;
  /** 高度，默认 320 */
  height?: number;
  /** 点击节点回调（用于下钻） */
  onSelect?: (node: TreemapNode) => void;
  /** 当前路径面包屑（用于显示） */
  breadcrumb?: string[];
  /** 最小可见权重（小于此值的合并为 Other） */
  minWeight?: number;
}

interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface LaidOutNode extends TreemapNode {
  rect: Rect;
  depth: number;
  totalValue: number;
}

export function Treemap({
  root,
  width = '100%',
  height = 320,
  onSelect,
  breadcrumb,
  minWeight = 0,
}: TreemapProps) {
  const [hovered, setHovered] = useState<string | null>(null);

  const laidOut = useMemo(() => {
    const totalValue = computeValue(root);
    if (totalValue <= 0) return [];
    const w = 800; // viewBox 宽度
    const h = height;
    const result: LaidOutNode[] = [];
    // 顶层节点排序并合并小节点
    const top = (root.children ?? [root])
      .filter((n) => computeValue(n) > 0)
      .sort((a, b) => computeValue(b) - computeValue(a));

    // 合并小节点为 Other
    let nodes = top;
    if (minWeight > 0) {
      const big = top.filter((n) => computeValue(n) >= minWeight);
      const small = top.filter((n) => computeValue(n) < minWeight);
      if (small.length > 0) {
        const otherValue = small.reduce((s, n) => s + computeValue(n), 0);
        nodes = [...big, { name: 'Other', value: otherValue, children: small }];
      }
    }

    squarify(nodes, { x: 0, y: 0, w, h }, 0, result, totalValue);
    return result;
  }, [root, height, minWeight]);

  if (laidOut.length === 0) {
    return (
      <div className="treemap-empty" style={{ width, height }}>
        <span className="treemap-empty-text">No data</span>
      </div>
    );
  }

  return (
    <div className="treemap" style={{ width }}>
      {breadcrumb && breadcrumb.length > 0 && (
        <div className="treemap-breadcrumb">
          {breadcrumb.map((b, i) => (
            <span key={i} className="treemap-crumb">
              {i > 0 && <span className="treemap-crumb-sep">/</span>}
              {b}
            </span>
          ))}
        </div>
      )}
      <svg
        width="100%"
        height={height}
        viewBox={`0 0 800 ${height}`}
        preserveAspectRatio="none"
        className="treemap-svg"
      >
        {laidOut.map((n, i) => {
          const isHovered = hovered === (n.path ?? n.name);
          const color = n.color ?? colorForName(n.name, i);
          const labelVisible = n.rect.w > 60 && n.rect.h > 28;
          const valueLabel = formatBytes(n.totalValue);
          const valueVisible = n.rect.w > 80 && n.rect.h > 44;
          return (
            <g
              key={i}
              className={`treemap-cell ${isHovered ? 'treemap-cell-hover' : ''} ${onSelect ? 'treemap-cell-clickable' : ''}`}
              onMouseEnter={() => setHovered(n.path ?? n.name)}
              onMouseLeave={() => setHovered(null)}
              onClick={() => onSelect?.(n)}
            >
              <rect
                x={n.rect.x + 1}
                y={n.rect.y + 1}
                width={Math.max(0, n.rect.w - 2)}
                height={Math.max(0, n.rect.h - 2)}
                fill={color}
                rx={3}
                className="treemap-rect"
              />
              {labelVisible && (
                <text
                  x={n.rect.x + 8}
                  y={n.rect.y + 18}
                  className="treemap-label"
                >
                  {truncate(n.name, Math.floor(n.rect.w / 7))}
                </text>
              )}
              {valueVisible && (
                <text
                  x={n.rect.x + 8}
                  y={n.rect.y + 34}
                  className="treemap-value"
                >
                  {valueLabel}
                </text>
              )}
            </g>
          );
        })}
      </svg>
    </div>
  );
}

// ---- Squarified Treemap 算法 ----
// 参考：Bruls, Huizing, van Wijk. "Squarified Treemaps" (2000)
function squarify(
  nodes: TreemapNode[],
  rect: Rect,
  depth: number,
  result: LaidOutNode[],
  _totalValue: number,
) {
  if (nodes.length === 0) return;
  const items = nodes.map((n) => ({ node: n, value: computeValue(n) }));
  const total = items.reduce((s, it) => s + it.value, 0);
  if (total <= 0 || rect.w <= 0 || rect.h <= 0) return;

  // 按比例缩放到当前矩形面积
  const area = rect.w * rect.h;
  const scale = area / total;
  const scaled = items.map((it) => ({ ...it, area: it.value * scale }));

  let remaining = [...scaled];
  let currentRect = { ...rect };
  let row: typeof scaled = [];

  const worst = (r: typeof scaled, w: number) => {
    if (r.length === 0) return Infinity;
    const areas = r.map((x) => x.area);
    const maxA = Math.max(...areas);
    const minA = Math.min(...areas);
    const sum = areas.reduce((s, a) => s + a, 0);
    const w2 = w * w;
    const s2 = sum * sum;
    return Math.max((w2 * maxA) / s2, s2 / (w2 * minA));
  };

  const layoutRow = (r: typeof scaled, side: number, horizontal: boolean) => {
    const sum = r.reduce((s, x) => s + x.area, 0);
    let offset = 0;
    for (const it of r) {
      const frac = it.area / sum;
      if (horizontal) {
        const h = frac * currentRect.h;
        result.push({
          ...it.node,
          rect: {
            x: currentRect.x,
            y: currentRect.y + offset,
            w: side,
            h,
          },
          depth,
          totalValue: it.value,
        });
        offset += h;
      } else {
        const w = frac * currentRect.w;
        result.push({
          ...it.node,
          rect: {
            x: currentRect.x + offset,
            y: currentRect.y,
            w,
            h: side,
          },
          depth,
          totalValue: it.value,
        });
        offset += w;
      }
    }
    // 缩小剩余矩形
    if (horizontal) {
      currentRect = {
        x: currentRect.x + side,
        y: currentRect.y,
        w: currentRect.w - side,
        h: currentRect.h,
      };
    } else {
      currentRect = {
        x: currentRect.x,
        y: currentRect.y + side,
        w: currentRect.w,
        h: currentRect.h - side,
      };
    }
  };

  while (remaining.length > 0) {
    const shortest = Math.min(currentRect.w, currentRect.h);
    const next = remaining[0];
    const newRow = [...row, next];

    if (row.length === 0 || worst(row, shortest) >= worst(newRow, shortest)) {
      row = newRow;
      remaining = remaining.slice(1);
      // 如果是最后一个，直接布局
      if (remaining.length === 0) {
        const horizontal = currentRect.w >= currentRect.h;
        layoutRow(row, shortest, horizontal);
        row = [];
      }
    } else {
      // 布局当前 row
      const horizontal = currentRect.w >= currentRect.h;
      layoutRow(row, shortest, horizontal);
      row = [];
    }
  }
}

function computeValue(n: TreemapNode): number {
  if (n.children && n.children.length > 0) {
    return n.children.reduce((s, c) => s + computeValue(c), 0);
  }
  return n.value ?? 0;
}

function truncate(s: string, maxLen: number): string {
  if (maxLen <= 0) return '';
  if (s.length <= maxLen) return s;
  if (maxLen <= 1) return s[0];
  return s.slice(0, maxLen - 1) + '…';
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const v = bytes / Math.pow(1024, i);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

// 基于名称 hash 生成稳定的颜色（在品牌色系内变化）
const TREEMAP_PALETTE = [
  '#4ade80', // green-400
  '#22d3ee', // cyan-400
  '#a78bfa', // violet-400
  '#fbbf24', // amber-400
  '#fb7185', // rose-400
  '#60a5fa', // blue-400
  '#34d399', // emerald-400
  '#f472b6', // pink-400
  '#c084fc', // purple-400
  '#facc15', // yellow-400
];

function colorForName(name: string, idx: number): string {
  // 用 idx 优先，保证顺序稳定
  if (idx < TREEMAP_PALETTE.length) return TREEMAP_PALETTE[idx];
  // 否则 hash
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = (hash * 31 + name.charCodeAt(i)) | 0;
  }
  return TREEMAP_PALETTE[Math.abs(hash) % TREEMAP_PALETTE.length];
}
