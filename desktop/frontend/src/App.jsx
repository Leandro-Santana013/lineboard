import { useEffect, useRef, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Autocomplete,
  AppShell,
  Badge,
  Box,
  Button,
  Card,
  Collapse,
  Divider,
  Drawer,
  Group,
  Modal,
  Paper,
  Progress,
  ScrollArea,
  Select,
  SimpleGrid,
  Stack,
  Table,
  Text,
  TextInput,
  Textarea,
  ThemeIcon,
  Title,
  Tooltip,
} from '@mantine/core';
import {
  IconAdjustments,
  IconArchive,
  IconArrowLeft,
  IconBarcode,
  IconBox,
  IconBuildingStore,
  IconCash,
  IconChevronDown,
  IconChevronRight,
  IconCircleCheck,
  IconChartBar,
  IconCloudOff,
  IconCreditCard,
  IconDeviceFloppy,
  IconFileExport,
  IconHistory,
  IconInfoCircle,
  IconMinus,
  IconPlus,
  IconQrcode,
  IconReceipt,
  IconRefresh,
  IconSearch,
  IconSettings,
  IconShoppingCart,
  IconTag,
  IconTrash,
  IconX,
} from '@tabler/icons-react';
import { callHost, hasDesktopHost, requestId } from './bridge';
import { ProductPhotoField, ProductPhotoPreview } from './ProductPhoto.jsx';
import storeLogo from './assets/lines-boardshop.jpg';

const pt = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
const integer = new Intl.NumberFormat('pt-BR');
const colorOptions = ['Preta', 'Branca', 'Azul', 'Verde', 'Vermelha', 'Amarela', 'Areia', 'Bege', 'Cinza'].map((value) => ({ value, label: value }));
const sizeOptions = ['PP', 'P', 'M', 'G', 'GG', '36', '38', '40', '42', '44'].map((value) => ({ value, label: value }));
const fiscalLabels = {
  codipi: 'NCM', cst: 'CST / CSOSN', cean: 'GTIN do produto', ceantrib: 'GTIN tributável', cest: 'CEST',
  icms: 'ICMS (%)', ipi: 'IPI (%)', origem: 'Origem', cclasstrib: 'Classificação tributária', ipi_cst: 'CST do IPI',
  cst_pis: 'CST do PIS', cst_cofins: 'CST da COFINS', cbenef: 'Código de benefício fiscal', cst_ibscbs: 'CST IBS / CBS',
  basecalculo: 'Base de cálculo', pesobruto: 'Peso bruto', pesoliq: 'Peso líquido', ipi_basecalc: 'Base de cálculo do IPI',
  fcp: 'FCP (%)', cprodanp: 'Código ANP',
};
const fiscalTextKeys = ['codipi', 'cst', 'cean', 'ceantrib', 'cest', 'cclasstrib', 'ipi_cst', 'cst_pis', 'cst_cofins', 'cbenef', 'cst_ibscbs'];
const fiscalNumberKeys = ['icms', 'ipi', 'origem', 'basecalculo', 'pesobruto', 'pesoliq', 'ipi_basecalc', 'fcp', 'cprodanp'];

const emptyVariant = () => ({ color: '', size: '', quantity: 1 });
const emptyDraft = () => ({
  name: '', brand: '', category: '', internal_code: '', cost: '0,00', price: '0,00', color: '', size: '', location: '', photo: '', notes: '', fiscal: {},
  variants: [emptyVariant()], request_id: null,
});

function valueText(value) {
  return value === null || value === undefined ? '' : String(value);
}

function decimalText(value) {
  if (value === null || value === undefined || value === '') return '0,00';
  const numeric = parseDecimal(value);
  return Number.isFinite(numeric) ? numeric.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) : String(value);
}

function decimalValue(value) {
  const numeric = parseDecimal(value);
  return Number.isFinite(numeric) ? numeric : NaN;
}

function parseDecimal(value) {
  if (typeof value === 'number') return value;
  const raw = String(value ?? '').trim();
  if (!raw) return NaN;
  if (raw.includes(',') && raw.includes('.')) return Number(raw.replace(/\./g, '').replace(',', '.'));
  if (raw.includes(',')) return Number(raw.replace(',', '.'));
  return Number(raw);
}

function money(value) {
  const numeric = typeof value === 'number' ? value : decimalValue(value);
  return Number.isFinite(numeric) ? pt.format(numeric) : 'R$ 0,00';
}

function makeDraftFromUnit(unit) {
  const fiscal = {};
  Object.keys(fiscalLabels).forEach((key) => { if (unit && unit[key] !== null && unit[key] !== undefined) fiscal[key] = fiscalNumberKeys.includes(key) ? decimalText(unit[key]) : valueText(unit[key]); });
  return {
    name: valueText(unit && unit.name), brand: valueText(unit && unit.brand), category: valueText(unit && unit.category), internal_code: valueText(unit && unit.internal_code),
    cost: decimalText(unit && unit.cost), price: decimalText(unit && unit.price), color: valueText(unit && unit.color), size: valueText(unit && unit.size),
    location: valueText(unit && unit.location), photo: valueText(unit && unit.photo_path), notes: valueText(unit && unit.notes), fiscal,
    variants: [{ color: valueText(unit && unit.color), size: valueText(unit && unit.size), quantity: 1 }], request_id: null,
    barcode: valueText(unit && unit.barcode), revision: unit && unit.revision,
  };
}

