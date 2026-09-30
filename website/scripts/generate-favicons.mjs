import sharp from 'sharp';
import { readFile, writeFile } from 'node:fs/promises';

const publicDirectory = new URL('../public/', import.meta.url);
const source = await readFile(new URL('favicon.svg', publicDirectory));
const render = (size) => sharp(source, { density: 288 }).resize(size, size).png().toBuffer();
await writeFile(new URL('favicon-32.png', publicDirectory), await render(32));
await writeFile(new URL('apple-touch-icon.png', publicDirectory),
  await sharp(await render(180)).flatten({ background: '#ffffff' }).png().toBuffer());

// An ICO with PNG entries keeps the small sizes crisp in legacy browser tabs.
const sizes = [16, 32, 48];
const images = await Promise.all(sizes.map(render));
const header = Buffer.alloc(6 + sizes.length * 16);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(sizes.length, 4);
let offset = header.length;
images.forEach((image, index) => {
  const entry = 6 + index * 16;
  header[entry] = sizes[index];
  header[entry + 1] = sizes[index];
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(image.length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += image.length;
});
await writeFile(new URL('favicon.ico', publicDirectory), Buffer.concat([header, ...images]));
