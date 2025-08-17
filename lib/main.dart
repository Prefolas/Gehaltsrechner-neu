// lib/main.dart – Schichtkalender + Auswertung + Vorlagen & Rotationen (DE 2025)
// Features:
// - Tab „Kalender“: Tage wählen, per Long-Press „Schnelleingabe“ (Früh/Spät/Nacht/Urlaub/Frei)
// - Tab „Auswertung“: Monats-Brutto aus Stundenlohn + Zuschlägen → Netto (vereinfachte Steuer)
// - Vorlagen (Schichtarten) editierbar & dauerhaft gespeichert (shared_preferences)
// - Alle eingetragenen Schichten werden dauerhaft gespeichert
// Hinweise:
// - Für exakte Steuer bitte BMF-PAP 2025 implementieren (hier vereinfachte §32a-Näherung).
// - Abhängigkeit in pubspec.yaml hinzufügen: shared_preferences: ^2.2.3

import 'dart:convert';
import 'dart:math';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const GehaltsrechnerApp());

class GehaltsrechnerApp extends StatelessWidget {
  const GehaltsrechnerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Schichtkalender & Gehalt',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ShiftHome(),
    );
  }
}

// ========================= DATE HELPERS =========================
class DateHelper {
  static DateTime firstDayOfMonth(DateTime date) => DateTime(date.year, date.month, 1);
  static DateTime nextMonth(DateTime date) =>
      (date.month < 12) ? DateTime(date.year, date.month + 1, 1) : DateTime(date.year + 1, 1, 1);
  static DateTime prevMonth(DateTime date) =>
      (date.month > 1) ? DateTime(date.year, date.month - 1, 1) : DateTime(date.year - 1, 12, 1);
  static int daysInMonth(DateTime date) =>
      nextMonth(firstDayOfMonth(date)).difference(firstDayOfMonth(date)).inDays;
  static String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static const monthNames = [
    'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'
  ];
}

// Globale Zeitformatierung
String fmtTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

// ========================= MODELLE =========================
enum ShiftKind { frueh, spaet, nacht, urlaub, frei, custom }

Color shiftKindColor(ShiftKind k, BuildContext ctx) {
  final cs = Theme.of(ctx).colorScheme;
  switch (k) {
    case ShiftKind.frueh: return cs.primary;
    case ShiftKind.spaet: return cs.tertiary;
    case ShiftKind.nacht: return cs.secondary;
    case ShiftKind.urlaub: return cs.inversePrimary;
    case ShiftKind.frei: return cs.outline;
    case ShiftKind.custom: return cs.primary;
  }
}

Widget codePill(BuildContext ctx, String text, ShiftKind kind) {
  final c = shiftKindColor(kind, ctx);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12),
      border: Border.all(color: c.withOpacity(0.6)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
  );
}

class ShiftTemplate {
  final String id;
  final String name; // „Frühschicht“
  final String code; // F/S/N/U/X
  final ShiftKind kind;
  final TimeOfDay? start;
  final TimeOfDay? end;

  const ShiftTemplate({
    required this.id,
    required this.name,
    required this.code,
    required this.kind,
    this.start,
    this.end,
  });

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'code': code, 'kind': kind.index,
        'startH': start?.hour, 'startM': start?.minute,
        'endH': end?.hour, 'endM': end?.minute,
      };

  factory ShiftTemplate.fromJson(Map<String, dynamic> j) => ShiftTemplate(
        id: j['id'] as String,
        name: j['name'] as String,
        code: j['code'] as String,
        kind: ShiftKind.values[j['kind'] as int],
        start: (j['startH'] == null) ? null : TimeOfDay(hour: j['startH'], minute: j['startM']),
        end: (j['endH'] == null) ? null : TimeOfDay(hour: j['endH'], minute: j['endM']),
      );
}

class Shift {
  final String id; // stabiler Key
  final DateTime date; // Start-Tag
  final TimeOfDay? start;
  final TimeOfDay? end;
  final String templateId;
  final ShiftKind kind;
  final String code;

  Shift({
    required this.id,
    required this.date,
    required this.start,
    required this.end,
    required this.templateId,
    required this.kind,
    required this.code,
  });

  DateTime get startDT => start == null
      ? DateTime(date.year, date.month, date.day, 0, 0)
      : DateTime(date.year, date.month, date.day, start!.hour, start!.minute);

  DateTime get endDT {
    if (end == null) return DateTime(date.year, date.month, date.day, 0, 0);
    final e = DateTime(date.year, date.month, date.day, end!.hour, end!.minute);
    if (!e.isAfter(startDT)) return e.add(const Duration(days: 1)); // über Mitternacht
    return e;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': DateHelper.ymd(date),
        'startH': start?.hour, 'startM': start?.minute,
        'endH': end?.hour, 'endM': end?.minute,
        'templateId': templateId, 'kind': kind.index, 'code': code,
      };