function App() {
  const [view, setView] = useState('inventory');
  const [catalog, setCatalog] = useState([]);
  const [cart, setCart] = useState({ version: 0, items: [], total: 0 });
  const [syncState, setSyncState] = useState('loading');
  const [draft, setDraft] = useState(emptyDraft);
  const [productMode, setProductMode] = useState('create');
  const [selected, setSelected] = useState(null);
  const [hostError, setHostError] = useState(null);
  const [environmentMode, setEnvironmentMode] = useState('sandbox');
  const [message, setMessage] = useState(null);
  const [busy, setBusy] = useState('');
  const [editUnit, setEditUnit] = useState(null);
  const [adjustUnit, setAdjustUnit] = useState(null);
  const mutationEpoch = useRef(0);
  const activeMutations = useRef(0);
  const operationIds = useRef(new Map());

  const refresh = async (force = false) => {
    if (activeMutations.current && !force) return;
    const epoch = mutationEpoch.current;
    try {
      const data = await callHost('bootstrap', {});
      if (epoch !== mutationEpoch.current) return;
      setCatalog(Array.isArray(data && data.catalog) ? data.catalog : []);
      setCart(data && data.cart ? data.cart : { version: 0, items: [], total: 0 });
      setSyncState(data && data.sync_state ? data.sync_state : 'up_to_date');
      setEnvironmentMode(data && data.mode === 'production' ? 'production' : 'sandbox');
      setHostError(null);
    } catch (error) {
      if (epoch !== mutationEpoch.current) return;
      setHostError(error);
      setSyncState('desktop_required');
    }
  };

  useEffect(() => {
    refresh();
    const timer = window.setInterval(refresh, 1800);
    return () => window.clearInterval(timer);
  }, []);

  const navigate = (next) => { setView(next); setMessage(null); };
  const startProduct = () => { setProductMode('create'); setDraft((current) => current || emptyDraft()); setView('product'); setMessage(null); };
  const cancelProduct = () => { setView('inventory'); setDraft(emptyDraft()); setMessage(null); };

  const run = async (key, action, payload, success, { showSuccess = true } = {}) => {
    if (busy || activeMutations.current) return null;
    mutationEpoch.current += 1;
    activeMutations.current += 1;
    setBusy(key);
    try {
      const result = await callHost(action, payload);
      if (success) success(result);
      if (showSuccess) setMessage({ type: 'success', text: 'Operação concluída.' });
      await refresh(true);
      return result;
    } catch (error) {
      setMessage({ type: 'error', text: error.message || 'Operação não concluída.' });
      return null;
    } finally {
      activeMutations.current = Math.max(0, activeMutations.current - 1);
      setBusy('');
    }
  };

  const operationRequest = (key) => {
    if (!operationIds.current.has(key)) operationIds.current.set(key, requestId());
    return operationIds.current.get(key);
  };
  const clearOperation = (key) => operationIds.current.delete(key);
  const addCart = (unit) => { const key = `cart-add-${unit.barcode}`; return run(key, 'cart.add', { request_id: operationRequest(key), barcode: unit.barcode }, () => clearOperation(key), { showSuccess: false }); };
  const removeCart = (unit) => { const key = `cart-remove-${unit.barcode}`; return run(key, 'cart.remove', { request_id: operationRequest(key), barcode: unit.barcode }, () => clearOperation(key), { showSuccess: false }); };
  const confirmCart = (payment, fiscal_document, onSuccess) => {
    const key = `cart-confirm-${cart.version}-${payment}-${fiscal_document || 'none'}`;
    return run('cart-confirm', 'cart.confirm', { request_id: operationRequest(key), version: cart.version, payment, fiscal_document }, () => {
      clearOperation(key);
      if (onSuccess) onSuccess();
    }, { showSuccess: false });
  };

  const openEdit = async (unit) => {
    try { const detail = await callHost('unit.get', { barcode: unit.barcode }); setEditUnit(detail || unit); }
    catch (error) { setMessage({ type: 'error', text: error.message }); }
  };
  const openAdjust = (unit) => setAdjustUnit(unit);

  const saveProduct = async (nextDraft, modeOverride = productMode) => {
    const name = nextDraft.name.trim();
    if (!name) { setMessage({ type: 'error', text: 'Informe o nome do produto.' }); return; }
    const price = decimalValue(nextDraft.price); const cost = decimalValue(nextDraft.cost);
    if (!Number.isFinite(price) || !Number.isFinite(cost) || price < 0 || cost < 0) { setMessage({ type: 'error', text: 'Confira os valores de custo e venda.' }); return; }
    const fiscal = { ...nextDraft.fiscal };
    for (const key of fiscalNumberKeys) {
      if (fiscal[key] === undefined || fiscal[key] === null || fiscal[key] === '') continue;
      const parsed = decimalValue(fiscal[key]);
      if (!Number.isFinite(parsed) || parsed < 0) { setMessage({ type: 'error', text: `Confira o campo fiscal ${fiscalLabels[key]}.` }); return; }
      fiscal[key] = parsed;
    }
    const variants = nextDraft.variants.filter((variant) => variant.color || variant.size || Number(variant.quantity) !== 1);
    if (modeOverride === 'create' && (!variants.length || variants.some((variant) => !variant.color || !variant.size || !Number.isInteger(Number(variant.quantity)) || Number(variant.quantity) < 1 || Number(variant.quantity) > 500))) {
      setMessage({ type: 'error', text: 'Confira cor, tamanho e quantidade de cada variação.' }); return;
    }
    const request_id = nextDraft.request_id || requestId();
    if (modeOverride === 'edit') {
      const editDraft = { request_id, revision: nextDraft.revision, name: nextDraft.name, brand: nextDraft.brand, category: nextDraft.category, color: nextDraft.color, size: nextDraft.size, cost, price, location: nextDraft.location, photo: nextDraft.photo, notes: nextDraft.notes, internal_code: nextDraft.internal_code, fiscal };
      try { await run('product-save', 'unit.edit', { barcode: nextDraft.barcode, draft: editDraft }, () => { setEditUnit(null); }); } catch { /* run already exposes a recoverable message */ }
    } else {
      // Keep the localized text in the draft so a failed retry still displays 7,25.
      // The converted numeric copy above is sent only to the host payload.
      setDraft({ ...nextDraft, request_id });
      try { await run('product-save', 'product.create', { name: nextDraft.name, brand: nextDraft.brand, category: nextDraft.category, color: nextDraft.color, size: nextDraft.size, cost, price, location: nextDraft.location, photo: nextDraft.photo, notes: nextDraft.notes, internal_code: nextDraft.internal_code, fiscal, request_id, variants }, () => { setDraft(emptyDraft()); setView('inventory'); }); } catch { /* run already exposes a recoverable message */ }
    }
  };

  const applyAdjustment = async (quantity, reason) => {
    if (!adjustUnit) return;
    if (!reason.trim()) { setMessage({ type: 'error', text: 'Informe o motivo do ajuste.' }); return; }
    await run('adjust', 'stock.adjust', { request_id: requestId(), barcode: adjustUnit.barcode, quantity: Number(quantity), reason: reason.trim() }, () => setAdjustUnit(null));
  };

  const content = view === 'product'
    ? <ProductPage draft={draft} setDraft={setDraft} onSave={saveProduct} onCancel={cancelProduct} busy={busy === 'product-save'} mode={productMode} environmentMode={environmentMode} />
    : view === 'checkout' ? <CheckoutPage catalog={catalog} cart={cart} addCart={addCart} removeCart={removeCart} confirmCart={confirmCart} busy={busy} environmentMode={environmentMode} />
      : view === 'sales' ? <SalesDashboardPage />
        : view === 'history' ? <HistoryPage />
          : view === 'labels' ? <LabelsPage />
            : view === 'settings' ? <SettingsPage />
              : <InventoryPage catalog={catalog} cart={cart} selected={selected} setSelected={setSelected} addCart={addCart} onEdit={openEdit} onAdjust={openAdjust} onNew={startProduct} environmentMode={environmentMode} />;

  return <AppShell
    padding={0}
    navbar={{ width: 252, breakpoint: 0 }}
    header={{ height: 0 }}
    styles={{ main: { background: '#f5f5f5', minHeight: '100vh' }, navbar: { background: '#111111', border: 0 } }}
  >
    <AppShell.Navbar p="md">
      <Sidebar active={view} navigate={navigate} cartCount={cart.items.length} environmentMode={environmentMode} />
    </AppShell.Navbar>
    <AppShell.Main>
      <Box className={`app-content ${view === 'inventory' || view === 'checkout' ? 'operation-shell' : ''}`}>
        {!hasDesktopHost() && !hostError ? <Alert icon={<IconCloudOff size={18} />} color="yellow" mb="md">Abra este conteúdo pelo executável desktop para acessar o SIC.</Alert> : null}
        {hostError ? <Alert icon={<IconCloudOff size={18} />} color="yellow" mb="md" title="Desktop necessário">{hostError.message || 'Abra o Lineboard pelo aplicativo desktop para acessar o SIC.'}</Alert> : null}
        {message ? <Alert mb="md" color={message.type === 'error' ? 'red' : 'brand'} icon={message.type === 'error' ? <IconX size={18} /> : <IconCircleCheck size={18} />} withCloseButton onClose={() => setMessage(null)}>{message.text}</Alert> : null}
        {content}
      </Box>
    </AppShell.Main>
    <EditDrawer unit={editUnit} onClose={() => setEditUnit(null)} onSave={(unitDraft) => saveProduct(unitDraft, 'edit')} busy={busy === 'product-save'} />
    <AdjustDrawer unit={adjustUnit} onClose={() => setAdjustUnit(null)} onSave={applyAdjustment} busy={busy === 'adjust'} />
  </AppShell>;
}

function Sidebar({ active, navigate, cartCount, environmentMode }) {
  const links = [
    { key: 'inventory', label: 'Estoque', icon: IconBuildingStore },
    { key: 'checkout', label: 'Caixa', icon: IconShoppingCart },
    { key: 'sales', label: 'Vendas e saídas', icon: IconChartBar },
    { key: 'history', label: 'Histórico', icon: IconHistory },
    { key: 'labels', label: 'Etiquetas', icon: IconTag },
  ];
  return <Stack justify="space-between" h="100%">
    <Stack gap="lg">
      <Box className="brand">
        <img className="brand-logo" src={storeLogo} alt="Lines Boardshop" />
        <Text className="brand-caption" size="xs" c="#bdbdbd" ta="center">LINEBOARD · Gestão da loja</Text>
      </Box>
      <Text size="xs" c="#bdbdbd" fw={700} lts=".08em">OPERAÇÃO</Text>
      <Stack gap={5}>{links.map(({ key, label, icon: Icon }) => <Button key={key} variant="subtle" justify="flex-start" leftSection={<Icon size={22} />} rightSection={key === 'checkout' && cartCount ? <Badge color="brand" variant="filled" size="sm" circle>{cartCount}</Badge> : null} className={`nav-link ${active === key ? 'active' : ''}`} onClick={() => navigate(key)}>{label}</Button>)}</Stack>
    </Stack>
    <Stack gap="sm">
      <Button variant="subtle" justify="flex-start" leftSection={<IconSettings size={22} />} className={`nav-link ${active === 'settings' ? 'active' : ''}`} onClick={() => navigate('settings')}>Configurações</Button>
      <Text size="sm" c={environmentMode === 'production' ? '#dddddd' : '#ffc45a'}><span className={`lab-dot ${environmentMode === 'production' ? 'production' : ''}`} /> {environmentMode === 'production' ? 'SICNET · produção' : 'Modo laboratório'}</Text>
    </Stack>
  </Stack>;
}

