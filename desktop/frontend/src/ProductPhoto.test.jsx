import { MantineProvider } from '@mantine/core';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ProductPhotoField, readPhoto } from './ProductPhoto.jsx';
import { clearBridgeMock, setBridgeMock } from './bridge.js';

const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
afterEach(() => clearBridgeMock());

it.each([
  ['produto.jpg', 'image/jpeg'],
  ['produto.JPG', ''],
  ['produto.jpeg', 'image/jpg'],
])('accepts %s using the JPEG content even with missing or alternative MIME', async (name, type) => {
  const file = new File([new Uint8Array([255, 216, 255, 224])], name, { type });
  await expect(readPhoto(file)).resolves.toEqual({ content_type: 'image/jpeg', data: '/9j/4A==' });
});

it('uploads the selected file and returns a stable photo reference', async () => {
  const onChange = vi.fn(); const onBusy = vi.fn(); const calls = [];
  setBridgeMock(({ action, payload }) => { calls.push({ action, payload }); return { photo_path: 'store/file.png' }; });
  render(<MantineProvider><ProductPhotoField value="" onChange={onChange} onBusyChange={onBusy} /></MantineProvider>);
  fireEvent.change(screen.getByLabelText('Escolher imagem do produto'), { target: { files: [new File([png], 'photo.png', { type: 'image/png' })] } });
  await waitFor(() => expect(onChange).toHaveBeenCalledWith('store/file.png'));
  expect(calls[0]).toEqual({ action: 'photo.upload', payload: { content_type: 'image/png', data: 'iVBORw0KGgo=' } });
  expect(onBusy.mock.calls).toEqual([[true], [false]]);
});

it('rejects unsupported and oversized files before calling the desktop', async () => {
  await expect(readPhoto(new File(['<svg/>'], 'fake.png', { type: 'image/png' }))).rejects.toThrow('JPEG, PNG ou WebP');
  await expect(readPhoto(new File([new Uint8Array(5 * 1024 * 1024 + 1)], 'large.png'))).rejects.toThrow('5 MB');
});

it('retains the previous reference when an upload fails and allows removal', async () => {
  const onChange = vi.fn();
  setBridgeMock(({ action }) => { if (action === 'photo.url') return { url: 'https://example.com/test.png' }; throw new Error('Sem conexão'); });
  render(<MantineProvider><ProductPhotoField value="store/existing.png" onChange={onChange} onBusyChange={() => {}} /></MantineProvider>);
  fireEvent.change(screen.getByLabelText('Escolher imagem do produto'), { target: { files: [new File([png], 'photo.png')] } });
  expect(await screen.findByRole('alert')).toHaveTextContent('Sem conexão');
  expect(onChange).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Remover imagem' }));
  expect(onChange).toHaveBeenCalledWith('');
});

it('explains an outdated native executable when its bridge does not recognize photo uploads', async () => {
  const onChange = vi.fn();
  setBridgeMock(() => ({ ok: false, error: { code: 'UNKNOWN_ACTION', message: 'A ação solicitada não está disponível.' } }));
  render(<MantineProvider><ProductPhotoField value="" onChange={onChange} onBusyChange={() => {}} /></MantineProvider>);
  fireEvent.change(screen.getByLabelText('Escolher imagem do produto'), { target: { files: [new File([png], 'photo.png')] } });
  expect(await screen.findByRole('alert')).toHaveTextContent('O executável do Lineboard está desatualizado');
  expect(onChange).not.toHaveBeenCalled();
});