  factory Shift.fromJson(Map<String, dynamic> j) {
    final d = DateTime.parse(j['date'] as String);
    TimeOfDay? parseT(String h, String m) =>
        (j[h] == null) ? null : TimeOfDay(hour: j[h], minute: j[m]);
    return Shift(
      id: (j['id'] as String?) ?? UniqueKey().toString(),
      date: DateTime(d.year, d.month, d.day),
      start: parseT('startH', 'startM'),
      end: parseT('endH', 'endM'),
      templateId: j['templateId'],
      kind: ShiftKind.values[j['kind'] as int],
      code: j['code'],
    );
  }
}

// Rotation/Schichtsystem
class RotationPreset {
  final String id;
  final String title;
  final int weeks;                // 1..8
  final List<String?> dayTplIds;  // Länge = weeks*7

  const RotationPreset({
    required this.id,
    required this.title,
    required this.weeks,
    required this.dayTplIds,
  });

  int get days => weeks * 7;

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'weeks': weeks, 'dayTplIds': dayTplIds};

  factory RotationPreset.fromJson(Map<String, dynamic> j) => RotationPreset(
        id: j['id'], title: j['title'], weeks: j['weeks'],
        dayTplIds: (j['dayTplIds'] as List).map((e) => e as String?).toList(),
      );
}

// ========================= HOME (3 TABS) =========================
class ShiftHome extends StatefulWidget {
  const ShiftHome({super.key});
  @override
  State<ShiftHome> createState() => _ShiftHomeState();
}

class _ShiftHomeState extends State<ShiftHome> {
  // Einstellungen
  final hourlyWageCtrl = TextEditingController(text: '15.00');
  final kvZusatzCtrl = TextEditingController(text: '3.39'); // IKK gesund plus
  bool kirchensteuer = true;
  bool kinderlos = false;
  String bundesland = 'ST';
  final pctSatCtrl = TextEditingController(text: '0');
  final pctSunCtrl = TextEditingController(text: '50');
  final pctNightCtrl = TextEditingController(text: '25');
  final nightStartCtrl = TextEditingController(text: '22:00');
  final nightEndCtrl = TextEditingController(text: '06:00');

  // Kalender
  DateTime visibleMonth = DateHelper.firstDayOfMonth(DateTime.now());
  DateTime selectedDate = DateTime.now();
  final List<Shift> shifts = [];
  final List<ShiftTemplate> templates = [];
  final List<RotationPreset> presets = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();

    // Templates
    final rawTpl = prefs.getString('shift_templates_v1');
    if (rawTpl == null) {
      templates.addAll(_defaultTemplates());
      await _saveTemplates();
    } else {
      final List list = jsonDecode(rawTpl) as List;
      templates.addAll(list
          .map((e) => ShiftTemplate.fromJson(Map<String, dynamic>.from(e)))
          .toList());
    }

    // Rotationen/Presets
    final rawPresets = prefs.getString('shift_presets_v1');
    if (rawPresets != null) {
      final List list = jsonDecode(rawPresets) as List;
      presets.addAll(list
          .map((e) => RotationPreset.fromJson(Map<String, dynamic>.from(e)))
          .toList());
    }

    // Schichten
    final rawShifts = prefs.getString('shifts_v1');
    if (rawShifts != null) {
      final List list = jsonDecode(rawShifts) as List;
      shifts.addAll(
          list.map((e) => Shift.fromJson(Map<String, dynamic>.from(e))).toList());
    }