function PageHeading({ eyebrow, title, description, action, onBack }) {
  return <Group justify="space-between" align="flex-start" mb="lg" className="page-heading">
    <Box>{eyebrow ? <Text size="sm" c="dimmed" mb={5}>{eyebrow}</Text> : null}<Group gap="sm"><Title order={1}>{title}</Title></Group>{description ? <Text c="dimmed" mt={3}>{description}</Text> : null}</Box>
    {action || (onBack ? <Button variant="default" leftSection={<IconArrowLeft size={18} />} onClick={onBack}>Voltar</Button> : null)}
  </Group>;
}

function InventoryPage({ catalog, cart, selected, setSelected, addCart, onEdit, onAdjust, onNew, environmentMode }) {
  const [query, setQuery] = useState(''); const [filter, setFilter] = useState('all');
  const filtered = catalog.filter((unit) => {
    const haystack = [unit.name, unit.barcode, unit.brand, unit.category, unit.color, unit.size, unit.internal_code].join(' ').toLocaleLowerCase('pt-BR');
    const matches = haystack.normalize('NFD').replace(/[\u0300-\u036f]/g, '').includes(query.toLocaleLowerCase('pt-BR').normalize('NFD').replace(/[\u0300-\u036f]/g, ''));
    const inCart = cart.items.some((item) => item.barcode === unit.barcode);
    const quantity = Number(unit.quantity || 0); const conflict = Boolean(unit.conflict);
    return matches && (filter === 'all' || (filter === 'available' && quantity === 1 && !inCart && !conflict) || (filter === 'cart' && inCart) || (filter === 'empty' && quantity !== 1) || (filter === 'conflict' && conflict));
  });
  const selectedUnit = selected ? catalog.find((unit) => unit.barcode === selected) : null;
  return <>
    <PageHeading title="Estoque" description="Consulte, edite e ajuste as peças disponíveis na loja." action={<Button leftSection={<IconPlus size={18} />} color="brand" onClick={onNew}>Novo produto</Button>} />
    <Alert color="yellow" icon={<IconInfoCircle size={18} />} mb="md">{environmentMode === 'production' ? 'SICNET · Emissão fiscal pendente de configuração' : 'Ambiente de teste · Emissão fiscal pendente de configuração'}</Alert>
    <Paper withBorder radius="md" p="lg" className="inventory-card">
      <Group justify="space-between" mb="md"><Box><Title order={3}>Peças em estoque</Title><Text size="sm" c="dimmed">{catalog.length} peças rastreadas individualmente</Text></Box><Group><TextInput aria-label="Buscar no estoque" placeholder="Buscar produto ou código" leftSection={<IconBarcode size={17} />} value={query} onChange={(event) => setQuery(event.currentTarget.value)} /><Select aria-label="Filtrar estoque" w={155} value={filter} onChange={(value) => setFilter(value || 'all')} data={[{ value: 'all', label: 'Todas as peças' }, { value: 'available', label: 'Disponíveis' }, { value: 'cart', label: 'No caixa' }, { value: 'empty', label: 'Sem saldo' }, { value: 'conflict', label: 'Em conflito' }]} /></Group></Group>
      <ScrollArea type="auto" className="inventory-scroll"><Table highlightOnHover withColumnBorders={false} verticalSpacing="sm"><Table.Thead><Table.Tr><Table.Th>PRODUTO</Table.Th><Table.Th className="inventory-barcode-column">CÓDIGO</Table.Th><Table.Th>COR / TAM.</Table.Th><Table.Th ta="right">PREÇO</Table.Th><Table.Th>SITUAÇÃO</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{filtered.map((unit) => <InventoryRow key={unit.barcode} unit={unit} inCart={cart.items.some((item) => item.barcode === unit.barcode)} selected={selected === unit.barcode} onSelect={() => setSelected(unit.barcode)} />)}</Table.Tbody></Table>{filtered.length === 0 ? <EmptyState title={catalog.length ? 'Nenhum resultado' : 'Nenhuma peça cadastrada'} text={catalog.length ? 'Altere a busca ou o filtro para continuar.' : 'Cadastre o primeiro produto para começar.'} /> : null}</ScrollArea>
      <Group justify="space-between" mt="md" className="inventory-actions"><Text size="sm" c="dimmed">{selectedUnit ? '1 peça selecionada' : 'Selecione uma peça no estoque'}</Text><Group gap="xs"><Button variant="default" size="sm" disabled={!selectedUnit} onClick={() => onEdit(selectedUnit)}>Editar peça</Button><Button variant="default" size="sm" disabled={!selectedUnit} onClick={() => onAdjust(selectedUnit)} leftSection={<IconAdjustments size={16} />}>Entrada / ajuste</Button><Button size="sm" color="brand" disabled={!selectedUnit || Boolean(selectedUnit.conflict) || Number(selectedUnit.quantity) !== 1 || cart.items.some((item) => item.barcode === selectedUnit.barcode)} onClick={() => addCart(selectedUnit)} leftSection={<IconShoppingCart size={16} />}>Adicionar ao caixa</Button></Group></Group>
    </Paper>
  </>;
}

function InventoryRow({ unit, inCart, selected, onSelect }) {
  const quantity = Number(unit.quantity || 0); const conflict = Boolean(unit.conflict); const state = conflict ? ['Em conflito', 'red'] : inCart ? ['No caixa', 'yellow'] : quantity !== 1 ? ['Sem saldo', 'gray'] : ['Disponível', 'brand'];
  return <Table.Tr className={selected ? 'selected-row' : ''} onClick={onSelect}><Table.Td className="inventory-product-cell"><Group gap="sm" wrap="nowrap"><ProductPhotoPreview path={unit.photo_path} name={unit.name} size={44} /><Box><Text fw={600} className="inventory-product-name">{unit.name}</Text><Text size="xs" ff="monospace" className="inventory-inline-barcode">{unit.barcode}</Text></Box></Group></Table.Td><Table.Td className="inventory-barcode-column"><Text size="xs" ff="monospace">{unit.barcode}</Text></Table.Td><Table.Td className="inventory-variant-cell">{[unit.color, unit.size].filter(Boolean).join(' · ') || '—'}</Table.Td><Table.Td ta="right" className="inventory-price-cell">{money(unit.price)}</Table.Td><Table.Td><Badge color={state[1]} variant="light" className="inventory-state-badge">{state[0]}</Badge></Table.Td></Table.Tr>;
}

function CheckoutProductPhoto({ unit }) {
  const initials = <span aria-hidden="true">{(unit.name || 'Peça').trim().split(/\s+/).slice(0, 2).map((word) => word[0]).join('').toLocaleUpperCase('pt-BR')}</span>;
  return <Box className="pos-item-avatar"><ProductPhotoPreview path={unit.photo_path} name={unit.name} size={50} fallback={initials} /></Box>;
}

