import { MantineProvider } from '@mantine/core';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import App from './App.jsx';
import { clearBridgeMock, setBridgeMock } from './bridge.js';
import './styles.css';

const unit = (overrides = {}) => ({
  stock_item_id: 'unit-1', product_id: 'product-1', revision: 1, barcode: 'SLB-000000000001', name: 'Camiseta básica', brand: 'Laboratório',
  color: 'Preta', size: 'M', cost: 35, price: 69.9, quantity: 1, expected_quantity: 1, internal_code: 'CAM-001', location: 'A1', photo_path: '', notes: '',
  icms: 7.25, conflict: false, ...overrides,
});

function bootstrap() {
  const first = unit();
  return { catalog: [first, unit({ stock_item_id: 'unit-2', barcode: 'SLB-000000000002', name: 'Calça jeans', color: 'Azul', size: '40', price: 129.9, internal_code: 'CAL-002' }), unit({ stock_item_id: 'unit-3', barcode: 'SLB-000000000003', name: 'Jaqueta leve', color: 'Verde', size: 'G', price: 159.9, internal_code: 'JAQ-003' })], cart: { version: 3, items: [first], total: 69.9 }, mode: 'sandbox', sync_state: 'up_to_date' };
}

function renderApp() {
  return render(<MantineProvider defaultColorScheme="light"><App /></MantineProvider>);
}

