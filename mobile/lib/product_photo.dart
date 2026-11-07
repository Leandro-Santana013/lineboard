import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class ProductPhoto {
  ProductPhoto(this.bytes) : contentType = validate(bytes);
  final Uint8List bytes;
  final String contentType;
  String get extension => switch (contentType) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    _ => 'jpg',
  };

  static const maxBytes = 5 * 1024 * 1024;
  static String validate(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const FormatException('PHOTO_TOO_LARGE');
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((matches) => matches);
    if (starts([0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
    if (starts([82, 73, 70, 70]) &&
        bytes.length >= 12 &&
        bytes[8] == 87 &&
        bytes[9] == 69 &&
        bytes[10] == 66 &&
        bytes[11] == 80) {
      return 'image/webp';
    }
    throw const FormatException('INVALID_PHOTO_TYPE');
  }
}

class ProductPhotoSelection {
  ProductPhotoSelection.remote(this.path) : photo = null;
  ProductPhotoSelection.local(ProductPhoto this.photo) : path = null;

  final String? path;
  final ProductPhoto? photo;
  String? uploadedPath;
}

String photoError(Object error) => switch (error.toString()) {
  final message when message.contains('PHOTO_TOO_LARGE') =>
    'A foto deve ter no máximo 5 MB.',
  final message when message.contains('INVALID_PHOTO_TYPE') =>
    'Escolha uma foto JPG/JPEG, PNG ou WebP válida.',
  _ =>
    'Não foi possível abrir a foto. Confira as permissões e tente novamente.',
};

class ProductPhotoField extends StatelessWidget {
  const ProductPhotoField({
    super.key,
    required this.photos,
    required this.onChanged,
    this.photoUrls = const {},
    this.enabled = true,
  });
  final List<ProductPhotoSelection> photos;
  final ValueChanged<List<ProductPhotoSelection>> onChanged;
  final Map<String, String> photoUrls;
  final bool enabled;

  Future<void> choose(BuildContext context, ImageSource source) async {
    if (photos.length >= 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('É possível adicionar no máximo 6 imagens.'),
        ),
      );
      return;
    }
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );
      if (file == null) return;
      if (await file.length() > ProductPhoto.maxBytes) {
        throw const FormatException('PHOTO_TOO_LARGE');
      }
      final selected = ProductPhoto(await file.readAsBytes());
      if (context.mounted) {
        onChanged([...photos, ProductPhotoSelection.local(selected)]);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(photoError(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Imagens do produto (opcional)'),
      const SizedBox(height: 8),
      if (photos.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < photos.length; index++)
              SizedBox(
                width: 112,
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _preview(photos[index]),
                    ),
                    TextButton(
                      onPressed: enabled
                          ? () => onChanged([
                              for (var i = 0; i < photos.length; i++)
                                if (i != index) photos[i],
                            ])
                          : null,
                      child: Text('Remover ${index + 1}'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: enabled && photos.length < 6
                ? () => choose(context, ImageSource.gallery)
                : null,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Escolher imagem'),
          ),
          OutlinedButton.icon(
            onPressed: enabled && photos.length < 6
                ? () => choose(context, ImageSource.camera)
                : null,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Tirar foto'),
          ),
          Text('${photos.length}/6'),
        ],
      ),
      const Text('JPG/JPEG, PNG ou WebP. Até 5 MB cada.'),
      const SizedBox(height: 12),
    ],
  );

  Widget _preview(ProductPhotoSelection selection) {
    final photo = selection.photo;
    if (photo != null) {
      return Image.memory(
        photo.bytes,
        height: 100,
        width: 112,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Text('Prévia indisponível.'),
      );
    }
    final url = photoUrls[selection.path];
    if (url == null) {
      return const SizedBox(
        height: 100,
        width: 112,
        child: Center(child: Text('Imagem indisponível.')),
      );
    }
    return Image.network(
      url,
      height: 100,
      width: 112,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Text('Imagem indisponível.'),
    );
  }
}
