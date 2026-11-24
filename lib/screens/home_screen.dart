import 'package:flutter/material.dart';

import '../models/series_item.dart';
import '../services/aedex_client.dart';
import '../services/cache_service.dart';
import '../widgets/series_card.dart';
import 'series_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SeriesItem> _items = [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final cached = CacheService.getSeries();
    if (cached.isNotEmpty && !force) {
      setState(() {
        _items = cached;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final fresh = await AedexClient.fetchCatalog();
      if (fresh.isEmpty) {
        throw Exception('El catálogo vino vacío (posible bloqueo temporal).');
      }
      await CacheService.saveSeries(fresh);
      if (!mounted) return;
      setState(() {
        _items = fresh;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar el catálogo.\n$e';
        _loading = false;
        _items = cached;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _items
        : _items
            .where((s) => s.title.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            children: [
              TextSpan(text: 'aedex', style: TextStyle(color: Colors.white)),
              TextSpan(text: 'nox', style: TextStyle(color: Color(0xFFFF3563))),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar catálogo',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(force: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Buscar en el catálogo...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: const Color(0xFF151520),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
            if (_loading && _items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _load(force: true),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.54,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => SeriesCard(
                      item: filtered[i],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SeriesScreen(item: filtered[i]),
                        ),
                      ),
                    ),
                    childCount: filtered.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
