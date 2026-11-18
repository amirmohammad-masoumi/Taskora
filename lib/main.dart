import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const _bg = Color(0xff080b18);
const _surface = Color(0xff151b32);
const _elevated = Color(0xff1b2340);
const _violet = Color(0xff7655ff);
const _blue = Color(0xff4169ff);
const _text = Color(0xfff5f6ff);
const _secondary = Color(0xff9299b5);
const _mint = Color(0xff5ee6c3);
const _gold = Color(0xffffc95c);

bool _isPersian = false;
String _tr(String en, String fa) => _isPersian ? fa : en;
String _category(String value) => switch (value) {
      'Work' => _tr('Work', 'کاری'),
      'Health' => _tr('Health', 'سلامت'),
      'Learning' => _tr('Learning', 'یادگیری'),
      _ => _tr('Personal', 'شخصی'),
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.initialize();
  runApp(const TaskoraApp());
}

class Todo {
  Todo({
    required this.id,
    required this.title,
    this.note = '',
    required this.date,
    this.priority = 1,
    this.category = 'Personal',
    this.done = false,
    this.completedAt,
    this.pinned = false,
    this.reminder,
    this.remind = false,
  });
  final String id;
  final String title;
  final String note;
  final DateTime date;
  final int priority;
  final String category;
  bool done;
  DateTime? completedAt;
  bool pinned;
  DateTime? reminder;
  bool remind;
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'date': date.toIso8601String(),
        'priority': priority,
        'category': category,
        'done': done,
        'completedAt': completedAt?.toIso8601String(),
        'pinned': pinned,
        'reminder': reminder?.toIso8601String(),
        'remind': remind,
      };
  factory Todo.fromJson(Map<String, dynamic> v) => Todo(
        id: v['id'],
        title: v['title'],
        note: v['note'] ?? '',
        date: DateTime.parse(v['date']),
        priority: v['priority'] ?? 1,
        category: v['category'] ?? 'Personal',
        done: v['done'] ?? false,
        completedAt:
            v['completedAt'] == null ? null : DateTime.parse(v['completedAt']),
        pinned: v['pinned'] ?? false,
        reminder: v['reminder'] == null ? null : DateTime.parse(v['reminder']),
        remind: v['remind'] ?? false,
      );
}

class TaskoraApp extends StatefulWidget {
  const TaskoraApp({super.key});
  @override
  State<TaskoraApp> createState() => _TaskoraAppState();
}

class _TaskoraAppState extends State<TaskoraApp> {
  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted)
      setState(() => _isPersian = prefs.getBool('taskora.persian') ?? false);
  }

  Future<void> _setLanguage(bool value) async {
    setState(() => _isPersian = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('taskora.persian', value);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: _tr('Taskora', 'تسکورا'),
        locale: Locale(_isPersian ? 'fa' : 'en'),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _violet,
            brightness: Brightness.dark,
            surface: _surface,
          ),
          fontFamily: 'sans',
        ),
        home: TaskoraShell(onLanguageChanged: _setLanguage),
      );
}

class TaskoraShell extends StatefulWidget {
  const TaskoraShell({super.key, required this.onLanguageChanged});
  final ValueChanged<bool> onLanguageChanged;
  @override
  State<TaskoraShell> createState() => _TaskoraShellState();
}

