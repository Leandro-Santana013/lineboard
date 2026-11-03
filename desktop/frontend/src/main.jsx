import React from 'react';
import { createRoot } from 'react-dom/client';
import { MantineProvider } from '@mantine/core';
import '@mantine/core/styles.css';
import './styles.css';
import App from './App.jsx';
import { theme } from './theme.js';

createRoot(document.getElementById('root')).render(<MantineProvider theme={theme} defaultColorScheme="light"><App /></MantineProvider>);
