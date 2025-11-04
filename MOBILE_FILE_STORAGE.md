# Mobile File Storage in Flutter - What to Expect

## ✅ **TL;DR: Yes, it works on mobile!**

The CSV-based tactics database will work perfectly on iOS and Android. Files are stored in app-private storage that:
- ✅ Persists across app launches
- ✅ Requires no special permissions
- ✅ Works offline
- ✅ Is backed up (on iOS via iCloud, Android via Google Drive backup)
- ✅ Is deleted when app is uninstalled

---

## 📱 **How Flutter Stores Files on Each Platform**

### **Android**
```
/data/data/com.yourapp.chess_auto_prep/app_flutter/
└── tactics_positions.csv
```
- **Location**: Internal app storage (not external SD card)
- **Permissions**: None needed! (app-private storage)
- **User access**: Can't browse in file manager (requires root)
- **Backup**: Included in Android Auto Backup (if enabled)

### **iOS**
```
<Container>/Documents/
└── tactics_positions.csv
```
- **Location**: Sandboxed app container
- **Permissions**: None needed!
- **User access**: Can't browse directly (iOS sandbox)
- **Backup**: Automatically backed up to iCloud
- **iTunes**: Shows up in iTunes file sharing (can enable)

### **Desktop (for comparison)**
**Linux**: `~/.local/share/chess_auto_prep/tactics_positions.csv`
**macOS**: `~/Library/Containers/chess_auto_prep/Data/Documents/tactics_positions.csv`
**Windows**: `C:\Users\<user>\AppData\Roaming\chess_auto_prep\tactics_positions.csv`

---

## 🤔 **What Works & What Doesn't on Mobile**

### ✅ **What Works Perfectly:**

1. **Loading tactics from Lichess** → Auto-saves to CSV
2. **Solving tactics** → Stats update in CSV automatically
3. **App restarts** → All data persists
4. **Offline usage** → Works without internet after initial download
5. **Multiple sessions** → Review history builds over time
6. **File size** → CSV is tiny (1000 positions ≈ 500KB)

### ❌ **Limitations on Mobile:**

1. **Can't manually edit CSV** - File is hidden inside app
2. **Can't copy between Python & Flutter** - Different sandboxes
3. **Can't share with other apps** - Unless you add export feature
4. **Lost on uninstall** - Files deleted when app removed

---

## 💡 **Mobile-Friendly Enhancements**

I've created `lib/services/tactics_export_import.dart` which adds:

### **1. Export Tactics (Share)**
```dart
// On mobile: Opens share sheet → AirDrop, email, cloud storage
// On desktop: Opens file picker to save anywhere
await exportImport.exportTactics();
```

**Mobile UX:**
- Tap "Export" → Share sheet appears
- Choose: Email, AirDrop, Google Drive, Dropbox, etc.
- Send to friend, backup to cloud, or save to Files app

### **2. Import Tactics**
```dart
// Opens file picker on all platforms
final count = await exportImport.importTactics();
```

**Mobile UX:**
- Tap "Import" → File picker opens
- Choose from: Files app, Google Drive, Dropbox, etc.
- Merges with existing tactics

### **3. View Storage Stats**
```dart
final stats = await exportImport.getTacticsStats();
// Returns: file path, size, position count, reviews, etc.
```

---

## 🚀 **How to Add Export/Import to Your UI**

Here's a simple example for your settings or tactics screen:

```dart
// In your settings screen or tactics control panel
import '../services/tactics_export_import.dart';

class SettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final database = TacticsDatabase();
    final exportImport = TacticsExportImport(database);

    return ListView(
      children: [
        ListTile(
          leading: Icon(Icons.upload),
          title: Text('Export Tactics'),
          subtitle: Text('Share or backup your tactics'),
          onTap: () async {
            try {
              await exportImport.exportTactics();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Tactics exported!')),
              );
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Export failed: $e')),
              );
            }
          },
        ),
        ListTile(
          leading: Icon(Icons.download),
          title: Text('Import Tactics'),
          subtitle: Text('Load tactics from file'),
          onTap: () async {
            try {
              final count = await exportImport.importTactics();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Imported $count positions')),
              );
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Import failed: $e')),
              );
            }
          },
        ),
        ListTile(
          leading: Icon(Icons.info),
          title: Text('Storage Info'),
          onTap: () async {
            final stats = await exportImport.getTacticsStats();
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('Storage Info'),
                content: Text(
                  'Positions: ${stats['positions_count']}\n'
                  'Total Reviews: ${stats['total_reviews']}\n'
                  'File Size: ${(stats['file_size_bytes'] / 1024).toStringAsFixed(1)} KB\n'
                  'Path: ${stats['file_path']}'
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('OK'),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
```