class _TaskoraShellState extends State<TaskoraShell> {
  List<Todo> tasks = [];
  int index = 0;
  bool loading = true;
  bool remindersEnabled = true;
  int focusSessions = 0;
  Timer? reminderTimer;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTasks = prefs.getString('taskora.tasks');
    setState(() {
      tasks = savedTasks == null
          ? _starterTasks()
          : (jsonDecode(savedTasks) as List)
              .map((item) => Todo.fromJson(item as Map<String, dynamic>))
              .toList();
      remindersEnabled = prefs.getBool('taskora.reminders') ?? true;
      focusSessions = prefs.getInt('taskora.focusSessions') ?? 0;
      loading = false;
    });
    await _syncNotifications();
  }

  List<Todo> _starterTasks() {
    final n = DateTime.now();
    return [
      Todo(
        id: '1',
        title: _tr('Design weekly plan', 'برنامهٔ هفتگی را طراحی کن'),
        note: _tr('Outline the three most important goals.',
            'سه هدف مهم را مشخص کن.'),
        date: n,
        priority: 3,
        category: 'Work',
        pinned: true,
      ),
      Todo(
        id: '2',
        title: _tr('Evening run', 'پیاده‌روی عصرگاهی'),
        note: _tr(
            '30 minutes at a comfortable pace.', '۳۰ دقیقه با ریتم دلخواه.'),
        date: n,
        priority: 1,
        category: 'Health',
      ),
      Todo(
        id: '3',
        title: _tr('Review project notes', 'یادداشت‌های پروژه را مرور کن'),
        date: n.add(const Duration(days: 1)),
        priority: 2,
        category: 'Work',
      ),
    ];
  }

  void _update(void Function() action) {
    setState(action);
    _scheduleReminder();
    _persistAndSync();
  }

  Future<void> _persistAndSync() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('taskora.tasks',
        jsonEncode(tasks.map((task) => task.toJson()).toList()));
    await prefs.setBool('taskora.reminders', remindersEnabled);
    await prefs.setInt('taskora.focusSessions', focusSessions);
    await _syncNotifications();
  }

  Future<void> _syncNotifications() async {
    final scheduledTasks = tasks
        .where((task) =>
            remindersEnabled &&
            !task.done &&
            task.remind &&
            task.reminder != null &&
            task.reminder!.isAfter(DateTime.now()))
        .toList();
    for (final task in tasks.where((task) => !scheduledTasks.contains(task))) {
      await NotificationService.instance.cancel(task.id);
    }
    if (scheduledTasks.isNotEmpty &&
        !await NotificationService.instance.ensureNotificationPermission()) {
      return;
    }
    for (final task in scheduledTasks) {
      await NotificationService.instance.schedule(task);
    }
  }

  void _scheduleReminder() {
    reminderTimer?.cancel();
    if (!remindersEnabled) return;
    final upcoming = tasks
        .where((task) =>
            task.remind &&
            !task.done &&
            task.reminder != null &&
            task.reminder!.isAfter(DateTime.now()))
        .toList()
      ..sort((a, b) => a.reminder!.compareTo(b.reminder!));
    if (upcoming.isEmpty) return;
    final task = upcoming.first;
    reminderTimer = Timer(task.reminder!.difference(DateTime.now()), () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.alert);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              _tr('⏰ Reminder: ${task.title}', '⏰ یادآوری: ${task.title}')),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
              label: _tr('OPEN', 'باز کردن'),
              onPressed: () => _addOrEdit(task))));
      _scheduleReminder();
    });
  }

  @override
  void dispose() {
    reminderTimer?.cancel();
    super.dispose();
  }

  void _addOrEdit([Todo? edit]) async {
    final result = await showModalBottomSheet<Todo>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TaskEditor(task: edit),
    );
    if (result == null) return;
    _update(() {
      if (edit == null) {
        tasks.add(result);
      } else {
        tasks[tasks.indexWhere((t) => t.id == edit.id)] = result;
      }
      SystemSound.play(SystemSoundType.click);
    });
  }

  void _delete(Todo task) {
    _update(() => tasks.remove(task));
    NotificationService.instance.cancel(task.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_tr('"${task.title}" deleted', '«${task.title}» حذف شد')),
        action: SnackBarAction(
            label: _tr('UNDO', 'بازگردانی'),
            onPressed: () => _update(() => tasks.add(task))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final pages = [
      HomePage(
          tasks: tasks,
          onToggle: (t) {
            HapticFeedback.selectionClick();
            SystemSound.play(SystemSoundType.click);
            _update(() {
              t.done = !t.done;
              t.completedAt = t.done ? DateTime.now() : null;
            });
          },
          onEdit: _addOrEdit,
          onFocus: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => FocusSprintSheet(
                    onFinished: () {
                      _update(() => focusSessions++);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(_tr(
                            'Focus sprint complete — brilliant work!',
                            'جلسهٔ تمرکز تمام شد؛ عالی بود!')),
                        behavior: SnackBarBehavior.floating,
                      ));
                    },
                  )),
          onSmartPlan: () => _showDailyPlan(),
          focusSessions: focusSessions),
      TasksPage(
        tasks: tasks,
        onToggle: (t) {
          HapticFeedback.selectionClick();
          SystemSound.play(SystemSoundType.click);
          _update(() {
            t.done = !t.done;
            t.completedAt = t.done ? DateTime.now() : null;
          });
        },
        onEdit: _addOrEdit,
        onDelete: _delete,
      ),
      CalendarPage(tasks: tasks, onEdit: _addOrEdit),
      InsightsPage(tasks: tasks, focusSessions: focusSessions),
      SettingsPage(
          remindersEnabled: remindersEnabled,
          persian: _isPersian,
          onLanguageChanged: widget.onLanguageChanged,
          onRemindersChanged: (value) async {
            if (value) {
              final granted =
                  await NotificationService.instance.requestPermissions();
              if (!granted && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(_tr(
                        'Notifications need permission to send your nudges.',
                        'برای ارسال یادآوری‌ها، اجازهٔ اعلان‌ها را فعال کنید.')),
                    behavior: SnackBarBehavior.floating));
                return;
              }
            }
            _update(() => remindersEnabled = value);
          },
          onClear: () => _update(() => tasks.clear())),
    ];
    return Directionality(
        textDirection: _isPersian ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-.75, -.9),
                radius: 1.15,
                colors: [Color(0xff25275c), _bg, Color(0xff050711)],
              ),
            ),
            child: SafeArea(
              child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                          position: Tween<Offset>(
                                  begin: const Offset(.025, 0),
                                  end: Offset.zero)
                              .animate(animation),
                          child: child)),
                  child:
                      KeyedSubtree(key: ValueKey(index), child: pages[index])),
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addOrEdit,
            backgroundColor: _violet,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: Text(_tr('Add task', 'افزودن کار')),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            backgroundColor: const Color(0xff0d1224),
            indicatorColor: _violet.withValues(alpha: .25),
            onDestinationSelected: (v) {
              HapticFeedback.selectionClick();
              setState(() => index = v);
            },
            destinations: [
              NavigationDestination(
                  icon: const Icon(Icons.grid_view_rounded),
                  label: _tr('Home', 'خانه')),
              NavigationDestination(
                  icon: const Icon(Icons.checklist_rounded),
                  label: _tr('Tasks', 'کارها')),
              NavigationDestination(
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: _tr('Calendar', 'تقویم')),
              NavigationDestination(
                  icon: const Icon(Icons.insights_rounded),
                  label: _tr('Insights', 'آمار')),
              NavigationDestination(
                  icon: const Icon(Icons.tune_rounded),
                  label: _tr('Settings', 'تنظیمات')),
            ],
          ),
        ));
  }

  void _showDailyPlan() {
    final plan = tasks.where((task) => !task.done).toList()
      ..sort((a, b) {
        final priority = b.priority.compareTo(a.priority);
        return priority != 0 ? priority : a.date.compareTo(b.date);
      });
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => DailyPlanSheet(tasks: plan.take(3).toList()),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage(
      {super.key,
      required this.tasks,
      required this.onToggle,
      required this.onEdit,
      required this.onFocus,
      required this.onSmartPlan,
      required this.focusSessions});
  final List<Todo> tasks;
  final ValueChanged<Todo> onToggle;
  final ValueChanged<Todo> onEdit;
  final VoidCallback onFocus;
  final VoidCallback onSmartPlan;
  final int focusSessions;
  @override
  Widget build(BuildContext context) {
    final today = tasks.where((t) => _sameDay(t.date, DateTime.now())).toList();
    final done = today.where((t) => t.done).length;
    final ratio = today.isEmpty ? 0.0 : done / today.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
      children: [
        Row(
          children: [
            const BrandMark(),
            const Spacer(),
            IconButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(_tr('All caught up — you’re doing great!',
                            'همه‌چیز به‌روز است؛ عالی پیش می‌روید!')),
                        behavior: SnackBarBehavior.floating)),
                icon: const Icon(Icons.notifications_none_rounded)),
          ],
        ),
        const SizedBox(height: 30),
        Text(
          _tr('Good ${_dayGreeting()}!', '${_persianGreeting()} بخیر!'),
          style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w700, color: _text),
        ),
        const SizedBox(height: 5),
        Text(_prettyDate(DateTime.now()),
            style: const TextStyle(color: _secondary)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: _card(gradient: true),
          child: Row(
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: ratio,
                      strokeWidth: 10,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _localizedDigits('${(ratio * 100).round()}%'),
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold),
                          ),
                          Text(_tr('complete', 'انجام‌شده'),
                              style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr('Today’s focus', 'تمرکز امروز'),
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _tr('$done of ${today.length} tasks finished',
                          '${_localizedDigits('$done')} از ${_localizedDigits('${today.length}')} کار انجام شده'),
                      style: const TextStyle(color: Color(0xffe4e0ff)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _tr('Keep your momentum going.',
                          'ریتم خوبتان را حفظ کنید.'),
                      style: TextStyle(color: Color(0xffd0cbff), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        InkWell(
            onTap: onFocus,
            borderRadius: BorderRadius.circular(20),
            child: Container(
                padding: const EdgeInsets.all(16),
                decoration: _card(),
                child: Row(children: [
                  DecoratedBox(
                      decoration:
                          BoxDecoration(color: _violet, shape: BoxShape.circle),
                      child: const SizedBox(
                          width: 40,
                          height: 40,
                          child:
                              Icon(Icons.timer_outlined, color: Colors.white))),
                  const SizedBox(width: 13),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(_tr('Focus sprint', 'اسپرینت تمرکز'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                            _tr('25 distraction-free minutes',
                                '۲۵ دقیقه بدون حواس‌پرتی'),
                            style: const TextStyle(
                                color: _secondary, fontSize: 12))
                      ])),
                  const Icon(Icons.play_arrow_rounded, color: _violet)
                ]))),
        const SizedBox(height: 12),
        InkWell(
          onTap: onSmartPlan,
          borderRadius: BorderRadius.circular(20),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                    color: Color(0x335ee6c3), shape: BoxShape.circle),
                child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.auto_awesome_rounded, color: _mint)),
              ),
              const SizedBox(width: 13),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_tr('Smart daily plan', 'برنامهٔ هوشمند روز'),
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                        _tr('Your next best ${tasks.where((t) => !t.done).length.clamp(0, 3)} priorities, curated',
                            'بهترین ${_localizedDigits('${tasks.where((t) => !t.done).length.clamp(0, 3)}')} اولویت بعدی شما'),
                        style:
                            const TextStyle(color: _secondary, fontSize: 12)),
                  ])),
              const Icon(Icons.arrow_forward_rounded, color: _mint),
            ]),
          ),
        ),
        if (focusSessions > 0) ...[
          const SizedBox(height: 12),
          Text(
              _tr('⚡ $focusSessions focus ${focusSessions == 1 ? 'sprint' : 'sprints'} completed',
                  '⚡ ${_localizedDigits('$focusSessions')} جلسهٔ تمرکز انجام‌شده'),
              style: const TextStyle(color: _mint, fontSize: 12)),
        ],
        const SizedBox(height: 28),
        SectionTitle(
            title: _tr('Today’s tasks', 'کارهای امروز'),
            trailing: _tr('${today.length} tasks',
                '${_localizedDigits('${today.length}')} کار')),
        const SizedBox(height: 10),
        if (today.isEmpty)
          EmptyState(
              text: _tr('Nothing scheduled for today.',
                  'برای امروز کاری برنامه‌ریزی نشده است.'))
        else
          ...today.map(
            (t) => TaskTile(
                task: t, onToggle: () => onToggle(t), onTap: () => onEdit(t)),
          ),
        const SizedBox(height: 22),
        SectionTitle(
            title: _tr('Pinned', 'سنجاق‌شده‌ها'),
            trailing: _tr('View all', 'همه')),
        const SizedBox(height: 10),
        ...tasks.where((t) => t.pinned && !today.contains(t)).map((t) =>
            TaskTile(
                task: t, onToggle: () => onToggle(t), onTap: () => onEdit(t))),
      ],
    );
  }
}