function CheckoutPage({ catalog, cart, addCart, removeCart, confirmCart, busy, environmentMode }) {
  const scanBufferRef = useRef('');
  const scanBufferTimerRef = useRef(null);
  const pendingScanRef = useRef('');
  const [scanError, setScanError] = useState('');
  const [manualSearchOpen, setManualSearchOpen] = useState(false);
  const [manualQuery, setManualQuery] = useState('');
  const [payment, setPayment] = useState('pix');
  const [confirming, setConfirming] = useState(false);
  const [fiscalDocument, setFiscalDocument] = useState('nfce');
  const available = catalog.filter((unit) => Number(unit.quantity) === 1 && !unit.conflict && !cart.items.some((item) => item.barcode === unit.barcode));
  const normalizedManualQuery = manualQuery.toLocaleLowerCase('pt-BR').normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  const manualMatches = available.filter((unit) => [unit.name, unit.barcode, unit.brand, unit.category, unit.color, unit.size, unit.internal_code].join(' ').toLocaleLowerCase('pt-BR').normalize('NFD').replace(/[\u0300-\u036f]/g, '').includes(normalizedManualQuery));
  const paymentOptions = [
    { value: 'pix', label: 'Pix', icon: IconQrcode },
    { value: 'cash', label: 'Dinheiro', icon: IconCash },
    { value: 'credit', label: 'Crédito', icon: IconCreditCard },
    { value: 'debit', label: 'Débito', icon: IconCreditCard },
  ];
  const scanProduct = async (rawCode) => {
    const code = rawCode.trim();
    if (!code || busy) return;
    const unit = catalog.find((item) => item.barcode.toLocaleLowerCase('pt-BR') === code.toLocaleLowerCase('pt-BR'));
    if (!unit) { setScanError('Código não encontrado no estoque. Confira a leitura ou use a busca manual.'); return; }
    if (cart.items.some((item) => item.barcode === unit.barcode)) { setScanError('Esta peça já está na comanda.'); return; }
    if (Number(unit.quantity) !== 1 || unit.conflict) { setScanError('Esta peça não está disponível para venda.'); return; }
    setScanError('');
    await addCart(unit);
  };
  useEffect(() => {
    if (busy || !pendingScanRef.current) return;
    const code = pendingScanRef.current;
    pendingScanRef.current = '';
    scanProduct(code);
  }, [busy]);
  useEffect(() => {
    if (manualSearchOpen || confirming) return undefined;
    const clearBuffer = () => {
      scanBufferRef.current = '';
      if (scanBufferTimerRef.current) window.clearTimeout(scanBufferTimerRef.current);
      scanBufferTimerRef.current = null;
    };
    const captureScanner = (event) => {
      if (event.ctrlKey || event.altKey || event.metaKey) return;
      if (event.key === 'Enter') {
        const code = scanBufferRef.current.trim();
        clearBuffer();
        if (!code) return;
        const exactMatch = catalog.some((item) => item.barcode.toLocaleLowerCase('pt-BR') === code.toLocaleLowerCase('pt-BR'));
        if (!exactMatch && code.length < 6) return;
        event.preventDefault();
        if (busy) {
          if (!pendingScanRef.current) {
            pendingScanRef.current = code;
            setScanError('Leitura recebida. A peça será adicionada assim que a operação atual terminar.');
          }
          return;
        }
        scanProduct(code);
        return;
      }
      if (event.key.length !== 1) return;
      scanBufferRef.current += event.key;
      if (scanBufferTimerRef.current) window.clearTimeout(scanBufferTimerRef.current);
      scanBufferTimerRef.current = window.setTimeout(clearBuffer, 300);
    };
    document.addEventListener('keydown', captureScanner, true);
    return () => {
      document.removeEventListener('keydown', captureScanner, true);
      clearBuffer();
    };
  }, [busy, cart.items, catalog, confirming, manualSearchOpen]);
  const addManualProduct = async (unit) => {
    const result = await addCart(unit);
    if (result === null) return;
    setScanError('');
    setManualSearchOpen(false);
    setManualQuery('');
  };
  const openManualStock = () => {
    setScanError('');
    setManualSearchOpen(true);
  };
  return <>
    <h1 className="visually-hidden">Caixa</h1>
    <Box className="checkout-layout">
      <Paper withBorder radius="md" p={0} className="pos-ticket">
        <Box className="pos-ticket-head">
          <Box className="pos-ticket-heading">
            <Text className="pos-ticket-eyebrow"><span className="pos-status-dot" />COMANDA ATUAL</Text>
            <Title order={2}>Venda em aberto</Title>
            <Text className="pos-ticket-description">Revise os itens e escolha o pagamento para finalizar.</Text>
          </Box>
          <Group gap="sm" wrap="nowrap" className="pos-ticket-actions">
            <Badge className="pos-item-count" radius="md">{cart.items.length} {cart.items.length === 1 ? 'item' : 'itens'}</Badge>
            <Button variant="white" color="dark" className="pos-open-stock" leftSection={<IconSearch size={18} />} onClick={openManualStock}>Abrir estoque</Button>
          </Group>
        </Box>
        {scanError ? <Alert color="red" m="md" mb={0} icon={<IconInfoCircle size={18} />}>{scanError}</Alert> : null}
        <Box className="pos-ticket-body">
          <ScrollArea className="pos-cart-scroll">
            {cart.items.length ? <ul className="pos-cart-list">{cart.items.map((item) => <li key={item.barcode} className="pos-cart-item">
              <CheckoutProductPhoto unit={item} />
              <Box className="pos-item-copy">
                <Text className="pos-item-name">{item.name}</Text>
                <Box className="pos-item-details"><Text component="span" className="pos-item-variant">{[item.color, item.size].filter(Boolean).join(' · ') || 'Peça individual'}</Text><Text component="span" className="pos-item-barcode">{item.barcode}</Text></Box>
              </Box>
              <Text className="pos-item-price">{money(item.price)}</Text>
              <Tooltip label="Remover do caixa"><ActionIcon variant="subtle" color="red" className="pos-remove-item" aria-label={`Remover ${item.name}`} onClick={() => removeCart(item)}><IconX size={17} /></ActionIcon></Tooltip>
            </li>)}</ul> : <EmptyState title="Comanda vazia" text="Escaneie a etiqueta da peça ou abra o estoque para localizar um produto." icon={<IconShoppingCart size={32} />} />}
          </ScrollArea>
          <Box component="section" aria-labelledby="pos-payment-heading" className="pos-ticket-footer">
            <Title order={3} id="pos-payment-heading" className="pos-payment-heading">Pagamento</Title>
            <Text className="pos-payment-description">Selecione como o cliente vai pagar</Text>
            <SimpleGrid cols={2} spacing={8} className="payment-grid">{paymentOptions.map(({ value, label, icon: PaymentIcon }) => <Button key={value} variant="default" className={`pos-payment-option ${payment === value ? 'selected' : ''}`} leftSection={<PaymentIcon size={17} />} disabled={!cart.items.length} aria-pressed={payment === value} onClick={() => setPayment(value)}>{label}</Button>)}</SimpleGrid>
            <Select className="pos-fiscal-select" label="Documento fiscal" value={fiscalDocument} onChange={(value) => setFiscalDocument(value || 'nfce')} data={[{ value: 'nfce', label: 'NFC-e · modelo 65' }, { value: 'nfe', label: 'NF-e · modelo 55' }]} disabled={!cart.items.length} />
            <Box className="pos-sale-summary">
              <dl className="pos-summary-lines"><div><dt>Subtotal</dt><dd>{money(cart.total)}</dd></div><div><dt>Descontos</dt><dd className="pos-discount">{money(0)}</dd></div></dl>
              <Box className="pos-total"><Text className="pos-total-label">Total da venda</Text><Text className="pos-total-value">{money(cart.total)}</Text></Box>
            </Box>
            {confirming ? <Alert mt="sm" color="yellow" title="Revisar venda e documento fiscal" icon={<IconReceipt size={18} />}>
              <Text size="sm">O estoque será baixado uma vez. A solicitação de {fiscalDocument === 'nfe' ? 'NF-e (modelo 55)' : 'NFC-e (modelo 65)'} ficará registrada; a nota só será considerada autorizada após o retorno da SEFAZ.</Text>
              <Group justify="flex-end" mt="sm"><Button variant="default" onClick={() => setConfirming(false)}>Voltar</Button><Button color="brand" loading={busy === 'cart-confirm'} onClick={() => confirmCart(payment, fiscalDocument, () => setConfirming(false))}>Registrar e solicitar nota</Button></Group>
            </Alert> : <Button fullWidth className="pos-confirm-sale" leftSection={<IconReceipt size={18} />} disabled={!cart.items.length} onClick={() => setConfirming(true)}>Registrar venda e emitir nota</Button>}
            <Text className="pos-fiscal-notice">Confira os dados antes de concluir. A emissão fiscal está pendente de configuração{environmentMode === 'production' ? ' no SICNET' : ' no ambiente de teste'}.</Text>
          </Box>
        </Box>
      </Paper>
    </Box>
    <Drawer opened={manualSearchOpen} onClose={() => { setManualSearchOpen(false); setManualQuery(''); }} position="right" size="xl" title={<Box><Text size="xs" fw={800} lts=".08em" c="teal">BUSCA MANUAL</Text><Title order={3}>Produtos disponíveis no estoque</Title></Box>} className="stock-search-drawer">
      <TextInput aria-label="Pesquisar produto no estoque" size="md" placeholder="Busque por nome, código, marca, cor ou tamanho" leftSection={<IconSearch size={19} />} value={manualQuery} onChange={(event) => setManualQuery(event.currentTarget.value)} autoFocus />
      <Group justify="space-between" mt="sm" mb="md"><Text size="sm" c="dimmed">Selecione uma peça para adicionar à comanda.</Text><Badge color="brand" variant="light">{manualMatches.length} resultados</Badge></Group>
      <ScrollArea className="manual-stock-results">
        {manualMatches.length ? <Stack gap="sm">{manualMatches.map((unit) => <Paper key={unit.barcode} withBorder radius="md" p="md" className="pos-product-row"><Group justify="space-between" wrap="nowrap"><CheckoutProductPhoto unit={unit} /><Box className="pos-product-copy"><Text fw={700} lineClamp={1}>{unit.name}</Text><Text size="sm" c="dimmed">{[unit.brand, unit.category, unit.color, unit.size].filter(Boolean).join(' · ') || 'Sem variação informada'}</Text><Text size="xs" ff="monospace" c="dimmed">{unit.barcode}</Text></Box><Group gap="md" wrap="nowrap"><Text fw={800} className="pos-product-price">{money(unit.price)}</Text><Button variant="light" color="brand" leftSection={<IconPlus size={16} />} loading={busy === `cart-add-${unit.barcode}`} onClick={() => addManualProduct(unit)} aria-label={`Adicionar ${unit.name} ao caixa`}>Adicionar</Button></Group></Group></Paper>)}</Stack> : <EmptyState title={available.length ? 'Nenhum produto encontrado' : 'Nenhuma peça disponível'} text={available.length ? 'Tente buscar por outro nome ou código.' : 'As peças disponíveis aparecerão aqui para venda.'} icon={<IconSearch size={32} />} />}
      </ScrollArea>
    </Drawer>
  </>;
}

