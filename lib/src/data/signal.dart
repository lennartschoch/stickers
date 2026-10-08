import 'dart:convert';
import 'dart:io';

/// Everything about Signal's sticker pack format lives here.
///
/// Unlike WhatsApp, Signal offers no way for a third party app to push a sticker pack into the
/// messenger. Signal only installs packs that live on its own CDN, opened through
/// `https://signal.art/addstickers/#pack_id=...&pack_key=...` links.
///
/// What we *can* do is produce the exact layout Signal's own upload tooling consumes: a
/// `manifest.json` next to the sticker images, zipped up. Feeding that zip to `signal-cli
/// uploadStickerPack` (or any of the "add your pack to Signal" websites) uploads it and gives you
/// an install link back. That zip is also what you receive when somebody sends you a pack.
///
/// The size/dimension limits are taken from the official sticker creator
/// (`sticker-creator/src/constants.ts` in signalapp/Signal-Desktop).

/// Stickers are rendered at 512x512 by Signal.
const int signalStickerSize = 512;

/// Images smaller than this are rejected by Signal.
const int signalMinImageSize = 10;

/// A single sticker image may not exceed this many bytes.
const int signalMaxStickerBytes = 300 * 1024;

/// A Signal pack may contain at most this many stickers.
const int signalMaxStickers = 200;

/// Name of the json file describing a Signal sticker pack.
const String signalManifestName = "manifest.json";

const String signalMimeWebP = "image/webp";
const String signalMimePng = "image/png";
const String signalMimeJpeg = "image/jpeg";
const String signalMimeGif = "image/gif";

/// Thrown when a zip/file doesn't contain a (valid) Signal sticker pack.
class SignalPackFormatException implements Exception {
  final String message;

  const SignalPackFormatException(this.message);

  @override
  String toString() => "SignalPackFormatException: $message";
}

/// One sticker of a Signal pack, as described by `manifest.json`.
class SignalSticker {
  SignalSticker({required this.id, required this.file, this.emoji = "", this.contentType});

  final int id;

  /// Image file name relative to the directory containing the manifest, e.g. `sticker-0.webp`.
  final String file;

  /// Emojis Signal suggests this sticker for. Empty if the pack doesn't specify any.
  final String emoji;

  /// Mime type of [file]. `null` lets the consumer sniff it out of the file itself.
  final String? contentType;

  Map<String, dynamic> toJson() => {
        "id": id,
        "emoji": emoji,
        "file": file,
        if (contentType != null) "contentType": contentType,
      };

  static SignalSticker fromJson(Map<String, dynamic> json, {int fallbackId = 0}) {
    final file = json["file"] ?? json["image-file"] ?? json["image"];
    if (file is! String || file.isEmpty) throw const SignalPackFormatException("Sticker without a file name");
    final emoji = json["emoji"] ?? json["name"];
    final emojis = json["emojis"];
    return SignalSticker(
      id: json["id"] is int ? json["id"] as int : fallbackId,
      file: file,
      emoji: emoji is String ? emoji : (emojis is List ? emojis.whereType<String>().join() : ""),
      contentType: json["contentType"] is String ? json["contentType"] as String : null,
    );
  }
}

/// The contents of a Signal pack's `manifest.json`.
class SignalPackManifest {
  SignalPackManifest({required this.title, required this.author, List<SignalSticker>? stickers, this.coverId})
      : stickers = stickers ?? [];

  String title;
  String author;
  List<SignalSticker> stickers;

  /// Sticker used as the pack icon. Defaults to the first sticker when `null`.
  int? coverId;

  SignalSticker? get cover {
    final id = coverId ?? stickers.firstOrNull?.id;
    if (id == null) return null;
    return stickers.where((sticker) => sticker.id == id).firstOrNull;
  }

  /// Serialises to the manifest read by Signal's upload tooling (`signal-cli` and friends).
  Map<String, dynamic> toJson() {
    final coverSticker = cover;
    return {
      "title": title,
      "author": author,
      if (coverSticker != null) "cover": coverSticker.toJson(),
      "stickers": stickers.map((sticker) => sticker.toJson()).toList(),
    };
  }
}

