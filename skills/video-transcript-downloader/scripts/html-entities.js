function decodeCodePoint(value, entity) {
  if (!Number.isInteger(value) || value < 0 || value > 0x10ffff) return entity;
  return String.fromCodePoint(value);
}

export function decodeHtmlEntities(input) {
  if (!input) return input;
  // Some transcripts come back double-encoded (e.g. "&amp;#39;").
  // Decode up to 2 passes; stop once stable.
  let text = input;
  for (let i = 0; i < 2; i++) {
    const decoded = text
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&#(\d+);/g, (entity, dec) => decodeCodePoint(Number(dec), entity))
      .replace(/&#x([0-9a-fA-F]+);/g, (entity, hex) => decodeCodePoint(parseInt(hex, 16), entity));
    if (decoded === text) break;
    text = decoded;
  }
  return text;
}
