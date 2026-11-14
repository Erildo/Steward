// The Worker: wires the relay to Cloudflare's fetch, email and cron handlers.

import { ApnsPusher, NoPusher, ResendMailer, type Mailer } from "./outbound.ts";
import { Relay, type Config } from "./relay.ts";
import { D1Store } from "./store.ts";

export interface Env {
  DB: D1Database;
  MAIL_DOMAIN: string;
  TRUSTED_AUTHSERV_ID: string;
  MODEL_BASE_URL: string;
  MODEL_ALLOW: string;
  MODEL_DAILY_REQUESTS: string;
  APNS_TOPIC: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_SANDBOX: string;
  // Secrets
  RESEND_API_KEY?: string;
  OPENROUTER_API_KEY?: string;
  APNS_KEY?: string;
  REGISTRATION_SECRET?: string;
  /** Local development only (.dev.vars): log sends instead of mailing. */
  DEV_LOG_MAIL?: string;
}

const noMailer: Mailer = {
  async send() {
    throw new Error("RESEND_API_KEY is not set");
  },
};

/** For `wrangler dev` only: says what would go out, sends nothing. Only the
 * addresses and subject are printed, in the developer's own terminal. */
const devMailer: Mailer = {
  async send(email) {
    console.log(`[dev] would send ${email.idempotencyKey}: ${email.from} -> ${email.to}: ${email.subject}`);
    return `dev-${email.idempotencyKey}`;
  },
};

export function relayFor(env: Env): Relay {
  const config: Config = {
    mailDomain: env.MAIL_DOMAIN.toLowerCase(),
    trustedAuthservId: env.TRUSTED_AUTHSERV_ID,
    modelBaseURL: env.MODEL_BASE_URL.replace(/\/+$/, ""),
    modelKey: env.OPENROUTER_API_KEY || null,
    modelAllow: env.MODEL_ALLOW.split(",").map((s) => s.trim()).filter(Boolean),
    modelDailyRequests: Number(env.MODEL_DAILY_REQUESTS) || 300,
    registrationSecret: env.REGISTRATION_SECRET || null,
  };
  const pusher = env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID
    ? new ApnsPusher({ keyPem: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC, sandbox: env.APNS_SANDBOX !== "false" })
    : new NoPusher();
  const mailer = env.RESEND_API_KEY ? new ResendMailer(env.RESEND_API_KEY) : env.DEV_LOG_MAIL === "true" ? devMailer : noMailer;
  return new Relay(new D1Store(env.DB), mailer, pusher, config);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return relayFor(env).fetch(request);
  },

  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    await relayFor(env).receive({ to: message.to, from: message.from, raw, reject: (reason) => message.setReject(reason) });
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(relayFor(env).tick());
  },
} satisfies ExportedHandler<Env>;
