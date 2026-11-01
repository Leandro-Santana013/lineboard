import React from 'react';
import { createRoot } from 'react-dom/client';
import { MantineProvider } from '@mantine/core';
import '@mantine/core/styles.css';
import './styles.css';
import App from './App.jsx';

const theme = {
  primaryColor: 'teal',
  fontFamily: 'Segoe UI, Arial, sans-serif',
  headings: { fontFamily: 'Segoe UI, Arial, sans-serif', fontWeight: '700' },
  defaultRadius: 'sm',
  colors: { teal: ['#e6fbfa', '#c8f1f0', '#9ee7e2', '#66d7d1', '#28bbb8', '#078f96', '#007e87', '#00666e', '#004d55', '#003a41'] },
};

createRoot(document.getElementById('root')).render(<MantineProvider theme={theme} defaultColorScheme="light"><App /></MantineProvider>);
