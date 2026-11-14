// Writes StewardCore/Tests/Conformance/relay_envelope.json: a key pair, and
// mail the relay sealed to it. StewardCore's RelayEnvelopeTests must open it
// and read the email inside, so the phone and the relay can't drift apart.
//
//   npm run fixture

import { writeFileSync } from "node:fs";
import { b64, seal } from "../src/crypto.ts";
import type { SealedMail } from "../src/relay.ts";

const out = new URL("../../StewardCore/Tests/Conformance/relay_envelope.json", import.meta.url);

const raw = [
  "Authentication-Results: mx.cloudflare.net; dkim=pass header.d=fitwerk.example",
  "From: =?UTF-8?Q?FitWerk_Kundenservice?= <kundenservice@fitwerk.example>",
  "To: case-7f3a2b9c4d@relay.steward.example",
  "Subject: =?UTF-8?B?UmU6IEvDvG5kaWd1bmcgNDQ4MTIw?=",
  "Date: Thu, 12 Nov 2026 09:30:00 +0100",
  "Message-ID: <abc123@fitwerk.example>",
  "MIME-Version: 1.0",
  'Content-Type: multipart/alternative; boundary="b1"',
  "",
  "--b1",
  "Content-Type: text/plain; charset=utf-8",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  "Sehr geehrte Frau Hoffmann,",
  "",
  "wir best=C3=A4tigen die K=C3=BCndigung zum 10.12.2026. Ein sehr langer Satz, d=",
  "er hier umbricht.",
  "",
  "--b1",
  "Content-Type: text/html; charset=utf-8",
  "",
  "<p>Sehr geehrte Frau Hoffmann, <b>HTML</b></p>",
  "--b1--",
  "",
].join("\r\n");

const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
const publicKey = b64((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
const jwk = (await crypto.subtle.exportKey("jwk", keys.privateKey)) as JsonWebKey;
const privateKey = b64(Uint8Array.from(atob(jwk.d!.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (jwk.d!.length % 4)) % 4)), (c) => c.charCodeAt(0)));

const sealed: SealedMail = {
  v: 1,
  caseId: "Qk3xv9Lr2mT8wPa1",
  receivedAt: "2026-11-12T08:30:05.000Z",
  envelopeFrom: "bounce@fitwerk.example",
  dkim: { pass: ["fitwerk.example"], authservId: "mx.cloudflare.net" },
  raw: b64(new TextEncoder().encode(raw)),
};
const envelope = await seal(publicKey, new TextEncoder().encode(JSON.stringify(sealed)));

const fixture = {
  note: "Written by relay/test/write-fixture.ts. The private key is a throwaway test key.",
  privateKey,
  publicKey,
  envelope,
  expect: {
    caseId: sealed.caseId,
    receivedAt: sealed.receivedAt,
    dkimPass: sealed.dkim.pass,
    from: "kundenservice@fitwerk.example",
    subject: "Re: Kündigung 448120",
    date: "2026-11-12T08:30:00Z",
    body: "Sehr geehrte Frau Hoffmann,\n\nwir bestätigen die Kündigung zum 10.12.2026. Ein sehr langer Satz, der hier umbricht.",
  },
};
writeFileSync(out, JSON.stringify(fixture, null, 2) + "\n");
console.log("wrote", out.pathname);