/// Parses a Signal `manifest.json`.
///
/// Two shapes are understood:
/// * the one used by Signal's own tooling - `{"title": ..., "author": ..., "stickers": [...]}`
/// * the older community one - `{"sticker-pack-name": ..., "sticker-pack-publisher": ..., ...}`
///   where every sticker lives in its own `sticker-N.json` (passed in through [stickerJson]).
SignalPackManifest parseSignalManifest(
  Map<String, dynamic> json, {
  Map<String, Map<String, dynamic>> stickerJson = const {},
}) {
  final title = json["title"] ?? json["sticker-pack-name"];
  final author = json["author"] ?? json["sticker-pack-publisher"];
  final raw = json["stickers"];

  final stickers = <SignalSticker>[];
  if (raw is List) {
    var id = 0;
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        stickers.add(SignalSticker.fromJson(entry, fallbackId: id));
        id++;
      } on SignalPackFormatException catch (_) {
        // Skip stickers we can't make sense of instead of failing the whole pack.
      }
    }
  }

  // Old format: the manifest only carries the pack metadata, each sticker has its own json file.
  if (stickers.isEmpty && stickerJson.isNotEmpty) {
    final names = stickerJson.keys.toList()..sort(_naturalSort);
    var id = 0;
    for (final name in names) {
      final entry = stickerJson[name]!;
      try {
        stickers.add(SignalSticker.fromJson(entry, fallbackId: id));
        id++;
      } on SignalPackFormatException catch (_) {
        // As above, ignore unusable stickers.
      }
    }
  }

  final rawCover = json["cover"];
  int? coverId;
  if (rawCover is Map<String, dynamic>) {
    final coverSticker = rawCover["file"];
    if (rawCover["id"] is int) {
      coverId = rawCover["id"] as int;
    } else if (coverSticker is String) {
      coverId = stickers.where((sticker) => sticker.file == coverSticker).firstOrNull?.id;
    }
  }

  return SignalPackManifest(
    title: title is String ? title : "",
    author: author is String ? author : "",
    stickers: stickers,
    coverId: coverId,
  );
}

/// Reads a Signal pack from a directory containing `manifest.json`.
///
/// Zips created by other tools sometimes wrap everything in a single top level folder, so the
/// manifest is looked up recursively (up to [maxDepth] levels).
Future<SignalPackManifest> readSignalPack(Directory dir, {int maxDepth = 2}) async {
  final manifestFile = await findSignalManifest(dir, maxDepth: maxDepth);
  if (manifestFile == null) {
    throw const SignalPackFormatException("$signalManifestName not found");
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(await manifestFile.readAsString());
  } on FormatException catch (e) {
    throw SignalPackFormatException("$signalManifestName is not valid json: ${e.message}");
  }
  if (decoded is! Map<String, dynamic>) throw const SignalPackFormatException("$signalManifestName is not an object");

  final packDir = manifestFile.parent;
  // For the old format every sticker ships as its own little json next to the manifest.
  final stickerJson = <String, Map<String, dynamic>>{};
  if (decoded["stickers"] is! List) {
    for (final entry in packDir.listSync()) {
      if (entry is! File) continue;
      final name = _nameOf(entry);
      if (entry.path == manifestFile.path || !name.toLowerCase().endsWith(".json")) continue;
      try {
        final content = jsonDecode(await entry.readAsString());
        if (content is Map<String, dynamic>) stickerJson[name] = content;
      } on FormatException catch (_) {
        // Not a sticker definition we could ever use.
      }
    }
  }

  final manifest = parseSignalManifest(decoded, stickerJson: stickerJson);

  if (manifest.stickers.isEmpty) {
    // Last resort: some packs ship nothing but images, take them in a sensible order.
    final images = packDir
        .listSync()
        .whereType<File>()
        .where((file) => sniffImageContentTypeHeaderSync(file) != null)
        .toList()
      ..sort((a, b) => _naturalSort(_nameOf(a), _nameOf(b)));
    var id = 0;
    manifest.stickers.addAll(images.map((file) => SignalSticker(id: id++, file: _nameOf(file))));
  }

  if (manifest.stickers.isEmpty) throw const SignalPackFormatException("Pack contains no stickers");
  return manifest;
}

/// Looks for a Signal manifest inside [dir], descending into subfolders if necessary.
///
/// `manifest.json` is the name used by Signal's tooling, the older format names its metadata file
/// after nothing in particular, so any json that describes a pack is taken as well.
Future<File?> findSignalManifest(Directory dir, {int maxDepth = 2}) async {
  final direct = File(_join(dir.path, signalManifestName));
  if (await direct.exists()) return direct;

  final List<FileSystemEntity> entries;
  try {
    entries = await dir.list().toList();
  } on FileSystemException catch (_) {
    return null; // Doesn't exist or isn't readable, so it holds no manifest either.
  }

  for (final entry in entries) {
    if (entry is! File) continue;
    if (entry.path.toLowerCase().endsWith(".json") && await _describesSignalPack(entry)) return entry;
  }
  if (maxDepth <= 1) return null;

  for (final entry in entries) {
    if (entry is! Directory) continue;
    final found = await findSignalManifest(entry, maxDepth: maxDepth - 1);
    if (found != null) return found;
  }
  return null;
}

/// Whether the json file in [file] describes a sticker pack (and not, say, this app's own format).
Future<bool> _describesSignalPack(File file) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on FormatException catch (_) {
    return false;
  }
  if (decoded is! Map<String, dynamic>) return false;
  if (decoded.containsKey("sticker-pack-id") || decoded.containsKey("sticker-pack-name")) return true;

  // `stickers: [{"file": ...}]`. This app's own manifest names that field "image" and is skipped.
  final stickers = decoded["stickers"];
  return stickers is List &&
      stickers.isNotEmpty &&
      stickers.every((entry) => entry is Map<String, dynamic> && (entry["file"] ?? entry["image-file"]) is String);
}

