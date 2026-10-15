import { createReadStream, createWriteStream, readFileSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { randomBytes, publicEncrypt, privateDecrypt, createCipheriv, createDecipheriv, constants } from 'node:crypto';

const [mode, input, keyPath, output] = process.argv.slice(2);
if (mode === 'seal') {
  const key = randomBytes(32);
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  await pipeline(createReadStream(input), cipher, createWriteStream(output + '.bin', { flags: 'wx' }));
  const wrapped = publicEncrypt({ key: readFileSync(keyPath), padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, key);
  writeFileSync(output + '.json', JSON.stringify({
    version: 1, cipher: 'AES-256-GCM', wrap: 'RSA-OAEP-SHA256',
    iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), key: wrapped.toString('base64')
  }, null, 2), { flag: 'wx' });
  key.fill(0);
} else if (mode === 'open') {
  const meta = JSON.parse(readFileSync(input + '.json', 'utf8'));
  if (meta.version !== 1 || meta.cipher !== 'AES-256-GCM' || meta.wrap !== 'RSA-OAEP-SHA256') throw new Error('Unsupported envelope');
  const key = privateDecrypt({ key: readFileSync(keyPath), padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(meta.key, 'base64'));
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(meta.iv, 'base64'));
  decipher.setAuthTag(Buffer.from(meta.tag, 'base64'));
  const temporary = output + '.authenticated-part';
  try {
    await pipeline(createReadStream(input + '.bin'), decipher, createWriteStream(temporary, { flags: 'wx' }));
    renameSync(temporary, output);
  } catch (error) {
    try { unlinkSync(temporary); } catch {}
    throw error;
  } finally { key.fill(0); }
} else {
  throw new Error('Usage: seal.mjs seal|open input key output');
}
