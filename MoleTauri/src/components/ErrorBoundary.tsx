// React Error Boundary：捕获子组件渲染异常，防止白屏
// 捕获到的错误会同时写入应用日志文件，方便在日志页面查看。
import { Component, ReactNode } from 'react';
import { writeLog, copyToClipboard } from '../lib/cli';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
  componentStack: string | null;
  copied: boolean;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null, componentStack: null, copied: false };
  }

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    const stack = info.componentStack || '';
    console.error('[ErrorBoundary]', error, stack);
    this.setState({ componentStack: stack });
    // 写入应用日志文件，供日志页面查看
    try {
      writeLog('error', `页面渲染异常: ${error.message}\nStack: ${error.stack || ''}\nComponentStack: ${stack}`).catch(() => {});
    } catch {
      // ignore
    }
  }

  handleReset = () => {
    this.setState({ hasError: false, error: null, componentStack: null, copied: false });
  };

  handleCopy = async () => {
    const err = this.state.error;
    if (!err) return;
    const text = [
      `Error: ${err.message}`,
      ``,
      `Stack:`,
      err.stack || '(no stack)',
      ``,
      `Component Stack:`,
      this.state.componentStack || '(none)',
    ].join('\n');
    try {
      await copyToClipboard(text);
      this.setState({ copied: true });
      setTimeout(() => this.setState({ copied: false }), 2000);
    } catch {
      // ignore
    }
  };

  render() {
    if (this.state.hasError) {
      const err = this.state.error;
      return (
        <div className="error-boundary">
          <div className="error-boundary-icon">⚠️</div>
          <h2 className="error-boundary-title">页面渲染出错</h2>
          <p className="error-boundary-desc">
            {err?.message || '未知错误'}
          </p>
          {err?.stack && (
            <details className="error-boundary-details" open>
              <summary>错误堆栈（点击复制）</summary>
              <pre>{err.stack}</pre>
            </details>
          )}
          {this.state.componentStack && (
            <details className="error-boundary-details">
              <summary>组件堆栈</summary>
              <pre>{this.state.componentStack}</pre>
            </details>
          )}
          <div className="error-boundary-actions">
            <button className="btn btn-primary" onClick={this.handleReset}>
              重试
            </button>
            <button
              className="btn btn-secondary"
              onClick={() => window.location.reload()}
            >
              刷新页面
            </button>
            <button
              className="btn btn-secondary"
              onClick={this.handleCopy}
            >
              {this.state.copied ? '✓ 已复制' : '复制错误信息'}
            </button>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}
