import React, { Component, useCallback, useLayoutEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Renderer } from '@openuidev/react-lang';
import { openuiLibrary, ThemeProvider } from '@openuidev/react-ui';
import '@openuidev/react-ui/index.css';
import 'katex/dist/katex.min.css';
import { contentHeight, bodyPortals } from './contentSize.js';
import './host.css';

const rootElement = document.getElementById('root');
const reactRoot = createRoot(rootElement);
let pendingRequest = null;
let acceptRequest = null;
let activeRequest = null;
let sizeTimer = 0;
let lastSize = null;
let lastDiagnostics = null;

function emit(kind, payload, sourceID = activeRequest?.sourceID ?? null) {
  window.webkit?.messageHandlers?.picoOpenUI?.postMessage({
    kind,
    payload: payload == null ? payload : JSON.parse(JSON.stringify(payload)),
    sourceID,
  });
}

function reportErrors(errors, sourceID = activeRequest?.sourceID ?? null) {
  const diagnostics = (Array.isArray(errors) ? errors : [errors]).slice(0, 20).map(error => ({
    source: String(error?.source ?? 'runtime').slice(0, 80),
    code: String(error?.code ?? 'render-error').slice(0, 80),
    message: String(error?.message ?? error).slice(0, 800),
    ...(error?.statementId ? { statementId: String(error.statementId).slice(0, 120) } : {}),
    ...(error?.component ? { component: String(error.component).slice(0, 120) } : {}),
    ...(error?.severity ? { severity: String(error.severity).slice(0, 40) } : {}),
  }));
  const signature = JSON.stringify(diagnostics);
  if (lastDiagnostics?.sourceID === sourceID && lastDiagnostics.signature === signature) return;
  lastDiagnostics = { sourceID, signature };
  emit('error', diagnostics, sourceID);
}

function scheduleSize() {
  if (sizeTimer) return;
  // A hosted WKWebView can be temporarily inactive; measurement must not
  // depend on requestAnimationFrame, which WebKit pauses for inactive pages.
  sizeTimer = window.setTimeout(() => {
    sizeTimer = 0;
    const content = rootElement.querySelector('[data-source-id]');
    if (!content) return;
    const sourceID = content.dataset.sourceId;
    if (sourceID !== activeRequest?.sourceID) return;
    const rect = rootElement.getBoundingClientRect();
    // Wait until the host supplies space beyond the root's horizontal padding.
    if (rect.width <= 32) return;
    const height = contentHeight(rootElement, bodyPortals(rootElement));
    if (!Number.isFinite(height) || height <= 0) {
      reportErrors([{ code: 'invalid-content-height', message: 'OpenUI content has an invalid measured height.' }], sourceID);
      return;
    }
    if (lastSize?.sourceID === sourceID && lastSize.height === height) return;
    lastSize = { height, sourceID };
    emit('size', { height }, sourceID);
  }, 16);
}

class ContentBoundary extends Component {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error) { reportErrors([error], this.props.sourceID); }
  render() {
    return this.state.failed ? <p role="alert">OpenUI content is unavailable.</p> : this.props.children;
  }
}

function RenderedChild({ request }) {
  const sourceID = request.sourceID;
  const onAction = useCallback(event => {
    if (sourceID === activeRequest?.sourceID) emit('action', event, sourceID);
  }, [sourceID]);
  const onError = useCallback(errors => {
    if (sourceID !== activeRequest?.sourceID) return;
    reportErrors(errors, sourceID);
    scheduleSize();
  }, [sourceID]);
  useLayoutEffect(scheduleSize, [request]);

  return <div data-source-id={sourceID}>
    <ThemeProvider mode={request.colorScheme}>
      <ContentBoundary key={sourceID} sourceID={sourceID}>
        <Renderer
          key={sourceID}
          response={request.source}
          library={openuiLibrary}
          isStreaming={request.isStreaming}
          onAction={onAction}
          onError={onError}
          publishObservability={false}
        />
      </ContentBoundary>
    </ThemeProvider>
  </div>;
}

function App() {
  const [request, setRequest] = useState(null);
  useLayoutEffect(() => {
    acceptRequest = setRequest;
    if (pendingRequest) { setRequest(pendingRequest); pendingRequest = null; }
    return () => { acceptRequest = null; };
  }, []);
  return request ? <RenderedChild request={request} /> : null;
}

window.picoOpenUI = {
  render(request) {
    if (!request || typeof request.source !== 'string' || typeof request.sourceID !== 'string' || !request.sourceID) {
      reportErrors([{ code: 'invalid-native-request', message: 'OpenUI requires source and a source identity.' }]);
      return false;
    }
    if (request.source.length > 100000) {
      reportErrors([{ code: 'source-limit', message: 'OpenUI source exceeds the supported length.' }], request.sourceID);
      return false;
    }
    const next = {
      source: request.source,
      sourceID: request.sourceID,
      colorScheme: request.colorScheme === 'dark' ? 'dark' : 'light',
      isStreaming: request.isStreaming === true,
    };
    if (activeRequest?.sourceID !== next.sourceID) {
      lastSize = null;
      lastDiagnostics = null;
    } else if (activeRequest.source === next.source && activeRequest.colorScheme === next.colorScheme
               && activeRequest.isStreaming === next.isStreaming) {
      scheduleSize();
      return true;
    }
    activeRequest = next;
    document.documentElement.style.colorScheme = next.colorScheme;
    if (acceptRequest) acceptRequest(next);
    else pendingRequest = next;
    scheduleSize();
    return true;
  },
};

const contentObserver = new ResizeObserver(scheduleSize);
contentObserver.observe(rootElement);
let observedPortals = new Set();
function observePortals() {
  const next = new Set(bodyPortals(rootElement));
  for (const portal of observedPortals) {
    if (!next.has(portal)) contentObserver.unobserve(portal);
  }
  for (const portal of next) {
    if (!observedPortals.has(portal)) contentObserver.observe(portal);
  }
  observedPortals = next;
}
// Official controls can portal into document.body, outside the measured React
// root. Observe only those siblings, so their open/close, placement and reflow
// update the native frame without observing mutations in the ordinary UI tree.
new MutationObserver(records => {
  const outsideRoot = records.some(record => record.target !== rootElement && !rootElement.contains(record.target));
  if (!outsideRoot) return;
  observePortals();
  scheduleSize();
}).observe(document.body, {
  childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'hidden'],
});
observePortals();
window.addEventListener('resize', scheduleSize);
window.addEventListener('error', event => reportErrors([event.message]));
window.addEventListener('unhandledrejection', event => reportErrors([event.reason]));
document.fonts?.ready.then(scheduleSize);
reactRoot.render(<App />);
emit('ready', { versions: __PICO_OPENUI_VERSIONS__ }, null);