class TasksPage extends StatefulWidget {
  const TasksPage({
    super.key,
    required this.tasks,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });
  final List<Todo> tasks;
  final ValueChanged<Todo> onToggle;
  final ValueChanged<Todo> onEdit;
  final ValueChanged<Todo> onDelete;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String filter = 'All';
  String query = '';
  @override
  Widget build(BuildContext context) {
    final shown = widget.tasks
        .where(
          (t) =>
              (filter == 'All' ||
                  (filter == 'Important' && t.priority >= 2) ||
                  (filter == 'Completed' && t.done)) &&
              t.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
      children: [
        Text(_tr('My tasks', 'کارهای من'),
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: _input(
              _tr('Search tasks', 'جست‌وجوی کارها'), Icons.search_rounded),
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['All', 'Important', 'Completed']
                .map(
                  (v) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(v == 'All'
                          ? _tr('All', 'همه')
                          : v == 'Important'
                              ? _tr('Important', 'مهم')
                              : _tr('Completed', 'انجام‌شده')),
                      selected: filter == v,
                      onSelected: (_) => setState(() => filter = v),
                      selectedColor: _violet,
                      backgroundColor: _surface,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 18),
        if (shown.isEmpty)
          EmptyState(
              text: _tr('No tasks match this view.',
                  'کاری مطابق این فیلتر پیدا نشد.'))
        else
          ...shown.map(
            (t) => Dismissible(
              key: ValueKey(t.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                decoration: _card(color: Colors.red.withValues(alpha: .16)),
                child: const Icon(Icons.delete_outline_rounded,
                    color: Colors.redAccent),
              ),
              onDismissed: (_) => widget.onDelete(t),
              child: TaskTile(
                task: t,
                onToggle: () => widget.onToggle(t),
                onTap: () => widget.onEdit(t),
              ),
            ),
          ),
      ],
    );
  }
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key, required this.tasks, required this.onEdit});
  final List<Todo> tasks;
  final ValueChanged<Todo> onEdit;
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime selected;
  @override
  void initState() {
    super.initState();
    selected = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(selected.year, selected.month);
    final weekStartOffset =
        _isPersian ? (first.weekday + 1) % 7 : first.weekday % 7;
    final days = List.generate(
        42, (i) => first.add(Duration(days: i - weekStartOffset)));
    final selectedTasks =
        widget.tasks.where((t) => _sameDay(t.date, selected)).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() =>
                  selected = DateTime(selected.year, selected.month - 1, 1)),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                _isPersian
                    ? '${_localizedDigits('${selected.year}')} ${_month(selected)}'
                    : '${_month(selected)} ${selected.year}',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: () => setState(() =>
                  selected = DateTime(selected.year, selected.month + 1, 1)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: (_isPersian
                  ? const ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج']
                  : const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
              .map(
                (d) => Expanded(
                  child: Center(
                    child: Text(d, style: TextStyle(color: _secondary)),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 42,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            childAspectRatio: 1,
          ),
          itemBuilder: (_, i) {
            final day = days[i];
            final active = _sameDay(day, selected);
            final marked = widget.tasks.any((t) => _sameDay(t.date, day));
            return InkWell(
              onTap: () => setState(() => selected = day),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: active ? _violet : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _localizedDigits('${day.day}'),
                      style: TextStyle(
                        color: day.month == selected.month ? _text : _secondary,
                        fontWeight:
                            active ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    if (marked)
                      Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 3),
                        decoration: const BoxDecoration(
                            color: _blue, shape: BoxShape.circle),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 28),
        SectionTitle(
          title: _sameDay(selected, DateTime.now())
              ? _tr('Today', 'امروز')
              : _isPersian
                  ? '${_localizedDigits('${selected.day}')} ${_month(selected)}'
                  : '${_month(selected)} ${selected.day}',
          trailing: _tr('${selectedTasks.length} tasks',
              '${_localizedDigits('${selectedTasks.length}')} کار'),
        ),
        const SizedBox(height: 10),
        if (selectedTasks.isEmpty)
          EmptyState(
              text: _tr('No tasks for this date.',
                  'برای این تاریخ کاری ثبت نشده است.'))
        else
          ...selectedTasks.map(
            (t) => TaskTile(
                task: t, onToggle: () {}, onTap: () => widget.onEdit(t)),
          ),
      ],
    );
  }
}

class InsightsPage extends StatelessWidget {
  const InsightsPage(
      {super.key, required this.tasks, required this.focusSessions});
  final List<Todo> tasks;
  final int focusSessions;
  @override
  Widget build(BuildContext context) {
    final complete = tasks.where((t) => t.done).length;
    final rate = tasks.isEmpty ? 0 : complete * 100 ~/ tasks.length;
    final groups = <String, int>{};
    for (final task in tasks) {
      groups[task.category] = (groups[task.category] ?? 0) + 1;
    }
    final streak = _completionStreak(tasks);
    final achievementCount = [
      complete >= 1,
      complete >= 10,
      streak >= 3,
      focusSessions >= 1,
    ].where((unlocked) => unlocked).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
      children: [
        Text(_tr('Insights', 'آمار'),
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(_tr('Your productivity at a glance', 'نمایی از بهره‌وری شما'),
            style: TextStyle(color: _secondary)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: _card(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_tr('Completion rate', 'درصد تکمیل'),
                  style: const TextStyle(color: _secondary)),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_localizedDigits('$rate%'),
                      style: const TextStyle(
                          fontSize: 42, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(
                    _tr('$complete / ${tasks.length} completed',
                        '${_localizedDigits('$complete')} / ${_localizedDigits('${tasks.length}')} تکمیل‌شده'),
                    style: const TextStyle(color: _secondary),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: rate / 100,
                  minHeight: 10,
                  backgroundColor: _elevated,
                  valueColor: const AlwaysStoppedAnimation(_violet),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SectionTitle(
            title: _tr('Momentum', 'روند پیشرفت'),
            trailing: _tr('Achievements', 'دستاوردها')),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(
                  color: Color(0x33ffc95c), shape: BoxShape.circle),
              child: const Icon(Icons.local_fire_department_rounded,
                  color: _gold, size: 30),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      _tr('$streak-day streak',
                          '${_localizedDigits('$streak')} روز پیاپی'),
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800)),
                  Text(
                      _tr('$achievementCount of 4 achievements unlocked',
                          '${_localizedDigits('$achievementCount')} از ۴ دستاورد باز شده'),
                      style: const TextStyle(color: _secondary, fontSize: 12)),
                ])),
            Text(_localizedDigits('${(streak * 7).clamp(0, 100)}%'),
                style:
                    const TextStyle(color: _gold, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Achievement(
                label: _tr('First win', 'اولین موفقیت'),
                unlocked: complete >= 1,
                icon: Icons.emoji_events_rounded),
            _Achievement(
                label: _tr('Task master', 'استاد انجام کارها'),
                unlocked: complete >= 10,
                icon: Icons.workspace_premium_rounded),
            _Achievement(
                label: _tr('On fire', 'پیوسته در اوج'),
                unlocked: streak >= 3,
                icon: Icons.local_fire_department_rounded),
            _Achievement(
                label: _tr('Deep work', 'تمرکز عمیق'),
                unlocked: focusSessions >= 1,
                icon: Icons.bolt_rounded),
          ],
        ),
        const SizedBox(height: 24),
        SectionTitle(
            title: _tr('Category balance', 'تقسیم‌بندی دسته‌ها'), trailing: ''),
        const SizedBox(height: 12),
        ...groups.entries.map((entry) {
          final ratio = tasks.isEmpty ? 0.0 : entry.value / tasks.length;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: _card(),
            child: Row(
              children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration:
                      const BoxDecoration(color: _blue, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_category(entry.key))),
                Text(
                    _tr('${entry.value} tasks',
                        '${_localizedDigits('${entry.value}')} کار'),
                    style: const TextStyle(color: _secondary)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 60,
                  child: LinearProgressIndicator(
                    value: ratio,
                    color: _blue,
                    backgroundColor: _elevated,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage(
      {super.key,
      required this.onClear,
      required this.remindersEnabled,
      required this.persian,
      required this.onLanguageChanged,
      required this.onRemindersChanged});
  final VoidCallback onClear;
  final bool remindersEnabled;
  final bool persian;
  final ValueChanged<bool> onLanguageChanged;
  final ValueChanged<bool> onRemindersChanged;
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
        children: [
          Text(_tr('Settings', 'تنظیمات'),
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),
          Container(
              padding: const EdgeInsets.all(18),
              decoration: _card(gradient: true),
              child: Row(children: [
                const CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.white24,
                    child: Icon(Icons.auto_awesome_rounded)),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(_tr('Make today count', 'امروز را پربار بسازید'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 17)),
                      Text(
                          _tr('Small wins, big energy.',
                              'موفقیت‌های کوچک، انگیزه‌ای بزرگ.'),
                          style: const TextStyle(color: Color(0xffddd9ff)))
                    ]))
              ])),
          const SizedBox(height: 24),
          SectionTitle(title: _tr('Preferences', 'ترجیحات'), trailing: ''),
          Container(
              margin: const EdgeInsets.only(top: 10),
              decoration: _card(),
              child: SwitchListTile(
                  value: persian,
                  onChanged: onLanguageChanged,
                  secondary: const Icon(Icons.language_rounded, color: _mint),
                  title: Text(_tr('Persian interface', 'رابط کاربری فارسی')),
                  subtitle: Text(_tr(
                      'Use right-to-left layout and Persian labels',
                      'چیدمان راست‌به‌چپ و برچسب‌های فارسی')))),
          const SizedBox(height: 10),
          Container(
              margin: const EdgeInsets.only(top: 10),
              decoration: _card(),
              child: SwitchListTile(
                  value: remindersEnabled,
                  onChanged: onRemindersChanged,
                  secondary: const Icon(Icons.notifications_active_outlined,
                      color: _violet),
                  title: Text(_tr('Gentle reminders', 'یادآوری‌های ملایم')),
                  subtitle: Text(remindersEnabled
                      ? _tr('Tiny nudges are ready', 'یادآوری‌ها آماده‌اند')
                      : _tr('Taking a quiet break',
                          'اعلان‌ها فعلاً خاموش هستند')))),
          const SizedBox(height: 18),
          SectionTitle(title: _tr('Data', 'داده‌ها'), trailing: ''),
          SettingRow(
            icon: Icons.delete_outline_rounded,
            title: _tr('Clear all tasks', 'پاک‌سازی همهٔ کارها'),
            subtitle: _tr(
                'Permanently remove local tasks', 'حذف دائمی کارهای ذخیره‌شده'),
            onTap: () => showDialog(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(_tr('Clear all tasks?', 'همهٔ کارها پاک شوند؟')),
                content: Text(_tr(
                    'This cannot be undone.', 'این کار قابل بازگردانی نیست.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: Text(_tr('Cancel', 'انصراف'))),
                  FilledButton(
                    onPressed: () {
                      onClear();
                      Navigator.pop(c);
                    },
                    child: Text(_tr('Clear', 'پاک‌سازی')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text('${_tr('Taskora', 'تسکورا')} 1.0.0',
                style: const TextStyle(color: _secondary, fontSize: 12)),
          ),
        ],
      );
}

class FocusSprintSheet extends StatefulWidget {
  const FocusSprintSheet({super.key, required this.onFinished});
  final VoidCallback onFinished;
  @override
  State<FocusSprintSheet> createState() => _FocusSprintSheetState();
}

class _FocusSprintSheetState extends State<FocusSprintSheet> {
  Timer? timer;
  int seconds = 25 * 60;
  bool running = false;
  void toggle() {
    if (running) {
      timer?.cancel();
      setState(() => running = false);
      return;
    }
    setState(() => running = true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (seconds == 0) {
        timer?.cancel();
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
        setState(() => running = false);
        widget.onFinished();
        return;
      }
      setState(() => seconds--);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(99))),
        const SizedBox(height: 24),
        const Icon(Icons.timer_outlined, color: _violet, size: 40),
        const SizedBox(height: 10),
        Text(_tr('Focus sprint', 'جلسهٔ تمرکز'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            _tr('One little session. One big win.',
                'یک جلسهٔ کوتاه؛ یک موفقیت بزرگ.'),
            style: const TextStyle(color: _secondary)),
        const SizedBox(height: 22),
        Text(
            _localizedDigits(
                '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'),
            style: const TextStyle(fontSize: 54, fontWeight: FontWeight.w700)),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(
              child: OutlinedButton(
                  onPressed: () => setState(() => seconds = 25 * 60),
                  child: Text(_tr('Reset', 'از نو')))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton.icon(
                  onPressed: toggle,
                  icon: Icon(
                      running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  label: Text(
                      running ? _tr('Pause', 'توقف') : _tr('Start', 'شروع')),
                  style: FilledButton.styleFrom(
                      backgroundColor: _violet,
                      padding: const EdgeInsets.symmetric(vertical: 14))))
        ])
      ]));
}

class DailyPlanSheet extends StatelessWidget {
  const DailyPlanSheet({super.key, required this.tasks});
  final List<Todo> tasks;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 34),
        decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                  child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(99)))),
              const SizedBox(height: 22),
              Text(_tr('Smart daily plan', 'برنامهٔ هوشمند روز'),
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text(
                  _tr('A focused, priority-first plan for your day.',
                      'برنامه‌ای متمرکز که اولویت‌ها را در نظر می‌گیرد.'),
                  style: const TextStyle(color: _secondary)),
              const SizedBox(height: 18),
              if (tasks.isEmpty)
                Text(
                    _tr('You’re all clear. A perfect moment for a focus sprint.',
                        'همهٔ کارها انجام شده‌اند؛ فرصت خوبی برای تمرکز است.'),
                    style: const TextStyle(color: _secondary))
              else
                ...tasks.asMap().entries.map((entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: GlassCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            CircleAvatar(
                                radius: 14,
                                backgroundColor: _violet.withValues(alpha: .22),
                                child: Text(
                                    _localizedDigits('${entry.key + 1}'),
                                    style: const TextStyle(
                                        color: _text,
                                        fontWeight: FontWeight.bold))),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Text(entry.value.title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700))),
                            PriorityDot(priority: entry.value.priority),
                          ])),
                    )),
            ]),
      );
}

