const pending = new Map();
let mockTransport = null;
let sequence = 0;

function correlationId() {
  sequence += 1;
  return `ui-${Date.now().toString(36)}-${sequence.toString(36)}`;
}

function isHostAvailable() {
  return Boolean(window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function');
}

function onHostMessage(event) {
  const message = event && event.data;
  if (!message || !message.id || !pending.has(message.id)) return;
  const request = pending.get(message.id);
  pending.delete(message.id);
  if (message.ok === false) {
    const error = new Error(message.error && message.error.message ? message.error.message : 'Operação não concluída.');
    error.code = message.error && message.error.code ? message.error.code : 'HOST_ERROR';
    request.reject(error);
    return;
  }
  request.resolve(message.data);
}

if (typeof window !== 'undefined') {
  if (window.chrome && window.chrome.webview && typeof window.chrome.webview.addEventListener === 'function') {
    window.chrome.webview.addEventListener('message', onHostMessage);
  }
}

export function setBridgeMock(transport) {
  mockTransport = transport;
}

export function clearBridgeMock() {
  mockTransport = null;
}

export function hasDesktopHost() {
  return isHostAvailable() || Boolean(mockTransport);
}

export function callHost(action, payload = {}) {
  const id = correlationId();
  if (mockTransport) {
    return Promise.resolve().then(() => mockTransport({ id, action, payload })).then((response) => {
      if (response && response.ok === false) {
        const error = new Error(response.error && response.error.message ? response.error.message : 'Operação não concluída.');
        error.code = response.error && response.error.code ? response.error.code : 'HOST_ERROR';
        throw error;
      }
      return response && Object.prototype.hasOwnProperty.call(response, 'data') ? response.data : response;
    });
  }
  if (!isHostAvailable()) {
    const error = new Error('Abra o Lineboard pelo aplicativo desktop para acessar o SIC.');
    error.code = 'DESKTOP_REQUIRED';
    return Promise.reject(error);
  }
  return new Promise((resolve, reject) => {
    const timeout = action === 'labels.export' ? 0 : 15000;
    const timer = timeout ? window.setTimeout(() => {
      pending.delete(id);
      const error = new Error('O desktop não respondeu. Tente novamente.');
      error.code = 'HOST_TIMEOUT';
      reject(error);
    }, timeout) : null;
    pending.set(id, {
      resolve: (value) => { if (timer) window.clearTimeout(timer); resolve(value); },
      reject: (error) => { if (timer) window.clearTimeout(timer); reject(error); },
    });
    window.chrome.webview.postMessage({ id, action, payload });
  });
}

export function requestId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  return `${correlationId()}-${Math.random().toString(16).slice(2)}`;
}