/// Writes [manifest] as `manifest.json` into [dir] and returns the written file.
Future<File> writeSignalManifest(Directory dir, SignalPackManifest manifest) async {
  await dir.create(recursive: true);
  final file = File(_join(dir.path, signalManifestName));
  await file.writeAsString(jsonEncode(manifest.toJson()));
  return file;
}

/// Reasons a pack can't be handed to Signal.
enum SignalIssue { empty, tooMany, animated, oversized }

/// Result of checking a pack against the limits Signal enforces on upload.
class SignalCheckResult {
  SignalCheckResult({required this.animated, required this.oversized, required this.total});

  /// Signal only understands animated APNG, animated webp (what this app produces) is unsupported.
  final bool animated;

  /// Indices of stickers that are larger than [signalMaxStickerBytes].
  final List<int> oversized;

  final int total;

  bool get empty => total == 0;

  bool get tooMany => total > signalMaxStickers;

  bool get ok => !empty && !tooMany && !animated && oversized.isEmpty;

  /// All problems found, in the order a user is most likely to care about them.
  List<SignalIssue> get issues => [
        if (empty) SignalIssue.empty,
        if (tooMany) SignalIssue.tooMany,
        if (animated) SignalIssue.animated,
        if (oversized.isNotEmpty) SignalIssue.oversized,
      ];
}

/// Thrown when a pack doesn't satisfy [checkSignalLimits], so the UI can explain why.
class SignalExportException implements Exception {
  final SignalCheckResult check;

  const SignalExportException(this.check);

  List<SignalIssue> get issues => check.issues;

  @override
  String toString() => "SignalExportException: ${check.issues.join(", ")}";
}

/// Checks [files] against [signalMaxStickers] and [signalMaxStickerBytes].
Future<SignalCheckResult> checkSignalLimits({required bool animated, required List<String> files}) async {
  final oversized = <int>[];
  for (var i = 0; i < files.length; i++) {
    try {
      if (await File(files[i]).length() > signalMaxStickerBytes) oversized.add(i);
    } on FileSystemException catch (_) {
      // A missing file is not a size problem, let the actual export complain about it.
    }
  }
  return SignalCheckResult(animated: animated, oversized: oversized, total: files.length);
}

/// Detects an animated webp by looking at the flags of its `VP8X` chunk.
bool isAnimatedWebP(List<int> bytes) {
  if (bytes.length < 21) return false;
  if (!_matchAscii(bytes, 0, "RIFF") || !_matchAscii(bytes, 8, "WEBP")) return false;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final size = _readUint32LE(bytes, offset + 4);
    if (_matchAscii(bytes, offset, "VP8X")) {
      // Bit 1 of the VP8X flags is the animation flag.
      return bytes[offset + 8] & 0x02 != 0;
    }
    if (size > bytes.length) return false;
    offset += 8 + size + (size & 1); // Chunks are padded to an even size.
  }
  return false;
}

/// Returns the mime type of the image [bytes], or `null` if it isn't an image we recognise.
/// Only the header is looked at, passing the first bytes of a file is enough.
String? sniffImageContentType(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] == 0x89 && _matchAscii(bytes, 1, "PNG")) return signalMimePng;
  if (_matchAscii(bytes, 0, "RIFF") && _matchAscii(bytes, 8, "WEBP")) return signalMimeWebP;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return signalMimeJpeg;
  if (_matchAscii(bytes, 0, "GIF8")) return signalMimeGif;
  return null;
}

/// [sniffImageContentType] for the first bytes of a file, without loading the whole thing.
String? sniffImageContentTypeHeaderSync(File file) {
  RandomAccessFile? raf;
  try {
    raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(16);
    return sniffImageContentType(header);
  } on FileSystemException catch (_) {
    return null;
  } finally {
    raf?.closeSync();
  }
}

bool _matchAscii(List<int> bytes, int offset, String ascii) {
  if (offset + ascii.length > bytes.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

int _readUint32LE(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);

/// Sorts so that `sticker-2` comes before `sticker-10`.
int _naturalSort(String a, String b) {
  final ta = _numberIn(a), tb = _numberIn(b);
  if (ta != tb) return ta.compareTo(tb);
  return a.compareTo(b);
}

int _numberIn(String value) {
  final match = RegExp(r"(\d+)").allMatches(value).lastOrNull;
  return match == null ? -1 : int.tryParse(match.group(1)!) ?? -1;
}

String _nameOf(File file) => file.uri.pathSegments.last;

String _join(String dir, String file) => dir.endsWith("/") ? "$dir$file" : "$dir/$file";