---

## 📦 **Required Dependencies**

Already added to `pubspec.yaml`:

```yaml
dependencies:
  path_provider: ^2.1.1      # Get app documents directory
  csv: ^6.0.0               # Parse/write CSV files
  share_plus: ^10.0.0       # Share files on mobile
  file_picker: ^6.1.1       # Pick files for import
```

---

## 🧪 **Testing on Mobile**

### **iOS Testing:**
```bash
flutter run -d iphone  # or your iOS device name
```

**What to check:**
1. Load tactics → Check they persist after app restart
2. Export → Verify share sheet appears
3. Import → Pick a CSV from Files app
4. Uninstall → Reinstall → Verify data is gone (expected)

### **Android Testing:**
```bash
flutter run -d android  # or your Android device name
```

**What to check:**
1. Load tactics → Check they persist
2. Export → Verify Android share sheet
3. Import → Pick from Google Drive or local files
4. Check file location: `adb shell run-as com.yourapp.chess_auto_prep ls app_flutter/`

---

## 🛡️ **Data Safety on Mobile**

### **Backup Strategies:**

1. **Auto Backup (iOS)**
   - Tactics CSV is backed up to iCloud automatically
   - Restores when you set up new device

2. **Auto Backup (Android)**
   - Included in Android Auto Backup
   - Restores if you reinstall app on same Google account

3. **Manual Export** (recommended)
   - Export to cloud storage (Google Drive, iCloud Drive)
   - Send to yourself via email
   - Keep offline backup

### **Data Loss Scenarios:**

❌ **You WILL lose data if:**
- User uninstalls app
- User clears app data (Settings → Apps → Clear Data)
- Device is factory reset without backup

✅ **Data is safe if:**
- App crashes or force closes
- Device restarts
- App is updated
- User switches between WiFi/cellular

---

## 🎯 **Best Practices for Mobile**

1. **Add Export Feature** - Let users backup their progress
2. **Show Storage Stats** - Display file size, position count
3. **Periodic Reminders** - "Export your tactics to backup"
4. **Cloud Sync** (advanced) - Use Firebase or similar
5. **Import on First Launch** - "Do you have a backup to restore?"

---

## 📊 **File Size Expectations**

CSV is very efficient for this use case:

| Positions | Approximate Size | Notes |
|-----------|------------------|-------|
| 100 | ~50 KB | Light user |
| 500 | ~250 KB | Average user |
| 1,000 | ~500 KB | Heavy user |
| 5,000 | ~2.5 MB | Power user |

**Conclusion:** Even heavy users won't notice the storage impact!

---

## 🎬 **Final Answer**

> **"Can I really expect this to work on mobile?"**

**YES!** Here's what happens in practice:

1. User opens app on iPhone
2. Loads 500 tactics from Lichess → Saved to CSV
3. Solves 50 tactics over the week → Stats updated in CSV
4. Closes app, reopens next day → All 500 tactics still there!
5. Uses "Export" → AirDrops CSV to their Mac
6. Mac opens the same CSV in Python version
7. All stats match perfectly! ✅

The only thing you need to add is the **Export/Import UI** I created in `tactics_export_import.dart` so users can:
- Backup their data
- Share with friends
- Transfer between devices
- Use the same file in Python version (on desktop)

---

## 🚀 **Next Steps**

1. Add the export/import buttons to your UI (see example above)
2. Test on iOS simulator or device
3. Test on Android emulator or device
4. Enjoy full cross-platform tactics training!

The core CSV functionality works perfectly on mobile - the export/import features are just quality-of-life improvements for advanced users who want to backup or share their data.
