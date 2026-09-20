class FineTuneLyricLine {
  final String text;
  final Duration? time;

  const FineTuneLyricLine({required this.text, this.time});

  FineTuneLyricLine copyWith({
    String? text,
    Duration? time,
    bool clearTime = false,
  }) {
    return FineTuneLyricLine(
      text: text ?? this.text,
      time: clearTime ? null : (time ?? this.time),
    );
  }
}

class LyricFineTuneDocument {
  static final RegExp _timeTag = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]',
  );
  static final RegExp _wordTimeTag = RegExp(
    r'<(?:(?:\d{1,3}):\d{2}(?:\.\d{1,3})?|\d+,\d+)>',
  );
  static final RegExp _metadataTag = RegExp(r'^\[[a-zA-Z]+:.*\]$');

  final List<String> metadata;
  final List<FineTuneLyricLine> lines;

  const LyricFineTuneDocument({
    this.metadata = const [],
    this.lines = const [],
  });

  factory LyricFineTuneDocument.parse(String source) {
    final metadata = <String>[];
    final lines = <FineTuneLyricLine>[];
    for (final rawLine
        in source.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      if (_metadataTag.hasMatch(trimmed) && !_timeTag.hasMatch(trimmed)) {
        metadata.add(trimmed);
        continue;
      }

      final match = _timeTag.firstMatch(trimmed);
      final text = trimmed
          .replaceAll(_timeTag, '')
          .replaceAll(_wordTimeTag, '')
          .trim();
      if (text.isEmpty) continue;
      lines.add(
        FineTuneLyricLine(
          text: text,
          time: match == null ? null : _parseTime(match),
        ),
      );
    }
    return LyricFineTuneDocument(metadata: metadata, lines: lines);
  }

  LyricFineTuneDocument clearTimes() {
    return LyricFineTuneDocument(
      metadata: metadata,
      lines: [for (final line in lines) line.copyWith(clearTime: true)],
    );
  }

  LyricFineTuneDocument setLineTime(int index, Duration time) {
    if (index < 0 || index >= lines.length) return this;
    final normalized = time.isNegative ? Duration.zero : time;
    return LyricFineTuneDocument(
      metadata: metadata,
      lines: [
        for (int i = 0; i < lines.length; i++)
          i == index ? lines[i].copyWith(time: normalized) : lines[i],
      ],
    );
  }

  LyricFineTuneDocument clearLineTime(int index) {
    if (index < 0 || index >= lines.length) return this;
    return LyricFineTuneDocument(
      metadata: metadata,
      lines: [
        for (int i = 0; i < lines.length; i++)
          i == index ? lines[i].copyWith(clearTime: true) : lines[i],
      ],
    );
  }

  Duration previousAnchorFor(int index) {
    for (int i = index - 1; i >= 0; i--) {
      final time = lines[i].time;
      if (time != null) return time;
    }
    return Duration.zero;
  }

  int? activeTimedIndex(Duration position) {
    int? activeIndex;
    Duration? activeTime;
    for (int i = 0; i < lines.length; i++) {
      final time = lines[i].time;
      if (time == null || time > position) continue;
      if (activeTime == null || time >= activeTime) {
        activeTime = time;
        activeIndex = i;
      }
    }
    return activeIndex;
  }

  int? matchingIndex(Duration position, Duration duration) {
    if (lines.isEmpty) return null;
    final clampedPosition = position > duration && duration > Duration.zero
        ? duration
        : position;
    int previousIndex = -1;
    int nextIndex = lines.length;
    Duration previousTime = Duration.zero;
    Duration nextTime = duration > Duration.zero
        ? duration
        : const Duration(days: 1);

    for (int i = 0; i < lines.length; i++) {
      final time = lines[i].time;
      if (time == null) continue;
      if (time <= clampedPosition && time >= previousTime) {
        previousTime = time;
        previousIndex = i;
      } else if (time > clampedPosition && time < nextTime) {
        nextTime = time;
        nextIndex = i;
      }
    }

    if (previousIndex >= nextIndex) {
      return lines.indexWhere((line) => line.time == null).takeIfFound;
    }
    for (int i = previousIndex + 1; i < nextIndex; i++) {
      if (lines[i].time == null) return i;
    }
    return null;
  }

  String toLrc() {
    final output = <String>[...metadata];
    for (final line in lines) {
      final time = line.time;
      output.add(time == null ? line.text : '${_formatTime(time)}${line.text}');
    }
    return output.join('\n');
  }

  static Duration _parseTime(RegExpMatch match) {
    final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
    final fraction = (match.group(3) ?? '').padRight(3, '0');
    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: int.tryParse(fraction) ?? 0,
    );
  }

  static String _formatTime(Duration value) {
    final totalMs = value.inMilliseconds.clamp(0, 359999999);
    final minutes = totalMs ~/ 60000;
    final seconds = (totalMs ~/ 1000) % 60;
    final centiseconds = (totalMs % 1000) ~/ 10;
    return '[${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}]';
  }
}

extension on int {
  int? get takeIfFound => this < 0 ? null : this;
}
