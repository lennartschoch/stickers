import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:image_editor/image_editor.dart';
import 'package:share_plus/share_plus.dart';
import 'package:stickers/src/constants.dart';
import 'package:stickers/src/data/signal.dart';
import 'package:stickers/src/data/sticker.dart';
import 'package:stickers/src/data/sticker_pack.dart';
import 'package:stickers/src/globals.dart';

String _sanitizeFileName(String value) => value.replaceAll(RegExp("[^ \\-_!&a-zA-Z0-9]"), "_");

String _joinPath(String dir, String file) => dir.endsWith("/") ? "$dir$file" : "$dir/$file";

String _extensionForContentType(String contentType) {
  switch (contentType) {
    case signalMimePng:
      return ".png";
    case signalMimeJpeg:
      return ".jpg";
    case signalMimeGif:
      return ".gif";
    default:
      return ".webp";
  }
}

void savePacks(List<StickerPack> packs) async {
  File output = File("$packsDir/packs.json");
  output.writeAsString(jsonEncode(packs.map((pack) => pack.toJson()).toList()));
}

Future<void> exportPack(StickerPack pack) async {
  Stopwatch sw = Stopwatch()..start();
  Directory exportDir = Directory(exportCacheDir);
  Directory packDir = Directory("${exportDir.path}/pack_${DateTime.timestamp().millisecondsSinceEpoch}/");
  await packDir.create(recursive: true);
  File jsonFile = File("${packDir.path}/pack.json");
  Map<String, dynamic> exportData = pack.toJson();
  //TODO Don't hardcode extensions
  for (var i = 0; i < pack.stickers.length; i++) {
    await File(pack.stickers[i].source).copy("${packDir.path}$i.webp");
    exportData["stickers"][i]["source"] = "$i.webp";
  }
  if (pack.trayIcon != null) {
    await File(pack.trayIcon!).copy("${packDir.path}tray.png");
    exportData["trayIcon"] = "tray.png";
  }
  debugPrint("Copy t=${sw.elapsedMilliseconds}ms");
  await jsonFile.writeAsString(jsonEncode(exportData));
  debugPrint("Json written  t=${sw.elapsedMilliseconds}ms");

  File zipFile = File("${exportDir.path}/${_sanitizeFileName(pack.title)}.zip");
  await ZipFile.createFromDirectory(sourceDir: packDir, zipFile: zipFile);

  debugPrint("Exported to: ${zipFile.path} t=${sw.elapsedMilliseconds}ms");
  SharePlus.instance.share(ShareParams(files: [XFile(zipFile.path)]));
}

/// Exports [pack] in Signal's sticker pack format (a zip holding `manifest.json` and the images)
/// and shares it. Signal can't install packs itself, the zip is meant to be handed to a tool that
/// uploads it to Signal's CDN and gives back an "Add to Signal" link (signal-cli, ...).
///
/// Throws [SignalExportException] listing the reasons when Signal wouldn't take the pack.
Future<File> exportPackAsSignal(StickerPack pack) async {
  final check = await checkSignalLimits(
    animated: pack.animated,
    files: pack.stickers.map((sticker) => sticker.source).toList(),
  );
  if (!check.ok) throw SignalExportException(check);

  Directory exportDir = Directory(exportCacheDir);
  Directory packDir = Directory("${exportDir.path}/signal_${DateTime.timestamp().millisecondsSinceEpoch}/");
  await packDir.create(recursive: true);

  final signalPack = SignalPackManifest(title: pack.title, author: pack.author);
  for (var i = 0; i < pack.stickers.length; i++) {
    final source = File(pack.stickers[i].source);
    final contentType = sniffImageContentTypeHeaderSync(source) ?? signalMimeWebP;
    final name = "sticker-$i${_extensionForContentType(contentType)}";
    await source.copy(_joinPath(packDir.path, name));
    signalPack.stickers.add(
      SignalSticker(id: i, file: name, emoji: pack.stickers[i].emojis.join(), contentType: contentType),
    );
  }

  // Signal has no separate tray image, one of the stickers is used as the pack icon instead.
  await writeSignalManifest(packDir, signalPack);

  File zipFile = File("${exportDir.path}/${_sanitizeFileName(pack.title)}_signal.zip");
  await ZipFile.createFromDirectory(sourceDir: packDir, zipFile: zipFile);

  debugPrint("Exported for Signal to: ${zipFile.path}");
  SharePlus.instance.share(ShareParams(files: [XFile(zipFile.path)]));
  return zipFile;
}

