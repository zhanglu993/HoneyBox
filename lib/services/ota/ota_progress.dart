class OtaProgressTracker {
  double _progress = 0;
  double update(
      {int? imageIndex,
      int? imageCount,
      num? currentPercent,
      num? overallProgress}) {
    final count = imageCount != null && imageCount > 0 ? imageCount : 1;
    final index = (imageIndex ?? 0).clamp(0, count - 1).toInt();
    final value = overallProgress ?? currentPercent;
    if (value == null || !value.isFinite) return _progress;
    final fraction = (value.toDouble() / 100).clamp(0.0, 1.0).toDouble();
    final next =
        overallProgress != null ? fraction : (index + fraction) / count;
    if (next > _progress) _progress = next;
    return _progress;
  }
}
