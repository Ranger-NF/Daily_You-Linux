import 'dart:convert';
import 'dart:io';
import 'package:daily_you/stats_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:daily_you/models/entry.dart';
import 'package:image_picker/image_picker.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

import 'config_manager.dart';

class EntriesDatabase {
  static final EntriesDatabase instance = EntriesDatabase._init();

  static Database? _database;

  EntriesDatabase._init();

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    if (usingExternalDb()) syncExternalDatabase();
    final dbPath = await getLogDatabasePath();

    return await openDatabase(dbPath, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
CREATE TABLE $entriesTable (
  ${EntryFields.id} INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ${EntryFields.text} TEXT NOT NULL,
  ${EntryFields.imgPath} TEXT,
  ${EntryFields.mood} INTEGER,
  ${EntryFields.timeCreate} DATETIME NOT NULL DEFAULT (DATETIME('now')),
  ${EntryFields.timeModified} DATETIME NOT NULL DEFAULT (DATETIME('now'))
)
''');
  }

  Future<Entry> create(Entry entry) async {
    final db = await instance.database;

    final id = await db.insert(entriesTable, entry.toJson());
    await StatsProvider.instance.updateStats();
    if (usingExternalDb()) await updateExternalDatabase();
    return entry.copy(id: id);
  }

  Future<Entry?> getEntry(int id) async {
    final db = await instance.database;

    final maps = await db.query(
      entriesTable,
      columns: EntryFields.values,
      where: '${EntryFields.id} = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Entry.fromJson(maps.first);
    } else {
      return null;
    }
  }

  Future<Entry?> getEntryForDate(DateTime date) async {
    final entries = await getAllEntries();

    //Search each entry for one on the date
    for (var entry in entries) {
      if (entry.timeCreate.day == date.day &&
          entry.timeCreate.month == date.month &&
          entry.timeCreate.year == date.year) {
        return entry;
      }
    }

    return null;
  }

  Future<List<Entry>> getAllEntries() async {
    final db = await instance.database;

    final result =
        await db.query(entriesTable, orderBy: '${EntryFields.timeCreate} DESC');

    return result.map((json) => Entry.fromJson(json)).toList();
  }

  Future<List<Entry>> getAllEntriesSorted(String orderBy, String order) async {
    final db = await instance.database;

    final result = await db.query(entriesTable, orderBy: '$orderBy $order');

    return result.map((json) => Entry.fromJson(json)).toList();
  }

  Future<int> updateEntry(Entry entry) async {
    final db = await instance.database;

    final id = await db.update(
      entriesTable,
      entry.toJson(),
      where: '${EntryFields.id} = ?',
      whereArgs: [entry.id],
    );
    await StatsProvider.instance.updateStats();
    if (usingExternalDb()) await updateExternalDatabase();
    return id;
  }

  Future<int> deleteEntry(int id) async {
    final db = await instance.database;

    final removedId = await db.delete(
      entriesTable,
      where: '${EntryFields.id} = ?',
      whereArgs: [id],
    );
    await StatsProvider.instance.updateStats();
    if (usingExternalDb()) await updateExternalDatabase();
    return removedId;
  }

  Future<void> deleteAllEntries() async {
    final entries = await getAllEntries();
    for (Entry entry in entries) {
      await deleteEntryImage(entry.id!);
      await deleteEntry(entry.id!);
    }
  }

  Future close() async {
    final db = await instance.database;
    _database = null;
    db.close();
  }

  bool usingExternalDb() {
    return ConfigManager.instance.getField('useExternalDb') ?? false;
  }

  Future<String> getImgPath(String imageName) async {
    var basePath = await getImgDatabasePath();

    return '$basePath/$imageName';
  }

  Future<void> deleteEntryImage(int id) async {
    final entry = await getEntry(id);
    if (entry != null && entry.imgPath != null) {
      final path = '${await getImgDatabasePath()}/${entry.imgPath!}';
      if (await File(path).exists()) {
        await File(path).delete();
      }
    }
  }

  Future<String> getImgDatabasePath() async {
    if (ConfigManager.instance.getField('imgPath') == '') {
      Directory basePath;
      if (Platform.isAndroid) {
        basePath = (await getExternalStorageDirectory())!;
        basePath = Directory('${basePath.path}/Images');
      } else {
        basePath = await getApplicationSupportDirectory();
        basePath = Directory('${basePath.path}/Images');
      }

      if (!basePath.existsSync()) {
        basePath.createSync(recursive: true);
      }

      return basePath.path;
    }
    final rootImgPath = ConfigManager.instance.getField('imgPath');
    return rootImgPath;
  }

  Future<String> getLogDatabasePath() async {
    Directory basePath;
    if (Platform.isAndroid) {
      basePath = (await getExternalStorageDirectory())!;
    } else {
      basePath = await getApplicationSupportDirectory();
    }
    if (!basePath.existsSync()) {
      basePath.createSync(recursive: true);
    }

    return join(basePath.path, 'daily_you.db');
  }

  Future<bool> selectDatabaseLocation() async {
    // Get external folder Uri
    var newFolderUri = await saf.openDocumentTree();
    if (newFolderUri != null) {
      // Check if DB exists in external directory
      var existingNewDb = await saf.child(newFolderUri, "daily_you.db",
          requiresWriteAccess: true);
      if (existingNewDb != null) {
        // Import external DB
        var bytes = await existingNewDb.getContent();
        if (bytes != null) {
          //Overwrite internal DB
          await File(await getLogDatabasePath()).writeAsBytes(bytes);

          // Use external DB
          await ConfigManager.instance
              .setField('externalDbUri', existingNewDb.uri.toString());
          await ConfigManager.instance.setField('useExternalDb', true);

          return true;
        }
      } else {
        // Export internal DB
        var bytes = await File(await getLogDatabasePath()).readAsBytes();
        var newExternalDb = await saf.createFileAsBytes(newFolderUri,
            mimeType: "*/*", displayName: "daily_you.db", bytes: bytes);
        if (newExternalDb != null) {
          // Use external DB
          await ConfigManager.instance
              .setField('externalDbUri', newExternalDb.uri.toString());
          await ConfigManager.instance.setField('useExternalDb', true);

          return true;
        }
      }
    }

    return false;
  }

  Future<bool> updateExternalDatabase() async {
    var updated = false;

    var externalUriPath = ConfigManager.instance.getField('externalDbUri');
    var bytes = await File(await getLogDatabasePath()).readAsBytes();
    var externUri = Uri.parse(externalUriPath);
    var canWrite = await saf.canWrite(externUri);
    if (canWrite != null && canWrite) {
      updated = await saf.writeToFileAsBytes(externUri, bytes: bytes) ?? false;
    }
    return updated;
  }

  Future<bool> syncExternalDatabase() async {
    // Check which file is newer
    if (await isExternalDbNewer()) {
      var bytes = await saf.getDocumentContent(
          Uri.parse(ConfigManager.instance.getField('externalDbUri')));
      if (bytes != null) {
        //Overwrite internal DB
        await File(await getLogDatabasePath()).writeAsBytes(bytes);
        return true;
      } else {
        return false;
      }
    }
    return true;
  }

  Future<bool> isExternalDbNewer() async {
    var internalModifiedTime =
        await File(await getLogDatabasePath()).lastModified();

    var externalModifiedTime = DateTime.now();
    var externalDb = await saf.DocumentFile.fromTreeUri(
        Uri.parse(ConfigManager.instance.getField('externalDbUri')));
    if (externalDb != null) {
      externalModifiedTime = externalDb.lastModified ?? DateTime.now();
    }

    return externalModifiedTime.isAfter(internalModifiedTime);
  }

  void resetDatabaseLocation() async {
    await ConfigManager.instance.setField('useExternalDb', false);
  }

  Future<bool> selectImageFolder() async {
    final selectedDirectory = await getDirectoryPath();
    if (selectedDirectory.isNotEmpty && selectedDirectory != "/") {
      await ConfigManager.instance.setField('imgPath', selectedDirectory);
      return true;
    }
    return false;
  }

  void resetImageFolderLocation() async {
    await ConfigManager.instance.setField('imgPath', '');
  }

  Future<String> getDirectoryPath() async {
    Directory? selectedDirectory;
    final result = await FilePicker.platform.getDirectoryPath();

    if (result != null) {
      selectedDirectory = Directory(result);
    }

    return selectedDirectory?.path ?? '';
  }

  Future<String> getFilePath() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );

    if (result != null) {
      final filePath = result.files.single.path;
      return filePath ?? '';
    }

    return '';
  }

  Future<bool> importFromOneShot() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result == null) {
      return false;
    }

    final jsonFile = File(result.files.single.path!);
    final jsonContent = await jsonFile.readAsString();
    final jsonData = json.decode(jsonContent);

    final happinessMapping = {
      "VERY_SAD": -2,
      "SAD": -1,
      "NEUTRAL": 0,
      "HAPPY": 1,
      "VERY_HAPPY": 2,
    };

    final db = await instance.database;

    for (var entry in jsonData) {
      final createdTimestamp = entry['created'];
      final createdDateTime =
          DateTime.fromMillisecondsSinceEpoch(createdTimestamp * 1000)
              .toIso8601String();
      final modifiedDateTime = DateTime.now().toUtc().toIso8601String();

      final happinessText = entry['happiness'];
      final mood = happinessMapping[happinessText];

      // Skip if the day already has an entry
      if (await getEntryForDate(DateTime.parse(createdDateTime)) == null) {
        await db.insert('entries', {
          'text': entry['textContent'],
          'img_path': entry['relativePath'],
          'mood': mood,
          'time_create': createdDateTime,
          'time_modified': modifiedDateTime,
        });
      }
    }

    return true;
  }

  Future<bool> exportImages() async {
    List<Entry> entries = await getAllEntries();
    final imgDirectory = await EntriesDatabase.instance.getImgDatabasePath();

    String? saveDir = await FilePicker.platform.getDirectoryPath();
    if (saveDir == null) return false;

    for (Entry entry in entries) {
      if (entry.imgPath == null) continue;

      final imageFilePath = "$imgDirectory/${entry.imgPath}";

      File image = File(imageFilePath);
      if (await image.exists()) {
        final saveFilePath = "$saveDir/${entry.imgPath}";
        await image.copy(saveFilePath);

        if (Platform.isAndroid) {
          // Add image to media store
          MediaScanner.loadMedia(path: saveFilePath);
        }
      }
    }

    return true;
  }

  Future<bool> importImages() async {
    final picker = ImagePicker();
    final pickedFiles = await picker.pickMultiImage();

    for (XFile file in pickedFiles) {
      final imgDirectory = await EntriesDatabase.instance.getImgDatabasePath();

      final imageFilePath = "$imgDirectory/${file.name}";
      await file.saveTo(imageFilePath);
      if (Platform.isAndroid) {
        // Add image to media store
        MediaScanner.loadMedia(path: imageFilePath);
      }
      // Delete picked file from cache
      await File(file.path).delete();
    }
    return true;
  }

  Future<bool> exportToJson() async {
    String? savePath = await getDirectoryPath();

    if (savePath.isEmpty) {
      return false;
    }

    final db = await instance.database;

    final List<Map<String, dynamic>> entries = await db.query('entries');

    final List<Map<String, dynamic>> jsonData = entries.map((entry) {
      return {
        'timeCreated': entry['time_create'],
        'timeModified': entry['time_modified'],
        'imgPath': entry['img_path'],
        'mood': entry['mood'],
        'text': entry['text'] ?? '',
      };
    }).toList();

    final jsonFile = File('$savePath/daily_you_logs.json');
    final jsonString = json.encode(jsonData);
    await jsonFile.create();
    await jsonFile.writeAsString(jsonString);
    return true;
  }

  Future<bool> importFromJson() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result == null) {
      return false;
    }

    final jsonFile = File(result.files.single.path!);
    final jsonContent = await jsonFile.readAsString();
    final jsonData = json.decode(jsonContent);

    final db = await instance.database;

    for (var entry in jsonData) {
      // Skip if the day already has an entry
      if (await getEntryForDate(DateTime.parse(entry['timeCreated'])) == null) {
        await db.insert('entries', {
          'text': entry['text'],
          'img_path': entry['imgPath'],
          'mood': entry['mood'],
          'time_create': entry['timeCreated'],
          'time_modified': entry['timeModified'],
        });
      }
    }
    return true;
  }
}