    setState(() {});
  }

  List<ShiftTemplate> _defaultTemplates() => const [
        ShiftTemplate(
            id: 'tpl_f', name: 'Frühschicht', code: 'F', kind: ShiftKind.frueh,
            start: TimeOfDay(hour: 6, minute: 0), end: TimeOfDay(hour: 14, minute: 0)),
        ShiftTemplate(
            id: 'tpl_s', name: 'Spätschicht', code: 'S', kind: ShiftKind.spaet,
            start: TimeOfDay(hour: 14, minute: 0), end: TimeOfDay(hour: 22, minute: 0)),
        ShiftTemplate(
            id: 'tpl_n', name: 'Nachtschicht', code: 'N', kind: ShiftKind.nacht,
            start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 6, minute: 0)),
        ShiftTemplate(id: 'tpl_u', name: 'Urlaub', code: 'U', kind: ShiftKind.urlaub),
        ShiftTemplate(id: 'tpl_x', name: 'Frei', code: 'X', kind: ShiftKind.frei),
      ];

  Future<void> _saveTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shift_templates_v1',
        jsonEncode(templates.map((e) => e.toJson()).toList()));
  }

  Future<void> _savePresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shift_presets_v1',
        jsonEncode(presets.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveShifts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'shifts_v1', jsonEncode(shifts.map((e) => e.toJson()).toList()));
  }

  // ====================== Kalender-Tab ======================
  Widget _calendarTab(BuildContext context) {
    final monthShifts = _byMonth(visibleMonth);
    final dayShifts =
        monthShifts.where((s) => DateUtils.isSameDay(s.date, selectedDate)).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Legende
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final t in templates) codePill(context, t.code, t.kind),
        ]),
        const SizedBox(height: 8),

        // Header
        Row(children: [
          IconButton(
              onPressed: () =>
                  setState(() => visibleMonth = DateHelper.prevMonth(visibleMonth)),
              icon: const Icon(Icons.chevron_left)),
          const SizedBox(width: 4),
          Expanded(
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  visibleMonth = DateHelper.firstDayOfMonth(DateTime.now());
                  selectedDate = DateTime.now();
                }),
                icon: const Icon(Icons.today),
                label: const Text('Heute'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${DateHelper.monthNames[visibleMonth.month - 1]} ${visibleMonth.year}',
                  style: Theme.of(context).textTheme.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
          const SizedBox(width: 4),
          IconButton(
              onPressed: () {
                final c = DefaultTabController.maybeOf(context);
                c?.animateTo(2); // Vorlagen & Rotationen
              },
              tooltip: 'Vorlagen & Rotationen',
              icon: const Icon(Icons.tune)),
          IconButton(
              onPressed: () =>
                  setState(() => visibleMonth = DateHelper.nextMonth(visibleMonth)),
              icon: const Icon(Icons.chevron_right)),
        ]),

        const SizedBox(height: 8),
        _calendarMonthGrid(context, monthShifts),
        const Divider(height: 24),

        ListTile(
          title: const Text('Schichten am ausgewählten Tag'),
          subtitle: Text(DateHelper.ymd(selectedDate)),
          trailing: FilledButton.icon(
            onPressed: () => _quickAddSheet(selectedDate),
            icon: const Icon(Icons.add),
            label: const Text('Schnelleingabe'),
          ),
        ),

        if (dayShifts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Keine Schichten an diesem Tag.'),
          )
        else
          ...dayShifts.map(
            (s) => Dismissible(
              key: ValueKey(s.id),
              onDismissed: (_) async {
                final removed = s;
                setState(() => shifts.remove(s));
                await _saveShifts();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Schicht ${removed.code} am ${DateHelper.ymd(removed.date)} gelöscht'),
                    action: SnackBarAction(
                      label: 'Rückgängig',
                      onPressed: () async {
                        setState(() => shifts.add(removed));
                        await _saveShifts();
                      },
                    ),
                  ),
                );
              },
              background: Container(
                color: Colors.red,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 16),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              secondaryBackground: Container(
                color: Colors.red,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(_titleForShift(s)),
                subtitle: Text(DateHelper.ymd(s.date)),
              ),
            ),
          ),
      ],
    );
  }

  String _titleForShift(Shift s) {
    final tpl = templates.firstWhere(
      (t) => t.id == s.templateId,
      orElse: () => ShiftTemplate(id: 'x', name: 'Schicht', code: s.code, kind: s.kind),
    );
    if (s.kind == ShiftKind.urlaub || s.kind == ShiftKind.frei) return tpl.name;
    return '${tpl.name}  ${_fmtTime(s.start!)}–${_fmtTime(s.end!)}';
  }

  Future<void> _quickAddSheet(DateTime date) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Text('Schnelleingabe: Vorlage wählen',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in templates)
                  ActionChip(
                    label: Text('${t.code} – ${t.name}'),
                    backgroundColor:
                        shiftKindColor(t.kind, context).withOpacity(0.12),
                    onPressed: () async {
                      final shift = Shift(
                        id: UniqueKey().toString(),
                        date: DateTime(date.year, date.month, date.day),
                        start: t.start, end: t.end,
                        templateId: t.id, kind: t.kind, code: t.code,
                      );
                      setState(() => shifts.add(shift));
                      await _saveShifts();
                      if (mounted) Navigator.pop(context);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _calendarMonthGrid(BuildContext context, List<Shift> monthShifts) {
    final firstWeekday = visibleMonth.weekday; // 1=Mo..7=So
    final days = DateHelper.daysInMonth(visibleMonth);
    final startPadding = (firstWeekday + 6) % 7;

    final cells = <Widget>[];
    const dow = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    cells.addAll(dow.map((d) =>
        Center(child: Text(d, style: const TextStyle(fontWeight: FontWeight.w600)))));

    for (int i = 0; i < startPadding; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (int day = 1; day <= days; day++) {
      final date = DateTime(visibleMonth.year, visibleMonth.month, day);
      final isSel = DateUtils.isSameDay(date, selectedDate);
      final dayShifts =
          monthShifts.where((s) => DateUtils.isSameDay(s.date, date)).toList();

      cells.add(GestureDetector(
        onTap: () => setState(() => selectedDate = date),
        onLongPress: () { setState(() => selectedDate = date); _quickAddSheet(date); },
        child: Container(
          decoration: BoxDecoration(
            color: isSel ? Theme.of(context).colorScheme.secondaryContainer : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: dayShifts.isNotEmpty
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).dividerColor,
              width: dayShifts.isNotEmpty ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.topRight, child: Text('$day')),
              if (dayShifts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final s in dayShifts.take(2))
                      codePill(context, s.code, s.kind),
                  ]),
                ),
            ],
          ),
        ),
      ));
    }

    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < 0) setState(() => visibleMonth = DateHelper.nextMonth(visibleMonth));
        if (v > 0) setState(() => visibleMonth = DateHelper.prevMonth(visibleMonth));
      },
      child: GridView.count(
        padding: const EdgeInsets.only(bottom: 8),
        crossAxisCount: 7,
        childAspectRatio: 0.85,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: cells,
      ),
    );
  }

  // ====================== Auswertung-Tab ======================
  Widget _summaryTab(BuildContext context) {
    final monthShifts = _byMonth(visibleMonth);

    final wage = _parseDouble(hourlyWageCtrl.text);
    final kvZusatz = _parseDouble(kvZusatzCtrl.text) / 100.0;
    final pctSat = _parseDouble(pctSatCtrl.text) / 100.0;
    final pctSun = _parseDouble(pctSunCtrl.text) / 100.0;
    final pctNight = _parseDouble(pctNightCtrl.text) / 100.0;
    final nightStart = _parseTime(nightStartCtrl.text) ?? const TimeOfDay(hour: 22, minute: 0);
    final nightEnd = _parseTime(nightEndCtrl.text) ?? const TimeOfDay(hour: 6, minute: 0);

    final cat = Categoriser.categorise(
        shifts: monthShifts, nightStart: nightStart, nightEnd: nightEnd);
    final hours = cat.totalMinutes / 60.0;
    final satH = cat.saturdayMinutes / 60.0;
    final sunH = cat.sundayMinutes / 60.0;
    final nightH = cat.nightMinutes / 60.0;

    final baseGross = hours * wage;
    final satBonus = satH * wage * pctSat;
    final sunBonus = sunH * wage * pctSun;
    final nightBonus = nightH * wage * pctNight;
    final gross = baseGross + satBonus + sunBonus + nightBonus;

    final steuer = NetCalculator2025.netto(
      bruttoMonat: gross,
      steuerklasse: 1,
      bundesland: bundesland,
      kirchensteuer: kirchensteuer,
      kinderlos: kinderlos,
      kvZusatzGesamt: kvZusatz,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${DateHelper.monthNames[visibleMonth.month - 1]} ${visibleMonth.year}',
              style: Theme.of(context).textTheme.titleLarge),
          FilledButton.icon(
              onPressed: () => setState(() {}),
              icon: const Icon(Icons.refresh),
              label: const Text('Neu berechnen')),
        ]),
        const SizedBox(height: 12),
        _settingsCard(context),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _kv('Arbeitsstunden gesamt', _h(hours)),
              _kv('… Samstag', _h(satH)),
              _kv('… Sonntag', _h(sunH)),
              _kv('… Nacht (Fenster)', _h(nightH)),
              const Divider(),
              _kv('Grund-Brutto', _e(baseGross)),
              _kv('Samstagszuschlag', _e(satBonus)),
              _kv('Sonntagszuschlag', _e(sunBonus)),
              _kv('Nachtzuschlag', _e(nightBonus)),
              _kvStrong('Monats-Brutto', _e(gross)),
              const Divider(),
              _kv('Lohnsteuer', _e(steuer['LSt'] ?? 0)),
              _kv('Soli', _e(steuer['Soli'] ?? 0)),
              _kv('Kirchensteuer', _e(steuer['Kirche'] ?? 0)),
              _kv('KV (AN)', _e(steuer['KV'] ?? 0)),
              _kv('PV (AN)', _e(steuer['PV'] ?? 0)),
              _kv('RV (AN)', _e(steuer['RV'] ?? 0)),
              _kv('AV (AN)', _e(steuer['AV'] ?? 0)),
              _kvStrong('Netto', _e(steuer['Netto'] ?? 0)),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _settingsCard(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Einstellungen', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _rowFields([
              _numField(hourlyWageCtrl, label: 'Stundenlohn (€)', prefix: '€ '),
              _percentField(kvZusatzCtrl, label: 'KV-Zusatz (%)'),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _bundeslandDropdown(),
              FilterChip(
                  label: const Text('Kirchensteuer'),
                  selected: kirchensteuer,
                  onSelected: (v) => setState(() => kirchensteuer = v)),
              FilterChip(
                  label: const Text('Kinderlos (PV +0,6 %-Pkt.)'),
                  selected: kinderlos,
                  onSelected: (v) => setState(() => kinderlos = v)),
            ]),
            const SizedBox(height: 8),
            _rowFields([
              _percentField(pctSatCtrl, label: 'Samstag (%)'),
              _percentField(pctSunCtrl, label: 'Sonntag (%)'),
              _percentField(pctNightCtrl, label: 'Nacht (%)'),
            ]),
            _rowFields([
              _timeField(nightStartCtrl, label: 'Nacht beginnt'),
              _timeField(nightEndCtrl, label: 'Nacht endet'),
            ]),
          ]),
        ),
      );

  // ====================== Vorlagen & Rotationen (Tab) ======================
  Widget _templatesTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Schicht-Vorlagen', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            for (final t in templates)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: shiftKindColor(t.kind, context).withOpacity(0.15),
                  foregroundColor: shiftKindColor(t.kind, context),
                  child: Text(t.code),
                ),
                title: Text(t.name),
                subtitle: Text(_tplSubtitle(t)),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editTemplateDialog(t),
                ),
              ),
            ButtonBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _editTemplateDialog(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Vorlage hinzufügen'),
                ),
              ],
            ),
          ]),
        ),

        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Rotationen / Presets', style: Theme.of(context).textTheme.titleLarge),
            TextButton.icon(
              onPressed: () => _openRotationEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Rotation erstellen'),
            ),
          ],
        ),
        Card(
          child: (presets.isEmpty)
              ? const ListTile(
                  title: Text('Keine Rotation gespeichert'),
                  subtitle: Text('Erstelle eine neue Rotation und speichere sie als Preset.'),
                )
              : Column(children: [
                  for (final p in presets)
                    ListTile(
                      leading: const Icon(Icons.grid_view),
                      title: Text(p.title),
                      subtitle: Text('${p.weeks} Wochen • ${p.days} Tage'),
                      trailing: Wrap(spacing: 8, children: [
                        IconButton(
                            tooltip: 'Bearbeiten',
                            icon: const Icon(Icons.edit),
                            onPressed: () => _openRotationEditor(existing: p)),
                        IconButton(
                          tooltip: 'Auf sichtbaren Monat anwenden',
                          icon: const Icon(Icons.playlist_add),
                          onPressed: () => _applyPresetToVisibleMonth(p, overwrite: true),
                        ),
                        IconButton(
                          tooltip: 'Löschen',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            setState(() => presets.removeWhere((x) => x.id == p.id));
                            await _savePresets();
                          },
                        ),
                      ]),
                    ),
                ]),
        ),
      ],
    );
  }

  String _tplSubtitle(ShiftTemplate t) =>
      (t.kind == ShiftKind.urlaub || t.kind == ShiftKind.frei)
          ? 'keine Arbeitszeit'
          : '${fmtTime(t.start!)} – ${fmtTime(t.end!)}';

  Future<void> _editTemplateDialog(ShiftTemplate? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? 'Neue Vorlage');
    final codeCtrl = TextEditingController(text: existing?.code ?? 'C');
    ShiftKind kind = existing?.kind ?? ShiftKind.custom;
    TimeOfDay? start = existing?.start;
    TimeOfDay? end = existing?.end;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        return AlertDialog(
          title: Text(existing == null ? 'Vorlage erstellen' : 'Vorlage bearbeiten'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'Code (Kurz)')),
              const SizedBox(height: 8),
              DropdownButtonFormField<ShiftKind>(
                value: kind,
                items: ShiftKind.values
                    .map((k) => DropdownMenuItem(value: k, child: Text(k.toString().split('.').last)))
                    .toList(),
                onChanged: (v) => setSt(() => kind = v ?? ShiftKind.custom),
                decoration: const InputDecoration(labelText: 'Art'),
              ),
              const SizedBox(height: 8),
              if (!(kind == ShiftKind.urlaub || kind == ShiftKind.frei)) ...[
                // >>> FIX: start!/end! (non-null) für fmtTime <<<
                ListTile(
                  title: Text('Start: ${start == null ? '--:--' : fmtTime(start!)}'),
                  trailing: const Icon(Icons.schedule),
                  onTap: () async {
                    final t = await showTimePicker(
                        context: ctx, initialTime: start ?? const TimeOfDay(hour: 8, minute: 0));
                    if (t != null) setSt(() => start = t);
                  },
                ),
                ListTile(
                  title: Text('Ende: ${end == null ? '--:--' : fmtTime(end!)}'),
                  trailing: const Icon(Icons.schedule),
                  onTap: () async {
                    final t = await showTimePicker(
                        context: ctx, initialTime: end ?? const TimeOfDay(hour: 16, minute: 0));
                    if (t != null) setSt(() => end = t);
                  },
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              onPressed: () async {
                final t = ShiftTemplate(
                  id: existing?.id ?? UniqueKey().toString(),
                  name: nameCtrl.text.trim().isEmpty ? 'Vorlage' : nameCtrl.text.trim(),
                  code: codeCtrl.text.trim().isEmpty ? 'C' : codeCtrl.text.trim(),
                  kind: kind,
                  start: (kind == ShiftKind.urlaub || kind == ShiftKind.frei) ? null : start,
                  end: (kind == ShiftKind.urlaub || kind == ShiftKind.frei) ? null : end,
                );
                setState(() {
                  final idx = templates.indexWhere((x) => x.id == t.id);
                  if (idx == -1) templates.add(t); else templates[idx] = t;
                });
                await _saveTemplates();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Speichern'),
            ),
          ],
        );
      }),
    );
  }

  // Rotation-Editor öffnen
  void _openRotationEditor({RotationPreset? existing}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RotationEditorScreen(
        templates: templates,
        existing: existing,
        onSaved: (preset) async {
          setState(() {
            final i = presets.indexWhere((p) => p.id == preset.id);
            if (i == -1) presets.add(preset); else presets[i] = preset;
          });
          await _savePresets();
        },
      ),
    ));
  }

  // Rotation auf sichtbaren Monat anwenden
  Future<void> _applyPresetToVisibleMonth(RotationPreset p, {bool overwrite = true}) async {
    final first = DateHelper.firstDayOfMonth(visibleMonth);
    final nextFirst = DateHelper.nextMonth(first);

    if (overwrite) {
      shifts.removeWhere((s) => s.endDT.isAfter(first) && !s.startDT.isAfter(nextFirst));
    }

    final mapTpl = {for (final t in templates) t.id: t};

    int idx = 0;
    for (DateTime d = first; d.isBefore(nextFirst); d = d.add(const Duration(days: 1))) {
      final tplId = p.dayTplIds[idx % p.dayTplIds.length];
      idx++;
      if (tplId == null) continue;
      final tpl = mapTpl[tplId];
      if (tpl == null) continue;

      shifts.add(Shift(
        id: UniqueKey().toString(),
        date: DateTime(d.year, d.month, d.day),
        start: tpl.start, end: tpl.end,
        templateId: tpl.id, kind: tpl.kind, code: tpl.code,
      ));
    }

    setState(() {});
    await _saveShifts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rotation auf Monat angewendet')),
    );
  }

  // ====================== Gemeinsame Helfer ======================
  List<Shift> _byMonth(DateTime m) {
    final first = DateHelper.firstDayOfMonth(m);
    final nextFirst = DateHelper.nextMonth(first);
    // rechter Rand inklusiv (Start vor ODER am 1. des Folgemonats)
    return shifts.where((s) =>
        s.endDT.isAfter(first) && !s.startDT.isAfter(nextFirst)).toList();
  }

  Widget _rowFields(List<Widget> children) =>
      LayoutBuilder(builder: (ctx, c) {
        if (c.maxWidth < 640) {
          return Column(
            children: children
                .map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w))
                .toList(),
          );
        }
        return Row(
          children: children
              .map((w) => Expanded(
                    child: Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 8), child: w),
                  ))
              .toList(),
        );
      });

  Widget _numField(TextEditingController ctrl, {required String label, String? prefix}) =>
      TextFormField(
        controller: ctrl,
        decoration: InputDecoration(
            labelText: label, prefixText: prefix, border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        validator: (v) => _parseDouble(v) > 0 ? null : 'Bitte Zahl > 0 eingeben',
      );

  Widget _percentField(TextEditingController ctrl, {required String label}) =>
      TextFormField(
        controller: ctrl,
        decoration:
            InputDecoration(labelText: label, suffixText: '%', border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        validator: (v) {
          final x = _parseDouble(v);
          return (x < 0 || x > 200) ? '0–200%' : null;
        },
      );

  Widget _timeField(TextEditingController ctrl, {required String label}) => TextFormField(
        controller: ctrl,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        readOnly: true,
        onTap: () async {
          final t = _parseTime(ctrl.text) ?? const TimeOfDay(hour: 0, minute: 0);
          final picked = await showTimePicker(context: context, initialTime: t);
          if (picked != null) ctrl.text = _fmtTime(picked);
        },
      );

  Widget _bundeslandDropdown() {
    const laender = [
      'BW','BY','BE','BB','HB','HH','HE','MV','NI','NW','RP','SL','SN','ST','SH','TH'
    ];
    return DropdownButtonFormField<String>(
      value: bundesland,
      items: laender.map((e) => DropdownMenuItem(value: e, child: Text('Bundesland: $e'))).toList(),
      onChanged: (v) => setState(() => bundesland = v ?? 'ST'),
      decoration: const InputDecoration(border: OutlineInputBorder()),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k),
          Text(v, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      );

  Widget _kvStrong(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(v, style: const TextStyle(
            fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      );

  String _e(double v) => '€ ${v.toStringAsFixed(2).replaceAll('.', ',')}';
  String _h(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} h';
  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static double _parseDouble(String? s) =>
      double.tryParse((s ?? '0').replaceAll(',', '.')) ?? 0;
  static TimeOfDay? _parseTime(String? s) {
    if (s == null || !s.contains(':')) return null;
    final parts = s.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return TimeOfDay(hour: min(23, max(0, h)), minute: min(59, max(0, m)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Schichtkalender & Gehalt 2025'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Kalender', icon: Icon(Icons.calendar_month)),
            Tab(text: 'Auswertung', icon: Icon(Icons.payments)),
            Tab(text: 'Vorlagen & Rotationen', icon: Icon(Icons.tune)),
          ]),
        ),
        body: TabBarView(children: [
          _calendarTab(context),
          _summaryTab(context),
          _templatesTab(context),
        ]),
      ),
    );
  }
}