class _Achievement extends StatelessWidget {
  const _Achievement(
      {required this.label, required this.unlocked, required this.icon});
  final String label;
  final bool unlocked;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: unlocked
              ? _gold.withValues(alpha: .13)
              : Colors.white.withValues(alpha: .04),
          border: Border.all(
              color: unlocked ? _gold.withValues(alpha: .35) : Colors.white12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: unlocked ? _gold : _secondary),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: unlocked ? _text : _secondary)),
        ]),
      );
}

class TaskEditor extends StatefulWidget {
  const TaskEditor({super.key, this.task});
  final Todo? task;
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late TextEditingController title;
  late TextEditingController note;
  late DateTime date;
  late int priority;
  late String category;
  late bool remind;
  TimeOfDay reminderTime = const TimeOfDay(hour: 9, minute: 0);
  @override
  void initState() {
    super.initState();
    final task = widget.task;
    title = TextEditingController(text: task?.title);
    note = TextEditingController(text: task?.note);
    date = task?.date ?? DateTime.now();
    priority = task?.priority ?? 1;
    category = task?.category ?? 'Personal';
    remind = task?.remind ?? false;
    if (task?.reminder != null)
      reminderTime = TimeOfDay.fromDateTime(task!.reminder!);
  }

  @override
  void dispose() {
    title.dispose();
    note.dispose();
    super.dispose();
  }

