import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:stickers/src/data/apng.dart';
import 'package:stickers/src/data/signal.dart';

/// A frame of flat, opaque, moving colour - as close to sticker art as a test gets.
img.Image _frame(int i, int width, int height, int duration) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(20 + 7 * i, 60, 120, 255));
  img.fillRect(
      image, x1: (i * 7) % width, y1: 0, x2: width - 1, y2: height - 1, color: img.ColorRgba8(250, 200, 40, 255));
  image.frameDuration = duration;
  return image;
}

img.Image _animation(List<int> durations, {int width = 120, int height = 90}) {
  final frames = [for (var i = 0; i < durations.length; i++) _frame(i, width, height, durations[i])];
  final animation = frames.first;
  for (final frame in frames.skip(1)) {
    animation.addFrame(frame);
  }
  animation.frameType = img.FrameType.animation;
  animation.loopCount = 0;
  return animation;
}

/// Animations are made as png - package:image's own webp encoder turns 10 frames into 19 on the way
/// out, which makes assertions about the source about as useful as assertions about the result.
Uint8List _animationAs(String format, int frames, {int width = 120, int height = 90, int duration = 100}) {
  final animation = _animation(List.filled(frames, duration), width: width, height: height);
  return format == "webp" ? img.encodeWebP(animation) : img.encodePng(animation);
}

bool _hasChunk(Uint8List bytes, String name) {
  for (var i = 8; i + name.length + 4 <= bytes.length; i++) {
    // A chunk is its length, then its four type characters.
    if (String.fromCharCodes(bytes.sublist(i, i + name.length)) == name) return true;
  }
  return false;
}

int _totalDuration(img.Image animation) =>
    animation.frames.fold<int>(0, (sum, frame) => sum + frame.frameDuration);

void main() {
  group("encodeAnimatedPng", () {
    test("turns an animated webp into a looping, square animated png", () {
      final png = encodeAnimatedPng(_animationAs("webp", 10), maxSize: 96);

      expect(_hasChunk(png, "acTL"), isTrue);
      expect(sniffImageContentType(png), signalMimePng);
      expect(isAnimatedWebP(png), isFalse, reason: "it is a png now");

      final result = img.decodeImage(png)!;
      expect(result.width, 96);
      expect(result.height, 96);
      expect(result.loopCount, 0, reason: "Signal stickers loop");
      expect(result.frames.length, greaterThan(1));
    });

    test("caps the frame rate but keeps how long the animation runs", () {
      final source = _animationAs("png", 30, duration: 40); // 1.2 s of 25 fps

      final result = img.decodeImage(encodeAnimatedPng(source, maxSize: 64))!;

      expect(result.frames.length, 1200 * signalAnimatedMaxFps ~/ 1000);
      expect(_totalDuration(result), closeTo(1200, 30));
    });

    test("adds margins instead of cropping", () {
      final result =
          img.decodeImage(encodeAnimatedPng(_animationAs("png", 2, width: 120, height: 60), maxSize: 96))!;

      expect(result.width, 96);
      expect(result.height, 96);
      expect(result.getPixel(48, 48).a, 255, reason: "the picture is in the middle");
      expect(result.getPixel(2, 2).a, 0, reason: "and the band beside it is transparent");
    });

    test("drops frames until the file fits, keeping the playback speed", () {
      final source = _animationAs("png", 24);
      final full = encodeAnimatedPng(source, maxSize: 96);
      final budget = (full.lengthInBytes * 0.6).floor();

      final fitted = encodeAnimatedPng(source, maxSize: 96, maxBytes: budget);
      final result = img.decodeImage(fitted)!;

      expect(fitted.lengthInBytes, lessThanOrEqualTo(budget));
      expect(result.frames.length, lessThan(24));
      expect(_totalDuration(result), closeTo(2400, 60));
    });

    test("gives up when not even two frames fit", () {
      expect(
        () => encodeAnimatedPng(_animationAs("png", 10), maxSize: 96, maxBytes: 64),
        throwsA(isA<AnimatedPngException>()),
      );
    });

    test("leaves a static image static", () {
      final png = encodeAnimatedPng(img.encodePng(_frame(1, 100, 60, 0)), maxSize: 64);

      expect(_hasChunk(png, "acTL"), isFalse);
      expect(img.decodeImage(png)!.frames.length, 1);
    });
  });
}