function ProductPage({ draft, setDraft, onSave, onCancel, busy, mode, environmentMode }) {
  const [additionalOpen, setAdditionalOpen] = useState(false);
  const [photoBusy, setPhotoBusy] = useState(false);
  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const updateFiscal = (key, value) => setDraft((current) => ({ ...current, fiscal: { ...current.fiscal, [key]: value } }));
  const updateVariant = (index, key, value) => setDraft((current) => ({ ...current, variants: current.variants.map((variant, row) => row === index ? { ...variant, [key]: key === 'quantity' ? (String(value).trim() === '' ? '' : (Number.isFinite(Number(value)) ? Number(value) : String(value))) : value } : variant) }));
  const addVariant = () => setDraft((current) => ({ ...current, variants: [...current.variants, emptyVariant()] }));
  const removeVariant = (index) => setDraft((current) => ({ ...current, variants: current.variants.length === 1 ? [emptyVariant()] : current.variants.filter((_, row) => row !== index) }));
  const validVariants = draft.variants.filter((variant) => variant.color && variant.size && Number.isInteger(Number(variant.quantity)) && Number(variant.quantity) >= 1 && Number(variant.quantity) <= 500);
  const pieces = validVariants.reduce((sum, variant) => sum + Number(variant.quantity), 0);
  const title = mode === 'edit' ? 'Editar peça' : 'Novo produto';
  return <Box className="product-page">
    <PageHeading eyebrow="Estoque  /  Cadastro" title={title} description={mode === 'edit' ? 'Altere os dados da peça selecionada.' : 'Cadastre o produto e informe as peças disponíveis.'} onBack={onCancel} />
    <Alert color="yellow" icon={<IconInfoCircle size={18} />} mb="md">{environmentMode === 'production' ? 'SICNET · Emissão fiscal pendente de configuração' : 'Ambiente de teste · Emissão fiscal pendente de configuração'}</Alert>
    <Box className="product-layout">
      <Stack gap="md" className="product-main">
    <Paper withBorder radius="md" p="lg"><SectionTitle number="1" title="Informações do produto" /><Stack gap="sm" mt="md"><TextInput label="Nome do produto" required value={draft.name} onChange={(event) => update('name', event.currentTarget.value)} autoFocus /><SimpleGrid cols={{ base: 1, sm: 3 }}><TextInput label="Marca (opcional)" placeholder="Informe a marca" value={draft.brand} onChange={(event) => update('brand', event.currentTarget.value)} /><TextInput label="Tipo de peça" placeholder="Ex.: camiseta, calça" value={draft.category} onChange={(event) => update('category', event.currentTarget.value)} /><TextInput label="Código interno (opcional)" value={draft.internal_code} onChange={(event) => update('internal_code', event.currentTarget.value)} /></SimpleGrid><SimpleGrid cols={2}><MoneyInput label="Preço de custo" value={draft.cost} onChange={(value) => update('cost', value)} /><MoneyInput label="Preço de venda" required value={draft.price} onChange={(value) => update('price', value)} /></SimpleGrid>{mode === 'edit' ? <SimpleGrid cols={2}><TextInput label="Cor" value={draft.color} onChange={(event) => update('color', event.currentTarget.value)} /><TextInput label="Tamanho" value={draft.size} onChange={(event) => update('size', event.currentTarget.value)} /></SimpleGrid> : <Text size="sm" c="dimmed">O mesmo preço será aplicado às peças deste cadastro.</Text>}</Stack></Paper>
        <Paper withBorder radius="md" p="lg"><ProductPhotoField value={draft.photo} onChange={(value) => update('photo', value)} disabled={busy} onBusyChange={setPhotoBusy} /></Paper>
        <Paper withBorder radius="md" p="lg"><Group justify="space-between" mb="xs"><SectionTitle number="2" title="Cores, tamanhos e quantidades" /></Group><Text size="sm" c="dimmed" ml={42} mb="sm">Adicione uma linha para cada combinação de cor e tamanho.</Text><VariantTable variants={draft.variants} onChange={updateVariant} onRemove={removeVariant} readOnly={mode === 'edit'} /><Group justify="space-between" mt="sm"><Button variant="default" leftSection={<IconPlus size={17} />} onClick={addVariant} disabled={mode === 'edit'}>Adicionar variação</Button><Text size="sm" fw={700} c="dimmed">{integer.format(pieces)} peças no total</Text></Group></Paper>
        <Paper withBorder radius="md" p={0}><Button fullWidth variant="subtle" justify="space-between" rightSection={additionalOpen ? <IconChevronDown size={17} /> : <IconChevronRight size={17} />} leftSection={<IconChevronRight size={17} />} onClick={() => setAdditionalOpen((value) => !value)} className="additional-toggle">Informações adicionais <Text span size="sm" c="dimmed" fw={400}>Localização, observações e dados fiscais</Text></Button><Collapse expanded={additionalOpen}><Box p="lg" pt={0}><SimpleGrid cols={2} mt="md"><TextInput label="Localização" value={draft.location} onChange={(event) => update('location', event.currentTarget.value)} /></SimpleGrid><Textarea mt="sm" label="Observações" minRows={3} value={draft.notes} onChange={(event) => update('notes', event.currentTarget.value)} /><Text fw={700} mt="lg" mb="sm">Dados fiscais</Text><SimpleGrid cols={2}>{[...fiscalTextKeys, ...fiscalNumberKeys].map((key) => <TextInput key={key} label={fiscalLabels[key]} value={valueText(draft.fiscal[key])} onChange={(event) => updateFiscal(key, event.currentTarget.value)} />)}</SimpleGrid></Box></Collapse></Paper>
      </Stack>
      <SummaryCard draft={draft} variants={validVariants} pieces={pieces} />
    </Box>
    <Paper withBorder radius={0} className="product-actions"><Text size="sm" c="dimmed">Confira as quantidades antes de cadastrar.</Text><Group><Button variant="default" disabled={busy || photoBusy} onClick={onCancel}>Cancelar</Button><Button color="brand" leftSection={<IconDeviceFloppy size={17} />} loading={busy} disabled={photoBusy} onClick={() => onSave(draft)}>{mode === 'edit' ? 'Salvar alterações' : 'Cadastrar produto'}</Button></Group></Paper>
  </Box>;
}

