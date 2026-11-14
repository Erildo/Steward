// The DKIM verdict on an incoming email, read from the receiving server's
// Authentication-Results header (RFC 8601).
//
// Anyone can write an Authentication-Results header into an email they send,
// so only the topmost one, added by our own receiving server, counts, and
// only if it names that server (`trustedAuthservId`). The relay reads it
// before sealing the email and seals the verdict with it, so a company's
// "we confirm your cancellation" only counts as proof if the company's own
// domain signed it (docs/adr/0002, decision 3).

export interface DkimVerdict {
  /** Domains (d=) whose DKIM signature passed. */
  pass: string[];
  /** The server that gave the verdict, or null if no trusted header was found. */
  authservId: string | null;
}

/** The raw header block: everything before the first empty line, unfolded. */
export function headerLines(raw: string): string[] {
  const end = raw.search(/\r?\n\r?\n/);
  const block = end === -1 ? raw : raw.slice(0, end);
  const lines: string[] = [];
  for (const line of block.split(/\r?\n/)) {
    if (/^[ \t]/.test(line) && lines.length > 0) {
      lines[lines.length - 1] += " " + line.trim();
    } else {
      lines.push(line);
    }
  }
  return lines;
}

/** Drops (comments) from a header value, which may hold misleading text. */
function stripComments(value: string): string {
  let out = "";
  let depth = 0;
  for (const ch of value) {
    if (ch === "(") depth++;
    else if (ch === ")" && depth > 0) depth--;
    else if (depth === 0) out += ch;
  }
  return out;
}

export function dkimVerdict(raw: string, trustedAuthservId: string): DkimVerdict {
  const first = headerLines(raw).find((l) => /^authentication-results\s*:/i.test(l));
  if (!first) return { pass: [], authservId: null };
  const value = stripComments(first.slice(first.indexOf(":") + 1)).trim();
  const [authserv, ...results] = value.split(";").map((s) => s.trim());
  const id = (authserv ?? "").split(/\s+/)[0]?.toLowerCase() ?? "";
  if (id !== trustedAuthservId.toLowerCase()) return { pass: [], authservId: null };

  const pass = new Set<string>();
  for (const result of results) {
    const m = /^dkim\s*=\s*pass\b(.*)$/i.exec(result);
    if (!m) continue;
    const d = /(?:^|\s)header\.d\s*=\s*"?([a-z0-9.-]+)"?/i.exec(m[1] ?? "");
    if (d?.[1]) pass.add(d[1].toLowerCase());
  }
  return { pass: [...pass].sort(), authservId: id };
}

/** True when the company's domain, or one of its subdomains (such as
 * mail.company.example), signed the email. A parent domain doesn't count. */
export function signedBy(verdict: DkimVerdict, domain: string): boolean {
  const want = domain.toLowerCase();
  return verdict.pass.some((d) => d === want || d.endsWith("." + want));
}
