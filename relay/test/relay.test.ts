import { beforeEach, describe, expect, it } from "vitest";
import { open, type Envelope } from "../src/crypto.ts";
import { dkimVerdict, signedBy } from "../src/dkim.ts";
import type { Mailer, OutgoingEmail, Push, Pusher } from "../src/outbound.ts";
import { Relay, type Config, type SealedMail } from "../src/relay.ts";
import { MemoryStore } from "../src/store.ts";

// ---------- fakes ----------

class RecordingMailer implements Mailer {
  sent: OutgoingEmail[] = [];
  failures = 0;
  async send(email: OutgoingEmail) {
    this.sent.push(email);
    if (this.failures > 0) {
      this.failures--;
      throw new Error("timeout");
    }
    return `msg-${this.sent.length}`;
  }
}

class RecordingPusher implements Pusher {
  pushes: { token: string; push: Push }[] = [];
  async push(token: string, push: Push) {
    this.pushes.push({ token, push });
  }
}

const config: Config = {
  mailDomain: "relay.steward.example",
  trustedAuthservId: "mx.cloudflare.net",
  modelBaseURL: "https://models.example/api/v1",
  modelKey: "steward-key",
  modelAllow: [],
  modelDailyRequests: 2,
  registrationSecret: null,
};

let store: MemoryStore;
let mailer: RecordingMailer;
let pusher: RecordingPusher;
let clock: number;
let upstream: { url: string; init: RequestInit }[];
let relay: Relay;

function makeRelay(overrides: Partial<Config> = {}) {
  relay = new Relay(store, mailer, pusher, { ...config, ...overrides }, () => clock, async (url, init) => {
    upstream.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ choices: [{ message: { content: "hi" } }] }), { status: 200, headers: { "content-type": "application/json" } });
  });
}

beforeEach(() => {
  store = new MemoryStore();
  mailer = new RecordingMailer();
  pusher = new RecordingPusher();
  clock = Date.UTC(2026, 10, 14, 9, 0);
  upstream = [];
  makeRelay();
});

