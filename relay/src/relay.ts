// The relay's behaviour, independent of Cloudflare: index.ts wires it to the
// Worker's fetch, email and scheduled handlers.
//
// It never acts on its own (docs/adr/0002, decision 4). It seals mail for the
// phone, sends only what the phone hands it, and shows a notification when a
// wake the phone asked for comes due. It can't read a case.

import { b64, isPublicKey, randomLocalPart, randomToken, seal, sha256 } from "./crypto.ts";
import { dkimVerdict, type DkimVerdict } from "./dkim.ts";
import type { Mailer, Pusher } from "./outbound.ts";
import type { CaseRow, Device, Store } from "./store.ts";

export interface Config {
  mailDomain: string;
  trustedAuthservId: string;
  modelBaseURL: string;
  modelKey: string | null;
  /** Empty: any model. */
  modelAllow: string[];
  modelDailyRequests: number;
  /** When set, registering a device needs this in X-Steward-Invite. */
  registrationSecret: string | null;
}

export interface IncomingMail {
  /** The envelope recipient: a case address. */
  to: string;
  /** The envelope sender, as the receiving server saw it. */
  from: string;
  raw: Uint8Array;
  reject(reason: string): void;
}

/** What the phone finds when it opens an envelope. */
export interface SealedMail {
  v: 1;
  caseId: string;
  receivedAt: string;
  envelopeFrom: string;
  dkim: DkimVerdict;
  /** The whole message as received (RFC 5322), base64. */
  raw: string;
}

