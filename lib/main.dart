// lib/main.dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
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
  bool _isBusy = false;
  String _status = "Готов к сканированию";
  List<ParsedItem> _items = [];

  // Простой словарь ключевых слов -> категория
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
    // добавь свои правила
  };

  @override
  void initState() {
    super.initState();
    if (cameras.isNotEmpty) {
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      _controller!.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
      });
    } else {
      setState(() {
        _status = "Камера не доступна";
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<File> _captureAndSave() async {
    final tempDir = await getTemporaryDirectory();
    final name = 'receipt_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final filePath = '${tempDir.path}/$name';

    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception("Камера не готова");
    }

    final xfile = await _controller!.takePicture();
    final bytes = await xfile.readAsBytes();

    // иногда нужно сделать поворот/кроп — здесь сохраняем как есть
    final file = File(filePath);
    await file.writeAsBytes(bytes);
    return file;
  }

  // Запускаем ML Kit TextRecognizer
  Future<void> _processImage() async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _status = "Обработка...";
      _items = [];
    });

    try {
      final file = await _captureAndSave();

      // Опционально: нормализуем изображение (поворот/уменьшение)
      final inputImage = InputImage.fromFile(file);

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin); // латиница+кириллица ML Kit обрабатывает обе
      final result = await recognizer.processImage(inputImage);

      // Собираем все строки текста
      List<String> lines = [];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          lines.add(line.text);
        }
      }

      // Парсим позиции из строк
      final parsed = _parseReceiptLines(lines);

      // Классифицируем по словарю
      final classified = parsed.map((p) {
        final cat = _classifyByKeywords(p.name);
        return ParsedItem(name: p.name, price: p.price, category: cat);
      }).toList();

      setState(() {
        _items = classified;
        _status = "Готово. Найдено ${_items.length} позиций";
      });

      await recognizer.close();
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

  // Очень простая эвристика: ищем строки с числом (цена) в конце
  List<ParsedItem> _parseReceiptLines(List<String> lines) {
    final List<ParsedItem> res = [];
    final priceReg = RegExp(r'(\d+[.,]?\d{0,2})\s*$'); // ищем число в конце строки
    for (var raw in lines) {
      var s = raw.trim().toLowerCase();
      // убираем служебные символы
      s = s.replaceAll(RegExp(r'[^а-яА-Яa-zA-Z0-9,.\s\-]'), ' ').trim();
      final m = priceReg.firstMatch(s);
      if (m != null) {
        final priceStr = m.group(1)!.replaceAll(',', '.');
        double? price = double.tryParse(priceStr);
        if (price != null) {
          final name = s.substring(0, m.start).trim();
          if (name.isNotEmpty) {
            res.add(ParsedItem(name: _capitalize(name), price: price, category: 'Неизвестно'));
          }
        }
      }
    }

    // Если не нашли по ценам — попробуем выделить строки с длинными словами (наименования)
    if (res.isEmpty) {
      for (var s in lines) {
        final cleaned = s.trim();
        if (cleaned.length > 4) {
          res.add(ParsedItem(name: _capitalize(cleaned), price: 0.0, category: 'Неизвестно'));
        }
      }
    }

    return res;
  }

  String _classifyByKeywords(String name) {
    final low = name.toLowerCase();
    for (final entry in _keywordCategories.entries) {
      if (low.contains(entry.key)) return entry.value;
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
    final controllerInitialized = _controller != null && _controller!.value.isInitialized;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Трекер: чек → покупки / расходы'),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 4,
            child: Container(
              color: Colors.black,
              child: controllerInitialized
                  ? CameraPreview(_controller!)
                  : Center(child: Text(_status)),
            ),
          ),
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Статус: $_status'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isBusy ? null : _processImage,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Сканировать чек'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _items.isEmpty ? null : () {
                          // тут можно отправить в БД / добавить в покупки
                          final now = DateFormat('yyyy-MM-dd – kk:mm').format(DateTime.now());
                          final summary = 'Добавлено ${_items.length} позиций, сумма ${total.toStringAsFixed(2)}';
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$summary\n$now')));
                        },
                        icon: const Icon(Icons.add_shopping_cart),
                        label: const Text('Добавить в покупки'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Распознанные позиции:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _items.isEmpty
                        ? const Center(child: Text('Пока нет распознанных позиций'))
                        : ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (context, i) {
                              final it = _items[i];
                              return ListTile(
                                title: Text(it.name),
                                subtitle: Text(it.category),
                                trailing: Text(it.price != null ? it.price!.toStringAsFixed(2) : '-'),
                                onTap: () {
                                  // ручная правка категории/цены — полезно для обучения системы
                                  _showEditDialog(it);
                                },
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text('Итого: ${total.toStringAsFixed(2)}'),
                ],
              ),
            ),
          )
        ],
      ),
    );
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
            TextField(controller: priceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Цена')),
            TextField(controller: categoryCtrl, decoration: const InputDecoration(labelText: 'Категория')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                item.price = double.tryParse(priceCtrl.text.replaceAll(',', '.')) ?? item.price;
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