/// Turns a parsed Signal pack into one of this app's packs.
/// The images are referenced by absolute path, [importPack] copies them to their permanent home.
StickerPack _fromSignalPack(SignalPackManifest signal, String dir) {
  return StickerPack(
    signal.title,
    signal.author,
    "pack_${DateTime.timestamp().millisecondsSinceEpoch}",
    signal.stickers
        .map((sticker) => Sticker(_joinPath(dir, sticker.file), _emojisOf(sticker.emoji)))
        .toList(),
    "1000",
    false, // Animated Signal stickers are APNG, this app stores animations as animated webp.
    trayIcon: signal.cover == null ? null : _joinPath(dir, signal.cover!.file),
  );
}

/// Signal keeps the emojis a sticker answers to in one string, this app uses a list of graphemes.
List<String> _emojisOf(String emojis) => emojis.isEmpty ? ["\u2764"] : emojis.characters.toList();

Future<void> importPack(File f) async {
  //TODO show progress
  Stopwatch sw = Stopwatch()..start();
  Directory importDir = Directory(mediaCacheDir);
  Directory unzipDir = Directory("${importDir.path}pack_${DateTime.timestamp().millisecondsSinceEpoch}/");
  await unzipDir.create(recursive: true);
  await ZipFile.extractToDirectory(zipFile: f, destinationDir: unzipDir);
  debugPrint("Unzip t=${sw.elapsedMilliseconds}ms");

  List<StickerPack> packsToAdd = [];

  // Signal packs are plain zips, they are recognised by their manifest instead of by file extension.
  final signalManifest = await findSignalManifest(unzipDir);
  switch (signalManifest != null ? "signal" : f.path.split(".").last.toLowerCase()) {
    case "signal":
      final signalPack = await readSignalPack(signalManifest!.parent);
      packsToAdd.add(_fromSignalPack(signalPack, signalManifest.parent.path));
      break;
    case "wastickers":
      final dirContents = unzipDir.listSync();
      final pack = StickerPack(
          (await File("${unzipDir.path}title.txt").readAsString()).replaceAll("\n", ""),
          (await File("${unzipDir.path}author.txt").readAsString()).replaceAll("\n", ""),
          "pack_${DateTime.timestamp().millisecondsSinceEpoch}",
          dirContents
              .map((entry) => entry.path)
              .where((path) => path.toLowerCase().endsWith(".webp"))
              .map((path) => Sticker(path, ["❤"]))
              .toList(),
          "1000",
          false, // It's not possible to directly export animated packs from that app.
          trayIcon: dirContents.where((entry) => entry.path.toLowerCase().endsWith(".png")).firstOrNull?.path);
      packsToAdd.add(pack);
      break;
    case "stickify":
      final dirs = unzipDir.listSync().whereType<Directory>();
      for (final dir in dirs) {
        final json = jsonDecode(File("${dir.path}/contents.json").readAsStringSync());
        for (final packJson in json["sticker_packs"]) {
          final pack = StickerPack(
            packJson["name"],
            packJson["publisher"],
            packJson["identifier"],
            (packJson["stickers"] as List)
                .map((sticker) => Sticker(
                      "${dir.path}/${sticker["image_file"]}",
                      (sticker["emojis"] as List).isEmpty ? ["❤"] : sticker["emojis"],
                    ))
                .toList(),
            packJson["image_data_version"],
            packJson["animated_sticker_pack"],
            publisherWebsite: packJson["publisher_website"],
            licenseAgreementWebsite: packJson["license_agreement_website"],
            privacyPolicyWebsite: packJson["privacy_policy_website"],
          );
          packsToAdd.add(pack);
        }
      }
      break;
    default:
      //TODO support stickify's backup file format
      File jsonFile = File("${unzipDir.path}pack.json");
      final pack = StickerPack.fromJson(jsonDecode(await jsonFile.readAsString()));
      for (var sticker in pack.stickers) {
        sticker.source = unzipDir.path + sticker.source;
      }
      if (pack.trayIcon != null) {
        pack.trayIcon = unzipDir.path + pack.trayIcon!;
      }
      packsToAdd.add(pack);
  }
  debugPrint("Parse t=${sw.elapsedMilliseconds}ms");

  for (final pack in packsToAdd) {
    while (packs.where((p) => p.id == pack.id).isNotEmpty) {
      pack.id = "${pack.id}_";
    }
    await Directory("$packsDir/${pack.id}").create(recursive: true);

    for (var i = 0; i < pack.stickers.length; i++) {
      await File(pack.stickers[i].source).copy("$packsDir/${pack.id}/imported_$i.webp");
      pack.stickers[i].source = File("$packsDir/${pack.id}/imported_$i.webp").path;
    }
    if (pack.trayIcon != null) {
      await File("${pack.trayIcon}").copy("$packsDir/${pack.id}/imported_tray.webp");
      pack.trayIcon = File("$packsDir/${pack.id}/imported_tray.webp").path;
    }
    debugPrint("[${pack.id}] Copy t=${sw.elapsedMilliseconds}ms");
    packs.add(pack);
  }

  // Clean up - even if the same files are imported again, they are copied again so there's no point in caching them
  // There is no await here since we don't need to wait
  // until the deletion of the temporary folder is complete to move on
  unzipDir.delete(recursive: true);
  f.parent.delete(recursive: true);

  savePacks(packs);
}