  void submit() {
    if (title.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      Todo(
        id: widget.task?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: title.text.trim(),
        note: note.text.trim(),
        date: date,
        priority: priority,
        category: category,
        done: widget.task?.done ?? false,
        completedAt: widget.task?.completedAt,
        pinned: widget.task?.pinned ?? false,
        remind: remind,
        reminder: remind
            ? DateTime(date.year, date.month, date.day, reminderTime.hour,
                reminderTime.minute)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          decoration: const BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.task == null
                      ? _tr('New task', 'کار جدید')
                      : _tr('Edit task', 'ویرایش کار'),
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: _input(
                      _tr('What needs to be done?', 'چه کاری باید انجام شود؟'),
                      Icons.edit_outlined),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 2,
                  decoration: _input(_tr('Add a note', 'افزودن یادداشت'),
                      Icons.subject_rounded),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                            initialDate: date,
                          );
                          if (picked != null) setState(() => date = picked);
                        },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(_prettyDate(date)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: category,
                        decoration: _input('', Icons.category_outlined),
                        items: [
                          'Personal',
                          'Work',
                          'Health',
                          'Learning',
                        ]
                            .map((v) => DropdownMenuItem(
                                value: v, child: Text(_category(v))))
                            .toList(),
                        onChanged: (v) => setState(() => category = v!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                    decoration: _card(),
                    child: SwitchListTile(
                        value: remind,
                        onChanged: (value) => setState(() => remind = value),
                        secondary:
                            const Icon(Icons.alarm_rounded, color: _violet),
                        title: Text(_tr('Give me a gentle nudge',
                            'یک یادآوری ملایم برای من')),
                        subtitle: Text(remind
                            ? _tr('At ${reminderTime.format(context)}',
                                'ساعت ${reminderTime.format(context)}')
                            : _tr(
                                'No reminder for this one', 'بدون یادآوری')))),
                if (remind)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showTimePicker(
                                context: context, initialTime: reminderTime);
                            if (picked != null)
                              setState(() => reminderTime = picked);
                          },
                          icon: const Icon(Icons.schedule_rounded),
                          label: Text(_tr(
                              'Reminder time · ${reminderTime.format(context)}',
                              'زمان یادآوری · ${reminderTime.format(context)}')))),
                const SizedBox(height: 16),
                Text(_tr('Priority', 'اولویت'),
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: List.generate(
                    4,
                    (i) => Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i == 3 ? 0 : 8),
                        child: ChoiceChip(
                          label: Text(_isPersian
                              ? ['کم', 'متوسط', 'زیاد', 'فوری'][i]
                              : ['Low', 'Medium', 'High', 'Urgent'][i]),
                          selected: priority == i,
                          onSelected: (_) => setState(() => priority = i),
                          selectedColor: _violet,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: _violet,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(widget.task == null
                        ? _tr('Create task', 'ایجاد کار')
                        : _tr('Save changes', 'ذخیرهٔ تغییرات')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key});
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: .28)),
              borderRadius: BorderRadius.all(Radius.circular(9)),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: SizedBox(
                width: 31,
                height: 31,
                child: Image.asset('assets/images/taskora_logo.png',
                    fit: BoxFit.cover),
              ),
            ),
          ),
          SizedBox(width: 9),
          Text(
            _tr('taskora', 'تسکورا'),
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.5),
          ),
        ],
      );
}

