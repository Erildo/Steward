// What the relay keeps, behind one interface: D1 in production, memory in tests.

export interface Device {
  id: string;
  tokenHash: string;
  publicKey: string;
  pushToken: string | null;
  createdAt: number;
}

export interface CaseRow {
  id: string;
  deviceId: string;
  address: string;
  createdAt: number;
  closedAt: number | null;
}

export interface InboxItem {
  id: string;
  deviceId: string;
  caseId: string;
  envelope: string;
  receivedAt: number;
}

export interface SendRow {
  sendId: string;
  deviceId: string;
  caseId: string;
  status: "sending" | "sent";
  messageId: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface Wake {
  caseId: string;
  deviceId: string;
  at: number;
}

export interface Store {
  addDevice(device: Device): Promise<void>;
  deviceByTokenHash(hash: string): Promise<Device | null>;
  device(id: string): Promise<Device | null>;
  setPushToken(deviceId: string, token: string | null): Promise<void>;

  addCase(row: CaseRow): Promise<void>;
  caseById(id: string): Promise<CaseRow | null>;
  caseByAddress(address: string): Promise<CaseRow | null>;
  closeCase(id: string, at: number): Promise<void>;

  addInbox(item: InboxItem): Promise<void>;
  inbox(deviceId: string, limit: number): Promise<InboxItem[]>;
  /** Deletes the device's items with these ids; others' items are untouched. */
  ack(deviceId: string, ids: string[]): Promise<number>;
  dropInboxForCase(caseId: string): Promise<void>;

  send(sendId: string): Promise<SendRow | null>;
  /** Inserts a new "sending" row. Returns false if the send ID already exists. */
  startSend(row: SendRow): Promise<boolean>;
  finishSend(sendId: string, messageId: string, at: number): Promise<void>;

  setWake(wake: Wake): Promise<void>;
  clearWake(caseId: string): Promise<void>;
  /** Removes and returns every wake due at or before `now`. */
  takeDueWakes(now: number, limit: number): Promise<Wake[]>;

  /** Adds one to today's count and returns the new count. */
  countRequest(deviceId: string, day: string): Promise<number>;
}

export class MemoryStore implements Store {
  devices = new Map<string, Device>();
  cases = new Map<string, CaseRow>();
  items = new Map<string, InboxItem>();
  sends = new Map<string, SendRow>();
  wakes = new Map<string, Wake>();
  usage = new Map<string, number>();

  async addDevice(d: Device) { this.devices.set(d.id, { ...d }); }
  async deviceByTokenHash(hash: string) { return [...this.devices.values()].find((d) => d.tokenHash === hash) ?? null; }
  async device(id: string) { return this.devices.get(id) ?? null; }
  async setPushToken(id: string, token: string | null) {
    const d = this.devices.get(id);
    if (d) d.pushToken = token;
  }

  async addCase(row: CaseRow) {
    if ([...this.cases.values()].some((c) => c.address === row.address)) throw new Error("address taken");
    this.cases.set(row.id, { ...row });
  }
  async caseById(id: string) { return this.cases.get(id) ?? null; }
  async caseByAddress(address: string) { return [...this.cases.values()].find((c) => c.address === address) ?? null; }
  async closeCase(id: string, at: number) {
    const c = this.cases.get(id);
    if (c) c.closedAt = at;
  }

  async addInbox(item: InboxItem) { this.items.set(item.id, { ...item }); }
  async inbox(deviceId: string, limit: number) {
    return [...this.items.values()].filter((i) => i.deviceId === deviceId).sort((a, b) => a.receivedAt - b.receivedAt).slice(0, limit);
  }
  async ack(deviceId: string, ids: string[]) {
    let n = 0;
    for (const id of ids) {
      if (this.items.get(id)?.deviceId === deviceId) {
        this.items.delete(id);
        n++;
      }
    }
    return n;
  }
  async dropInboxForCase(caseId: string) {
    for (const [id, item] of this.items) if (item.caseId === caseId) this.items.delete(id);
  }

  async send(sendId: string) { return this.sends.get(sendId) ?? null; }
  async startSend(row: SendRow) {
    if (this.sends.has(row.sendId)) return false;
    this.sends.set(row.sendId, { ...row });
    return true;
  }
  async finishSend(sendId: string, messageId: string, at: number) {
    const s = this.sends.get(sendId);
    if (s) Object.assign(s, { status: "sent", messageId, updatedAt: at });
  }

  async setWake(w: Wake) { this.wakes.set(w.caseId, { ...w }); }
  async clearWake(caseId: string) { this.wakes.delete(caseId); }
  async takeDueWakes(now: number, limit: number) {
    const due = [...this.wakes.values()].filter((w) => w.at <= now).sort((a, b) => a.at - b.at).slice(0, limit);
    for (const w of due) this.wakes.delete(w.caseId);
    return due;
  }

  async countRequest(deviceId: string, day: string) {
    const key = `${deviceId}/${day}`;
    const n = (this.usage.get(key) ?? 0) + 1;
    this.usage.set(key, n);
    return n;
  }
}

type Row = Record<string, unknown>;

export class D1Store implements Store {
  constructor(private db: D1Database) {}