// ========================= Rotation-Editor (Raster) =========================
class RotationEditorScreen extends StatefulWidget {
  final List<ShiftTemplate> templates;
  final RotationPreset? existing;
  final ValueChanged<RotationPreset> onSaved;
  const RotationEditorScreen({super.key, required this.templates, this.existing, required this.onSaved});

  @override
  State<RotationEditorScreen> createState() => _RotationEditorScreenState();
}

class _RotationEditorScreenState extends State<RotationEditorScreen> {
  late TextEditingController _title;
  int _weeks = 4; // 4 Wochen = 28 Tage
  late List<String?> _cells; // Länge = _weeks*7
  String? _selectedTplId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? 'Rota 1');
    _weeks = widget.existing?.weeks ?? 4;
    _cells = List<String?>.from(widget.existing?.dayTplIds ?? List.filled(_weeks * 7, null));
  }

  @override
  Widget build(BuildContext context) {
    final days = _weeks * 7;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Neue Rotation' : 'Rotation bearbeiten'),
        actions: [
          TextButton(
            onPressed: () {
              final preset = RotationPreset(
                id: widget.existing?.id ?? UniqueKey().toString(),
                title: _title.text.trim().isEmpty ? 'Rotation' : _title.text.trim(),
                weeks: _weeks,
                dayTplIds: _cells,
              );
              widget.onSaved(preset);
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: TextField(controller: _title, decoration: const InputDecoration(labelText: 'Titel', border: OutlineInputBorder()))),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _weeks,
                items: [1,2,3,4,5,6,7,8].map((w) => DropdownMenuItem(value: w, child: Text('$w Wochen'))).toList(),
                onChanged: (w) {
                  if (w == null) return;
                  setState(() {
                    _weeks = w;
                    final newLen = _weeks * 7;
                    if (newLen > _cells.length) {
                      _cells = [..._cells, ...List.filled(newLen - _cells.length, null)];
                    } else if (newLen < _cells.length) {
                      _cells = _cells.take(newLen).toList();
                    }
                  });
                },
              ),
            ]),
          ),

          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.0,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: days,
              itemBuilder: (c, i) {
                final tplId = _cells[i];
                final tpl = (tplId == null)
                    ? null
                    : widget.templates.firstWhere((t) => t.id == tplId, orElse: () => widget.templates.first);
                return GestureDetector(
                  onTap: () => setState(() => _cells[i] = _selectedTplId),
                  onLongPress: () => setState(() => _cells[i] = null),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                      borderRadius: BorderRadius.circular(8),
                      color: (tpl == null) ? null : shiftKindColor(tpl.kind, context).withOpacity(0.12),
                    ),
                    child: Center(
                      child: (tpl == null)
                          ? const Icon(Icons.circle_outlined, size: 20)
                          : codePill(context, tpl.code, tpl.kind),
                    ),
                  ),
                );
              },
            ),
          ),

          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final t in widget.templates)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: _selectedTplId == t.id,
                        label: Text(t.name, overflow: TextOverflow.ellipsis),
                        avatar: CircleAvatar(
                          backgroundColor: shiftKindColor(t.kind, context).withOpacity(0.2),
                          foregroundColor: shiftKindColor(t.kind, context),
                          child: Text(t.code),
                        ),
                        onSelected: (_) => setState(() => _selectedTplId = t.id),
                      ),
                    ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _selectedTplId = null),
                    icon: const Icon(Icons.block),
                    label: const Text('Leeren'),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ========================= Netto-Rechner (vereinfachte Näherung) =========================
