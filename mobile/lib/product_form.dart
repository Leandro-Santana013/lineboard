import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';
import 'domain.dart';
import 'repository.dart';
import 'scan_label.dart';
import 'product_photo.dart';

class VariantFields {
  final color = TextEditingController();
  final size = TextEditingController();
  final quantity = TextEditingController(text: '1');
  void dispose() {
    color.dispose();
    size.dispose();
    quantity.dispose();
  }

  Map<String, dynamic> toJson() => {
    'color': color.text.trim(),
    'size': size.text.trim(),
    'quantity': int.parse(quantity.text),
  };
}

class ProductForm extends StatefulWidget {
  const ProductForm(this.repo, this.org, {super.key});
  final Repository repo;
  final String org;
  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      category = TextEditingController(),
      brand = TextEditingController(),
      model = TextEditingController(),
      cost = TextEditingController(text: '0,00'),
      price = TextEditingController(text: '0,00'),
      notes = TextEditingController();
  final variants = [VariantFields()];
  String tracking = 'quantity';
  ProductPhoto? photo;
  bool busy = false;
  String? error;
  Map<String, dynamic>? pending;
  List<CatalogItem>? labels;
  @override
  void initState() {
    super.initState();
    pending = widget.repo.pendingProduct(widget.org);
    if (pending != null) {
      final saved = pending!['product'] as Map;
      name.text = saved['name'] ?? '';
      category.text = saved['category'] ?? '';
      brand.text = saved['brand'] ?? '';
      model.text = saved['model'] ?? '';
      cost.text = _moneyText(saved['cost']);
      price.text = _moneyText(saved['price']);
      notes.text = saved['notes'] ?? '';
      tracking = saved['tracking'];
      variants.single.dispose();
      variants.clear();
      for (final value in saved['variants'] as List) {
        variants.add(
          VariantFields()
            ..color.text = value['color'] ?? ''
            ..size.text = value['size'] ?? ''
            ..quantity.text = value['quantity'].toString(),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in [
      name,
      category,
      brand,
      model,
      cost,
      price,
      notes,
    ]) {
      controller.dispose();
    }
    for (final variant in variants) {
      variant.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (pending == null && !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (pending == null) {
        // Check real server access; Wi-Fi availability alone does not prove internet.
        await widget.repo.client
            .from('memberships')
            .select('role')
            .eq('organization_id', widget.org)
            .eq('user_id', widget.repo.userId)
            .single()
            .timeout(const Duration(seconds: 12));
        final unique = <String>{};
        for (final v in variants) {
          if (!unique.add(
            '${v.color.text.trim()}\u0000${v.size.text.trim()}',
          )) {
            throw const FormatException('DUPLICATE_VARIANT');
          }
        }
        String? path;
        if (photo != null) {
          path = await widget.repo.uploadPhoto(widget.org, photo!);
        }
        final product = <String, dynamic>{
          'name': name.text.trim(),
          'category': category.text.trim(),
          'brand': brand.text.trim(),
          'model': model.text.trim(),
          'cost': _money(cost.text),
          'price': _money(price.text),
          'notes': notes.text.trim(),
          'tracking': tracking,
          'variants': variants.map((v) => v.toJson()).toList(),
          'photo_path': path,
        };
        final key = const Uuid().v4();
        await widget.repo.savePendingProduct(widget.org, key, product);
        pending = {'key': key, 'product': product};
      }
      final created = await widget.repo.sendProduct(widget.org, pending!);
      final rawUnits = created['units'];
      final result = rawUnits is List
          ? rawUnits
                .map(
                  (item) => CatalogItem(Map<String, dynamic>.from(item as Map)),
                )
                .toList()
          : await widget.repo.productLabels(
              widget.org,
              created['product_id'] as String,
            );
      // Leave pending until labels are recovered: a failed lookup can be retried safely.
      await widget.repo.clearPendingProduct(widget.org);
      if (mounted) {
        setState(() => labels = result);
      }
      // Home will refresh its offline catalog when requested; do not delay the result.
    } catch (e) {
      if (e is PostgrestException &&
          [
            'INVALID_PRODUCT',
            'INVALID_VARIANTS',
            'INVALID_QUANTITY',
            '23505',
            '23514',
            '23502',
          ].any((code) => e.message.contains(code) || e.code == code)) {
        // A transactional validation failure is definitive, so the form can be corrected.
        await widget.repo.clearPendingProduct(widget.org);
        pending = null;
      }
      if (mounted) {
        setState(
          () => error = switch (e.toString()) {
            final s when s.contains('DUPLICATE_VARIANT') =>
              'Não repita a mesma combinação de cor e tamanho.',
            final s when s.contains('PHOTO_TOO_LARGE') =>
              'A foto deve ter no máximo 5 MB.',
            final s when s.contains('INVALID_PHOTO_TYPE') =>
              'Escolha uma foto JPEG, PNG ou WebP.',
            _ => friendlyError(e),
          },
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (labels != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Produto cadastrado')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.check_circle, size: 56, color: accent),
            const SizedBox(height: 16),
            const Text(
              'Salvo na sua loja.',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text('Os produtos novos são impressos somente com código de barras.'),
            const SizedBox(height: 24),
            for (final item in labels!)
              Card(
                child: ListTile(
                  title: Text(item.name),
                  subtitle: Text('${item.variant}\n${item.barcode}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.ios_share),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LabelPage(item, repo: widget.repo),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (pending != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Retomar cadastro')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.cloud_sync_outlined, size: 56, color: accent),
            const SizedBox(height: 24),
            Text(
              pending!['product']['name'],
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            const Text(
              'O resultado deste cadastro ainda precisa ser confirmado. Retome para recuperar os mesmos códigos, sem criar outro produto.',
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(
                busy ? 'Confirmando…' : 'Confirmar e recuperar etiquetas',
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Cadastrar produto')),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Uma ficha. Todas as variantes.',
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text('O código é gerado e registrado na nuvem ao salvar.'),
            const SizedBox(height: 24),
            field(name, 'Nome do produto', required: true, limit: 160),
            field(category, 'Categoria'),
            field(brand, 'Marca'),
            field(model, 'Modelo'),
            Row(
              children: [
                Expanded(child: moneyField(cost, 'Custo')),
                const SizedBox(width: 12),
                Expanded(
                  child: moneyField(price, 'Preço de venda', required: true),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: tracking,
              decoration: const InputDecoration(labelText: 'Controle'),
              items: const [
                DropdownMenuItem(
                  value: 'quantity',
                  child: Text('Quantidade por variante'),
                ),
                DropdownMenuItem(
                  value: 'individual',
                  child: Text('Cada unidade física'),
                ),
              ],
              onChanged: busy ? null : (v) => setState(() => tracking = v!),
            ),
            const SizedBox(height: 12),
            Text(
              tracking == 'quantity'
                  ? 'Peças iguais usam a mesma etiqueta.'
                  : 'Cada unidade recebe uma etiqueta exclusiva.',
            ),
            const SizedBox(height: 24),
            for (var i = 0; i < variants.length; i++) variantCard(i),
            OutlinedButton.icon(
              onPressed: busy || variants.length >= 100
                  ? null
                  : () => setState(() => variants.add(VariantFields())),
              icon: const Icon(Icons.add),
              label: const Text('Adicionar variante'),
            ),
            const SizedBox(height: 20),
            field(notes, 'Observações', lines: 3, limit: 2000),
            ProductPhotoField(
              photo: photo,
              enabled: !busy,
              onChanged: (value) => setState(() => photo = value),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(
                busy ? 'Salvando na nuvem…' : 'Salvar e gerar etiquetas',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool required = false,
    int lines = 1,
    int limit = 120,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      maxLines: lines,
      maxLength: limit,
      decoration: InputDecoration(labelText: label, counterText: ''),
      validator: (v) => required && (v == null || v.trim().isEmpty)
          ? 'Preencha este campo.'
          : null,
    ),
  );
  Widget moneyField(
    TextEditingController controller,
    String label, {
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, prefixText: r'R$ '),
      validator: (value) {
        final parsed = _money(value ?? '');
        if (parsed == null || parsed < 0 || (required && parsed == 0)) {
          return required
              ? 'Informe um valor maior que zero.'
              : 'Informe um valor válido.';
        }
        return null;
      },
    ),
  );

  double? _money(String value) {
    var normalized = value.trim().replaceAll(r'R$', '').replaceAll(' ', '');
    if (normalized.contains(',')) {
      normalized = normalized.replaceAll('.', '').replaceAll(',', '.');
    }
    return double.tryParse(normalized);
  }

  String _moneyText(Object? value) => value == null
      ? '0,00'
      : (double.tryParse(value.toString()) ?? 0)
            .toStringAsFixed(2)
            .replaceAll('.', ',');
  Widget variantCard(int i) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Variante ${i + 1}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (variants.length > 1)
                IconButton(
                  tooltip: 'Remover variante',
                  onPressed: busy
                      ? null
                      : () => setState(() => variants.removeAt(i).dispose()),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          field(variants[i].color, 'Cor'),
          field(variants[i].size, 'Tamanho / medida'),
          TextFormField(
            controller: variants[i].quantity,
            enabled: !busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantidade inicial'),
            validator: (v) {
              final amount = int.tryParse(v ?? '');
              final max = tracking == 'individual' ? 500 : 100000;
              final min = tracking == 'individual' ? 1 : 0;
              return amount == null || amount < min || amount > max
                  ? 'Informe um número inteiro de $min a $max.'
                  : null;
            },
          ),
        ],
      ),
    ),
  );
}
