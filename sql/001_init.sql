BEGIN;

CREATE TYPE routing_mode AS ENUM ('softphone', 'voicemail', 'forward');
CREATE TYPE e911_state  AS ENUM ('unregistered', 'pending', 'provisioned', 'failed');
CREATE TYPE topup_source AS ENUM ('stripe', 'manual');

CREATE TABLE domains (
  id          bigserial PRIMARY KEY,
  domain      text NOT NULL UNIQUE,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE extensions (
  id             bigserial PRIMARY KEY,
  domain_id      bigint NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
  extension      text NOT NULL,
  sip_password   text NOT NULL,
  vm_password    text NOT NULL,
  display_name   text,
  routing_mode   routing_mode NOT NULL DEFAULT 'voicemail',
  forward_number text,
  vm_email       text,
  accountcode    text NOT NULL UNIQUE,
  balance        numeric(10,4) NOT NULL DEFAULT 0,
  nibble_rate    numeric(10,4) NOT NULL DEFAULT 0.02,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),

  UNIQUE (domain_id, extension),
  CONSTRAINT extension_digits CHECK (extension ~ '^[0-9]{2,10}$'),
  CONSTRAINT vm_password_present CHECK (length(vm_password) > 0),
  CONSTRAINT forward_needs_number
    CHECK (routing_mode <> 'forward' OR forward_number IS NOT NULL),
  -- defence in depth behind the P12 validation: forwarding to an emergency
  -- number would route around route_emergency entirely
  CONSTRAINT forward_not_emergency
    CHECK (forward_number IS NULL OR forward_number !~ '^\+?1?(911|933|112|999|000)$')
);

CREATE TABLE dids (
  id              bigserial PRIMARY KEY,
  e164            text NOT NULL UNIQUE,
  domain_id       bigint NOT NULL REFERENCES domains(id) ON DELETE RESTRICT,
  extension_id    bigint REFERENCES extensions(id) ON DELETE SET NULL,
  is_primary      boolean NOT NULL DEFAULT false,
  e911_status     e911_state NOT NULL DEFAULT 'unregistered',
  e911_address    text,
  e911_updated_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT e164_digits CHECK (e164 ~ '^[0-9]{10,15}$')
);

-- exactly one primary DID per extension: this is the number presented on a 911
-- call and the one whose e911_status gates activation
CREATE UNIQUE INDEX dids_one_primary_per_extension
  ON dids (extension_id) WHERE is_primary;

CREATE INDEX dids_extension_id ON dids (extension_id);

CREATE TABLE topups (
  id           bigserial PRIMARY KEY,
  extension_id bigint NOT NULL REFERENCES extensions(id) ON DELETE RESTRICT,
  amount       numeric(10,4) NOT NULL CHECK (amount > 0),
  source       topup_source NOT NULL,
  reference    text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX topups_extension_created ON topups (extension_id, created_at DESC);

-- stripe event id as PK is the idempotency mechanism: a duplicate insert
-- inside the credit transaction means already processed
CREATE TABLE stripe_events (
  event_id     text PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE vm_retention (
  message_uuid uuid PRIMARY KEY,
  extension_id bigint NOT NULL REFERENCES extensions(id) ON DELETE CASCADE,
  deposited_at timestamptz NOT NULL,
  last_folder  text NOT NULL DEFAULT 'inbox',
  retain_until timestamptz NOT NULL
);

CREATE INDEX vm_retention_expiry ON vm_retention (retain_until);

-- Written by mod_odbc_cdr. Epoch integers rather than timestamps: an unanswered
-- call yields an empty answer stamp, and '' will not cast to timestamptz, which
-- would fail the insert and lose the record. nibble_total is text for the same
-- reason on unbilled paths.
CREATE TABLE cdrs (
  id                     bigserial PRIMARY KEY,
  uuid                   text NOT NULL,
  bleg_uuid              text,
  domain                 text,
  accountcode            text,
  direction              text,
  caller_id_number       text,
  destination_number     text,
  start_epoch            bigint,
  answer_epoch           bigint,
  end_epoch              bigint,
  duration               integer,
  billsec                integer,
  hangup_cause           text,
  sip_hangup_disposition text,
  routing_mode           text,
  balance_state          text,
  nibble_total           text,
  gateway                text
);

CREATE INDEX cdrs_account_start ON cdrs (accountcode, start_epoch DESC);
CREATE INDEX cdrs_uuid ON cdrs (uuid);
CREATE INDEX cdrs_start_epoch ON cdrs (start_epoch);

COMMIT;
