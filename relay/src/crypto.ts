// Sealing incoming mail to the owner's phone, and the relay's own tokens.
//
// The envelope: an ephemeral X25519 key agrees a secret with the phone's
// public key; HKDF-SHA256 (salt: ephemeral public key then the phone's public
// key, info: INFO) turns it into an AES-256-GCM key. Only the phone's private
// key, which never leaves the device, can open it. StewardCore's
// RelayEnvelope opens the same format, and Tests/Conformance/relay_envelope.json
// holds both to it.

export const INFO = "steward-relay-mail-v1";
export const ALG = "X25519-HKDF-SHA256-AES256GCM";

export interface Envelope {
  v: 1;
  alg: typeof ALG;
  epk: string; // ephemeral public key, base64
  nonce: string; // 12 bytes, base64
  ct: string; // ciphertext followed by the 16-byte tag, base64
}

const enc = new TextEncoder();

export function b64(bytes: ArrayBuffer | Uint8Array): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u8) s += String.fromCharCode(b);
  return btoa(s);
}

export function unb64(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** A valid X25519 public key as the phone sends it: 32 bytes, base64. */
export function isPublicKey(text: unknown): text is string {
  if (typeof text !== "string") return false;
  try {
    return unb64(text).length === 32;
  } catch {
    return false;
  }
}

/** X25519 key agreement. The runtime takes `public`; Cloudflare's type
 * definitions call it `$public`, hence the cast. */
function x25519(publicKey: CryptoKey): SubtleCryptoDeriveKeyAlgorithm {
  return { name: "X25519", public: publicKey } as unknown as SubtleCryptoDeriveKeyAlgorithm;
}

async function aesKey(shared: ArrayBuffer, salt: Uint8Array): Promise<CryptoKey> {
  const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: enc.encode(INFO) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/** Seals `plaintext` so only the holder of `recipientPublicKey`'s private key can read it. */
export async function seal(recipientPublicKey: string, plaintext: Uint8Array): Promise<Envelope> {
  const recipientRaw = unb64(recipientPublicKey);
  const recipient = await crypto.subtle.importKey("raw", recipientRaw, { name: "X25519" }, false, []);
  const eph = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const ephRaw = new Uint8Array((await crypto.subtle.exportKey("raw", eph.publicKey)) as ArrayBuffer);
  const shared = await crypto.subtle.deriveBits(x25519(recipient), eph.privateKey, 256);
  const key = await aesKey(shared, concat(ephRaw, recipientRaw));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, plaintext);
  return { v: 1, alg: ALG, epk: b64(ephRaw), nonce: b64(nonce), ct: b64(ct) };
}

/** Opens an envelope with the recipient's private key. The relay never does
 * this; tests use it to prove the phone can. */
export async function open(envelope: Envelope, privateKey: CryptoKey, recipientPublicKey: string): Promise<Uint8Array> {
  const ephRaw = unb64(envelope.epk);
  const eph = await crypto.subtle.importKey("raw", ephRaw, { name: "X25519" }, false, []);
  const shared = await crypto.subtle.deriveBits(x25519(eph), privateKey, 256);
  const key = await aesKey(shared, concat(ephRaw, unb64(recipientPublicKey)));
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(envelope.nonce) }, key, unb64(envelope.ct));
  return new Uint8Array(plain);
}

/** A random id or token: `bytes` random bytes, URL-safe base64 without padding. */
export function randomToken(bytes = 32): string {
  return b64(crypto.getRandomValues(new Uint8Array(bytes))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** A mailbox name that says nothing about the owner or the errand. */
export function randomLocalPart(): string {
  const alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return "case-" + Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

export async function sha256(text: string): Promise<string> {
  return b64(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}