describe('Lineboard frontend', () => {
  let calls;
  let delayNextCartAdd;
  let releaseCartAdd;
  beforeEach(() => {
    calls = [];
    delayNextCartAdd = false;
    releaseCartAdd = null;
    vi.spyOn(window, 'open').mockImplementation(() => null);
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'unit.get') return { data: unit() };
      if (action === 'history.list') return { data: { items: [] } };
      if (action === 'labels.preview') return { data: { html: '<!doctype html><html><body>Etiqueta</body></html>' } };
      if (action === 'settings.info') return { data: { address: 'localhost:47831', sync_configured: false, mode: 'sandbox' } };
      if (action === 'pair.open') return { data: { address: 'localhost:47831', pin: '123456', expires_in_seconds: 180 } };
      if (action === 'cart.add' && delayNextCartAdd) {
        delayNextCartAdd = false;
        await new Promise((resolve) => { releaseCartAdd = resolve; });
      }
      return { data: { units: [] } };
    });
  });
  afterEach(() => { clearBridgeMock(); vi.restoreAllMocks(); });

  it('shows the saved product photo in the caixa and keeps initials when unavailable', async () => {
    const photoPath = 'store/checkout-product.jpg';
    setBridgeMock(({ action }) => {
      if (action === 'bootstrap') {
        const data = bootstrap();
        data.cart.items[0] = { ...data.cart.items[0], photo_path: photoPath };
        data.catalog[1].photo_path = photoPath;
        return { data };
      }
      if (action === 'photo.url') return { url: 'https://example.test/checkout-product.jpg' };
      return { data: {} };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    const photo = await screen.findByRole('img', { name: 'Foto de Camiseta básica' });
    expect(photo).toHaveAttribute('src', 'https://example.test/checkout-product.jpg');
    expect(document.querySelector('.pos-item-avatar')).not.toHaveTextContent('CB');
    fireEvent.error(photo);
    expect(screen.queryByRole('img', { name: 'Foto de Camiseta básica' })).not.toBeInTheDocument();
    expect(document.querySelector('.pos-item-avatar')).toHaveTextContent('CB');
    fireEvent.click(screen.getByRole('button', { name: 'Abrir estoque' }));
    expect(await screen.findByRole('img', { name: 'Foto de Calça jeans' })).toHaveAttribute('src', 'https://example.test/checkout-product.jpg');
    const noPhoto = screen.getByRole('button', { name: 'Adicionar Jaqueta leve ao caixa' }).closest('.pos-product-row');
    expect(within(noPhoto).queryByRole('img')).not.toBeInTheDocument();
    expect(noPhoto.querySelector('.pos-item-avatar')).toHaveTextContent('JL');
  });

  it('separates estoque and caixa into dedicated navigation views', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    expect(within(screen.getByRole('row', { name: /Camiseta básica/ })).getByText('No caixa')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Novo produto' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Registrar venda e emitir nota' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    expect(await screen.findByRole('heading', { name: 'Caixa' })).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'Leitura de código de barras' })).not.toBeInTheDocument();
    expect(screen.queryByRole('textbox', { name: 'Código de barras da peça' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Abrir estoque' })).toBeInTheDocument();
    expect(screen.getByText('COMANDA ATUAL')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Venda em aberto' })).toBeInTheDocument();
    const payment = screen.getByRole('region', { name: 'Pagamento' });
    expect(within(payment).getByRole('button', { name: 'Pix' })).toHaveAttribute('aria-pressed', 'true');
    expect(within(payment).getByText('Subtotal').nextElementSibling).toHaveTextContent('R$ 69,90');
    expect(within(payment).getByText('Descontos').nextElementSibling).toHaveTextContent('R$ 0,00');
    expect(within(payment).getByText('Total da venda').nextElementSibling).toHaveTextContent('R$ 69,90');
    expect(window.open).not.toHaveBeenCalled();
  });

  it('prioritizes exact barcode scanning when adding a product to the caixa', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    fireEvent.keyDown(document, { key: 'Enter' });
    expect(calls.some((call) => call.action === 'cart.add')).toBe(false);
    for (const key of 'Calça jeans') fireEvent.keyDown(document, { key });
    fireEvent.keyDown(document, { key: 'Enter' });
    expect(await screen.findByText('Código não encontrado no estoque. Confira a leitura ou use a busca manual.')).toBeInTheDocument();
    expect(calls.some((call) => call.action === 'cart.add')).toBe(false);
    for (const key of 'SLB-000000000002') fireEvent.keyDown(document, { key });
    fireEvent.keyDown(document, { key: 'Enter' });
    await waitFor(() => expect(calls.some((call) => call.action === 'cart.add' && call.payload.barcode === 'SLB-000000000002')).toBe(true));
  });

  it('opens the stock search only as a manual fallback', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    for (const key of 'codigo-invalido') fireEvent.keyDown(document, { key });
    fireEvent.keyDown(document, { key: 'Enter' });
    expect(await screen.findByText('Código não encontrado no estoque. Confira a leitura ou use a busca manual.')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Abrir estoque' }));
    expect(screen.queryByText('Código não encontrado no estoque. Confira a leitura ou use a busca manual.')).not.toBeInTheDocument();
    const search = await screen.findByRole('textbox', { name: 'Pesquisar produto no estoque' });
    fireEvent.change(search, { target: { value: 'Calça' } });
    fireEvent.click(await screen.findByRole('button', { name: 'Adicionar Calça jeans ao caixa' }));
    await waitFor(() => expect(calls.some((call) => call.action === 'cart.add' && call.payload.barcode === 'SLB-000000000002')).toBe(true));
    await waitFor(() => expect(screen.queryByRole('textbox', { name: 'Pesquisar produto no estoque' })).not.toBeInTheDocument());
    expect(screen.queryByText('Operação concluída.')).not.toBeInTheDocument();
  });

  it('queues a barcode read while another cart operation is busy', async () => {
    delayNextCartAdd = true;
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    for (const key of 'SLB-000000000002') fireEvent.keyDown(document, { key });
    fireEvent.keyDown(document, { key: 'Enter' });
    await waitFor(() => expect(releaseCartAdd).toBeTypeOf('function'));
    for (const key of 'SLB-000000000003') fireEvent.keyDown(document, { key });
    fireEvent.keyDown(document, { key: 'Enter' });
    expect(await screen.findByText('Leitura recebida. A peça será adicionada assim que a operação atual terminar.')).toBeInTheDocument();
    releaseCartAdd();
    await waitFor(() => expect(calls.some((call) => call.action === 'cart.add' && call.payload.barcode === 'SLB-000000000003')).toBe(true));
  });

  it('keeps the product draft while navigating and calculates 3 variations / 4 pieces', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Camiseta básica' } });
    fireEvent.change(screen.getByLabelText('Preço de custo'), { target: { value: '35,00' } });
    fireEvent.change(screen.getByRole('textbox', { name: /^Preço de venda/ }), { target: { value: '69,90' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 1' }), { target: { value: 'Preta' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 1' }), { target: { value: 'M' } });
    fireEvent.change(screen.getByLabelText('Quantidade da variação 1'), { target: { value: '2' } });
    fireEvent.click(screen.getByRole('button', { name: 'Adicionar variação' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 2' }), { target: { value: 'Preta' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 2' }), { target: { value: 'G' } });
    fireEvent.click(screen.getByRole('button', { name: 'Adicionar variação' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 3' }), { target: { value: 'Branca' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 3' }), { target: { value: 'M' } });
    const summary = document.querySelector('.summary-card');
    expect(within(summary).getByText('3')).toBeInTheDocument();
    expect(within(summary).getByText('4')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Estoque/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    expect(screen.getByRole('textbox', { name: /^Nome do produto/ })).toHaveValue('Camiseta básica');
    expect(document.querySelector('.product-layout')).toBeInTheDocument();
    expect(document.querySelector('.product-actions')).toHaveClass('product-actions');
  });

  it('validates the draft and sends fiscal decimal values as numbers on create', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cadastrar produto' }));
    expect(await screen.findByText('Informe o nome do produto.')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Camiseta básica' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 1' }), { target: { value: 'Preta livre' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 1' }), { target: { value: 'M-extra' } });
    fireEvent.click(screen.getByRole('button', { name: /Informações adicionais/ }));
    fireEvent.change(screen.getByLabelText('ICMS (%)'), { target: { value: '7,25' } });
    fireEvent.click(screen.getByRole('button', { name: 'Cadastrar produto' }));
    await waitFor(() => expect(calls.some((call) => call.action === 'product.create')).toBe(true));
    const request = calls.find((call) => call.action === 'product.create').payload;
    expect(request.variants[0]).toMatchObject({ color: 'Preta livre', size: 'M-extra', quantity: 1 });
    expect(request.fiscal.icms).toBe(7.25);
    expect(typeof request.request_id).toBe('string');
  });

  it('retries create with the same id while preserving localized fiscal text', async () => {
    let attempts = 0;
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'product.create') {
        attempts += 1;
        if (attempts === 1) throw new Error('falha temporária no cadastro');
        return { data: { ok: true } };
      }
      return { data: {} };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Produto com fiscal' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 1' }), { target: { value: 'Preta' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 1' }), { target: { value: 'M' } });
    fireEvent.click(screen.getByRole('button', { name: /Informações adicionais/ }));
    fireEvent.change(screen.getByLabelText('ICMS (%)'), { target: { value: '7,25' } });
    fireEvent.click(screen.getByRole('button', { name: 'Cadastrar produto' }));
    expect(await screen.findByText('falha temporária no cadastro')).toBeInTheDocument();
    expect(screen.getByLabelText('ICMS (%)')).toHaveValue('7,25');
    fireEvent.click(screen.getByRole('button', { name: 'Cadastrar produto' }));
    await waitFor(() => expect(calls.filter((call) => call.action === 'product.create')).toHaveLength(2));
    const creates = calls.filter((call) => call.action === 'product.create');
    expect(creates[0].payload.request_id).toBe(creates[1].payload.request_id);
    expect(creates[0].payload.fiscal.icms).toBe(7.25);
    expect(creates[1].payload.fiscal.icms).toBe(7.25);
  });

  it('edits one unit from the drawer with explicit edit keys and fiscal round-trip', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('row', { name: /Camiseta básica/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Editar peça' }));
    expect(await screen.findByRole('heading', { name: 'Editar peça' })).toBeInTheDocument();
    fireEvent.change(screen.getByRole('textbox', { name: /^Preço de venda/ }), { target: { value: '79,90' } });
    fireEvent.change(screen.getByLabelText('ICMS (%)'), { target: { value: '7,25' } });
    fireEvent.click(screen.getByRole('button', { name: 'Salvar alterações' }));
    await waitFor(() => expect(calls.some((call) => call.action === 'unit.edit')).toBe(true));
    const request = calls.find((call) => call.action === 'unit.edit').payload;
    expect(request.draft.price).toBe(79.9);
    expect(request.draft.fiscal.icms).toBe(7.25);
    expect(request.draft).not.toHaveProperty('variants');
    expect(request.draft).not.toHaveProperty('barcode');
  });

  it('keeps a create draft separate while editing a unit and reuses the edit request id after a failure', async () => {
    let editAttempts = 0;
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'unit.get') return { data: unit() };
      if (action === 'unit.edit') {
        editAttempts += 1;
        if (editAttempts === 1) throw new Error('falha temporária');
        return { data: { ok: true } };
      }
      return { data: { items: [] } };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Rascunho preservado' } });
    fireEvent.click(screen.getByRole('button', { name: /Estoque/ }));
    fireEvent.click(screen.getByRole('row', { name: /Camiseta básica/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Editar peça' }));
    expect(await screen.findByRole('heading', { name: 'Editar peça' })).toBeInTheDocument();
    expect(screen.getByLabelText('ICMS (%)')).toHaveValue('7,25');
    fireEvent.click(screen.getByRole('button', { name: 'Salvar alterações' }));
    expect(await screen.findByText('falha temporária')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Salvar alterações' }));
    await waitFor(() => expect(calls.filter((call) => call.action === 'unit.edit')).toHaveLength(2));
    const edits = calls.filter((call) => call.action === 'unit.edit');
    expect(edits[0].payload.draft.request_id).toBe(edits[1].payload.draft.request_id);
    fireEvent.click(screen.getByRole('button', { name: /Estoque/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    expect(screen.getByRole('textbox', { name: /^Nome do produto/ })).toHaveValue('Rascunho preservado');
  });

  it('rejects a non numeric or out of range quantity before creating', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Quantidade inválida' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Cor da variação 1' }), { target: { value: 'Preta' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Tamanho da variação 1' }), { target: { value: 'M' } });
    fireEvent.change(screen.getByLabelText('Quantidade da variação 1'), { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Cadastrar produto' }));
    expect(await screen.findByText('Confira cor, tamanho e quantidade de cada variação.')).toBeInTheDocument();
    expect(calls.some((call) => call.action === 'product.create')).toBe(false);
  });

  it('cancels a new product without sending a create request', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    fireEvent.change(screen.getByRole('textbox', { name: /^Nome do produto/ }), { target: { value: 'Descartar este produto' } });
    fireEvent.click(screen.getByRole('button', { name: 'Cancelar' }));
    expect(await screen.findByRole('heading', { name: 'Estoque' })).toBeInTheDocument();
    expect(calls.some((call) => call.action === 'product.create')).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: 'Novo produto' }));
    expect(screen.getByRole('textbox', { name: /^Nome do produto/ })).toHaveValue('');
  });

  it('reuses the same request id when retrying a timed out confirmation', async () => {
    let confirmations = 0;
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'cart.confirm') {
        confirmations += 1;
        if (confirmations === 1) throw new Error('desktop sem resposta');
        return { data: { ok: true } };
      }
      return { data: {} };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: /Caixa/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Dinheiro' }));
    fireEvent.click(screen.getByRole('button', { name: 'Registrar venda e emitir nota' }));
    fireEvent.click(screen.getByRole('button', { name: 'Registrar e solicitar nota', exact: true }));
    expect(await screen.findByText('desktop sem resposta')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Registrar e solicitar nota', exact: true }));
    await waitFor(() => expect(calls.filter((call) => call.action === 'cart.confirm')).toHaveLength(2));
    const requests = calls.filter((call) => call.action === 'cart.confirm');
    expect(requests[0].payload.request_id).toBe(requests[1].payload.request_id);
    expect(requests[0].payload.version).toBe(3);
    expect(requests[0].payload.payment).toBe('cash');
    expect(requests[0].payload.fiscal_document).toBe('nfce');
  });

  it('shows recoverable history and label errors instead of empty results', async () => {
    let historyAttempts = 0;
    let labelAttempts = 0;
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'history.list') {
        historyAttempts += 1;
        if (historyAttempts === 1) throw new Error('histórico indisponível');
        return { data: { items: [
          { id: 'h1', barcode: 'SLB-1', delta: -1, reason: 'sale', created_at: `/Date(${Date.UTC(2026, 9, 31, 12, 0)})/` },
          { id: 'h2', barcode: 'SLB-2', delta: 3, reason: 'initial', created_at: '2026-10-30T12:15:00Z' },
          { id: 'h3', sic_document_id: 'DOC-3', delta: 2, reason: 'adjustment', created_at: 'data inválida' },
        ] } };
      }
      if (action === 'labels.preview') {
        labelAttempts += 1;
        if (labelAttempts === 1) throw new Error('etiquetas indisponíveis');
        return { data: { html: '<!doctype html><html><body>Etiqueta</body></html>' } };
      }
      return { data: {} };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Histórico' }));
    expect(await screen.findByText('histórico indisponível')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Tentar novamente' }));
    expect(await screen.findByText('SLB-1')).toBeInTheDocument();
    expect(screen.getByText('Venda')).toBeInTheDocument();
    expect(screen.getByText('-1 peça')).toBeInTheDocument();
    expect(screen.getByText('Entrada inicial')).toBeInTheDocument();
    expect(screen.getByText('+3 peças')).toBeInTheDocument();
    expect(screen.getByText('Ajuste')).toBeInTheDocument();
    expect(screen.getByText('+2 peças')).toBeInTheDocument();
    expect(screen.getByText('Data indisponível')).toBeInTheDocument();
    expect(screen.getByText(/31\/10\/2026/)).toBeInTheDocument();
    expect(screen.getByText(/30\/10\/2026/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Etiquetas' }));
    expect(await screen.findByText('etiquetas indisponíveis')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Tentar novamente' }));
    expect(await screen.findByTitle('Prévia das etiquetas')).toBeInTheDocument();
  });

  it('uses internal navigation for history, labels, and settings', async () => {
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Histórico' }));
    expect(await screen.findByRole('heading', { name: 'Histórico' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Etiquetas' }));
    expect(await screen.findByTitle('Prévia das etiquetas')).toHaveAttribute('sandbox', '');
    fireEvent.click(screen.getByRole('button', { name: 'Configurações' }));
    expect(await screen.findByText('Operação automática')).toBeInTheDocument();
    expect(screen.queryByText('Parear celular')).not.toBeInTheDocument();
    expect(window.open).not.toHaveBeenCalled();
  });

  it('shows sales and outflow dashboard with period and classification data', async () => {
    const report = {
      summary: { revenue: 199.8, sales: 2, items: 3, average_ticket: 99.9 },
      filters: { brands: ['LINE'], categories: ['Camiseta'] },
      by_category: [{ label: 'Camiseta', items: 2, revenue: 139.8 }],
      by_brand: [{ label: 'LINE', items: 2, revenue: 139.8 }],
      rows: [{ sale_id: 'sale-1', created_at: '2026-10-31T12:00:00Z', name: 'Camiseta básica', barcode: 'SLB-000000000001', brand: 'LINE', category: 'Camiseta', quantity: 1, line_total: 69.9, payment: 'pix', fiscal_status: 'pending_adapter' }],
    };
    setBridgeMock(async ({ action, payload }) => {
      calls.push({ action, payload });
      if (action === 'bootstrap') return { data: bootstrap() };
      if (action === 'sales.report') return { data: report };
      return { data: {} };
    });
    renderApp();
    await screen.findByRole('heading', { name: 'Estoque' });
    fireEvent.click(screen.getByRole('button', { name: 'Vendas e saídas' }));
    expect(await screen.findByRole('heading', { name: 'Vendas e saídas' })).toBeInTheDocument();
    expect(screen.getByText('R$ 199,80')).toBeInTheDocument();
    expect(screen.getByText('Saída por tipo de peça')).toBeInTheDocument();
    expect(screen.getByText('Saída por marca')).toBeInTheDocument();
    expect(screen.getByText('Camiseta básica')).toBeInTheDocument();
    expect(screen.getByText('Aguardando emissor')).toBeInTheDocument();
    expect(calls.some((call) => call.action === 'sales.report' && call.payload.from && call.payload.to)).toBe(true);
  });
});
