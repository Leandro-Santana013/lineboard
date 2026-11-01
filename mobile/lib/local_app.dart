import 'package:flutter/material.dart';

import 'app.dart' show sea, ink;
import 'local_gateway.dart';
import 'local_product_form.dart';
import 'scan_label.dart';

class LocalLineboardApp extends StatefulWidget {
  const LocalLineboardApp(this.gateway, {super.key});
  final LocalGateway gateway;
  @override
  State<LocalLineboardApp> createState() => _LocalLineboardAppState();
}

class _LocalLineboardAppState extends State<LocalLineboardApp> {
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Lineboard',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: sea),
      scaffoldBackgroundColor: const Color(0xFFF5F7F4),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: widget.gateway.paired
        ? LocalHome(widget.gateway, onUnpaired: () => setState(() {}))
        : PairDesktopPage(widget.gateway, onPaired: () => setState(() {})),
  );
}

class PairDesktopPage extends StatefulWidget {
  const PairDesktopPage(this.gateway, {required this.onPaired, super.key});
  final LocalGateway gateway;
  final VoidCallback onPaired;
  @override
  State<PairDesktopPage> createState() => _PairDesktopPageState();
}

class _PairDesktopPageState extends State<PairDesktopPage> {
  final address = TextEditingController();
  final pin = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    address.dispose();
    pin.dispose();
    super.dispose();
  }

  Future<void> pair() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.pair(address.text, pin.text);
      if (mounted) widget.onPaired();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is LocalApiError ? e.toString() : 'Computador não encontrado. Confira o endereço e conecte os dois aparelhos ao mesmo Wi-Fi.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lineboard • conectar à loja')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.storefront, size: 64, color: sea),
              const SizedBox(height: 24),
              const Text(
                'Conecte seu celular ao caixa',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: ink,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'No desktop, abra “Parear celular”. Use o endereço do computador e o código exibido. O cadastro e a leitura funcionam pela rede local.',
              ),
              const SizedBox(height: 20),
              TextField(
                controller: address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Endereço do desktop',
                  hintText: 'http://192.168.1.10:47831',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pin,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Código de pareamento',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              FilledButton(
                onPressed: busy ? null : pair,
                child: Text(busy ? 'Conectando…' : 'Conectar ao desktop'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Versão de laboratório: usa uma cópia isolada do SIC. Não emite notas nem processa pagamentos.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LocalHome extends StatefulWidget {
  const LocalHome(this.gateway, {required this.onUnpaired, super.key});
  final LocalGateway gateway;
  final VoidCallback onUnpaired;
  @override
  State<LocalHome> createState() => _LocalHomeState();
}

class _LocalHomeState extends State<LocalHome> {
  bool busy = false;
  String? message;
  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is LocalApiError ? e.toString() : 'O desktop não confirmou a solicitação. Retome para conferir o resultado.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    await perform(() async {
      await widget.gateway.addCode(code);
      if (mounted) {
        setState(
          () => message =
              '$code enviado ao carrinho. Confira e confirme a compra no desktop.',
        );
      }
    });
  }

  Future<void> identify() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    await perform(() async {
      final item = await widget.gateway.lookup(code);
      if (mounted) {
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => LabelPage(item)));
      }
    });
  }

  Future<void> discard(String kind) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar tentativa pendente?'),
        content: const Text(
          'Isso apaga apenas a tentativa no celular. Uma operação que já chegou ao desktop continuará registrada. Confira o caixa antes de cadastrar ou enviar de novo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Descartar tentativa'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.gateway.discard(kind);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Lineboard • loja'),
      actions: [
        IconButton(
          tooltip: 'Desconectar deste caixa',
          icon: const Icon(Icons.link_off),
          onPressed: busy
              ? null
              : () async {
                  await widget.gateway.unpair();
                  if (mounted) widget.onUnpaired();
                },
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Cadastro e leitor do caixa',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        Text('Desktop: ${widget.gateway.address}'),
        const SizedBox(height: 8),
        const Text(
          'Laboratório • a leitura adiciona a peça ao carrinho. A baixa acontece somente no desktop.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: busy ? null : scan,
          icon: const Icon(Icons.barcode_reader),
          label: const Text('Escanear para o caixa'),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalProductForm(widget.gateway),
                    ),
                  );
                  if (mounted) setState(() {});
                },
          icon: const Icon(Icons.add_box_outlined),
          label: const Text('Cadastrar produto e gerar etiquetas'),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: busy ? null : identify,
          icon: const Icon(Icons.label_outline),
          label: const Text('Identificar peça / reimprimir etiqueta'),
        ),
        if (widget.gateway.pendingRequest('scan') != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'Uma leitura está aguardando confirmação do desktop.',
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            await widget.gateway.retryScan();
                            if (mounted) {
                              setState(
                                () => message = 'Leitura confirmada no carrinho do desktop.',
                              );
                            }
                          }),
                    child: const Text('Retomar envio da leitura'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => discard('scan'),
                    child: const Text('Descartar tentativa'),
                  ),
                ],
              ),
            ),
          ),
        if (widget.gateway.pendingRequest('product') != null)
          Card(
            child: ListTile(
              title: const Text('Cadastro aguardando confirmação'),
              subtitle: const Text(
                'Abra o cadastro para recuperar as mesmas peças e códigos.',
              ),
              trailing: IconButton(
                onPressed: busy ? null : () => discard('product'),
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(message!),
          ),
      ],
    ),
  );
}
