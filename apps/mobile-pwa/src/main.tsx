import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from './app/App';
import { installAppUpdateRecovery } from './app/appUpdateRecovery';
import './styles.css';
import { registerSW } from 'virtual:pwa-register';

installAppUpdateRecovery();
registerSW({ immediate: true });

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
