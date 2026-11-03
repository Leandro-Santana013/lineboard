import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:share_plus/share_plus.dart';

import 'app.dart';
import 'domain.dart';
import 'repository.dart';
import 'product_edit.dart';
import 'local_gateway.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final controller = MobileScannerController(
    formats: [BarcodeFormat.code128],
    detectionSpeed: DetectionSpeed.normal,
    autoZoom: true,
  );
  final manual = TextEditingController();
  bool accepted = false;
  String guidance = 'Aponte para o código e mantenha o celular firme.';
  DateTime? lastInvalidFeedback;
  @override
  void dispose() {
    controller.dispose();
    manual.dispose();
    super.dispose();
  }

  Future<void> accept(String code, {bool manualEntry = false}) async {
    if (accepted) return;
    code = canonicalBarcode(code);
    if (!validBarcode(code)) {
      showInvalidFeedback();
      if (manualEntry && mounted) {
        toast(context, 'Use um código interno SLB com 12 dígitos.');
      }
      return;
    }
    accepted = true;
    try {
      await controller.stop();
    } catch (_) {
      // The decoded value remains valid even if the camera cannot stop cleanly.
    }
    if (mounted) Navigator.of(context).pop(code);
  }

  void showInvalidFeedback() {
    final now = DateTime.now();
    if (lastInvalidFeedback != null &&
        now.difference(lastInvalidFeedback!) < const Duration(seconds: 2)) {
      return;
    }
    lastInvalidFeedback = now;
    if (mounted) {
      setState(
        () => guidance = 'Código visto, mas não é uma etiqueta Lineboard. Centralize o código inteiro.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ler etiqueta'),
      actions: [
        IconButton(
          tooltip: 'Lanterna',
          onPressed: controller.toggleTorch,
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: controller,
                  useAppLifecycleState: true,
                  onDetect: (capture) {
                    final decision = selectBarcode(
                      capture.barcodes.map((code) => code.rawValue),
                    );
                    if (decision.code != null) {
                      accept(decision.code!);
                    } else if (decision.sawValue) {
                      showInvalidFeedback();
                    }
                  },
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.no_photography, size: 48),
                          const SizedBox(height: 16),
                          const Text(
                            'Câmera indisponível. Autorize a câmera nas configurações do celular ou digite o código abaixo.',
                          ),
                          TextButton(
                            onPressed: controller.start,
                            child: const Text('Tentar novamente'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: Center(
                    child: Container(
                      height: 150,
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF6EE7CA),
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  guidance,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: lastInvalidFeedback == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Evite reflexos e aproxime ou afaste devagar até o código ficar nítido.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: manual,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Ou digite o código',
                    hintText: 'SLB-000000000001',
                    suffixIcon: IconButton(
                      onPressed: () => accept(manual.text, manualEntry: true),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                  onSubmitted: (value) => accept(value, manualEntry: true),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class BarcodeSelection {
  const BarcodeSelection({this.code, required this.sawValue});
  final String? code;
  final bool sawValue;
}

BarcodeSelection selectBarcode(Iterable<String?> values) {
  var sawValue = false;
  for (final rawValue in values) {
    if (rawValue == null || rawValue.trim().isEmpty) continue;
    sawValue = true;
    final code = canonicalBarcode(rawValue);
    if (validBarcode(code)) {
      return BarcodeSelection(code: code, sawValue: true);
    }
  }
  return BarcodeSelection(sawValue: sawValue);
}

class LabelPage extends StatefulWidget {
  const LabelPage(
    this.item, {
    super.key,
    this.repo,
    this.gateway,
    this.offline = false,
  });
  final CatalogItem item;
  final Repository? repo;
  final LocalGateway? gateway;
  final bool offline;
  @override
  State<LabelPage> createState() => _LabelPageState();
}

class _LabelPageState extends State<LabelPage> {
  final boundary = GlobalKey();
  bool sharing = false;
  String? photoUrl;
  CatalogItem? updatedItem;
  CatalogItem get item => updatedItem ?? widget.item;
  Future<void> edit() async {
    final fields = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ProductEditDialog(item, widget.repo!),
    );
    if (fields != null && mounted) {
      setState(() {
        updatedItem = CatalogItem({...item.data, ...fields});
        photoUrl = null;
      });
      await loadPhoto();
    }
  }

  @override
  void initState() {
    super.initState();
    loadPhoto();
  }

  Future<void> loadPhoto() async {
    final path = item.data['photo_path'];
    if (widget.offline ||
        path == null ||
        path == '' ||
        (widget.repo == null && widget.gateway == null)) {
      return;
    }
    try {
      final url = widget.repo != null
          ? await widget.repo!.photoUrl(path)
          : await widget.gateway!.photoUrl(path);
      if (mounted) setState(() => photoUrl = url);
    } catch (_) {
      /* Optional photo must not prevent label use. */
    }
  }

  Future<void> share() async {
    setState(() => sharing = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final picture = await render.toImage(pixelRatio: 3);
      final bytes = (await picture.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      picture.dispose();
      if (!mounted) return;
      final box = context.findRenderObject()! as RenderBox;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'image/png',
              name: '${item.barcode}.png',
            ),
          ],
          fileNameOverrides: ['${item.barcode}.png'],
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) {
        toast(
          context,
          'Não foi possível compartilhar a etiqueta. Tente novamente.',
        );
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ficha e etiqueta'),
      actions: [
        if (!widget.offline && widget.repo != null)
          IconButton(
            tooltip: 'Editar ficha',
            onPressed: sharing ? null : edit,
            icon: const Icon(Icons.edit_outlined),
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (widget.offline)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Ficha offline: os dados podem estar desatualizados.',
              style: TextStyle(color: Colors.orange),
            ),
          ),
        if (photoUrl != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.network(
              photoUrl!,
              height: 190,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          item.name,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          [
            item.data['brand'],
            item.data['model'],
            item.data['category'],
          ].whereType<String>().where((v) => v.isNotEmpty).join(' · '),
        ),
        const SizedBox(height: 16),
        Text(
          item.tracking == 'individual'
              ? 'Identificação de uma unidade física'
              : 'Identificação da variante',
        ),
        const SizedBox(height: 24),
        RepaintBoundary(key: boundary, child: LabelCard(item)),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: sharing ? null : share,
          icon: const Icon(Icons.ios_share),
          label: Text(
            sharing ? 'Gerando imagem…' : 'Compartilhar etiqueta PNG',
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Imprima sem cortar as margens brancas. Teste uma etiqueta com a câmera antes de imprimir o lote.',
        ),
        if ((item.data['notes'] ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(item.data['notes']),
          ),
      ],
    ),
  );
}

class LabelCard extends StatelessWidget {
  const LabelCard(this.item, {super.key});
  final CatalogItem item;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (item.variant.isNotEmpty)
            Text(
              item.variant,
              style: const TextStyle(color: Colors.black, fontSize: 13),
            ),
          const SizedBox(height: 16),
          BarcodeWidget(
            barcode: Barcode.code128(),
            data: item.barcode,
            height: 100,
            drawText: true,
            style: const TextStyle(color: Colors.black, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}