class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .075),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: .16)),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 18, offset: Offset(0, 9))
              ],
            ),
            child: child,
          ),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, required this.trailing});
  final String title, trailing;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(trailing,
              style: const TextStyle(color: _secondary, fontSize: 12)),
        ],
      );
}

class TaskTile extends StatelessWidget {
  const TaskTile(
      {super.key,
      required this.task,
      required this.onToggle,
      required this.onTap});
  final Todo task;
  final VoidCallback onToggle, onTap;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: _card(),
        child: ListTile(
          onTap: onTap,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
          leading: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 25,
              height: 25,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: task.done ? _violet : Colors.transparent,
                border: Border.all(
                    color: task.done ? _violet : _secondary, width: 2),
              ),
              child: task.done ? const Icon(Icons.check, size: 16) : null,
            ),
          ),
          title: Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: task.done ? TextDecoration.lineThrough : null,
              color: task.done ? _secondary : _text,
            ),
          ),
          subtitle: Text(
            '${_category(task.category)} · ${_prettyDate(task.date)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: _secondary),
          ),
          trailing: task.pinned
              ? const Icon(Icons.push_pin_rounded, color: _violet, size: 18)
              : PriorityDot(priority: task.priority),
        ),
      );
}

class PriorityDot extends StatelessWidget {
  const PriorityDot({super.key, required this.priority});
  final int priority;
  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: [
            const Color(0xff52d3a0),
            const Color(0xffffc25a),
            const Color(0xffff7e50),
            const Color(0xffff5277),
          ][priority],
          shape: BoxShape.circle,
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(28),
        decoration: _card(),
        child: Column(
          children: [
            const Icon(Icons.auto_awesome_rounded, color: _violet, size: 30),
            const SizedBox(height: 10),
            Text(text, style: const TextStyle(color: _secondary)),
          ],
        ),
      );
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 10),
        decoration: _card(),
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: _violet),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded, color: _secondary),
        ),
      );
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    tz_data.initializeTimeZones();
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
  }

  Future<bool> requestPermissions() async {
    final notifications = await ensureNotificationPermission();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestExactAlarmsPermission();
    return notifications;
  }

  Future<bool> ensureNotificationPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  Future<void> schedule(Todo task) async {
    final when = task.reminder;
    if (when == null || !when.isAfter(DateTime.now())) return;
    final details = NotificationDetails(
        android: AndroidNotificationDetails('taskora_reminders_v2',
            _tr('Taskora reminders', 'یادآوری‌های تسکورا'),
            channelDescription: _tr('Audible reminders for your tasks',
                'اعلان‌های صوتی برای یادآوری کارها'),
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            audioAttributesUsage: AudioAttributesUsage.alarm));
    final scheduledTime = tz.TZDateTime.from(when, tz.local);
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final exactAllowed =
        await android?.canScheduleExactNotifications() ?? false;
    await _scheduleAt(
      _idFor(task.id),
      _tr('Taskora', 'تسکورا'),
      task.title,
      scheduledTime,
      details,
      exactAllowed
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  Future<void> _scheduleAt(
    int id,
    String title,
    String body,
    tz.TZDateTime time,
    NotificationDetails details,
    AndroidScheduleMode mode,
  ) =>
      _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: time,
        notificationDetails: details,
        androidScheduleMode: mode,
      );

  Future<void> cancel(String taskId) => _plugin.cancel(id: _idFor(taskId));
  int _idFor(String taskId) => taskId.hashCode & 0x7fffffff;
}