export const MAX_MAIL_BYTES = 10 * 1024 * 1024;
const ADDRESS = /^[^\s@<>()",;:\\[\]]+@[a-z0-9.-]+\.[a-z]{2,}$/i;

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

function field(body: Record<string, unknown>, name: string, max = 10_000): string {
  const value = body[name];
  if (typeof value !== "string" || value.length === 0) throw new HttpError(400, `${name} is required`);
  if (value.length > max) throw new HttpError(400, `${name} is too long`);
  return value;
}

function optional(body: Record<string, unknown>, name: string, max = 10_000): string | undefined {
  return body[name] === undefined || body[name] === null ? undefined : field(body, name, max);
}

/** One line, no characters that could start a new header. */
function oneLine(value: string, name: string): string {
  if (/[\r\n\0]/.test(value)) throw new HttpError(400, `${name} must be one line`);
  return value;
}

export class Relay {
  constructor(
    private store: Store,
    private mailer: Mailer,
    private pusher: Pusher,
    private config: Config,
    private now: () => number = Date.now,
    private fetcher: typeof fetch = fetch,
  ) {}

  // ---------- HTTP ----------

  async fetch(request: Request): Promise<Response> {
    try {
      return await this.route(request);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message }, error.status);
      // Never echo internals, and never log request bodies.
      return json({ error: "Something went wrong at the relay." }, 500);
    }
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "");
    const method = request.method.toUpperCase();

    if (method === "POST" && path === "/v1/devices") return this.register(request);

    const device = await this.authenticate(request);
    if (method === "PUT" && path === "/v1/devices/push") return this.setPush(device, await this.body(request));
    if (method === "POST" && path === "/v1/cases") return this.openCase(device);
    if (method === "GET" && path === "/v1/inbox") return this.listInbox(device);
    if (method === "POST" && path === "/v1/inbox/ack") return this.ackInbox(device, await this.body(request));
    if (method === "POST" && path === "/v1/send") return this.send(device, await this.body(request));
    if (method === "POST" && path === "/v1/model/chat/completions") return this.proxyModel(device, request);

    const caseMatch = /^\/v1\/cases\/([A-Za-z0-9_-]+)(\/wake)?$/.exec(path);
    if (caseMatch) {
      const row = await this.ownedCase(device, caseMatch[1]!);
      if (caseMatch[2]) {
        if (method === "PUT") return this.setWake(row, await this.body(request));
        if (method === "DELETE") {
          await this.store.clearWake(row.id);
          return json({ ok: true });
        }
      } else if (method === "DELETE") {
        return this.closeCase(row);
      }
    }
    throw new HttpError(404, "Not found");
  }

  private async body(request: Request): Promise<Record<string, unknown>> {
    try {
      const data = await request.json();
      if (data && typeof data === "object" && !Array.isArray(data)) return data as Record<string, unknown>;
    } catch {
      // fall through
    }
    throw new HttpError(400, "Expected a JSON object");
  }

  private async authenticate(request: Request): Promise<Device> {
    const header = request.headers.get("authorization") ?? "";
    const token = /^Bearer\s+(\S+)$/i.exec(header)?.[1];
    if (!token) throw new HttpError(401, "Missing token");
    const device = await this.store.deviceByTokenHash(await sha256(token));
    if (!device) throw new HttpError(401, "Unknown token");
    return device;
  }

  private async ownedCase(device: Device, id: string): Promise<CaseRow> {
    const row = await this.store.caseById(id);
    // Someone else's case looks exactly like no case.
    if (!row || row.deviceId !== device.id) throw new HttpError(404, "Not found");
    return row;
  }

  // ---------- devices and cases ----------

  private async register(request: Request): Promise<Response> {
    if (this.config.registrationSecret && request.headers.get("x-steward-invite") !== this.config.registrationSecret) {
      throw new HttpError(403, "Registration is invite-only for now");
    }
    const body = await this.body(request);
    if (!isPublicKey(body.publicKey)) throw new HttpError(400, "publicKey must be a 32-byte X25519 key, base64");
    const pushToken = optional(body, "pushToken", 200);
    const token = randomToken();
    const device: Device = { id: randomToken(16), tokenHash: await sha256(token), publicKey: body.publicKey, pushToken: pushToken ?? null, createdAt: this.now() };
    await this.store.addDevice(device);
    // The only time the token is ever sent; the relay keeps its hash.
    return json({ deviceId: device.id, token }, 201);
  }

  private async setPush(device: Device, body: Record<string, unknown>): Promise<Response> {
    const token = body.pushToken === null ? null : field(body, "pushToken", 200);
    await this.store.setPushToken(device.id, token);
    return json({ ok: true });
  }

  private async openCase(device: Device): Promise<Response> {
    for (let attempt = 0; attempt < 5; attempt++) {
      const address = `${randomLocalPart()}@${this.config.mailDomain}`;
      if (await this.store.caseByAddress(address)) continue;
      const row: CaseRow = { id: randomToken(16), deviceId: device.id, address, createdAt: this.now(), closedAt: null };
      await this.store.addCase(row);
      return json({ caseId: row.id, address }, 201);
    }
    throw new HttpError(500, "Couldn't find a free address");
  }

  /** The address stops taking mail, and anything waiting for the case goes. */
  private async closeCase(row: CaseRow): Promise<Response> {
    await this.store.closeCase(row.id, this.now());
    await this.store.clearWake(row.id);
    await this.store.dropInboxForCase(row.id);
    return json({ ok: true });
  }

  // ---------- inbound mail ----------

  /** A company's reply arrives: seal it to the phone, keep only the sealed
   * copy, and hint to the phone that mail is waiting. */
  async receive(mail: IncomingMail): Promise<void> {
    const row = await this.store.caseByAddress(mail.to.trim().toLowerCase());
    if (!row || row.closedAt !== null) {
      mail.reject("No such mailbox.");
      return;
    }
    if (mail.raw.byteLength > MAX_MAIL_BYTES) {
      mail.reject("Message too large.");
      return;
    }
    const device = await this.store.device(row.deviceId);
    if (!device) {
      mail.reject("No such mailbox.");
      return;
    }
    const text = new TextDecoder("latin1").decode(mail.raw);
    const sealed: SealedMail = {
      v: 1,
      caseId: row.id,
      receivedAt: new Date(this.now()).toISOString(),
      envelopeFrom: mail.from,
      dkim: dkimVerdict(text, this.config.trustedAuthservId),
      raw: b64(mail.raw),
    };
    const envelope = await seal(device.publicKey, new TextEncoder().encode(JSON.stringify(sealed)));
    await this.store.addInbox({ id: randomToken(16), deviceId: device.id, caseId: row.id, envelope: JSON.stringify(envelope), receivedAt: this.now() });
    if (device.pushToken) {
      // A hint only: the phone also checks whenever it opens.
      await this.pusher.push(device.pushToken, { kind: "mail" }).catch(() => undefined);
    }
  }

  private async listInbox(device: Device): Promise<Response> {
    const items = await this.store.inbox(device.id, 50);
    return json({ items: items.map((i) => ({ id: i.id, caseId: i.caseId, envelope: JSON.parse(i.envelope), receivedAt: i.receivedAt })) });
  }

  /** The phone has the mail safely: the relay forgets it. */
  private async ackInbox(device: Device, body: Record<string, unknown>): Promise<Response> {
    const ids = body.ids;
    if (!Array.isArray(ids) || ids.length > 200 || !ids.every((i) => typeof i === "string")) throw new HttpError(400, "ids must be a list of strings");
    return json({ deleted: await this.store.ack(device.id, ids as string[]) });
  }

  // ---------- sending ----------

  /** Sends an email the owner approved, from the case's own address, once per
   * send ID however many times the phone retries (docs/adr/0002, decision 2). */
  private async send(device: Device, body: Record<string, unknown>): Promise<Response> {
    const sendId = oneLine(field(body, "sendId", 200), "sendId");
    const row = await this.ownedCase(device, field(body, "caseId", 100));
    if (row.closedAt !== null) throw new HttpError(409, "The case is closed");
    const to = oneLine(field(body, "to", 320), "to").trim();
    if (!ADDRESS.test(to)) throw new HttpError(400, "to must be one email address");
    const subject = oneLine(field(body, "subject", 998), "subject");
    const text = field(body, "body", 100_000);
    const fromName = optional(body, "fromName", 100);
    const replyTo = optional(body, "replyTo", 320);
    if (replyTo !== undefined && !ADDRESS.test(oneLine(replyTo, "replyTo"))) throw new HttpError(400, "replyTo must be one email address");

    const existing = await this.store.send(sendId);
    if (existing) {
      if (existing.deviceId !== device.id) throw new HttpError(409, "That send ID is taken");
      if (existing.status === "sent") return json({ status: "sent", messageId: existing.messageId, duplicate: true });
      // "sending": an earlier attempt didn't finish. Retry under the same key,
      // so the provider sends it at most once.
    } else {
      const now = this.now();
      const started = await this.store.startSend({ sendId, deviceId: device.id, caseId: row.id, status: "sending", messageId: null, createdAt: now, updatedAt: now });
      if (!started) {
        // Another request with this ID got in first.
        const other = await this.store.send(sendId);
        if (other?.status === "sent" && other.deviceId === device.id) return json({ status: "sent", messageId: other.messageId, duplicate: true });
        throw new HttpError(409, "This email is already being sent");
      }
    }

    let messageId: string;
    try {
      messageId = await this.mailer.send({ from: row.address, fromName: fromName ? oneLine(fromName, "fromName") : undefined, to, subject, text, replyTo, idempotencyKey: sendId });
    } catch {
      // Outcome unknown: the row stays "sending", so a retry reuses the key.
      throw new HttpError(502, "The mail service didn't confirm the send. Retrying with the same send ID is safe.");
    }
    await this.store.finishSend(sendId, messageId, this.now());
    // The body is not kept anywhere.
    return json({ status: "sent", messageId, duplicate: false });
  }

  // ---------- wakes ----------

  private async setWake(row: CaseRow, body: Record<string, unknown>): Promise<Response> {
    const at = body.at;
    if (typeof at !== "number" || !Number.isFinite(at)) throw new HttpError(400, "at must be a time in milliseconds");
    if (row.closedAt !== null) throw new HttpError(409, "The case is closed");
    await this.store.setWake({ caseId: row.id, deviceId: row.deviceId, at });
    return json({ ok: true });
  }

  /** Every minute: show a notification for each wake that has come due. */
  async tick(): Promise<number> {
    const due = await this.store.takeDueWakes(this.now(), 500);
    for (const wake of due) {
      const device = await this.store.device(wake.deviceId);
      if (!device?.pushToken) continue;
      await this.pusher.push(device.pushToken, { kind: "wake", caseId: wake.caseId }).catch(() => undefined);
    }
    return due.length;
  }

  // ---------- model proxy ----------

  /** Forwards a chat completion to the provider with Steward's key, within a
   * daily cap per phone. Nothing about the request is stored or logged. */
  private async proxyModel(device: Device, request: Request): Promise<Response> {
    if (!this.config.modelKey) throw new HttpError(503, "The model proxy isn't set up");
    const text = await request.text();
    if (text.length > 2_000_000) throw new HttpError(413, "Request too large");
    let model: unknown;
    try {
      model = (JSON.parse(text) as { model?: unknown }).model;
    } catch {
      throw new HttpError(400, "Expected a JSON object");
    }
    if (typeof model !== "string" || !model) throw new HttpError(400, "model is required");
    if (this.config.modelAllow.length > 0 && !this.config.modelAllow.includes(model)) throw new HttpError(403, "That model isn't available through Steward");
    const day = new Date(this.now()).toISOString().slice(0, 10);
    if ((await this.store.countRequest(device.id, day)) > this.config.modelDailyRequests) {
      throw new HttpError(429, "Today's model allowance is used up. It resets at midnight UTC.");
    }
    const upstream = await this.fetcher(`${this.config.modelBaseURL}/chat/completions`, {
      method: "POST",
      headers: { authorization: `Bearer ${this.config.modelKey}`, "content-type": "application/json" },
      body: text,
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  }
}