class CategorisedMinutes {
  final int totalMinutes, saturdayMinutes, sundayMinutes, nightMinutes;
  const CategorisedMinutes({
    required this.totalMinutes,
    required this.saturdayMinutes,
    required this.sundayMinutes,
    required this.nightMinutes,
  });
}

class Categoriser {
  static CategorisedMinutes categorise({
    required List<Shift> shifts,
    required TimeOfDay nightStart,
    required TimeOfDay nightEnd,
  }) {
    int total = 0, sat = 0, sun = 0, night = 0;
    for (final s in shifts) {
      if (s.kind == ShiftKind.urlaub || s.kind == ShiftKind.frei) continue;
      DateTime cur = s.startDT;
      final end = s.endDT;
      while (cur.isBefore(end)) {
        final next = cur.add(const Duration(minutes: 15));
        total += 15;
        final wd = cur.weekday;
        if (wd == DateTime.saturday) sat += 15;
        if (wd == DateTime.sunday) sun += 15;
        if (_isNight(cur, nightStart, nightEnd)) night += 15;
        cur = next;
      }
    }
    return CategorisedMinutes(
      totalMinutes: total, saturdayMinutes: sat, sundayMinutes: sun, nightMinutes: night);
  }

  static bool _isNight(DateTime t, TimeOfDay start, TimeOfDay end) {
    final s = start.hour * 60 + start.minute;
    final e = end.hour * 60 + end.minute;
    final m = t.hour * 60 + t.minute;
    return (s <= e) ? (m >= s && m < e) : (m >= s || m < e);
  }
}

