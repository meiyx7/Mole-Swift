import { useState } from 'react';
import Sidebar from './components/Sidebar';
import Clean from './components/Clean';
import Analyze from './components/Analyze';
import Status from './components/Status';
import Optimize from './components/Optimize';
import Uninstall from './components/Uninstall';
import Settings from './components/Settings';
import UpdateChecker from './components/UpdateChecker';

type Page = 'clean' | 'analyze' | 'status' | 'optimize' | 'uninstall' | 'settings';

export default function App() {
  const [page, setPage] = useState<Page>('clean');

  const renderPage = () => {
    switch (page) {
      case 'clean': return <Clean />;
      case 'analyze': return <Analyze />;
      case 'status': return <Status />;
      case 'optimize': return <Optimize />;
      case 'uninstall': return <Uninstall />;
      case 'settings': return <Settings />;
    }
  };

  return (
    <div className="app">
      <Sidebar current={page} onNavigate={setPage} />
      <main className="main-content">
        <UpdateChecker />
        {renderPage()}
      </main>
    </div>
  );
}
