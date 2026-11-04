import { inflateRawSync } from 'node:zlib';

export const DOCX_TYPE = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

/** One file from a ZIP archive, or undefined; throws on a broken archive. */
function unzipEntry(zip: Buffer, name: string): Buffer | undefined {
  // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
  let eocd = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 22 - 0xffff); i--) {
    if (zip.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip file');
  let pos = zip.readUInt32LE(eocd + 16);
  for (let n = zip.readUInt16LE(eocd + 10); n > 0; n--) {
    if (zip.readUInt32LE(pos) !== 0x02014b50) throw new Error('broken zip directory');
    const method = zip.readUInt16LE(pos + 10);
    const size = zip.readUInt32LE(pos + 20);
    const nameLen = zip.readUInt16LE(pos + 28);
    const extraLen = zip.readUInt16LE(pos + 30);
    const commentLen = zip.readUInt16LE(pos + 32);
    const local = zip.readUInt32LE(pos + 42);
    if (zip.toString('utf8', pos + 46, pos + 46 + nameLen) === name) {
      const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
      const body = zip.subarray(start, start + size);
      if (method === 0) return body;
      if (method === 8) return inflateRawSync(body);
      throw new Error('unsupported zip compression');
    }
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return undefined;
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

/** The text of a .docx: paragraphs on lines, table cells separated by tabs. */
export function docxText(docx: Buffer): string {
  const xml = unzipEntry(docx, 'word/document.xml')?.toString('utf8');
  if (xml == null) throw new Error('no document.xml');
  let out = '';
  const token = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>|<w:tab\s*\/>|<w:br\b[^>]*\/>|<\/w:p>|<\/w:tc>/g;
  for (const m of xml.matchAll(token)) {
    const t = m[0];
    if (m[1] != null) out += m[1].replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (_, e: string) =>
      e[0] === '#' ? String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : (ENTITIES[e] ?? `&${e};`));
    else if (t === '</w:p>' || t.startsWith('<w:br')) out += '\n';
    else out += '\t';
  }
  return out.replace(/\t+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