class NetCalculator2025 {
  static const bbgKV = 5512.50; // KV/PV (mtl.)
  static const bbgRV = 8050.00; // RV/AV (mtl.)
  static const rvAN = 0.093;    // 9,3 %
  static const avAN = 0.013;    // 1,3 %
  static const kvAllg = 0.146;  // gesamt
  static const pvGes = 0.036;   // gesamt

  static double _cap(double value, double cap) => value > cap ? cap : value;

  static Map<String, double> sozialabgaben({
    required double bruttoMonat,
    required double kvZusatzGesamt,
    required bool kinderlos,
    bool sachsen = false,
  }) {
    final kvBemess = _cap(bruttoMonat, bbgKV);
    final rvBemess = _cap(bruttoMonat, bbgRV);
    final kvAN = kvBemess * ((kvAllg + kvZusatzGesamt) / 2.0);
    final pvAN = (kvBemess * (pvGes / 2.0)) + (kinderlos ? kvBemess * 0.006 : 0.0);
    final rvANAmt = rvBemess * rvAN;
    final avANAmt = rvBemess * avAN;
    return {'KV': kvAN, 'PV': pvAN, 'RV': rvANAmt, 'AV': avANAmt};
  }

  // vereinfachte Grundtabelle StKl I
  static double lohnsteuerJahr(double zvE) {
    if (zvE <= 12096) return 0.0;
    if (zvE <= 17443) { final y = (zvE - 12096) / 10000.0; return (932.30 * y + 1400) * y; }
    if (zvE <= 68480) { final z = (zvE - 17443) / 10000.0; return (176.64 * z + 2397) * z + 1015.13; }
    if (zvE <= 277825) { return 0.42 * zvE - 10911.92; }
    return 0.45 * zvE - 19246.67;
  }

