import 'dart:convert';
import 'dart:io';

/// Everything about Signal's sticker pack format lives here.
///
/// Unlike WhatsApp, Signal offers no way for a third party app to push a sticker pack into the
/// messenger: Android and iOS install nothing but packs that live on Signal's own CDN, opened
/// through a `https://signal.art/addstickers/#pack_id=...&pack_key=...` link. The only native
/// upload tool is built into Signal Desktop, which takes loose images and offers them under
/// *File ▸ Create/upload sticker pack*.
///
/// So an exported pack is aimed at that creator: pictures in the shapes it accepts, in file names
/// that survive a file picker's sort order, together with a text file that explains the upload to
/// whoever unzips it. The `manifest.json` written next to them is for the second, less friendly
/// route - `signal-cli uploadStickerPack` and the websites built on it - and the same file is what
/// this app reads back when a Signal pack is imported.
///
/// The size/dimension limits, and the formats the creator drops in, come from the creator itself:
/// `sticker-creator/src/constants.ts`, `src/util/processImage.ts` and
/// `src/util/useStickerDropzone.ts` in signalapp/Signal-Desktop.

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

/// Name of the plain text instructions written into an exported pack, next to the pictures.
const String signalReadmeName = "ADD-TO-SIGNAL.txt";

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

/// Name of the [index]th image of an exported pack, e.g. `sticker-007.webp`.
///
/// Zero padded on purpose: Signal Desktop's creator keeps the stickers in the order the files are
/// picked, and a picker that sorts `sticker-10` in front of `sticker-2` would shuffle the pack.
String signalStickerFileName(int index, String extension) =>
    "sticker-${index.toString().padLeft(3, "0")}$extension";

/// Where Signal looks for sticker packs, and where its install links point.
const String signalAddStickersUrl = "https://signal.art/addstickers";

/// The link that opens an uploaded pack in Signal, on any of its apps.
String signalInstallLink(String packId, String packKey) =>
    "$signalAddStickersUrl/#pack_id=${packId.toLowerCase()}&pack_key=${packKey.toLowerCase()}";

/// A pack that lives on Signal's CDN: its id and the key that decrypts it, both hex.
class SignalPackRef {
  const SignalPackRef(this.packId, this.packKey);

  final String packId;
  final String packKey;

  String get installLink => signalInstallLink(packId, packKey);

  @override
  bool operator ==(Object other) => other is SignalPackRef && other.installLink == installLink;

  @override
  int get hashCode => installLink.hashCode;
}

final RegExp _signalPackIdPattern = RegExp(r"pack_id=([0-9a-fA-F]+)");
final RegExp _signalPackKeyPattern = RegExp(r"pack_key=([0-9a-fA-F]+)");

/// Reads a share link back into the pack it points at.
///
/// Understands both forms Signal uses - the share link
/// `https://signal.art/addstickers/#pack_id=...&pack_key=...` and the action uri the same screen
/// answers to, `sgnl://addstickers?pack_id=...&pack_key=...` - and returns `null` for anything that
/// doesn't carry a full id and a full key, however the rest of it is written.
SignalPackRef? parseSignalPackRef(String? value) {
  if (value == null) return null;
  final text = value.trim();
  final id = _signalPackIdPattern.firstMatch(text)?.group(1);
  final key = _signalPackKeyPattern.firstMatch(text)?.group(1);
  // A Signal pack id is 16 bytes and its key 32, nothing else is worth calling a link.
  if (id == null || key == null || id.length != 32 || key.length != 64) return null;
  return SignalPackRef(id.toLowerCase(), key.toLowerCase());
}

/// The instructions that go into an exported pack as [signalReadmeName].
///
/// They are written into the zip instead of only being shown on screen because the upload happens
/// on a computer, hours and one file transfer after the export, and the file lands next to the
/// pictures it describes. English only for the same reason - it travels with the pack, not with the
/// app's language.
String signalZipReadme(SignalPackManifest manifest) {
  final buffer = StringBuffer()
    ..writeln("How to add these stickers to Signal")
    ..writeln("===================================")
    ..writeln()
    ..writeln("Signal installs sticker packs from its own servers only, so these pictures have to be")
    ..writeln("uploaded once. Signal Desktop does that without any command line tools:")
    ..writeln()
    ..writeln("1. Get this archive onto the computer that runs Signal Desktop - mail it to yourself,")
    ..writeln("   plug the phone in, whatever you like - and unzip it.")
    ..writeln("2. In Signal Desktop, open File and choose \"Create/upload sticker pack\".")
    ..writeln("3. Drop every picture of this folder into the window, or add them with the plus tiles.")
    ..writeln("   The order they are added in is the order of the pack.")
    ..writeln("4. Give every sticker an emoji, then fill in the title and the author.")
    ..writeln("5. Press Upload. Signal answers with an install link that looks like")
    ..writeln("   $signalAddStickersUrl/#pack_id=...&pack_key=...")
    ..writeln("6. Open that link on your phone, or send it to anybody you like: the pack installs.")
    ..writeln()
    ..writeln("This is \"${manifest.title}\" by ${manifest.author}, in the shape Signal wants:")
    ..writeln("$signalStickerSize x $signalStickerSize pixels, no more than $signalMaxStickers stickers, no more")
    ..writeln("than ${signalMaxStickerBytes ~/ 1024} KB per sticker, animations as animated png that loop forever.")
    ..writeln("Signal checks every one of that again and says out loud when a sticker fails - if that")
    ..writeln("happens, remove the sticker it named and upload the rest.")
    ..writeln()
    ..writeln("Note that the creator asks for the emojis again, it doesn't read them from the")
    ..writeln("manifest. They are these, counted the way the stickers follow each other:")
    ..writeln();

  for (var position = 1; position <= manifest.stickers.length; position++) {
    final sticker = manifest.stickers[position - 1];
    buffer.writeln("  ${position.toString().padLeft(3)}. ${sticker.file}  ${sticker.emoji}");
  }

  buffer
    ..writeln()
    ..writeln("The manifest.json in this folder describes the same pack for tools that upload without")
    ..writeln("Signal Desktop, such as \"signal-cli uploadStickerPack\". You don't need it for the")
    ..writeln("steps above.");

  return buffer.toString();
}

/// Reasons a pack can't be handed to Signal.
enum SignalIssue { empty, tooMany, oversized }

/// Result of checking a pack against the limits Signal enforces on upload.
class SignalCheckResult {
  SignalCheckResult({required this.oversized, required this.total});

  /// Indices of stickers that are larger than [signalMaxStickerBytes].
  final List<int> oversized;

  final int total;

  bool get empty => total == 0;

  bool get tooMany => total > signalMaxStickers;

  bool get ok => !empty && !tooMany && oversized.isEmpty;

  /// All problems found, in the order a user is most likely to care about them.
  List<SignalIssue> get issues => [
        if (empty) SignalIssue.empty,
        if (tooMany) SignalIssue.tooMany,
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
  // An animated sticker is converted to animated png on the way out and the size of its webp says
  // nothing about the size of the result, so animated packs are not checked against it.
  if (animated) return SignalCheckResult(oversized: [], total: files.length);
  final oversized = <int>[];
  for (var i = 0; i < files.length; i++) {
    try {
      if (await File(files[i]).length() > signalMaxStickerBytes) oversized.add(i);
    } on FileSystemException catch (_) {
      // A missing file is not a size problem, let the actual export complain about it.
    }
  }
  return SignalCheckResult(oversized: oversized, total: files.length);
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