function SectionTitle({ number, title }) { return <Group gap="sm"><ThemeIcon color="brand" radius="xl" size={31}><Text fw={800}>{number}</Text></ThemeIcon><Title order={3}>{title}</Title></Group>; }

function MoneyInput({ label, value, onChange, required }) { return <TextInput label={label} required={required} leftSection={<Text size="sm" c="dimmed">R$</Text>} value={value} onChange={(event) => onChange(event.currentTarget.value)} />; }

function VariantTable({ variants, onChange, onRemove, readOnly }) {
  return <Box className="variant-table"><Table withColumnBorders={false}><Table.Thead><Table.Tr><Table.Th>COR</Table.Th><Table.Th>TAMANHO</Table.Th><Table.Th>QUANTIDADE</Table.Th><Table.Th w={52} /></Table.Tr></Table.Thead><Table.Tbody>{variants.map((variant, index) => { const quantity = Number(variant.quantity); const numericQuantity = Number.isFinite(quantity); return <Table.Tr key={index}><Table.Td><Autocomplete aria-label={`Cor da variação ${index + 1}`} placeholder="Escolha ou digite" data={colorOptions} value={variant.color || ''} onChange={(value) => onChange(index, 'color', value)} disabled={readOnly} /></Table.Td><Table.Td><Autocomplete aria-label={`Tamanho da variação ${index + 1}`} placeholder="Escolha ou digite" data={sizeOptions} value={variant.size || ''} onChange={(value) => onChange(index, 'size', value)} disabled={readOnly} /></Table.Td><Table.Td><Group gap={0} wrap="nowrap" className="quantity-control"><ActionIcon variant="default" aria-label="Diminuir quantidade" disabled={readOnly || !numericQuantity || quantity <= 1} onClick={() => onChange(index, 'quantity', quantity - 1)}><IconMinus size={15} /></ActionIcon><TextInput aria-label={`Quantidade da variação ${index + 1}`} value={String(variant.quantity)} onChange={(event) => onChange(index, 'quantity', event.currentTarget.value)} disabled={readOnly} styles={{ input: { textAlign: 'center', borderRadius: 0 } }} /><ActionIcon variant="default" aria-label="Aumentar quantidade" disabled={readOnly || !numericQuantity || quantity >= 500} onClick={() => onChange(index, 'quantity', quantity + 1)}><IconPlus size={15} /></ActionIcon></Group></Table.Td><Table.Td><Tooltip label="Remover variação"><ActionIcon color="red" variant="subtle" aria-label={`Remover variação ${index + 1}`} disabled={readOnly} onClick={() => onRemove(index)}><IconTrash size={17} /></ActionIcon></Tooltip></Table.Td></Table.Tr>; })}</Table.Tbody></Table></Box>;
}

function SummaryCard({ draft, variants, pieces }) {
  const first = variants[0]; return <Paper withBorder radius="md" p="lg" className="summary-card"><Title order={3}>Resumo do cadastro</Title><Title order={2} mt="lg" className="summary-name">{draft.name.trim() || 'Produto novo'}</Title><Divider my="md" /><SummaryMetric label="Preço por peça" value={money(draft.price)} /><SummaryMetric label="Variações" value={integer.format(variants.length)} /><SummaryMetric label="Peças a cadastrar" value={integer.format(pieces)} bold /><Alert color="brand" variant="light" mt="lg" icon={<IconBarcode size={30} />}><Text size="sm" fw={700}>Cada peça recebe um código próprio.</Text><Text size="sm">Os códigos são gerados automaticamente ao cadastrar.</Text></Alert><LabelExample name={draft.name.trim() || 'Produto novo'} variant={first ? `${first.color} · ${first.size}` : 'Cor · Tamanho'} price={money(draft.price)} /></Paper>;
}

function SummaryMetric({ label, value, bold }) { return <Group justify="space-between" py="sm" className="summary-metric"><Text c="dimmed">{label}</Text><Text fw={bold ? 800 : 500}>{value}</Text></Group>; }

function LabelExample({ name, variant, price }) { return <Box className="label-example"><Text size="sm" fw={700} mb="xs">Exemplo de etiqueta</Text><Card withBorder radius="md" p="md" className="label-card"><Text fw={800} ta="center" lineClamp={1}>{name}</Text><Text c="dimmed" ta="center" size="sm">{variant}</Text><Group justify="center" my="sm"><IconBarcode size={64} stroke={1.5} aria-label="Código de barras" /></Group><Text fw={800} ta="center" size="lg">{price}</Text><Text c="dimmed" ta="center" size="xs">Código gerado no cadastro</Text></Card></Box>; }

const historyReasonLabels = { initial: 'Entrada inicial', sale: 'Venda', adjustment: 'Ajuste' };
const historyDateFormatter = new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short' });

function historyReason(reason) {
  return historyReasonLabels[valueText(reason).trim().toLowerCase()] || 'Operação';
}

function historyMovement(delta) {
  const numeric = typeof delta === 'number' ? delta : Number(valueText(delta).trim().replace(',', '.'));
  if (!Number.isFinite(numeric)) return '—';
  const amount = integer.format(Math.abs(numeric));
  const sign = numeric > 0 ? '+' : numeric < 0 ? '-' : '';
  return `${sign}${amount} ${Math.abs(numeric) === 1 ? 'peça' : 'peças'}`;
}

function historyDate(value) {
  let date;
  if (value instanceof Date) date = value;
  else {
    const raw = valueText(value).trim();
    const dotNet = raw.match(/^\/Date\((-?\d+)(?:[+-]\d+)?\)\/$/);
    date = dotNet ? new Date(Number(dotNet[1])) : new Date(raw);
  }
  return date && Number.isFinite(date.getTime()) ? historyDateFormatter.format(date) : 'Data indisponível';
}

function reportPeriodRange(period) {
  const now = new Date();
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  if (period === 'week') {
    const mondayOffset = (start.getDay() + 6) % 7;
    start.setDate(start.getDate() - mondayOffset);
  } else if (period === 'year') {
    start.setMonth(0, 1);
  } else {
    start.setDate(1);
  }
  const end = new Date(start);
  if (period === 'week') end.setDate(end.getDate() + 7);
  else if (period === 'year') end.setFullYear(end.getFullYear() + 1);
  else end.setMonth(end.getMonth() + 1);
  return { from: start.toISOString(), to: end.toISOString() };
}

function reportNumber(value) {
  const number = typeof value === 'number' ? value : Number(value || 0);
  return Number.isFinite(number) ? number : 0;
}

function reportStatus(value) {
  const labels = { pending_adapter: 'Aguardando emissor', authorized: 'Autorizada', rejected: 'Rejeitada', cancelled: 'Cancelada', not_requested: 'Sem nota' };
  return labels[valueText(value)] || 'Pendente';
}

