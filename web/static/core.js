export function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
export function totalPages(total, size) { return Math.max(1, Math.ceil(total / size)); }
export function pageAt(index, length) { return clamp(Math.trunc(Number(index) || 0), 0, Math.max(0, length - 1)); }
export function preloadIndices(index, pages, maxBytes = 8 * 1024 * 1024) {
  if ((pages[index]?.size || 0) > 32 * 1024 * 1024) return [];
  return [index + 1, index - 1].filter(i => i >= 0 && i < pages.length && pages[i].size <= maxBytes);
}
export function validBook(book) {
  return book && typeof book.id === 'string' && /^[1-9][0-9]{0,18}$/.test(book.id) && typeof book.title === 'string';
}
export function validateManifest(value) {
  if (!value || !Array.isArray(value.pages) || value.pages.length > 20000) throw Error('页清单无效');
  let previous = 0;
  for (const page of value.pages) {
    if (!Number.isInteger(page.number) || page.number <= previous || page.number > 99999999 ||
        !/^[a-f0-9]{64}$/.test(page.sha256) || !Number.isSafeInteger(page.size) || page.size < 0) throw Error('页清单无效');
    previous = page.number;
  }
  return value.pages;
}
export function progressKey(libraryId, bookID) { return `${libraryId}:${bookID}`; }
export function rememberedIndex(saved, pages) {
  if (!saved) return 0;
  const match = pages.findIndex(p => p.number === saved.number);
  return match < 0 ? 0 : match;
}
