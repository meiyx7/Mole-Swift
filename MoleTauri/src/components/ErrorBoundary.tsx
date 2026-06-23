// React Error Boundary：捕获子组件渲染异常，防止白屏
import { Component, ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // 输出到控制台，方便在终端中查看
    console.error('[ErrorBoundary]', error, info.componentStack);
  }

  handleReset = () => {
    this.setState({ hasError: false, error: null });
  };

  render() {
    if (this.state.hasError) {
      return (
        <div className="error-boundary">
          <div className="error-boundary-icon">⚠️</div>
          <h2 className="error-boundary-title">页面渲染出错</h2>
          <p className="error-boundary-desc">
            {this.state.error?.message || '未知错误'}
          </p>
          {this.state.error?.stack && (
            <details className="error-boundary-details">
              <summary>堆栈信息</summary>
              <pre>{this.state.error.stack}</pre>
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
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}