Future<List<StickerPack>> getPacks() async {
  File input = File("$packsDir/packs.json");
  if (await input.exists()) {
    return (jsonDecode(await input.readAsString()) as List).map((json) => StickerPack.fromJson(json)).toList();
  }
  return List.empty(growable: true);
}

Future<Uint8List> cropSticker(
    Rect cropRect, Uint8List rawImageData, StickerPack pack, int index, double rotation) async {
  // Apply crop then scale then put on 512x512 transparent image in center

  final crop = ImageEditorOption();
  Size oldSize = cropRect.size;
  crop.addOption(RotateOption(rotation.toInt()));
  crop.addOption(ClipOption.fromRect(cropRect));
  Size newSize;
  // Make the longest border exactly 512 pixels wide, preserving aspect ratio
  if (oldSize.height > oldSize.width) {
    newSize = Size(oldSize.width * 512 / oldSize.height, 512);
  } else {
    newSize = Size(512, oldSize.height * 512 / oldSize.width);
  }
  crop.addOption(
    ScaleOption(
      newSize.width.toInt(),
      newSize.height.toInt(),
    ),
  );
  crop.outputFormat = const OutputFormat.png(); // Ensure the format supports transparency
  final intermediate = (await ImageEditor.editImage(image: rawImageData, imageEditorOption: crop))!;

  final option = ImageMergeOption(
    canvasSize: const Size.square(512),
    format: const OutputFormat.webp_lossy(50),
  );

  option.addImage(
    MergeImageConfig(
      image: MemoryImageSource(intermediate),
      position: ImagePosition(
        Offset((512 - newSize.width) / 2, (512 - newSize.height) / 2),
        newSize,
      ),
    ),
  );
  return (await ImageMerger.mergeToMemory(option: option))!;
}

/// Adds a sticker to a sticker pack
/// Copies the file to the required place
///
/// If [index] is 30 it changes the tray icon.
void addToPack(StickerPack pack, int index, Uint8List data) {
  Directory("$packsDir/${pack.id}").createSync(recursive: true);
  File output;
  if (index == 30) {
    output = File("$packsDir/${pack.id}/tray_${DateTime.now().millisecondsSinceEpoch}.webp");
    output.writeAsBytesSync(data);
    pack.trayIcon = output.path;
  } else {
    output = File("$packsDir/${pack.id}/sticker_${index}_${DateTime.now().millisecondsSinceEpoch}.webp");
    output.writeAsBytesSync(data);
    pack.stickers.add(Sticker(output.path, ["❤"]));
  }
  pack.onEdit();
  savePacks(packs);
  // Clear media cache after importing a sticker
  print("Clearing media cache");
  Directory(mediaCacheDir).list().listen((entry) => entry.delete());
}

Future<File> saveTemp(Uint8List data) async {
  File output = File("$mediaCacheDir/${DateTime.now().millisecondsSinceEpoch}.tmp.webp");
  await output.writeAsBytes(data);
  return output;
}