  private static device(r: Row): Device {
    return { id: r.id as string, tokenHash: r.token_hash as string, publicKey: r.public_key as string, pushToken: (r.push_token as string) ?? null, createdAt: r.created_at as number };
  }
  private static caseRow(r: Row): CaseRow {
    return { id: r.id as string, deviceId: r.device_id as string, address: r.address as string, createdAt: r.created_at as number, closedAt: (r.closed_at as number) ?? null };
  }
  private static sendRow(r: Row): SendRow {
    return { sendId: r.send_id as string, deviceId: r.device_id as string, caseId: r.case_id as string, status: r.status as SendRow["status"], messageId: (r.message_id as string) ?? null, createdAt: r.created_at as number, updatedAt: r.updated_at as number };
  }

  async addDevice(d: Device) {
    await this.db.prepare("INSERT INTO devices (id, token_hash, public_key, push_token, created_at) VALUES (?, ?, ?, ?, ?)")
      .bind(d.id, d.tokenHash, d.publicKey, d.pushToken, d.createdAt).run();
  }
  async deviceByTokenHash(hash: string) {
    const r = await this.db.prepare("SELECT * FROM devices WHERE token_hash = ?").bind(hash).first<Row>();
    return r ? D1Store.device(r) : null;
  }
  async device(id: string) {
    const r = await this.db.prepare("SELECT * FROM devices WHERE id = ?").bind(id).first<Row>();
    return r ? D1Store.device(r) : null;
  }
  async setPushToken(id: string, token: string | null) {
    await this.db.prepare("UPDATE devices SET push_token = ? WHERE id = ?").bind(token, id).run();
  }

  async addCase(c: CaseRow) {
    await this.db.prepare("INSERT INTO cases (id, device_id, address, created_at, closed_at) VALUES (?, ?, ?, ?, ?)")
      .bind(c.id, c.deviceId, c.address, c.createdAt, c.closedAt).run();
  }
  async caseById(id: string) {
    const r = await this.db.prepare("SELECT * FROM cases WHERE id = ?").bind(id).first<Row>();
    return r ? D1Store.caseRow(r) : null;
  }
  async caseByAddress(address: string) {
    const r = await this.db.prepare("SELECT * FROM cases WHERE address = ?").bind(address).first<Row>();
    return r ? D1Store.caseRow(r) : null;
  }
  async closeCase(id: string, at: number) {
    await this.db.prepare("UPDATE cases SET closed_at = ? WHERE id = ?").bind(at, id).run();
  }

  async addInbox(i: InboxItem) {
    await this.db.prepare("INSERT INTO inbox (id, device_id, case_id, envelope, received_at) VALUES (?, ?, ?, ?, ?)")
      .bind(i.id, i.deviceId, i.caseId, i.envelope, i.receivedAt).run();
  }
  async inbox(deviceId: string, limit: number) {
    const { results } = await this.db.prepare("SELECT * FROM inbox WHERE device_id = ? ORDER BY received_at LIMIT ?").bind(deviceId, limit).all<Row>();
    return results.map((r) => ({ id: r.id as string, deviceId: r.device_id as string, caseId: r.case_id as string, envelope: r.envelope as string, receivedAt: r.received_at as number }));
  }
  async ack(deviceId: string, ids: string[]) {
    let n = 0;
    for (const id of ids) {
      const res = await this.db.prepare("DELETE FROM inbox WHERE id = ? AND device_id = ?").bind(id, deviceId).run();
      n += res.meta.changes ?? 0;
    }
    return n;
  }
  async dropInboxForCase(caseId: string) {
    await this.db.prepare("DELETE FROM inbox WHERE case_id = ?").bind(caseId).run();
  }

  async send(sendId: string) {
    const r = await this.db.prepare("SELECT * FROM sends WHERE send_id = ?").bind(sendId).first<Row>();
    return r ? D1Store.sendRow(r) : null;
  }
  async startSend(s: SendRow) {
    const res = await this.db.prepare("INSERT OR IGNORE INTO sends (send_id, device_id, case_id, status, message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .bind(s.sendId, s.deviceId, s.caseId, s.status, s.messageId, s.createdAt, s.updatedAt).run();
    return (res.meta.changes ?? 0) === 1;
  }
  async finishSend(sendId: string, messageId: string, at: number) {
    await this.db.prepare("UPDATE sends SET status = 'sent', message_id = ?, updated_at = ? WHERE send_id = ?").bind(messageId, at, sendId).run();
  }

  async setWake(w: Wake) {
    await this.db.prepare("INSERT INTO wakes (case_id, device_id, at) VALUES (?, ?, ?) ON CONFLICT(case_id) DO UPDATE SET at = excluded.at")
      .bind(w.caseId, w.deviceId, w.at).run();
  }
  async clearWake(caseId: string) {
    await this.db.prepare("DELETE FROM wakes WHERE case_id = ?").bind(caseId).run();
  }
  async takeDueWakes(now: number, limit: number) {
    const { results } = await this.db.prepare("DELETE FROM wakes WHERE case_id IN (SELECT case_id FROM wakes WHERE at <= ? ORDER BY at LIMIT ?) RETURNING case_id, device_id, at")
      .bind(now, limit).all<Row>();
    return results.map((r) => ({ caseId: r.case_id as string, deviceId: r.device_id as string, at: r.at as number }));
  }

  async countRequest(deviceId: string, day: string) {
    const r = await this.db.prepare("INSERT INTO usage (device_id, day, requests) VALUES (?, ?, 1) ON CONFLICT(device_id, day) DO UPDATE SET requests = requests + 1 RETURNING requests")
      .bind(deviceId, day).first<Row>();
    return (r?.requests as number) ?? 1;
  }
}