function ReportBars({ title, rows }) {
  const maximum = Math.max(1, ...(rows || []).map((row) => reportNumber(row.revenue)));
  return <Paper withBorder radius="md" p="lg"><Group justify="space-between" mb="md"><Title order={3}>{title}</Title><Text size="sm" c="dimmed">Por faturamento</Text></Group>{rows && rows.length ? <Stack gap="sm">{rows.slice(0, 8).map((row) => <Box key={row.label}><Group justify="space-between" mb={4}><Text size="sm" fw={600}>{row.label}</Text><Text size="sm" c="dimmed">{money(row.revenue)} · {integer.format(reportNumber(row.items))} itens</Text></Group><Progress value={(reportNumber(row.revenue) / maximum) * 100} color="brand" radius="xl" /></Box>)}</Stack> : <EmptyState title="Sem saídas no período" text="Os agrupamentos aparecerão quando houver vendas." icon={<IconChartBar size={32} />} />}</Paper>;
}

function SalesDashboardPage() {
  const [filters, setFilters] = useState({ period: 'month', brand: 'all', category: 'all', payment: 'all', query: '' });
  const [state, setState] = useState({ loading: true, report: null, error: null });
  const updateFilter = (key, value) => setFilters((current) => ({ ...current, [key]: value || (key === 'query' ? '' : 'all') }));
  const load = () => {
    const range = reportPeriodRange(filters.period);
    setState((current) => ({ ...current, loading: true, error: null }));
    callHost('sales.report', { ...range, brand: filters.brand === 'all' ? '' : filters.brand, category: filters.category === 'all' ? '' : filters.category, payment: filters.payment === 'all' ? '' : filters.payment, query: filters.query.trim() })
      .then((report) => setState({ loading: false, report, error: null }))
      .catch((error) => setState({ loading: false, report: null, error }));
  };
  useEffect(() => { load(); }, [filters.period, filters.brand, filters.category, filters.payment]);
  const report = state.report || { summary: {}, filters: {}, by_category: [], by_brand: [], rows: [] };
  const brands = [{ value: 'all', label: 'Todas as marcas' }, ...(report.filters.brands || []).map((value) => ({ value, label: value }))];
  const categories = [{ value: 'all', label: 'Todos os tipos' }, ...(report.filters.categories || []).map((value) => ({ value, label: value }))];
  return <>
    <PageHeading title="Vendas e saídas" description="Veja o que saiu do estoque por período, marca e tipo de peça." action={<Button variant="default" leftSection={<IconRefresh size={17} />} onClick={load}>Atualizar</Button>} />
    <Paper withBorder radius="md" p="md" mb="md"><Group align="flex-end" wrap="wrap"><Select label="Período" value={filters.period} onChange={(value) => updateFilter('period', value)} data={[{ value: 'week', label: 'Esta semana' }, { value: 'month', label: 'Este mês' }, { value: 'year', label: 'Este ano' }]} w={170} /><Select label="Marca" value={filters.brand} onChange={(value) => updateFilter('brand', value)} data={brands} w={190} /><Select label="Tipo de peça" value={filters.category} onChange={(value) => updateFilter('category', value)} data={categories} w={190} /><Select label="Pagamento" value={filters.payment} onChange={(value) => updateFilter('payment', value)} data={[{ value: 'all', label: 'Todos' }, { value: 'pix', label: 'Pix' }, { value: 'cash', label: 'Dinheiro' }, { value: 'credit', label: 'Cartão de crédito' }, { value: 'debit', label: 'Cartão de débito' }]} w={190} /><TextInput label="Buscar produto ou código" value={filters.query} onChange={(event) => updateFilter('query', event.currentTarget.value)} onKeyDown={(event) => { if (event.key === 'Enter') load(); }} w={230} /></Group></Paper>
    {state.error ? <Alert color="red" mb="md" title="Não foi possível carregar o relatório" icon={<IconRefresh size={18} />}><Text size="sm">{state.error.message}</Text><Button mt="sm" size="xs" variant="default" onClick={load}>Tentar novamente</Button></Alert> : null}
    {state.loading && !state.report ? <Paper withBorder radius="md" p="xl"><Text c="dimmed">Carregando vendas e saídas…</Text></Paper> : <>
      <SimpleGrid cols={{ base: 1, sm: 2, lg: 4 }} mb="md"><MetricCard label="Faturamento" value={money(report.summary.revenue)} /><MetricCard label="Vendas" value={integer.format(reportNumber(report.summary.sales))} /><MetricCard label="Peças que saíram" value={integer.format(reportNumber(report.summary.items))} /><MetricCard label="Ticket médio" value={money(report.summary.average_ticket)} /></SimpleGrid>
      <SimpleGrid cols={{ base: 1, lg: 2 }} mb="md"><ReportBars title="Saída por tipo de peça" rows={report.by_category} /><ReportBars title="Saída por marca" rows={report.by_brand} /></SimpleGrid>
      <Paper withBorder radius="md" p="lg"><Group justify="space-between" mb="md"><Box><Title order={3}>Detalhamento das saídas</Title><Text size="sm" c="dimmed">{integer.format((report.rows || []).length)} linhas no período selecionado</Text></Box><Badge color="brand" variant="light">Estoque rastreável</Badge></Group>{report.rows && report.rows.length ? <ScrollArea><Table highlightOnHover><Table.Thead><Table.Tr><Table.Th>DATA</Table.Th><Table.Th>PRODUTO</Table.Th><Table.Th>MARCA / TIPO</Table.Th><Table.Th>QTD.</Table.Th><Table.Th ta="right">TOTAL</Table.Th><Table.Th>PAGAMENTO</Table.Th><Table.Th>FISCAL</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{report.rows.map((row, index) => <Table.Tr key={`${row.sale_id}-${row.barcode || index}`}><Table.Td>{historyDate(row.created_at)}</Table.Td><Table.Td><Text fw={600}>{row.name || 'Produto'}</Text><Text size="xs" c="dimmed" ff="monospace">{row.barcode || row.internal_code || '—'}</Text></Table.Td><Table.Td>{[row.brand, row.category].filter(Boolean).join(' · ') || 'Sem classificação'}</Table.Td><Table.Td>{integer.format(reportNumber(row.quantity))}</Table.Td><Table.Td ta="right">{money(row.line_total)}</Table.Td><Table.Td>{valueText(row.payment).toUpperCase()}</Table.Td><Table.Td><Badge color={row.fiscal_status === 'authorized' ? 'brand' : 'yellow'} variant="light">{reportStatus(row.fiscal_status)}</Badge></Table.Td></Table.Tr>)}</Table.Tbody></Table></ScrollArea> : <EmptyState title="Nenhuma saída encontrada" text="Altere o período ou os filtros para consultar outras vendas." icon={<IconChartBar size={32} />} />}</Paper>
    </>}
  </>;
}

function MetricCard({ label, value }) {
  return <Paper withBorder radius="md" p="lg"><Text size="sm" c="dimmed">{label}</Text><Text size="xl" fw={800} mt="xs">{value}</Text></Paper>;
}

function HistoryPage() {
  const [state, setState] = useState({ loading: true, rows: [], error: null });
  const load = () => { setState((current) => ({ ...current, loading: true, error: null })); callHost('history.list', {}).then((data) => setState({ loading: false, rows: data && Array.isArray(data.items) ? data.items : [], error: null })).catch((error) => setState({ loading: false, rows: [], error })); };
  useEffect(() => { load(); }, []);
  return <><PageHeading title="Histórico" description="Operações registradas no laboratório." /><Paper withBorder radius="md" p="lg">{state.loading ? <Text c="dimmed">Carregando histórico…</Text> : state.error ? <Alert color="red" title="Não foi possível carregar o histórico" icon={<IconRefresh size={18} />}><Text size="sm">{state.error.message}</Text><Button mt="sm" variant="default" size="xs" onClick={load}>Tentar novamente</Button></Alert> : state.rows.length ? <ScrollArea><Table><Table.Thead><Table.Tr><Table.Th>OPERAÇÃO</Table.Th><Table.Th>CÓDIGO</Table.Th><Table.Th>MOVIMENTO</Table.Th><Table.Th>DATA</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{state.rows.map((row, index) => <Table.Tr key={row.id || index}><Table.Td>{historyReason(row.reason)}</Table.Td><Table.Td ff="monospace">{row.barcode || row.sic_document_id || '—'}</Table.Td><Table.Td>{historyMovement(row.delta)}</Table.Td><Table.Td>{historyDate(row.created_at)}</Table.Td></Table.Tr>)}</Table.Tbody></Table></ScrollArea> : <EmptyState title="Nenhum registro por aqui" text="As operações aparecerão nesta tela conforme você usar o sistema." icon={<IconHistory size={32} />} />}</Paper></>;
}