BoxDecoration _card({bool gradient = false, Color? color}) => BoxDecoration(
      color: gradient ? null : color ?? _surface.withValues(alpha: .78),
      gradient: gradient
          ? const LinearGradient(
              colors: [Color(0xff4935d6), Color(0xff293fc4)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
          : null,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 8))
      ],
    );
InputDecoration _input(String hint, IconData icon) => InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: _secondary),
      filled: true,
      fillColor: _elevated,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: .06)),
      ),
    );
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
int _completionStreak(List<Todo> tasks) {
  final days = tasks
      .where((task) => task.done)
      .map((task) => DateUtils.dateOnly(task.completedAt ?? task.date))
      .toSet();
  var day = DateUtils.dateOnly(DateTime.now());
  if (!days.contains(day)) day = day.subtract(const Duration(days: 1));
  var streak = 0;
  while (days.contains(day)) {
    streak++;
    day = day.subtract(const Duration(days: 1));
  }
  return streak;
}

String _prettyDate(DateTime d) {
  final now = DateTime.now();
  if (_sameDay(d, now)) return _tr('Today', 'امروز');
  if (_sameDay(d, now.add(const Duration(days: 1))))
    return _tr('Tomorrow', 'فردا');
  return _isPersian
      ? '${_localizedDigits('${d.day}')} ${_month(d)}'
      : '${_month(d)} ${d.day}';
}

String _month(DateTime d) => (_isPersian
    ? const [
        'ژانویه',
        'فوریه',
        'مارس',
        'آوریل',
        'مه',
        'ژوئن',
        'ژوئیه',
        'اوت',
        'سپتامبر',
        'اکتبر',
        'نوامبر',
        'دسامبر',
      ]
    : const [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ])[d.month - 1];

String _localizedDigits(String value) {
  if (!_isPersian) return value;
  const digits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
  return value.replaceAllMapped(
      RegExp(r'[0-9]'), (match) => digits[int.parse(match[0]!)]);
}

String _dayGreeting() {
  final h = DateTime.now().hour;
  return h < 12
      ? 'morning'
      : h < 18
          ? 'afternoon'
          : 'evening';
}

String _persianGreeting() {
  final h = DateTime.now().hour;
  return h < 12
      ? 'صبح'
      : h < 18
          ? 'عصر'
          : 'شب';
}
