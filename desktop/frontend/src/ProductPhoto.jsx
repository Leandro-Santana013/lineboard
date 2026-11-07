import { useEffect, useRef, useState } from 'react';
import { Alert, Box, Button, Group, SimpleGrid, Stack, Text } from '@mantine/core';
import { callHost } from './bridge.js';

const urls = new Map();
const maxBytes = 5 * 1024 * 1024;
const maxPhotos = 6;

export function readPhoto(file) {
  if (file.size > maxBytes) return Promise.reject(new Error('Escolha uma imagem de até 5 MB.'));
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Não foi possível ler esta imagem.'));
    reader.onload = () => {
      const data = String(reader.result).split(',')[1] || '';
      const header = atob(data.slice(0, 24));
      const content_type = header.startsWith('\xff\xd8\xff') ? 'image/jpeg'
        : header.startsWith('\x89PNG\r\n\x1a\n') ? 'image/png'
          : header.startsWith('RIFF') && header.slice(8, 12) === 'WEBP' ? 'image/webp' : null;
      if (!content_type) reject(new Error('Escolha uma imagem JPG/JPEG, PNG ou WebP válida.'));
      else resolve({ content_type, data });
    };
    reader.readAsDataURL(file);
  });
}

export function ProductPhotoPreview({ path, name = 'produto', size = 140, fallback }) {
  const [url, setUrl] = useState('');
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let active = true;
    setUrl(''); setFailed(false);
    if (!path) return;
    const load = async () => {
      try {
        let entry = urls.get(path);
        if (!entry || entry.expires < Date.now()) {
          const promise = callHost('photo.url', { photo_path: path });
          entry = { promise, expires: Date.now() + 240000 };
          urls.set(path, entry);
          promise.catch(() => { if (urls.get(path) === entry) urls.delete(path); });
        }
        const result = await entry.promise;
        if (!result.url) throw new Error('Imagem indisponível.');
        if (active) { setUrl(result.url); setFailed(false); }
      } catch { if (active) setFailed(true); }
    };
    load();
    const timer = window.setInterval(load, 240000);
    return () => { active = false; window.clearInterval(timer); };
  }, [path]);
  if (!path) return fallback ?? null;
  return <Box style={{ width: size, minWidth: size }}>
    {url && !failed ? <img src={url} alt={`Foto de ${name}`} width={size} height={size} style={{ objectFit: 'contain', borderRadius: 8 }} onError={() => setFailed(true)} />
      : fallback ?? <Text size="xs" c="dimmed">{failed ? 'Imagem indisponível' : 'Carregando imagem…'}</Text>}
  </Box>;
}

export function ProductPhotoField({ value, onChange, disabled, onBusyChange }) {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const active = useRef(true);
  const paths = Array.isArray(value) ? value.filter(Boolean) : (value ? [value] : []);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  const select = async (event) => {
    const files = Array.from(event.currentTarget.files || []);
    event.currentTarget.value = '';
    if (!files.length) return;
    if (paths.length + files.length > maxPhotos) { setError('É possível adicionar no máximo 6 imagens por produto.'); return; }
    setUploading(true); setError(''); if (onBusyChange) onBusyChange(true);
    const uploaded = [];
    try {
      for (const file of files) {
        const payload = await readPhoto(file);
        const result = await callHost('photo.upload', payload);
        if (!result.photo_path) throw new Error('Não foi possível enviar esta imagem.');
        uploaded.push(result.photo_path);
      }
      if (active.current) onChange([...paths, ...uploaded]);
    } catch (failure) {
      if (active.current && uploaded.length) onChange([...paths, ...uploaded]);
      if (active.current) setError(failure.code === 'UNKNOWN_ACTION'
        ? 'O executável do Linesboard está desatualizado. Feche o programa e instale a versão atualizada para enviar imagens.'
        : failure.message || 'Não foi possível enviar esta imagem.');
    } finally {
      if (active.current) { setUploading(false); if (onBusyChange) onBusyChange(false); }
    }
  };
  return <Stack gap="xs">
    <Text fw={600}>Imagens do produto (opcional)</Text>
    <Text size="sm" c="dimmed">JPG/JPEG, PNG ou WebP, até 5 MB cada. Adicione até 6 imagens compartilhadas pelas variações.</Text>
    {paths.length ? <SimpleGrid cols={{ base: 2, sm: 3, md: 6 }} spacing="xs">{paths.map((path, index) => <Box key={`${path}-${index}`} style={{ position: 'relative', width: 105, minWidth: 105, height: 105 }}><ProductPhotoPreview path={path} size={105} /><Button size="compact-xs" variant="filled" color="red" style={{ position: 'absolute', top: 4, right: 4, zIndex: 2, padding: 0 }} aria-label={`Remover imagem ${index + 1}`} disabled={disabled || uploading} onClick={() => { setError(''); onChange(paths.filter((_, row) => row !== index)); }}>×</Button></Box>)}</SimpleGrid> : <Text size="sm" c="dimmed">Nenhuma imagem adicionada.</Text>}
    <Group>
      <Button component="label" variant="light" color="brand" disabled={disabled || uploading || paths.length >= maxPhotos}>
        {uploading ? 'Enviando imagens…' : 'Adicionar imagens'}
        <input type="file" multiple aria-label="Escolher imagens do produto" accept=".jpg,.jpeg,.png,.webp,image/jpeg,image/png,image/webp" hidden disabled={disabled || uploading || paths.length >= maxPhotos} onChange={select} />
      </Button>
      <Text size="sm" c="dimmed">{paths.length}/{maxPhotos}</Text>
    </Group>
    {error ? <Alert color="red" role="alert">{error}</Alert> : null}
  </Stack>;
}
