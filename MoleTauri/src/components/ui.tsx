// UI 原子组件库
import { ReactNode, ButtonHTMLAttributes } from 'react';

// ---- Card ----
interface CardProps {
  children: ReactNode;
  className?: string;
  variant?: 'default' | 'glass' | 'elevated' | 'compact' | 'flush';
  tone?: 'default' | 'success' | 'warn' | 'critical' | 'info' | 'accent' | 'success-soft' | 'warn-soft' | 'critical-soft' | 'info-soft';
}

export function Card({ children, className = '', variant = 'default', tone = 'default' }: CardProps) {
  const classes = ['card'];
  if (variant !== 'default') classes.push(variant);
  if (tone !== 'default') classes.push(tone);
  if (className) classes.push(className);
  return <div className={classes.join(' ')}>{children}</div>;
}

export function CardHeader({ title, icon, subtitle, action }: { title: ReactNode; icon?: ReactNode; subtitle?: ReactNode; action?: ReactNode }) {
  return (
    <div className="card-header">
      <div className="card-title">
        {icon && <span className="card-title-icon">{icon}</span>}
        {title}
        {subtitle && <span className="card-subtitle">{subtitle}</span>}
      </div>
      {action}
    </div>
  );
}

// ---- Button ----
interface BtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
  size?: 'sm' | 'md' | 'lg' | 'icon';
  block?: boolean;
}

export function Button({ variant = 'secondary', size = 'md', block, className = '', children, ...props }: BtnProps) {
  const classes = ['btn', `btn-${variant}`];
  if (size !== 'md') classes.push(`btn-${size}`);
  if (block) classes.push('btn-block');
  if (className) classes.push(className);
  return <button className={classes.join(' ')} {...props}>{children}</button>;
}

// ---- Badge ----
export function Badge({ children, tone = 'default', className = '' }: { children: ReactNode; tone?: 'default' | 'good' | 'warn' | 'critical' | 'info' | 'accent' | 'purple'; className?: string }) {
  const cls = tone === 'default' ? 'badge' : `badge badge-${tone}`;
  return <span className={`${cls} ${className}`}>{children}</span>;
}

