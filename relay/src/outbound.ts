// What leaves the relay: email through Resend, notifications through APNs.
// Both sit behind small interfaces so tests can record instead.

import { b64 } from "./crypto.ts";

export interface OutgoingEmail {
  from: string;
  fromName?: string;
  to: string;
  subject: string;
  text: string;
  replyTo?: string;
  /** The phone's sendID. Resend refuses to send the same key twice within a day. */
  idempotencyKey: string;
}

export interface Mailer {
  /** Returns the provider's message id. */
  send(email: OutgoingEmail): Promise<string>;
}

export class ResendMailer implements Mailer {
  constructor(private apiKey: string, private fetcher: typeof fetch = fetch) {}

  async send(email: OutgoingEmail): Promise<string> {
    const from = email.fromName ? `${email.fromName.replaceAll(/["<>\r\n]/g, "")} <${email.from}>` : email.from;
    const res = await this.fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": email.idempotencyKey,
      },
      body: JSON.stringify({
        from,
        to: [email.to],
        subject: email.subject,
        text: email.text,
        ...(email.replyTo ? { reply_to: email.replyTo } : {}),
      }),
    });
    if (!res.ok) throw new Error(`Resend answered ${res.status}`);
    const data = (await res.json()) as { id?: string };
    if (!data.id) throw new Error("Resend gave no message id");
    return data.id;
  }
}

export type Push =
  /** A hint that sealed mail is waiting. iOS may delay or drop it. */
  | { kind: "mail" }
  /** A visible notification for a wake the phone asked for. It says nothing
   * about the errand: the relay doesn't know what it is. */
  | { kind: "wake"; caseId: string };

export interface Pusher {
  push(deviceToken: string, push: Push): Promise<void>;
}

export class NoPusher implements Pusher {
  async push(): Promise<void> {}
}

/** Sends through APNs with a token (.p8) key. */
export class ApnsPusher implements Pusher {
  private jwt: { token: string; at: number } | null = null;

  constructor(
    private config: { keyPem: string; keyId: string; teamId: string; topic: string; sandbox: boolean },
    private fetcher: typeof fetch = fetch,
    private now: () => number = Date.now,
  ) {}

  async push(deviceToken: string, push: Push): Promise<void> {
    const host = this.config.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const visible = push.kind === "wake";
    const payload = visible
      ? { aps: { alert: { title: "Steward", body: "An errand is ready for its next step." }, sound: "default" }, case: push.caseId }
      : { aps: { "content-available": 1 } };
    const res = await this.fetcher(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.token()}`,
        "apns-topic": this.config.topic,
        "apns-push-type": visible ? "alert" : "background",
        "apns-priority": visible ? "10" : "5",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) throw new Error(`APNs answered ${res.status}`);
  }

  /** APNs wants a fresh ES256 token at most hourly; reuse one for 50 minutes. */
  private async token(): Promise<string> {
    const nowSec = Math.floor(this.now() / 1000);
    if (this.jwt && nowSec - this.jwt.at < 50 * 60) return this.jwt.token;
    const url = (s: string) => btoa(s).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
    const header = url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const claims = url(JSON.stringify({ iss: this.config.teamId, iat: nowSec }));
    const der = this.config.keyPem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(der), (c) => c.charCodeAt(0)), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
    const token = `${header}.${claims}.${b64(sig).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")}`;
    this.jwt = { token, at: nowSec };
    return token;
  }
}