async function call(method: string, path: string, token?: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await relay.fetch(new Request(`https://relay.test${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  }));
  const text = await res.text();
  return { status: res.status, data: text ? JSON.parse(text) : null };
}

/** A phone: its key pair (the private key stays here) and its relay token. */
async function phone(pushToken: string | null = "apns-1") {
  const keys = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  const publicKey = btoa(String.fromCharCode(...raw));
  const res = await call("POST", "/v1/devices", undefined, { publicKey, ...(pushToken ? { pushToken } : {}) });
  expect(res.status).toBe(201);
  return { keys, publicKey, token: res.data.token as string, deviceId: res.data.deviceId as string };
}

async function openCase(token: string) {
  const res = await call("POST", "/v1/cases", token);
  expect(res.status).toBe(201);
  return res.data as { caseId: string; address: string };
}

function rawMail(headers: string[], body = "We confirm your cancellation.") {
  return new TextEncoder().encode([...headers, "", body].join("\r\n"));
}

async function deliver(to: string, raw: Uint8Array) {
  const rejected: string[] = [];
  await relay.receive({ to, from: "support@company.example", raw, reject: (r) => rejected.push(r) });
  return rejected;
}

// ---------- devices and cases ----------

describe("devices", () => {
  it("registers a phone and only ever keeps a hash of its token", async () => {
    const p = await phone();
    const device = store.devices.get(p.deviceId)!;
    expect(device.tokenHash).not.toBe(p.token);
    expect(JSON.stringify([...store.devices.values()])).not.toContain(p.token);
  });

  it("refuses a malformed public key", async () => {
    expect((await call("POST", "/v1/devices", undefined, { publicKey: "short" })).status).toBe(400);
  });

  it("needs a valid token for everything else", async () => {
    expect((await call("POST", "/v1/cases")).status).toBe(401);
    expect((await call("POST", "/v1/cases", "made-up")).status).toBe(401);
  });

  it("can be invite-only", async () => {
    makeRelay({ registrationSecret: "letmein" });
    const body = { publicKey: btoa("x".repeat(32)) };
    expect((await call("POST", "/v1/devices", undefined, body)).status).toBe(403);
    expect((await call("POST", "/v1/devices", undefined, body, { "x-steward-invite": "letmein" })).status).toBe(201);
  });
});

describe("cases", () => {
  it("gives each case its own address that says nothing about the owner", async () => {
    const p = await phone();
    const a = await openCase(p.token);
    const b = await openCase(p.token);
    expect(a.address).toMatch(/^case-[a-z2-9]{10}@relay\.steward\.example$/);
    expect(a.address).not.toBe(b.address);
  });

  it("hides one phone's cases from another", async () => {
    const owner = await phone();
    const other = await phone();
    const c = await openCase(owner.token);
    expect((await call("PUT", `/v1/cases/${c.caseId}/wake`, other.token, { at: clock })).status).toBe(404);
    expect((await call("DELETE", `/v1/cases/${c.caseId}`, other.token)).status).toBe(404);
  });
});

// ---------- inbound mail ----------

describe("inbound mail", () => {
  it("seals mail so only the phone can read it, with the DKIM verdict inside", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    const raw = rawMail([
      "Authentication-Results: mx.cloudflare.net; dkim=pass header.d=company.example header.s=s1; spf=pass",
      "From: Support <support@company.example>",
      `To: ${c.address}`,
      "Subject: Re: Cancellation",
    ]);
    expect(await deliver(c.address.toUpperCase(), raw)).toEqual([]);

    // Nothing readable is stored.
    const stored = [...store.items.values()][0]!;
    expect(stored.envelope).not.toContain("cancellation");
    expect(stored.envelope).not.toContain("company.example");

    const inbox = await call("GET", "/v1/inbox", p.token);
    expect(inbox.data.items).toHaveLength(1);
    const plain = await open(inbox.data.items[0].envelope as Envelope, p.keys.privateKey, p.publicKey);
    const mail = JSON.parse(new TextDecoder().decode(plain)) as SealedMail;
    expect(mail.caseId).toBe(c.caseId);
    expect(mail.dkim).toEqual({ pass: ["company.example"], authservId: "mx.cloudflare.net" });
    expect(new TextDecoder().decode(Uint8Array.from(atob(mail.raw), (ch) => ch.charCodeAt(0)))).toContain("We confirm your cancellation.");
    expect(pusher.pushes).toEqual([{ token: "apns-1", push: { kind: "mail" } }]);
  });

  it("forgets mail once the phone has it", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    await deliver(c.address, rawMail(["Subject: Hi"]));
    const id = (await call("GET", "/v1/inbox", p.token)).data.items[0].id;
    const other = await phone();
    expect((await call("POST", "/v1/inbox/ack", other.token, { ids: [id] })).data.deleted).toBe(0);
    expect((await call("POST", "/v1/inbox/ack", p.token, { ids: [id] })).data.deleted).toBe(1);
    expect((await call("GET", "/v1/inbox", p.token)).data.items).toEqual([]);
  });

  it("refuses mail for unknown and closed cases", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    expect(await deliver("case-nobody@relay.steward.example", rawMail([]))).toEqual(["No such mailbox."]);
    await call("DELETE", `/v1/cases/${c.caseId}`, p.token);
    expect(await deliver(c.address, rawMail([]))).toEqual(["No such mailbox."]);
  });

  it("closing a case drops its waiting mail and wake", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    await deliver(c.address, rawMail([]));
    await call("PUT", `/v1/cases/${c.caseId}/wake`, p.token, { at: clock + 1000 });
    await call("DELETE", `/v1/cases/${c.caseId}`, p.token);
    expect(store.items.size).toBe(0);
    expect(store.wakes.size).toBe(0);
  });
});

describe("DKIM verdict", () => {
  const trusted = "mx.cloudflare.net";

  it("reads only the topmost header, from our own server", () => {
    const raw = [
      "Authentication-Results: mx.cloudflare.net; dkim=fail header.d=company.example",
      "Authentication-Results: mx.cloudflare.net; dkim=pass header.d=company.example",
      "",
      "body",
    ].join("\r\n");
    expect(dkimVerdict(raw, trusted).pass).toEqual([]);
  });

  it("ignores a header a sender wrote themselves", () => {
    const raw = "Authentication-Results: evil.example; dkim=pass header.d=company.example\r\n\r\nbody";
    expect(dkimVerdict(raw, trusted)).toEqual({ pass: [], authservId: null });
  });

  it("reads folded headers and ignores comments", () => {
    const raw = [
      "Authentication-Results: mx.cloudflare.net;",
      "\tdkim=pass (signature was verified; dkim=pass header.d=evil.example) header.d=Company.Example;",
      "\tdkim=pass header.d=esp.example",
      "",
      "Authentication-Results: mx.cloudflare.net; dkim=pass header.d=body.example",
    ].join("\r\n");
    expect(dkimVerdict(raw, trusted).pass).toEqual(["company.example", "esp.example"]);
  });

  it("counts the company's domain and its subdomains, never a parent", () => {
    expect(signedBy({ pass: ["mail.company.example"], authservId: trusted }, "company.example")).toBe(true);
    expect(signedBy({ pass: ["company.example"], authservId: trusted }, "company.example")).toBe(true);
    expect(signedBy({ pass: ["example"], authservId: trusted }, "company.example")).toBe(false);
    expect(signedBy({ pass: ["notcompany.example"], authservId: trusted }, "company.example")).toBe(false);
  });
});

// ---------- sending ----------

describe("sending", () => {
  async function ready() {
    const p = await phone();
    const c = await openCase(p.token);
    const email = { sendId: "case-1-call-7", caseId: c.caseId, to: "support@company.example", subject: "Cancellation", body: "Please cancel. Lena", fromName: "Lena Hoffmann" };
    return { p, c, email };
  }

  it("sends from the case's own address and keeps no body", async () => {
    const { p, c, email } = await ready();
    const res = await call("POST", "/v1/send", p.token, email);
    expect(res.data).toEqual({ status: "sent", messageId: "msg-1", duplicate: false });
    expect(mailer.sent[0]).toMatchObject({ from: c.address, fromName: "Lena Hoffmann", to: "support@company.example", idempotencyKey: "case-1-call-7" });
    expect(JSON.stringify([...store.sends.values()])).not.toContain("Please cancel");
  });

  it("sends once however often the phone retries", async () => {
    const { p, email } = await ready();
    await call("POST", "/v1/send", p.token, email);
    const again = await call("POST", "/v1/send", p.token, email);
    expect(again.data).toEqual({ status: "sent", messageId: "msg-1", duplicate: true });
    expect(mailer.sent).toHaveLength(1);
  });

  it("retries an unconfirmed send under the same key", async () => {
    const { p, email } = await ready();
    mailer.failures = 1;
    expect((await call("POST", "/v1/send", p.token, email)).status).toBe(502);
    expect(store.sends.get(email.sendId)?.status).toBe("sending");
    const retry = await call("POST", "/v1/send", p.token, email);
    expect(retry.data.status).toBe("sent");
    expect(mailer.sent.map((s) => s.idempotencyKey)).toEqual([email.sendId, email.sendId]);
  });

  it("won't let another phone use a send ID", async () => {
    const { p, email } = await ready();
    await call("POST", "/v1/send", p.token, email);
    const other = await phone();
    const theirs = await openCase(other.token);
    expect((await call("POST", "/v1/send", other.token, { ...email, caseId: theirs.caseId })).status).toBe(409);
  });

  it("refuses anything that could add a header or a second recipient", async () => {
    const { p, email } = await ready();
    for (const bad of [
      { to: "a@company.example, b@else.example" },
      { to: "a@company.example\r\nBcc: x@else.example" },
      { subject: "Hi\r\nBcc: x@else.example" },
      { replyTo: "x@else.example\nBcc: y@else.example" },
      { to: "not an address" },
    ]) {
      expect((await call("POST", "/v1/send", p.token, { ...email, sendId: Math.random().toString(), ...bad })).status).toBe(400);
    }
    expect(mailer.sent).toEqual([]);
  });

  it("won't send for a closed case", async () => {
    const { p, c, email } = await ready();
    await call("DELETE", `/v1/cases/${c.caseId}`, p.token);
    expect((await call("POST", "/v1/send", p.token, email)).status).toBe(409);
  });
});

// ---------- wakes ----------

describe("wakes", () => {
  it("shows a notification when a wake comes due, and only then", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    await call("PUT", `/v1/cases/${c.caseId}/wake`, p.token, { at: clock + 60_000 });
    expect(await relay.tick()).toBe(0);
    clock += 60_000;
    expect(await relay.tick()).toBe(1);
    expect(pusher.pushes).toEqual([{ token: "apns-1", push: { kind: "wake", caseId: c.caseId } }]);
    expect(await relay.tick()).toBe(0);
  });

  it("keeps one wake per case, the latest", async () => {
    const p = await phone();
    const c = await openCase(p.token);
    await call("PUT", `/v1/cases/${c.caseId}/wake`, p.token, { at: clock + 10 });
    await call("PUT", `/v1/cases/${c.caseId}/wake`, p.token, { at: clock + 99_000 });
    clock += 10;
    expect(await relay.tick()).toBe(0);
  });
});

// ---------- model proxy ----------

describe("model proxy", () => {
  const body = { model: "some/model", messages: [{ role: "user", content: "hi" }] };

  it("forwards with Steward's key, never the phone's token", async () => {
    const p = await phone();
    const res = await call("POST", "/v1/model/chat/completions", p.token, body);
    expect(res.status).toBe(200);
    expect(upstream[0]!.url).toBe("https://models.example/api/v1/chat/completions");
    const headers = upstream[0]!.init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer steward-key");
    expect(JSON.stringify(upstream[0]!.init)).not.toContain(p.token);
  });

  it("caps each phone's requests per day", async () => {
    const p = await phone();
    await call("POST", "/v1/model/chat/completions", p.token, body);
    await call("POST", "/v1/model/chat/completions", p.token, body);
    expect((await call("POST", "/v1/model/chat/completions", p.token, body)).status).toBe(429);
    clock += 24 * 3600_000;
    expect((await call("POST", "/v1/model/chat/completions", p.token, body)).status).toBe(200);
  });

  it("can be limited to some models, and is off without a key", async () => {
    makeRelay({ modelAllow: ["cheap/model"] });
    const p = await phone();
    expect((await call("POST", "/v1/model/chat/completions", p.token, body)).status).toBe(403);
    makeRelay({ modelKey: null });
    expect((await call("POST", "/v1/model/chat/completions", p.token, body)).status).toBe(503);
  });
});

// ---------- the phone's side of the format ----------

describe("shared envelope fixture", () => {
  it("opens with the fixture's private key, as the phone must", async () => {
    const { readFileSync } = await import("node:fs");
    const fixture = JSON.parse(readFileSync(new URL("../../StewardCore/Tests/Conformance/relay_envelope.json", import.meta.url), "utf8"));
    const d = fixture.privateKey as string;
    const x = fixture.publicKey as string;
    const url = (s: string) => s.replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
    const key = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "X25519", d: url(d), x: url(x) }, { name: "X25519" }, false, ["deriveBits"]);
    const mail = JSON.parse(new TextDecoder().decode(await open(fixture.envelope, key, x))) as SealedMail;
    expect(mail.caseId).toBe(fixture.expect.caseId);
    expect(mail.dkim.pass).toEqual(fixture.expect.dkimPass);
  });
});