function LabelsPage() {
  const [state, setState] = useState({ loading: true, html: '', error: null });
  const load = () => { setState((current) => ({ ...current, loading: true, error: null })); callHost('labels.preview', {}).then((data) => setState({ loading: false, html: data && data.html ? data.html : '', error: null })).catch((error) => setState({ loading: false, html: '', error })); };
  useEffect(() => { load(); }, []);
  const exportLabels = () => callHost('labels.export', {}).catch((error) => setState((current) => ({ ...current, error })));
  return <><PageHeading title="Etiquetas" description="Confira as etiquetas individuais antes de exportar." action={<Button color="brand" leftSection={<IconFileExport size={17} />} onClick={exportLabels}>Exportar etiquetas</Button>} /><Paper withBorder radius="md" p="lg" className="labels-preview">{state.loading ? <Text c="dimmed">Carregando prévia…</Text> : state.error ? <Alert color="red" title="Não foi possível carregar as etiquetas"><Text size="sm">{state.error.message}</Text><Button mt="sm" variant="default" size="xs" onClick={load}>Tentar novamente</Button></Alert> : state.html ? <iframe title="Prévia das etiquetas" srcDoc={state.html} sandbox="" /> : <EmptyState title="Nenhuma etiqueta disponível" text="Cadastre peças com saldo disponível para gerar a prévia." icon={<IconTag size={32} />} />}</Paper></>;
}

function SettingsPage() {
  const [state, setState] = useState({ info: null, error: null });
  const load = () => {
    setState((current) => ({ ...current, error: null }));
    callHost('settings.info', {}).then((info) => setState({ info, error: null })).catch((error) => setState({ info: null, error }));
  };
  useEffect(() => { load(); const timer = window.setInterval(load, 5000); return () => window.clearInterval(timer); }, []);
  const info = state.info;
  const syncStatus = valueText(info && info.sync_state);
  const status = info && info.sync_configured
    ? syncStatus === 'up_to_date' ? { label: 'Loja sincronizada', color: 'brand' }
      : syncStatus === 'conflict' ? { label: 'Conflito para conferir', color: 'red' }
        : { label: 'Sincronização pendente', color: 'yellow' }
    : { label: 'Aguardando configuração', color: 'gray' };
  return <>
    <PageHeading title="Configurações" description="O sistema trabalha em segundo plano para manter a loja atualizada." />
    {state.error ? <Alert color="red" mb="md" title="Não foi possível carregar as configurações"><Text size="sm">{state.error.message}</Text><Button mt="sm" variant="default" size="xs" onClick={load}>Tentar novamente</Button></Alert> : null}
    <SimpleGrid cols={{ base: 1, md: 2 }}>
      <Paper withBorder radius="md" p="lg">
        <Title order={3}>Operação automática</Title>
        <Text c="dimmed" mt="xs">Produtos e vendas são enviados e confirmados sem etapas técnicas para você.</Text>
        <Group mt="lg"><Badge color={status.color} variant="light">{status.label}</Badge><Text size="sm">Ambiente {info && info.mode ? info.mode : 'laboratório'}</Text></Group>
      </Paper>
      <Paper withBorder radius="md" p="lg">
        <Title order={3}>Precisa de ajuda?</Title>
        <Text c="dimmed" mt="xs">Deixe o Lineboard aberto no computador da loja. Se alguma operação ficar pendente, tente novamente nesta tela.</Text>
      </Paper>
    </SimpleGrid>
  </>;
}

function EditDrawer({ unit, onClose, onSave, busy }) {
  const [photoBusy, setPhotoBusy] = useState(false);
  const [draft, setDraft] = useState(null);
  useEffect(() => { setDraft(unit ? makeDraftFromUnit(unit) : null); }, [unit]);
  if (!draft) return null;
  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const updateFiscal = (key, value) => setDraft((current) => ({ ...current, fiscal: { ...current.fiscal, [key]: value } }));
  const submit = () => {
    const nextDraft = draft.request_id ? draft : { ...draft, request_id: requestId() };
    setDraft(nextDraft);
    onSave(nextDraft);
  };
  return <Modal opened={Boolean(unit)} onClose={busy || photoBusy ? () => {} : onClose} closeOnClickOutside={!busy && !photoBusy} closeOnEscape={!busy && !photoBusy} withCloseButton={!busy && !photoBusy} title="Editar peça" centered size={960} radius="md" padding="lg" classNames={{ content: 'stock-modal stock-edit-modal', header: 'stock-modal-header', body: 'stock-modal-body' }}>
    <Stack>
      <TextInput label="Nome do produto" required value={draft.name} onChange={(event) => update('name', event.currentTarget.value)} />
      <SimpleGrid cols={{ base: 1, sm: 3 }}>
        <TextInput label="Marca" value={draft.brand} onChange={(event) => update('brand', event.currentTarget.value)} />
        <TextInput label="Tipo de peça" value={draft.category} onChange={(event) => update('category', event.currentTarget.value)} />
        <TextInput label="Código interno" value={draft.internal_code} onChange={(event) => update('internal_code', event.currentTarget.value)} />
      </SimpleGrid>
      <SimpleGrid cols={2}>
        <TextInput label="Cor" value={draft.color} onChange={(event) => update('color', event.currentTarget.value)} />
        <TextInput label="Tamanho" value={draft.size} onChange={(event) => update('size', event.currentTarget.value)} />
      </SimpleGrid>
      <SimpleGrid cols={2}>
        <MoneyInput label="Preço de custo" value={draft.cost} onChange={(value) => update('cost', value)} />
        <MoneyInput label="Preço de venda" required value={draft.price} onChange={(value) => update('price', value)} />
      </SimpleGrid>
      <TextInput label="Localização" value={draft.location} onChange={(event) => update('location', event.currentTarget.value)} />
      <ProductPhotoField value={draft.photo} onChange={(value) => update('photo', value)} disabled={busy} onBusyChange={setPhotoBusy} />
      <Textarea label="Observações" value={draft.notes} onChange={(event) => update('notes', event.currentTarget.value)} />
      <Text fw={700}>Dados fiscais</Text>
      <SimpleGrid cols={2}>{[...fiscalTextKeys, ...fiscalNumberKeys].map((key) => <TextInput key={key} label={fiscalLabels[key]} value={valueText(draft.fiscal[key])} onChange={(event) => updateFiscal(key, event.currentTarget.value)} />)}</SimpleGrid>
      <Button color="brand" loading={busy} disabled={photoBusy} onClick={submit}>Salvar alterações</Button>
    </Stack>
  </Modal>;
}

function AdjustDrawer({ unit, onClose, onSave, busy }) { const [quantity, setQuantity] = useState(1); const [reason, setReason] = useState(''); useEffect(() => { setQuantity(1); setReason(''); }, [unit]); return <Modal opened={Boolean(unit)} onClose={onClose} title="Entrada / ajuste" centered size={480} radius="md" padding="lg" classNames={{ content: 'stock-modal stock-adjust-modal', header: 'stock-modal-header', body: 'stock-modal-body' }}><Stack><Text c="dimmed">Atualize a disponibilidade de <strong>{unit && unit.name}</strong>.</Text><Select label="Novo saldo" value={String(quantity)} onChange={(value) => setQuantity(Number(value))} data={[{ value: '0', label: 'Indisponível (saldo 0)' }, { value: '1', label: 'Disponível (saldo 1)' }]} /><Textarea label="Motivo do ajuste (obrigatório)" required value={reason} onChange={(event) => setReason(event.currentTarget.value)} /><Button color="brand" loading={busy} disabled={!reason.trim()} onClick={() => onSave(quantity, reason)}>Registrar ajuste</Button></Stack></Modal>; }

function EmptyState({ title, text, icon }) { return <Stack align="center" justify="center" gap="xs" py="xl" c="dimmed">{icon || <IconArchive size={32} />}<Text fw={700}>{title}</Text><Text size="sm" ta="center">{text}</Text></Stack>; }

export default App;
