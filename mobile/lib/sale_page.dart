import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';
import 'domain.dart';
import 'repository.dart';
import 'scan_label.dart';

class SalePage extends StatefulWidget {
  const SalePage(this.repo, this.org, {super.key});
  final Repository repo;
  final String org;
  @override
  State<SalePage> createState() => _SalePageState();
}

class _SalePageState extends State<SalePage> {
  final basket = SaleBasket();
  final reference = TextEditingController();
  PendingSale? pending;
  String? error, saleId;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    pending = widget.repo.pendingSale(widget.org);
  }

  @override
  void dispose() {
    reference.dispose();
    super.dispose();
  }

  Future<void> scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final item = await widget.repo.lookup(
        widget.org,
        code,
      ); // Sales never use cached identities.
      basket.add(item);
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is StateError && !e.toString().contains('BARCODE_NOT_FOUND')
              ? e.message.toString()
              : friendlyError(e),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    if (pending == null) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirmar saída física?'),
          content: const Text(
            'Os itens desta venda serão baixados do estoque central.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar venda'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (pending == null) {
        // Freeze payload on first send. An unknown result must be retried with the same key.
        final candidate = PendingSale(
          key: const Uuid().v4(),
          lines: basket.toJson(),
          reference: reference.text.trim(),
        );
        await widget.repo.savePendingSale(widget.org, candidate);
        pending = candidate;
      }
      final result = await widget.repo.sendSale(widget.org, pending!);
      await widget.repo.clearPendingSale(widget.org);
      if (mounted) setState(() => saleId = result['sale_id'] as String);
    } catch (e) {
      if (e is PostgrestException &&
          [
            'INSUFFICIENT_STOCK',
            'BARCODE_NOT_FOUND',
            'INVALID_LINES',
            '23505',
          ].any((code) => e.message.contains(code) || e.code == code)) {
        // A definitive transactional rejection made no changes. Permit correcting the cart.
        await widget.repo.clearPendingSale(widget.org);
        pending = null;
      }
      if (mounted) {
        setState(() => error = friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (saleId != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Saída registrada')),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              const Icon(Icons.check_circle, size: 72, color: sea),
              const SizedBox(height: 24),
              const Text(
                'Venda confirmada.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              const Text(
                'A saída foi registrada no estoque central.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SelectableText(
                'Comprovante: $saleId',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Concluir'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar saída')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Escaneie. Confira. Confirme.',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Use esta operação para vendas físicas. As vendas do e-commerce serão registradas pela integração.',
          ),
          const SizedBox(height: 24),
          if (pending != null) ...[
            const Card(
              color: Color(0xFFFFEBC6),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Aguardando confirmação do servidor. Retome esta mesma operação para evitar uma saída duplicada.',
                ),
              ),
            ),
            for (final line in pending!.lines)
              ListTile(
                title: Text(line['barcode']),
                trailing: Text('${line['quantity']} un.'),
              ),
            if (pending!.reference.isNotEmpty)
              Text('Referência: ${pending!.reference}'),
          ] else ...[
            for (final line in basket.lines.toList())
              Card(
                child: ListTile(
                  title: Text(line.item.name),
                  subtitle: Text('${line.item.variant}\n${line.item.barcode}'),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Diminuir',
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                line.quantity--;
                                if (line.quantity == 0) {
                                  basket.lines.remove(line);
                                }
                              }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('${line.quantity}'),
                      if (line.item.tracking == 'quantity')
                        IconButton(
                          tooltip: 'Aumentar',
                          onPressed: busy
                              ? null
                              : () => setState(() => line.quantity++),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                    ],
                  ),
                ),
              ),
            if (basket.lines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Nenhum item nesta venda. Escaneie uma etiqueta para começar.',
                ),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : scan,
              icon: const Icon(Icons.barcode_reader),
              label: Text(busy ? 'Buscando produto…' : 'Escanear item'),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: reference,
              enabled: !busy,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Referência da venda (opcional)',
                helperText: 'Ex.: número do comprovante do balcão',
              ),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy || (pending == null && basket.lines.isEmpty)
                ? null
                : confirm,
            child: Text(
              busy
                  ? 'Confirmando no servidor…'
                  : pending == null
                  ? 'Conferir e confirmar saída'
                  : 'Retomar confirmação',
            ),
          ),
        ],
      ),
    );
  }
}
