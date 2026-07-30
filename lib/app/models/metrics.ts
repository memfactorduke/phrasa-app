/** Word and duration metrics matching native TextMetrics (150 WPM default). */

export function wordCount(text: string): number {
  const trimmed = text.trim();
  if (!trimmed) return 0;
  return trimmed.split(/\s+/).filter(Boolean).length;
}

export function estimatedDurationSeconds(
  text: string,
  wordsPerMinute = 150,
): number {
  if (wordsPerMinute <= 0) return 0;
  return (wordCount(text) / wordsPerMinute) * 60;
}

export function estimatedSecondsRounded(
  text: string,
  wordsPerMinute = 150,
): number {
  return Math.round(estimatedDurationSeconds(text, wordsPerMinute));
}

export function previewText(body: string, max = 180): string {
  const flat = body
    .split(/\s+/)
    .filter(Boolean)
    .join(" ");
  return flat.length <= max ? flat : flat.slice(0, max);
}
