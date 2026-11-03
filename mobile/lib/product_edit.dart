import 'package:flutter/material.dart';

import 'domain.dart';
import 'repository.dart';
import 'product_photo.dart';

class ProductEditDialog extends StatefulWidget {
  const ProductEditDialog(this.item, this.repo, {super.key});
  final CatalogItem item;
  final Repository repo;
  @override
  State<ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends State<ProductEditDialog> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  bool busy = false;
  String? error;
  ProductPhoto? photo;
  String? uploadedPhotoPath;
  String? currentPhotoUrl;
  bool photoChanged = false;
  bool get hasPhoto =>
      !photoChanged &&
      (widget.item.data['photo_path'] as String? ?? '').isNotEmpty;
  static const names = {
    'name': 'Nome do produto',
    'category': 'Categoria',
    'brand': 'Marca',
    'model': 'Modelo',
    'notes': 'Observações',
  };
  @override
  void initState() {
    super.initState();
    fields = {
      for (final key in names.keys)
        key: TextEditingController(text: widget.item.data[key] ?? ''),
    };
    loadPhoto();
  }

  Future<void> loadPhoto() async {
    if (!hasPhoto) return;
    try {
      final url = await widget.repo.photoUrl(widget.item.data['photo_path']);
      if (mounted && !photoChanged) setState(() => currentPhotoUrl = url);
    } catch (_) {
      /* The product remains editable if its image is unavailable. */
    }
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final payload = <String, dynamic>{
        ...fields.map((key, field) => MapEntry(key, field.text.trim())),
      };
      if (photoChanged) {
        if (photo != null && uploadedPhotoPath == null) {
          uploadedPhotoPath = await widget.repo.uploadPhoto(
            widget.item.data['organization_id'],
            photo!,
          );
        }
        payload['photo_path'] = photo == null ? null : uploadedPhotoPath;
      }
      await widget.repo.updateProduct(widget.item, payload);
      if (mounted) Navigator.pop(context, payload);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? photoError(e) : friendlyError(e),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Editar ficha'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Estas informações são compartilhadas por todas as variantes do produto.',
                ),
                const SizedBox(height: 16),
                for (final entry in fields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextFormField(
                      controller: entry.value,
                      enabled: !busy,
                      maxLength: entry.key == 'notes'
                          ? 2000
                          : entry.key == 'name'
                          ? 160
                          : 120,
                      maxLines: entry.key == 'notes' ? 3 : 1,
                      decoration: InputDecoration(
                        labelText: names[entry.key],
                        counterText: '',
                      ),
                      validator: (v) =>
                          entry.key == 'name' && (v == null || v.trim().isEmpty)
                          ? 'Preencha o nome.'
                          : null,
                    ),
                  ),
                ProductPhotoField(
                  photo: photo,
                  currentUrl: currentPhotoUrl,
                  hasCurrentPhoto: hasPhoto,
                  enabled: !busy,
                  onChanged: (value) => setState(() {
                    photoChanged = true;
                    photo = value;
                    uploadedPhotoPath = null;
                    currentPhotoUrl = null;
                  }),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Salvando…' : 'Salvar na nuvem'),
        ),
      ],
    ),
  );
}