  static Map<String, double> netto({
    required double bruttoMonat,
    required int steuerklasse,
    required String bundesland,
    required bool kirchensteuer,
    required bool kinderlos,
    required double kvZusatzGesamt,
  }) {
    final so = sozialabgaben(
        bruttoMonat: bruttoMonat,
        kvZusatzGesamt: kvZusatzGesamt,
        kinderlos: kinderlos,
        sachsen: false);
    final gesSozial = so.values.reduce((a, b) => a + b);
    final jahresBrutto = bruttoMonat * 12.0;
    final jahresSozial = gesSozial * 12.0;
    final zvE = (jahresBrutto - jahresSozial).clamp(0, double.infinity).toDouble();
    final lstJahr = lohnsteuerJahr(zvE);
    final lstMonat = lstJahr / 12.0;
    final soliMonat = _soliMonat(lstJahr) / 12.0;
    final ksSatz = (bundesland == 'BY' || bundesland == 'BW') ? 0.08 : 0.09;
    final kircheMonat = kirchensteuer ? lstMonat * ksSatz : 0.0;
    final netto = bruttoMonat - gesSozial - lstMonat - soliMonat - kircheMonat;
    return {
      'Netto': netto, 'LSt': lstMonat, 'Soli': soliMonat, 'Kirche': kircheMonat,
      'KV': so['KV']!, 'PV': so['PV']!, 'RV': so['RV']!, 'AV': so['AV']!,
    };
  }

  static double _soliMonat(double lstJahr) {
    const freiGrenzeLSt = 39900.0; // vereinfachte Freigrenze
    if (lstJahr <= freiGrenzeLSt) return 0.0;
    return 0.055 * lstJahr;
  }
}
