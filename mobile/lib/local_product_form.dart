import 'package:flutter/material.dart';

import 'domain.dart';
import 'local_gateway.dart';
import 'scan_label.dart';
import 'product_photo.dart';

class LocalProductForm extends StatefulWidget {
  const LocalProductForm(this.gateway, {super.key});
  final LocalGateway gateway;
  @override
  State<LocalProductForm> createState() => _LocalProductFormState();
}

class _LocalProductFormState extends State<LocalProductForm> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{
    for (final key in [
      'name',
      'brand',
      'cost',
      'price',
      'location',
      'notes',
      'internal_code',
    ])
      key: TextEditingController(
        text: key == 'cost' || key == 'price' ? '0,00' : '',
      ),
  };
  final variants =
      <
        ({
          TextEditingController color,
          TextEditingController size,
          TextEditingController quantity,
        })
      >[];
  final taxes = <String, TextEditingController>{
    for (final key in [
      'codipi',
      'cst',
      'cean',
      'cest',
      'origem',
      'icms',
      'ipi',
      'basecalculo',
      'cst_pis',
      'cst_cofins',
      'cclasstrib',
    ])
      key: TextEditingController(),
  };
  bool busy = false;
  ProductPhoto? photo;
  String? uploadedPhotoPath;
  String? error;
  List<CatalogItem>? created;
  @override
  void initState() {
    super.initState();
    addVariant();
  }

  void addVariant() => variants.add((
    color: TextEditingController(),
    size: TextEditingController(),
    quantity: TextEditingController(text: '1'),
  ));
  @override
  void dispose() {
    for (final c in [...fields.values, ...taxes.values]) {
      c.dispose();
    }
    for (final v in variants) {
      v.color.dispose();
      v.size.dispose();
      v.quantity.dispose();
    }
    super.dispose();
  }

  double? money(String value) =>
      double.tryParse(value.trim().replaceAll(',', '.'));
  Future<void> save() async {
    if (busy) return;
    final pending = widget.gateway.pendingRequest('product');
    if (pending == null && !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (pending == null && photo != null && uploadedPhotoPath == null) {
        uploadedPhotoPath = await widget.gateway.uploadPhoto(photo!);
      }
      final result = pending != null
          ? await widget.gateway.retryProduct()
          : await widget.gateway.createProduct({
              'photo': uploadedPhotoPath ?? '',
              for (final entry in fields.entries)
                entry.key: entry.key == 'cost' || entry.key == 'price'
                    ? money(entry.value.text)!
                    : entry.value.text.trim(),
              'variants': [
                for (final v in variants)
                  {
                    'color': v.color.text.trim(),
                    'size': v.size.text.trim(),
                    'quantity': int.parse(v.quantity.text),
                  },
              ],
              'fiscal': {
                for (final entry in taxes.entries)
                  if (entry.value.text.trim().isNotEmpty)
                    entry.key:
                        [
                          'origem',
                          'icms',
                          'ipi',
                          'basecalculo',
                        ].contains(entry.key)
                        ? money(entry.value.text)!
                        : entry.value.text.trim(),
              },
            });
      if (mounted) {
        setState(
          () => created = (result['units'] as List)
              .map((e) => CatalogItem(Map<String, dynamic>.from(e)))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is LocalApiError ? e.toString() : 'O desktop não confirmou o cadastro. Retome para recuperar os mesmos códigos.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    int? max,
    bool required = false,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final text = (value ?? '').trim();
        if (required && text.isEmpty) return 'Preencha este campo.';
        if (max != null && text.length > max) return 'Use até $max caracteres.';
        if (numeric &&
            text.isNotEmpty &&
            (money(text) == null || money(text)! < 0)) {
          return 'Informe um número positivo.';
        }
        return null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (created != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Peças e etiquetas')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '${created!.length} peças cadastradas no desktop. Cada etiqueta identifica uma unidade.',
            ),
            for (final item in created!)
              Card(
                child: ListTile(
                  title: Text(item.name),
                  subtitle: Text('${item.variant}\n${item.barcode}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.label_outline),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LabelPage(item, gateway: widget.gateway),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final pending = widget.gateway.pendingRequest('product') != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Cadastrar produto')),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (pending)
              const Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: Text(
                  'Há um cadastro pendente neste caixa. Retome a confirmação para recuperar as peças sem gerar códigos duplicados.',
                ),
              ),
            if (!pending) ...[
              field(
                fields['name']!,
                'Nome do produto',
                max: 50,
                required: true,
              ),
              field(fields['brand']!, 'Marca / fabricante', max: 20),
              field(
                fields['cost']!,
                'Preço de custo',
                required: true,
                numeric: true,
              ),
              field(
                fields['price']!,
                'Preço de venda',
                required: true,
                numeric: true,
              ),
              field(
                fields['internal_code']!,
                'Código interno (opcional)',
                max: 20,
              ),
              field(fields['location']!, 'Localização', max: 80),
              ProductPhotoField(
                photo: photo,
                enabled: !busy,
                onChanged: (value) => setState(() {
                  photo = value;
                  uploadedPhotoPath = null;
                }),
              ),
              field(fields['notes']!, 'Observações', max: 4000),
              const Text(
                'Grade e quantidades',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < variants.length; i++)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text('Variante ${i + 1}'),
                        field(variants[i].color, 'Cor', max: 40),
                        field(variants[i].size, 'Tamanho / medida', max: 40),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextFormField(
                            controller: variants[i].quantity,
                            enabled: !busy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Quantidade de peças',
                            ),
                            validator: (value) {
                              final n = int.tryParse(value ?? '');
                              return n == null || n < 1 || n > 500
                                  ? 'Informe de 1 a 500 peças.'
                                  : null;
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton(
                onPressed: busy || variants.length >= 100
                    ? null
                    : () => setState(addVariant),
                child: const Text('Adicionar variante'),
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('Dados fiscais (opcionais nesta etapa)'),
                children: [
                  for (final entry in taxes.entries)
                    field(
                      entry.value,
                      const {
                        'codipi': 'NCM',
                        'cst': 'CST / CSOSN',
                        'cean': 'GTIN',
                        'cest': 'CEST',
                        'origem': 'Origem',
                        'icms': 'ICMS (%)',
                        'ipi': 'IPI (%)',
                        'basecalculo': 'Base de cálculo (%)',
                        'cst_pis': 'CST PIS',
                        'cst_cofins': 'CST Cofins',
                        'cclasstrib': 'Classificação tributária',
                      }[entry.key]!,
                      numeric: [
                        'origem',
                        'icms',
                        'ipi',
                        'basecalculo',
                      ].contains(entry.key),
                    ),
                ],
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(
                busy
                    ? 'Confirmando no desktop…'
                    : pending
                    ? 'Retomar cadastro pendente'
                    : 'Cadastrar e gerar códigos individuais',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
