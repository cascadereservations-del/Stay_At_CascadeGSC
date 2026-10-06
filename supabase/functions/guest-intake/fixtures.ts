// Test images with metadata in them (no real photo, no real location): the smallest files stripMetadata has to understand.
const bytes = (...parts: Array<ArrayLike<number> | string>) => Uint8Array.from(parts.flatMap((p) => typeof p === 'string' ? [...p].map((c) => c.charCodeAt(0)) : Array.from(p)));
const be16 = (n: number) => [n >> 8, n & 255];
const be32 = (n: number) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
const le32 = (n: number) => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255];

/** SOI, JFIF APP0, an APP1 Exif segment carrying a GPS tag, a COM, one scan, EOI. */
const exif = bytes('Exif\0\0', 'GPSLATLONG');
export const JPEG_GPS = bytes([0xff, 0xd8], [0xff, 0xe0], be16(16), 'JFIF\0', [1, 1, 0, 0, 1, 0, 1, 0, 0],
  [0xff, 0xe1], be16(exif.length + 2), exif, [0xff, 0xfe], be16(8), 'camera', [0xff, 0xda], be16(8), [1, 1, 0, 0, 0x3f, 0], [0x11, 0x22, 0x33], [0xff, 0xd9]);

const chunk = (type: string, data: number[] | string) => { const d = typeof data === 'string' ? [...data].map((c) => c.charCodeAt(0)) : data; return bytes(be32(d.length), type, d, [0, 0, 0, 0]); };
/** PNG with tEXt and eXIf chunks (the GPS text is in the eXIf). */
export const PNG_GPS = bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]),
  chunk('tEXt', 'Comment\0secret'), chunk('eXIf', 'GPSLATLONG'), chunk('IDAT', [1, 2, 3, 4]), chunk('IEND', []));

const wchunk = (cc: string, d: number[] | string) => { const a = typeof d === 'string' ? [...d].map((c) => c.charCodeAt(0)) : d; return bytes(cc, le32(a.length), a, a.length & 1 ? [0] : []); };
/** Extended WebP with the EXIF and XMP flags set, an EXIF chunk, an XMP chunk and an odd-sized image chunk. */
const wbody = bytes('WEBP', wchunk('VP8X', [0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0]), wchunk('EXIF', 'GPSLATLONG'), wchunk('XMP ', '<x:xmp/>'), wchunk('VP8 ', [1, 2, 3, 4, 5]));
export const WEBP_GPS = bytes('RIFF', le32(wbody.length), wbody);
