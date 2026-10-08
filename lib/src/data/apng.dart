import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:stickers/src/data/signal.dart';

/// Frame rate animated stickers are converted to.
/// Signal doesn't limit the frame rate of a sticker, it limits its size to [signalMaxStickerBytes]
/// instead, and every frame of an animated png costs a few kilobytes. 12 fps is high enough to look
/// smooth and leaves room for a few seconds of animation.
const int signalAnimatedMaxFps = 12;

/// Below this a sticker is a blur, so an animation that doesn't fit even then is reported instead of
/// shrunk further.
const int signalMinStickerSize = 256;

/// How often the encoder is allowed to retry with fewer frames or a smaller canvas.
const int _maxAttempts = 6;

/// Only this much of [signalMaxStickerBytes] is aimed for; png compressors differ in how much room
/// a picture takes, and Signal doesn't round in our favour.
const double _budget = 0.92;

/// How many frames an animation is worth shrinking the picture for - one second of motion.
const int _preferredFrames = 12;

/// Thrown when an animation is too long or too detailed to fit into Signal's size limit.
class AnimatedPngException implements Exception {
  const AnimatedPngException(this.message);

  final String message;

  @override
  String toString() => "AnimatedPngException: $message";
}

/// Converts an animation - the animated webp this app stores, a gif, an animated png - into an
/// animated png, the only animated format Signal accepts for stickers.
///
/// The result is square, at most [maxSize] pixels per side and loops forever. Playback speed is
/// always kept: the frame rate is capped at [fps] and every frame that is dropped to save room hands
/// its duration to the one that stays. When the file is still too big the canvas shrinks first and
/// frames only go with it, a sticker that moves at 300 pixels being a better sticker than a sharp one
/// that doesn't. [AnimatedPngException] if not even two frames at [signalMinStickerSize] fit into
/// [maxBytes].
///
/// Expensive: decoding and encoding take about a second per dozen frames, so call this off the UI
/// isolate.
Uint8List encodeAnimatedPng(
  Uint8List bytes, {
  int maxSize = signalStickerSize,
  int maxBytes = signalMaxStickerBytes,
  int fps = signalAnimatedMaxFps,
}) {
  final source = img.decodeImage(bytes);
  if (source == null) throw const AnimatedPngException("not an image Signal could read");

  final durations = [
    for (final frame in source.frames) frame.frameDuration > 0 ? frame.frameDuration : 100,
  ];
  if (durations.isEmpty) throw const AnimatedPngException("image without frames");

  final wanted = _frameCountAtFps(durations, fps);
  final minSize = math.min(signalMinStickerSize, maxSize);
  final minFrames = math.min(2, durations.length);
  final budget = (maxBytes * _budget).floor();

  // One frame at full size is the cheap way of learning what a frame costs - a photograph needs ten
  // times the room flat sticker art does, and the answer decides what the animation is worth.
  final cost = _encode(source, [durations.length ~/ 2], [100], maxSize).lengthInBytes;
  var frames = wanted;
  var size = maxSize;
  if (frames * cost > budget) {
    // Two frames isn't an animation, it's a slideshow, so rather than dropping to them the canvas
    // shrinks - sizes following areas, hence the square root - and the frames that fit in what is
    // left of the budget are the frames the animation gets.
    size = (maxSize * math.sqrt(budget / _preferredFrames / cost)).round().clamp(minSize, maxSize);
    final costHere = cost * (size * size) / (maxSize * maxSize);
    frames = (budget / costHere).floor().clamp(minFrames, wanted);
  }

  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    final indices = _spread(durations.length, frames);
    final png = _encode(source, indices, _coveredDurations(durations, indices), size);
    if (png.lengthInBytes <= maxBytes) return png;

    // The estimate above is rough, so the finished file is checked against reality: first a few
    // frames go, and only when the animation would stop being one the canvas shrinks again.
    final fitting = (frames * budget / png.lengthInBytes).floor();
    if (fitting >= minFrames && fitting < frames) {
      frames = fitting;
      continue;
    }
    if (size <= minSize) break;
    final scale = math.sqrt(budget / png.lengthInBytes);
    size = math.max(minSize, math.min(size - 1, (size * scale).round()));
  }

  throw AnimatedPngException("animation doesn't fit into $maxBytes bytes");
}

/// Number of frames the animation described by [durations] is played with at [fps] frames per
/// second, never more than it has.
int _frameCountAtFps(List<int> durations, int fps) {
  final ms = durations.fold<int>(0, (sum, duration) => sum + duration);
  return (ms * fps / 1000).round().clamp(1, durations.length);
}

/// [frames] evenly spread indices into the [count] frames of a source animation.
List<int> _spread(int count, int frames) {
  if (frames >= count) return List<int>.generate(count, (i) => i);
  return List<int>.generate(frames, (i) => (i * count / frames).floor().clamp(0, count - 1));
}

/// How long each of the [indices] frames is shown when the frames they replace are dropped: the sum
/// of their durations, so the animation keeps its length.
List<int> _coveredDurations(List<int> durations, List<int> indices) {
  if (indices.length == durations.length) return [for (final i in indices) durations[i]];
  return [
    for (var i = 0; i < indices.length; i++)
      durations.sublist(indices[i], i + 1 < indices.length ? indices[i + 1] : durations.length)
          .fold<int>(0, (sum, duration) => sum + duration),
  ];
}

/// Assembles the [indices] frames of [source] into an animated png of [size] pixels per side.
Uint8List _encode(img.Image source, List<int> indices, List<int> durations, int size) {
  img.Image? animation;
  for (var i = 0; i < indices.length; i++) {
    final canvas = img.Image(width: size, height: size, numChannels: 4)
      ..frameDuration = durations[i].clamp(1, 65535);
    _paintOn(canvas, source.getFrame(indices[i]), size);
    if (animation == null) {
      animation = canvas;
    } else {
      animation.addFrame(canvas);
    }
  }
  if (indices.length > 1) {
    animation!.frameType = img.FrameType.animation;
    animation.loopCount = 0; // Signal stickers loop.
  }
  return img.encodePng(animation!);
}

/// Scales [frame] onto [canvas], which is always a fresh image: the first frame of a decoded
/// animation still carries the whole animation of its source, and painting onto that would be
/// painted into.
/// Signal stickers are square and cropping them would cut something off, which is why a frame with a
/// different aspect ratio is centred with margins around it instead.
///
/// The canvas is always a fresh image: the first frame of a decoded animation still carries the whole
/// animation of its source, and painting onto that would be painted into.
void _paintOn(img.Image canvas, img.Image frame, int size) {
  final scaled = img.copyResize(frame,
      width: size, height: size, maintainAspect: true, interpolation: img.Interpolation.linear);
  img.compositeImage(canvas, scaled,
      center: scaled.width != size || scaled.height != size, blend: img.BlendMode.alpha);
}
