-- What the relay keeps. Nothing here can be read as an errand: mail is
-- sealed to the owner's phone on arrival, sends keep no body, and a wake is
-- only a case and a time.

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,  -- SHA-256 of the bearer token; the token itself is never stored
  public_key TEXT NOT NULL,         -- X25519, base64: incoming mail is sealed to it
  push_token TEXT,                  -- APNs device token
  created_at INTEGER NOT NULL
);

CREATE TABLE cases (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  address TEXT NOT NULL UNIQUE,     -- the case's own mailbox
  created_at INTEGER NOT NULL,
  closed_at INTEGER                 -- once set, mail to the address is refused
);

CREATE TABLE inbox (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  case_id TEXT NOT NULL REFERENCES cases(id),
  envelope TEXT NOT NULL,           -- sealed; only the phone can open it
  received_at INTEGER NOT NULL
);
CREATE INDEX inbox_device ON inbox(device_id, received_at);

CREATE TABLE sends (
  send_id TEXT PRIMARY KEY,         -- from the phone; a second send with it returns the first result
  device_id TEXT NOT NULL REFERENCES devices(id),
  case_id TEXT NOT NULL REFERENCES cases(id),
  status TEXT NOT NULL,             -- sending | sent
  message_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE wakes (
  case_id TEXT PRIMARY KEY REFERENCES cases(id),
  device_id TEXT NOT NULL REFERENCES devices(id),
  at INTEGER NOT NULL               -- when to show the owner a notification; never why
);
CREATE INDEX wakes_due ON wakes(at);

CREATE TABLE usage (
  device_id TEXT NOT NULL REFERENCES devices(id),
  day TEXT NOT NULL,
  requests INTEGER NOT NULL,
  PRIMARY KEY (device_id, day)
);