export function Tag({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <span className={`tag ${className}`}>{children}</span>;
}

// ---- ProgressBar ----
export function ProgressBar({ value, max = 100, tone = 'accent', striped, thin, thick, className = '' }: { value: number; max?: number; tone?: 'accent' | 'good' | 'warn' | 'critical' | 'info'; striped?: boolean; thin?: boolean; thick?: boolean; className?: string }) {
  const pct = Math.min(100, Math.max(0, (value / max) * 100));
  const classes = ['progress-bar'];
  if (thin) classes.push('progress-bar-thin');
  if (thick) classes.push('progress-bar-thick');
  if (className) classes.push(className);
  return (
    <div className={classes.join(' ')}>
      <div className={`progress-bar-fill ${tone} ${striped ? 'striped' : ''}`} style={{ width: `${pct}%` }} />
    </div>
  );
}

// ---- Spinner ----
export function Spinner({ size = 'md', className = '' }: { size?: 'sm' | 'md' | 'lg'; className?: string }) {
  const cls = size === 'md' ? 'spinner' : `spinner spinner-${size}`;
  return <div className={`${cls} ${className}`} />;
}

// ---- Toggle ----
export function Toggle({ checked, onChange, label, description }: { checked: boolean; onChange: (v: boolean) => void; label?: ReactNode; description?: ReactNode }) {
  return (
    <div>
      <label className="toggle">
        <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
        <span className="toggle-switch" />
        {label && <span className="toggle-label">{label}</span>}
      </label>
      {description && <div className="toggle-desc">{description}</div>}
    </div>
  );
}

// ---- Checkbox ----
export function Checkbox({ checked, onChange, className = '' }: { checked: boolean; onChange: (v: boolean) => void; className?: string }) {
  return (
    <div className={`checkbox ${checked ? 'checked' : ''} ${className}`} onClick={(e) => { e.stopPropagation(); onChange(!checked); }} />
  );
}

// ---- EmptyState ----
export function EmptyState({ icon, title, description, action }: { icon?: ReactNode; title: ReactNode; description?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty-state">
      {icon && <div className="empty-state-icon">{icon}</div>}
      <div className="empty-state-title">{title}</div>
      {description && <div className="empty-state-desc">{description}</div>}
      {action && <div className="mt-3">{action}</div>}
    </div>
  );
}

// ---- LoadingOverlay ----
export function LoadingOverlay({ text, subtext }: { text?: ReactNode; subtext?: ReactNode }) {
  return (
    <div className="loading-overlay">
      <Spinner size="lg" />
      {text && <div className="loading-text">{text}</div>}
      {subtext && <div className="loading-text-mono">{subtext}</div>}
    </div>
  );
}

// ---- Steps ----
export function Steps({ current, labels }: { current: number; labels: string[] }) {
  return (
    <div className="steps">
      {labels.map((label, i) => {
        const stepNum = i + 1;
        const status = stepNum < current ? 'done' : stepNum === current ? 'active' : '';
        return (
          <div key={i} className="flex items-center gap-2">
            <div className={`step ${status}`}>
              <div className={`step-dot ${status}`}>
                {status === 'done' ? '✓' : stepNum}
              </div>
              <span className={`step-label ${status}`}>{label}</span>
            </div>
            {i < labels.length - 1 && <div className={`step-connector ${stepNum < current ? 'done' : ''}`} />}
          </div>
        );
      })}
    </div>
  );
}

// ---- Banner ----
export function Banner({ tone = 'info', icon, title, children, action }: { tone?: 'info' | 'warn' | 'success' | 'error'; icon?: ReactNode; title?: ReactNode; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className={`banner banner-${tone}`}>
      {icon && <span className="banner-icon">{icon}</span>}
      <div className="banner-content">
        {title && <div className="banner-title">{title}</div>}
        {children && <div className="banner-desc">{children}</div>}
      </div>
      {action}
    </div>
  );
}

// ---- StatTile ----
export function StatTile({ label, value, delta, deltaUp }: { label: ReactNode; value: ReactNode; delta?: ReactNode; deltaUp?: boolean }) {
  return (
    <div className="stat-tile">
      <div className="stat-tile-label">{label}</div>
      <div className="stat-tile-value">{value}</div>
      {delta && <div className={`stat-tile-delta ${deltaUp ? 'up' : 'down'}`}>{delta}</div>}
    </div>
  );
}

// ---- KVList ----
export function KVList({ items }: { items: Array<{ label: ReactNode; value: ReactNode }> }) {
  return (
    <div className="kv-list">
      {items.map((item, i) => (
        <div key={i} className="kv-row">
          <span className="kv-label">{item.label}</span>
          <span className="kv-value">{item.value}</span>
        </div>
      ))}
    </div>
  );
}

// ---- ConsoleOutput ----
import { StreamingLine } from '../lib/cli';

export function ConsoleOutput({ lines, maxLines = 500 }: { lines: StreamingLine[]; maxLines?: number }) {
  const visible = lines.slice(-maxLines);
  return (
    <div className="console">
      {visible.map((line, i) => (
        <div key={i} className={`console-line ${line.type}`}>{line.text || '\u00A0'}</div>
      ))}
    </div>
  );
}

// ---- Divider ----
export function Divider({ label }: { label?: string }) {
  if (label) {
    return (
      <div className="divider-label">
        <span className="divider-label-text">{label}</span>
      </div>
    );
  }
  return <div className="divider" />;
}

// ---- PageHeader ----
export function PageHeader({ icon, title, subtitle }: { icon: ReactNode; title: ReactNode; subtitle?: ReactNode }) {
  return (
    <div className="page-header">
      <div className="page-header-row">
        <div className="page-header-icon">{icon}</div>
        <h1>{title}</h1>
      </div>
      {subtitle && <p className="page-header-desc">{subtitle}</p>}
    </div>
  );
}

// ---- Modal ----
import { useEffect } from 'react';

export function Modal({ open, onClose, title, children, footer }: { open: boolean; onClose: () => void; title: ReactNode; children: ReactNode; footer?: ReactNode }) {
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div className="modal-title">{title}</div>
          <button className="icon-btn" onClick={onClose}>✕</button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>
  );
}
