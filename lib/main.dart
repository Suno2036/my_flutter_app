// lib/main.dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

// Глобальная переменная для доступных камер
late List<CameraDescription> cameras;

Future<void> main() async {
  // Убеждаемся, что Flutter биндинги инициализированы
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Получаем список доступных камер
    cameras = await availableCameras();
  } on CameraException catch (e) {
    // Обрабатываем ошибку, если камеры не доступны
    print('Ошибка: ${e.code}\n${e.description}');
    cameras = [];
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Сканер чеков',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CameraController? _controller;
  late final TextRecognizer _textRecognizer;
  bool _isBusy = false;
  String _status = "Готов к сканированию";
  List<ParsedItem> _items = [];

  // Словарь ключевых слов -> категория
  final Map<String, String> _keywordCategories = {
    'молоко': 'Молочные продукты',
    'кефир': 'Молочные продукты',
    'хлеб': 'Выпечка',
    'булка': 'Выпечка',
    'сахар': 'Продукты',
    'мука': 'Продукты',
    'яйц': 'Продукты',
    'яблок': 'Фрукты',
    'банан': 'Фрукты',
    'чай': 'Напитки',
    'кофе': 'Напитки',
    'салфет': 'Бытовая химия',
    'порошок': 'Бытовая химия',
    'пельмен': 'Полуфабрикаты',
  };

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() {
        _status = "Камера не доступна";
      });
      return;
    }

    _controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;
      setState(() {});
    } on CameraException catch (e) {
      print('Ошибка инициализации камеры: ${e.description}');
      setState(() {
        _status = "Ошибка инициализации камеры";
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  Future<File> _captureAndSave() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception("Камера не готова");
    }

    // Делаем снимок
    final xFile = await _controller!.takePicture();
    return File(xFile.path);
  }

  Future<void> _processImage() async {
    if (_isBusy || _controller == null) return;

    setState(() {
      _isBusy = true;
      _status = "Обработка...";
      _items = [];
    });

    try {
      final file = await _captureAndSave();
      final inputImage = InputImage.fromFile(file);

      final result = await _textRecognizer.processImage(inputImage);

      List<String> lines = [];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          lines.add(line.text);
        }
      }

      final parsed = _parseReceiptLines(lines);
      final classified = parsed.map((p) {
        final cat = _classifyByKeywords(p.name);
        return ParsedItem(name: p.name, price: p.price, category: cat);
      }).toList();

      setState(() {
        _items = classified;
        _status = "Готово. Найдено ${_items.length} позиций";
      });
    } catch (e) {
      setState(() {
        _status = "Ошибка: $e";
      });
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  List<ParsedItem> _parseReceiptLines(List<String> lines) {
    final List<ParsedItem> res = [];
    // Регулярное выражение для поиска цены в конце строки
    final priceReg = RegExp(r'(\d+[.,]?\d{0,2})\s*$');
    final sumReg = RegExp(r'\b(итог|сумма|всего)\b', caseSensitive: false);

    for (var rawLine in lines) {
      var s = rawLine.trim();

      // Пропускаем строки с ключевыми словами "итог", "сумма" и т.п.
      if (sumReg.hasMatch(s.toLowerCase())) {
        continue;
      }

      final m = priceReg.firstMatch(s);
      if (m != null) {
        final priceStr = m.group(1)?.replaceAll(',', '.');
        double? price = double.tryParse(priceStr ?? '');
        
        if (price != null && price > 0) {
          // Имя товара — это часть строки до цены
          final name = s.substring(0, m.start).trim();
          if (name.isNotEmpty && name.length > 2) {
            res.add(ParsedItem(name: _capitalize(name), price: price));
          }
        }
      }
    }
    return res;
  }

  String _classifyByKeywords(String name) {
    final low = name.toLowerCase();
    for (final entry in _keywordCategories.entries) {
      if (low.contains(entry.key)) {
        return entry.value;
      }
    }
    return 'Другое';
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  double get total {
    return _items.fold(0.0, (p, e) => p + (e.price ?? 0.0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Трекер: чек → покупки / расходы'),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 4,
            child: CameraView(controller: _controller, status: _status),
          ),
          Expanded(
            flex: 5,
            child: ReceiptView(
              status: _status,
              items: _items,
              isBusy: _isBusy,
              onScanPressed: _processImage,
              onSavePressed: _saveItems,
              onItemEdited: _showEditDialog,
              total: total,
            ),
          )
        ],
      ),
    );
  }

  void _saveItems() {
    final now = DateFormat('yyyy-MM-dd – kk:mm').format(DateTime.now());
    final summary = 'Добавлено ${_items.length} позиций, сумма ${total.toStringAsFixed(2)}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$summary\n$now')));
  }

  void _showEditDialog(ParsedItem item) {
    final priceCtrl = TextEditingController(text: item.price?.toString() ?? '');
    final categoryCtrl = TextEditingController(text: item.category);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Правка: ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d{0,2}')),
              ],
              decoration: const InputDecoration(labelText: 'Цена'),
            ),
            TextField(controller: categoryCtrl, decoration: const InputDecoration(labelText: 'Категория')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                final newPrice = double.tryParse(priceCtrl.text.replaceAll(',', '.'));
                item.price = newPrice ?? item.price;
                item.category = categoryCtrl.text;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          )
        ],
      ),
    );
  }
}

class ParsedItem {
  String name;
  double? price;
  String category;
  ParsedItem({required this.name, this.price = 0.0, this.category = 'Неизвестно'});
}

class CameraView extends StatelessWidget {
  final CameraController? controller;
  final String status;

  const CameraView({super.key, required this.controller, required this.status});

  @override
  Widget build(BuildContext context) {
    final controllerInitialized = controller != null && controller!.value.isInitialized;
    return Container(
      color: Colors.black,
      child: controllerInitialized
          ? CameraPreview(controller!)
          : Center(child: Text(status, style: const TextStyle(color: Colors.white))),
    );
  }
}

class ReceiptView extends StatelessWidget {
  final String status;
  final List<ParsedItem> items;
  final bool isBusy;
  final VoidCallback onScanPressed;
  final VoidCallback onSavePressed;
  final Function(ParsedItem) onItemEdited;
  final double total;

  const ReceiptView({
    super.key,
    required this.status,
    required this.items,
    required this.isBusy,
    required this.onScanPressed,
    required this.onSavePressed,
    required this.onItemEdited,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Статус: $status'),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: isBusy ? null : onScanPressed,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Сканировать чек'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: items.isEmpty ? null : onSavePressed,
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Добавить в покупки'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Распознанные позиции:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Пока нет распознанных позиций'))
                : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                return ListTile(
                  title: Text(it.name),
                  subtitle: Text(it.category),
                  trailing: Text(it.price != null ? it.price!.toStringAsFixed(2) : '-'),
                  onTap: () => onItemEdited(it),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text('Итого: ${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
