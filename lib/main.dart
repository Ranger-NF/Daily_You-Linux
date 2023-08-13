import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:daily_you/entries_database.dart';
import 'package:daily_you/notification_manager.dart';
import 'package:daily_you/time_manager.dart';
import 'package:flutter/material.dart';
import 'package:daily_you/layouts/mobile_scaffold.dart';
import 'package:daily_you/layouts/responsive_layout.dart';
import 'package:daily_you/theme_mode_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:system_theme/system_theme.dart';
import 'config_manager.dart';
import 'package:provider/provider.dart';

@pragma('vm:entry-point')
void callbackDispatcher() async {
  if (await EntriesDatabase.instance.getEntryForDate(DateTime.now()) == null) {
    FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin.initialize(
        const InitializationSettings(
            android:
                AndroidInitializationSettings('@mipmap/ic_launcher_monochrome'),
            linux:
                LinuxInitializationSettings(defaultActionName: 'Log Today')));

    var androidPlatformChannelSpecifics = const AndroidNotificationDetails(
      'daily_you_reminder',
      'Log Reminder',
      icon: '@mipmap/ic_launcher_foreground',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    var platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
        0, 'Log Today!', 'Take your daily log...', platformChannelSpecifics);
  }

  await AndroidAlarmManager.oneShot(
      const Duration(hours: 1), 0, callbackDispatcher,
      alarmClock: true);
}

void main() async {
  if (Platform.isLinux || Platform.isWindows) {
    // Initialize FFI
    sqfliteFfiInit();
  }
  databaseFactory = databaseFactoryFfi;
  WidgetsFlutterBinding.ensureInitialized();
  await SystemTheme.accentColor.load();
  SystemTheme.fallbackColor = const Color.fromARGB(255, 1, 211, 239);

  // Create the config file if it doesn't exist
  await ConfigManager.instance.init();
  final themeProvider = ThemeModeProvider();
  await themeProvider.initializeThemeFromConfig();

  NotificationManager.instance.init();

  await AndroidAlarmManager.initialize();
  runApp(
    ChangeNotifierProvider(
      create: (_) => themeProvider,
      child: const MainApp(),
    ),
  );
}

Future<void> setAlarm() async {
  Duration timeUntilReminder;
  DateTime dayToRemind;
  if (TimeOfDay.now().hour < TimeManager.scheduledReminderTime().hour) {
    dayToRemind = TimeManager.startOfDay(DateTime.now());
  } else if (TimeOfDay.now().hour == TimeManager.scheduledReminderTime().hour &&
      TimeOfDay.now().minute < TimeManager.scheduledReminderTime().minute) {
    dayToRemind = TimeManager.startOfDay(DateTime.now());
  } else {
    dayToRemind = TimeManager.startOfNextDay();
  }
  DateTime reminderDateTime = TimeManager.addTimeOfDay(
      dayToRemind, TimeManager.scheduledReminderTime());
  timeUntilReminder = reminderDateTime.difference(DateTime.now());
  await AndroidAlarmManager.oneShot(timeUntilReminder, 0, callbackDispatcher,
      alarmClock: true);
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeModeProvider = Provider.of<ThemeModeProvider>(context);

    return GestureDetector(
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: MaterialApp(
        title: 'Daily You',
        themeMode: themeModeProvider.themeMode,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: SystemTheme.accentColor.accent,
              brightness: Brightness.light),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: SystemTheme.accentColor.accent,
              brightness: Brightness.dark),
        ),
        home: const ResponsiveLayout(
          mobileScaffold: MobileScaffold(),
          tabletScaffold: MobileScaffold(),
          desktopScaffold: MobileScaffold(),
        ),
      ),
    );
  }
}
