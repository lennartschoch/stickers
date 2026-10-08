import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stickers/src/data/signal.dart';

/// Minimal 1x1 png, only used to make the file sniffing and "is it an image" checks work.
final List<int> pngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, //
  0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

List<int> webpBytes({bool animated = false, List<List<int>> extraChunks = const []}) {
  final chunks = <List<int>>[
    // VP8X: flags, reserved, canvas-1 (24 bit x2)
    [animated ? 0x02 : 0x04, 0, 0, 0, 0xFF, 0x01, 0, 0xFF, 0x01, 0],
    ...extraChunks,
  ];
  final body = <int>[];
  for (final chunk in chunks) {
    body.addAll(utf8.encode(chunk == chunks.first ? "VP8X" : "XXXX"));
    body.addAll([chunk.length & 0xFF, (chunk.length >> 8) & 0xFF, 0, 0]);
    body.addAll(chunk);
  }
  final size = 4 + body.length;
  return [
    ...utf8.encode("RIFF"), //
    size & 0xFF, (size >> 8) & 0xFF, 0, 0,
    ...utf8.encode("WEBP"),
    ...body,
  ];
}

void main() {
  group("content type sniffing", () {
    test("recognises png, webp and jpeg", () {
      expect(sniffImageContentType(pngBytes), signalMimePng);
      expect(sniffImageContentType(webpBytes()), signalMimeWebP);
      expect(sniffImageContentType([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(20, 0)]), signalMimeJpeg);
      expect(sniffImageContentType([...utf8.encode("GIF89a"), ...List.filled(20, 0)]), signalMimeGif);
      expect(sniffImageContentType(utf8.encode("GIF87a")), signalMimeGif); // Only the header is needed.
    });

    test("returns null for anything that isn't an image", () {
      expect(sniffImageContentType(utf8.encode(jsonEncode({"a": 1}))), isNull);
      expect(sniffImageContentType([1, 2, 3]), isNull);
    });

    test("detects animated webp by the VP8X animation flag", () {
      expect(isAnimatedWebP(webpBytes(animated: true)), isTrue);
      expect(isAnimatedWebP(webpBytes()), isFalse);
      expect(isAnimatedWebP(pngBytes), isFalse);
    });
  });

  group("manifest parsing", () {
    test("reads the format used by Signal's own tooling", () {
      final manifest = parseSignalManifest({
        "title": "Cool pack",
        "author": "Nobody",
        "cover": {"id": 1, "emoji": "😁", "file": "sticker-1.webp"},
        "stickers": [
          {"id": 0, "emoji": "😀", "file": "sticker-0.webp", "contentType": "image/webp"},
          {"id": 1, "emoji": "😁", "file": "sticker-1.webp", "contentType": "image/webp"},
        ],
      });

      expect(manifest.title, "Cool pack");
      expect(manifest.author, "Nobody");
      expect(manifest.stickers.map((s) => s.file), ["sticker-0.webp", "sticker-1.webp"]);
      expect(manifest.stickers[1].emoji, "😁");
      expect(manifest.cover?.id, 1);
    });

    test("falls back to the first sticker as a cover", () {
      final manifest = parseSignalManifest({
        "title": "a",
        "author": "b",
        "stickers": [
          {"emoji": "😀", "file": "sticker-0.webp"},
          {"emoji": "😁", "file": "sticker-1.webp"},
        ],
      });

      expect(manifest.cover?.id, 0);
      // Missing ids are filled in by position so that json round trips stay meaningful.
      expect(manifest.stickers.map((s) => s.id), [0, 1]);
    });

    test("reads the old community format with one json per sticker", () {
      final manifest = parseSignalManifest({
        "sticker-pack-id": "c09dcfbd-b361-4832-9d18-af4d18211b83",
        "sticker-pack-name": "Old times",
        "sticker-pack-publisher": "Ancient",
        "emojis": ["x"],
      }, stickerJson: {
        "sticker-2.json": {"id": 2, "name": "😂", "image-file": "sticker-2.webp", "type": "STATIC"},
        "sticker-10.json": {"id": 10, "name": "🙃", "image-file": "sticker-10.webp", "type": "STATIC"},
        "sticker-1.json": {"id": 1, "name": "😀", "image-file": "sticker-1.webp", "type": "STATIC"},
      });

      expect(manifest.title, "Old times");
      expect(manifest.author, "Ancient");
      // sticker-2 before sticker-10, that's what natural sorting is for.
      expect(manifest.stickers.map((s) => s.file),
          ["sticker-1.webp", "sticker-2.webp", "sticker-10.webp"]);
      expect(manifest.stickers.map((s) => s.emoji), ["😀", "😂", "🙃"]);
    });

    test("skips unusable sticker entries instead of failing the pack", () {
      final manifest = parseSignalManifest({
        "title": "a",
        "author": "b",
        "stickers": [
          {"emoji": "😀", "file": "sticker-0.webp"},
          {"emoji": "😁"},
        ],
      });
      expect(manifest.stickers.length, 1);
    });

    test("serialises back to a manifest Signal accepts", () {
      final manifest = SignalPackManifest(
        title: "Round",
        author: "Trip",
        stickers: [SignalSticker(id: 0, file: "sticker-0.webp", emoji: "😀", contentType: signalMimeWebP)],
      );

      final json = manifest.toJson();
      expect(json["title"], "Round");
      expect(json["author"], "Trip");
      expect(json["cover"], json["stickers"].first);
      expect(parseSignalManifest(json).stickers.single.emoji, "😀");
    });
  });

  group("reading packs from disk", () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp("signal_pack"));
    tearDown(() => dir.delete(recursive: true));

    test("reads a manifest wrapped in a single folder, like most zips are", () async {
      final inner = Directory("${dir.path}/pack")..createSync();
      File(_join(inner.path, "manifest.json")).writeAsStringSync(jsonEncode({
        "title": "Nested",
        "author": "Me",
        "stickers": [
          {"id": 0, "emoji": "😀", "file": "sticker-0.webp"}
        ],
      }));

      final manifest = await readSignalPack(dir);
      expect(manifest.title, "Nested");
      expect(manifest.stickers.single.file, "sticker-0.webp");
    });

    test("falls back to loose images when the manifest lists none", () async {
      File(_join(dir.path, "manifest.json")).writeAsStringSync(jsonEncode({"title": "Loose", "author": "Me"}));
      for (final name in ["sticker-2.webp", "sticker-10.webp", "sticker-1.webp"]) {
        File(_join(dir.path, name)).writeAsBytesSync(pngBytes);
      }
      File(_join(dir.path, "not-an-image.txt")).writeAsStringSync("nope");

      final manifest = await readSignalPack(dir);
      expect(manifest.stickers.map((s) => s.file), ["sticker-1.webp", "sticker-2.webp", "sticker-10.webp"]);
    });

    test("throws when there is nothing to import", () async {
      File(_join(dir.path, "readme.txt")).writeAsStringSync("hello");
      expect(() => readSignalPack(dir), throwsA(isA<SignalPackFormatException>()));
    });

    test("writes a manifest that can be read back", () async {
      final manifest = SignalPackManifest(
        title: "Written",
        author: "Stickers",
        stickers: [SignalSticker(id: 0, file: "sticker-0.webp", emoji: "😀", contentType: signalMimeWebP)],
      );
      final file = await writeSignalManifest(dir, manifest);

      expect(await file.exists(), isTrue);
      expect(
        jsonDecode(await file.readAsString()),
        {"title": "Written", "author": "Stickers", "cover": anything, "stickers": anything},
      );

      final read = await readSignalPack(dir);
      expect(read.title, "Written");
      expect(read.cover?.emoji, "😀");
    });
  });

  group("finding manifests", () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp("find"));
    tearDown(() async => dir.delete(recursive: true));

    test("manifest.json is found, also one folder down", () async {
      await File("${dir.path}/manifest.json").writeAsString("{}");
      expect(await findSignalManifest(dir), isNotNull);

      final nested = await Directory("${dir.path}/pack/").create();
      await File("${nested.path}/manifest.json").writeAsString("{}");
      expect(await findSignalManifest(Directory("${dir.path}/nothing/"), maxDepth: 1), isNull);
    });

    test("the older format may name its manifest differently", () async {
      await File("${dir.path}/sticker-pack.json")
          .writeAsString(jsonEncode({"sticker-pack-id": "x", "sticker-pack-name": "Old"}));
      await File("${dir.path}/sticker-0.png").writeAsBytes(pngBytes);
      final found = await findSignalManifest(dir);
      expect(found, isNotNull);
      final pack = await readSignalPack(found!.parent);
      expect(pack.title, "Old");
      expect(pack.stickers.map((sticker) => sticker.file), ["sticker-0.png"]);
    });

    test("this app's own pack.json isn't a Signal pack", () async {
      await File("${dir.path}/pack.json")
          .writeAsString(jsonEncode({"title": "t", "stickers": [{"image": "1.png", "emojis": []}]}));
      expect(await findSignalManifest(dir), isNull);
    });
  });

  group("limit checks", () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp("signal_limits"));
    tearDown(() => dir.delete(recursive: true));

    Future<List<String>> filesOfSizes(List<int> sizes) async {
      final paths = <String>[];
      for (var i = 0; i < sizes.length; i++) {
        final file = File(_join(dir.path, "sticker-$i.webp"));
        file.writeAsBytesSync(List.filled(sizes[i], 1));
        paths.add(file.path);
      }
      return paths;
    }

    test("a normal pack passes", () async {
      final result = await checkSignalLimits(animated: false, files: await filesOfSizes([1024, 2048, 512]));
      expect(result.ok, isTrue);
      expect(result.issues, isEmpty);
    });

    test("oversized stickers are reported by index", () async {
      final result = await checkSignalLimits(
          animated: false, files: await filesOfSizes([1024, signalMaxStickerBytes + 1, signalMaxStickerBytes]));
      expect(result.ok, isFalse);
      expect(result.oversized, [1]);
    });

    test("animated packs and empty packs are rejected", () async {
      expect((await checkSignalLimits(animated: true, files: await filesOfSizes([1024]))).animated, isTrue);
      final empty = await checkSignalLimits(animated: false, files: []);
      expect(empty.empty, isTrue);
      expect(empty.ok, isFalse);
    });

    test("packs larger than Signal allows are reported", () async {
      final result = await checkSignalLimits(animated: false, files: List.filled(signalMaxStickers + 1, "missing"));
      expect(result.tooMany, isTrue);
      expect(result.ok, isFalse);
    });
  });
}

String _join(String dir, String file) => dir.endsWith("/") ? "$dir$file" : "$dir/$file";
