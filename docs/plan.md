# iqfone-lite — build plan

## What this is

A deliberately minimal hosted PBX. FreeSWITCH + PostgreSQL on a single Vultr instance.
Inbound calls reach exactly three terminations — **softphone**, **voicemail**, or
**call-forward**. No IVR, no queues, no conferencing, no transcription. Scoped for
immediate launch.

Derived from `docs/scratch.md`.

## Two corrections to the brief

1. **"Use the existing FreeSWITCH database schemas" only half-works.** FreeSWITCH's
   core schema (`core-db-dsn`) stores *runtime state* — registrations, channels,
   dialog state — and mod_voicemail owns its own message tables. There is no stock
   table for "which extensions exist and what is each one's password." A provisioning
   schema is unavoidable — it started at three tables and grew to seven as billing,
   CDRs and voicemail retention were added (P3). FreeSWITCH's own tables are still
   left entirely stock, which is the spirit of the request.
2. **BulkVS trunk hostnames/IPs must come from the BulkVS portal**, not from this
   document. Public docs don't pin them down. What follows describes
   IP-authenticated trunking (the normal BulkVS model — whitelist the server IP,
   `register=false`) and leaves the endpoints as a fill-in step.

## Architecture

```
BulkVS trunk (IP-auth)
        │  SIP/RTP
        ▼
  ┌──────────────────────────────────────────┐
  │ Vultr KVM instance                       │
  │                                          │
  │  FreeSWITCH                              │
  │   ├─ sofia "external"  ← BulkVS          │
  │   ├─ sofia "internal"  ← softphones      │
  │   ├─ mod_lua (directory handler)         │──► PostgreSQL
  │   ├─ mod_pgsql  (core state)             │──►
  │   ├─ mod_nibblebill (meters balance)     │──►
  │   ├─ mod_odbc_cdr  (call records)        │──►
  │   └─ mod_voicemail ──► local disk, MWI   │
  │                            │             │
  │                          msmtp           │
  │                            │             │
  │  provisioning service (HTTPS) ───────────│──► PostgreSQL
  │   ├─ /prov/*   ← billing system          │
  │   ├─ Stripe webhook                      │
  │   └─ BulkVS E911 webhook                 │
  └────────────────────────────┼─────────────┘
                               │ SMTP 465, implicit TLS
                               ▼
                  Cloudflare Email Sending
```

Voicemail audio never leaves the box. Cloudflare handles only outbound notification
mail, so there is no IP reputation to build and no OpenDKIM to run.

Two paths, deliberately separate: **the call path** (sofia → Lua directory → Postgres)
must never depend on the **control path** (provisioning service). The provisioning
service can be down for an hour and every call still works.

Custom surface is small and intentional: **the dynamic directory** and **the
dialplans**. Everything else is stock FreeSWITCH.

## Phases

### P0 — Host baseline
- Debian 12 on Vultr, behind a **Reserved IP** — provision it before BulkVS is
  configured (P13). Retrofitting means a coordinated carrier change for no benefit.
- **Pick a dedicated-CPU plan, not shared vCPU.** Real-time media is sensitive to
  CPU steal — on an oversubscribed shared instance it shows up as jitter and choppy
  audio, and it is miserable to diagnose after the fact. Vultr's Regular Cloud
  Compute is shared; Optimized Cloud / dedicated is what this wants.
- Choose the region by latency to the BulkVS ingress, not by proximity to you.
- Vultr bills bandwidth over the plan allowance. Audio is ~85 kbps per concurrent
  call each way — irrelevant at launch scale, worth watching as channels grow.
- `nftables`: allow 5061/tcp (softphone TLS) and 5060/udp (BulkVS only, P5), plus the
  RTP range (e.g. 16384–32768/udp) from BulkVS IPs
  and from softphone clients; SSH restricted; outbound 465/tcp for mail submission;
  drop everything else.
- No outbound :25 needed and no rDNS/PTR to arrange — mail goes out through
  Cloudflare over authenticated submission (P10), not direct-to-MX. This removes the
  provider port-25 unblock request that would otherwise sit on the critical path.
- Disk: voicemail is MP3 on a 30-day window (P10), ~1.2 MB per full-length message —
  single-digit GB at launch scale. Not a sizing constraint, but the pruning job is
  what keeps it that way.
- `fail2ban` with the FreeSWITCH jail, plus sofia ACLs. A PBX on a public IP is
  scanned within minutes.

### P1 — PostgreSQL
- Install, create `freeswitch` role + DB, `scram-sha-256`, listen on localhost only.
- Two logical areas in one DB: FreeSWITCH's own state tables (auto-created) and the
  provisioning schema from P3.

### P2 — FreeSWITCH install
- **Gotcha:** the SignalWire apt repo requires a Personal Access Token. Create a
  SignalWire Space → Personal Access Tokens → generate; use it as the HTTP-auth
  password when fetching the repo key and in `/etc/apt/auth.conf.d/`. Building from
  GitHub source needs no token but costs time — take the packages.
- Modules to enable in `modules.conf.xml`: `mod_sofia`, `mod_dialplan_xml`,
  `mod_lua`, `mod_pgsql`, `mod_voicemail`, `mod_db`, `mod_dptools`,
  `mod_sndfile`, `mod_shout` (MP3 voicemail, P10), `mod_nibblebill`,
  `mod_odbc_cdr` (P9), codecs (`mod_g711` implicit, `mod_opus`).
  Not `mod_xml_curl` — the directory is served by Lua in-process (P4).
  Disable the demo stuff: `mod_conference`, `mod_fifo`, `mod_callcenter`, `mod_verto`.
- **Delete the stock `conf/directory/default/*.xml` demo users (1000–1019) and the
  `conf/dialplan/default.xml` demo extensions.** They are a live toll-fraud path.

### P3 — Provisioning schema (the only custom tables)

**Tenancy: tenant-capable schema, one tenant live at launch.** The `domains` table
stays and **no realm is ever hardcoded** — directory lookups, voicemail, and dialplans
all resolve `${domain_name}` at runtime. Only one domain gets provisioned until a
second customer exists. FreeSWITCH is natively domain-scoped so this costs nothing
now, and it avoids a migration of every extension, DID mapping, and registered client
later. Anything that hardcodes a domain is a bug, not a shortcut.

- `domains` — id, domain (the SIP realm), active
- `extensions` — id, domain_id, extension, sip_password (or A1 hash), display_name,
  `routing_mode` enum(`softphone`|`voicemail`|`forward`), `forward_number`,
  `vm_email`, `vm_password`, `accountcode`, `balance` numeric(10,4),
  `nibble_rate` numeric(10,4), active
  - `vm_password` is the mailbox PIN, **separate from `sip_password`** and mandatory —
    it is what `*98` authenticates against. Generate one at provisioning; never leave
    it null (see P10).
- `dids` — id, e164, domain_id, extension_id (the inbound mapping),
  `e911_status` enum(`unregistered`|`pending`|`provisioned`|`failed`),
  `e911_address` (as registered with BulkVS), `e911_updated_at`, `is_primary`
  - `e911_status` gates **service activation, never 911 itself** (P6, P7).
  - An extension may hold more than one DID, but exactly **one is `is_primary`** — that
    is the number presented on a 911 call and the one whose `e911_status` gates
    activation. Without this the directory handler has no defined answer to "which
    address does dispatch get," which is not a question to leave to a `LIMIT 1`.
    Enforce one primary per extension in the schema, and require it before activation.
- `topups` — id, extension_id, amount, source (`stripe`|`manual`), reference,
  created_at. Every credit writes a row; `balance` is never adjusted bare. Makes
  balance derivable and disputes answerable.
- `stripe_events` — stripe event id as **primary key**, processed_at. The dedupe
  table; see P8.
- `vm_retention` — message_uuid PK, extension_id, deposited_at, last_folder,
  retain_until. Our retention clock for voicemail; mod_voicemail's own tables are
  never written to. See P10.
- `cdrs` — one row per call leg, written by `mod_odbc_cdr`. Schema in P9.

`routing_mode` is the whole product. Everything the dialplan decides comes from that
column plus `forward_number` — gated by `balance` (P8).

`balance` lives on `extensions` so mod_nibblebill can decrement it directly
(`db_table=extensions`, `db_column_account=accountcode`, `db_column_cash=balance`)
with no second table to reconcile.

### P4 — Dynamic directory (`mod_lua`)

The auth surface. **Nothing on the network path of an authentication** — no HTTP hop,
no separate process: `mod_lua` is bound to the `directory` section and queries Postgres
in-process. **`mod_xml_curl` is not used.**

(The provisioning service in P12 is a separate HTTP service, but it is deliberately
*off* the call and auth path — it can be down without affecting a single call. That
distinction is the whole reason the split exists.)

`autoload_configs/lua.conf.xml` — order matters, the script param must come first:
```xml
<configuration name="lua.conf" description="LUA Configuration">
  <settings>
    <param name="script-directory" value="$${script_dir}/?.lua"/>
    <param name="xml-handler-script" value="directory.lua"/>
    <param name="xml-handler-bindings" value="directory"/>
  </settings>
</configuration>
```

- Bind **`directory` only**. Dialplans stay static XML — a fixed 3-branch tree that
  doesn't need a lookup per call.
- The handler reads `XML_REQUEST` (`.section`, `.key_name`, `.key_value`) plus the
  `params` event, and must set the global `XML_STRING` to a
  `<document type="freeswitch/xml">` blob before returning.
- Postgres via `freeswitch.Dbh("pgsql://...")` — same DSN shape as `core-db-dsn`,
  requires `mod_pgsql`.

Per-user variables the handler must emit, so the dialplan reads everything off the
channel with no second lookup:

| Variable | Source | Used by |
|---|---|---|
| `routing_mode`, `forward_number` | `extensions` | P7 routing branch |
| `balance_state` (`ok`\|`zero`) | derived from `balance > 0` | P7 gates |
| `nibble_account`, `nibble_rate` | `extensions` | P8 metering |
| `vm-mailto`, `vm-email-all-messages`, `vm-attach-file` | `vm_email` | P10 notification |
| `vm-password` | `vm_password` | `*98` login, greeting recording (P10) |
| `e911_status`, `e911_did` | `dids` (the extension's **primary** DID) | P7 emergency route and activation gate |

`balance_state` is derived **here**, not in the dialplan — the dialplan branches on a
flag, never on an amount.

**This runs inside FreeSWITCH, in the auth path of every registration and INVITE.**
That is the tradeoff accepted by dropping the separate service, and it sets three
hard requirements:

1. **Wrap everything in `pcall`.** An uncaught Lua error takes out authentication
   itself — there is no service to restart independently. On any failure, emit the
   not-found document and log loudly. Never let an exception propagate.
2. **Never block.** Postgres is on localhost; still set a short statement timeout and
   treat a slow query as a failure rather than waiting. A stalled handler stalls
   registrations.
3. **Handle both request shapes** — `action=sip_auth` (registration and INVITE auth)
   and the plain user lookup. Return the not-found document for unknown users, not an
   error.

Cache reads in a module-level table with a short TTL, invalidated on write from the
admin path. Balance changes constantly, so either keep `balance_state` out of the
cache or keep the TTL to a few seconds.

Debuggability is the known weak point of this choice. Budget for it: keep the SQL and
XML generation in functions that can be exercised by `luarun` from `fs_cli`
independently of a live call, and log every lookup at debug level behind a flag.

### P5 — Sofia profiles
- `internal` — softphone registrations, auth required, `context=default`,
  **TLS + SRTP** (below).
- `external` — BulkVS-facing, `context=public`, `auth-calls=false` with a **strict
  ACL limited to BulkVS source IPs**. Getting this wrong is the classic toll-fraud
  hole; verify with `sofia status profile external`.
- Point registration storage at Postgres: `core-db-dsn` in `switch.conf.xml`, e.g.
  `pgsql://hostaddr=127.0.0.1 dbname=freeswitch user=freeswitch password='...'`
  (requires `mod_pgsql` loaded before core DB init).

**TLS + SRTP on `internal`.** Softphones register from coffee shops, hotel wifi and
mobile networks, so an ACL protects nothing on the client side — plain UDP puts SIP
credentials and call audio in the clear on exactly the networks you don't control.
Registration passwords are the thing worth stealing for toll fraud.

```xml
<param name="tls"             value="true"/>
<param name="tls-only"        value="true"/>
<param name="tls-bind-params" value="transport=tls"/>
<param name="tls-sip-port"    value="5061"/>
<param name="tls-cert-dir"    value="/etc/freeswitch/tls"/>
<param name="tls-version"     value="tlsv1.2,tlsv1.3"/>
<param name="rtp-secure-media" value="true"/>
```

- `tls-only=true` closes the plaintext 5060 port on this profile. Do this **after**
  every client is migrated, not before — otherwise you lock out anything not yet
  reconfigured. Leave it false during onboarding, then flip it and re-verify.
- Drop `tlsv1` and `tlsv1.1` from the stock `tls-version` list; they are dead.
- Certificate: Let's Encrypt, concatenated key + fullchain into the file sofia
  expects under `tls-cert-dir`. **Renewal must reload the profile** — a certbot
  `deploy-hook` running `fs_cli -x "sofia profile internal restart"`. Without it
  everything works for 90 days and then every client fails to register at once.
  - A profile `restart` **drops every registration on that profile**. Clients
    re-register automatically, but it is a brief outage. Have the deploy-hook defer
    the restart to a quiet window rather than firing whenever certbot happens to run.
    Alert on cert expiry (P14) so a deferred restart that never happened is visible.
- Firewall: 5061/tcp inbound, not just 5060/udp (P0).
- `rtp-secure-media=true` negotiates SRTP where the client offers it. Go to
  `mandatory` only once you have confirmed every client in the field supports it.
- Test with two different softphones before launch. TLS/SRTP interop is where cheap
  clients misbehave, and it is much cheaper to find that now than after provisioning.

**Addressing and NAT.** The server is not behind NAT, but the clients are, and the
Reserved IP (P13) makes the server side less automatic than it looks.

```xml
<param name="ext-sip-ip" value="<reserved-ip>"/>
<param name="ext-rtp-ip" value="<reserved-ip>"/>
```

- **Set these explicitly to the Reserved IP. Do not rely on auto-detection.** A Vultr
  Reserved IP is an additional address on the instance, so FreeSWITCH can advertise
  the instance's own primary address in `Contact` and SDP instead. The result is
  one-way audio and traffic arriving at BulkVS from an address it has not whitelisted
  — and it looks like a trunk problem, not an addressing one. This is the single most
  likely first-day fault in the whole build.
- Confirm outbound SIP actually **sources** from the Reserved IP, not just advertises
  it. Check what BulkVS sees, not what the config says.
- Never use `stun:` here. That is for clients behind NAT, not for a server with a
  public address.
- Client side: keep `rtp-auto-adjust` behaviour on so RTP follows the address the
  media really arrives from. TLS helps signalling — the TCP connection holds the NAT
  binding open — but **RTP is still UDP**, and a home router will close an idle
  binding.
- Set registration expiry low enough to keep bindings alive (~120–300s) and enable
  NAT options pings. Longer expiries look tidier and cause "calls don't ring the
  softphone" reports an hour later.
- One-way audio is almost always this. When it appears, check `ext-rtp-ip` before
  anything else.

### P6 — BulkVS trunk and E911

**Trunk**
- Gateway in the `external` profile, IP-authenticated: `register=false`, no
  username/password, `proxy` = BulkVS endpoint **from the portal**.
- Whitelist the **Reserved IP** (P13) in the BulkVS portal for outbound, never the
  instance's own address — that is what makes recovery a reassignment instead of a
  carrier ticket.
- Point purchased DIDs at the same Reserved IP for inbound.
- Outbound caller ID: set `effective_caller_id_number` to a DID the account owns, or
  BulkVS rejects the call.

**E911 — supported, via BulkVS**

Ownership split: the **billing system** (separate, outside this repo) handles signup,
payment, DID ordering, and E911 address registration through the BulkVS API. The PBX
owns routing. The contract between them is the `dids` table.

```
billing system ──order DID──► BulkVS
               ──register E911 address──►
                                   │
                        BulkVS webhook (status)
                                   ▼
                     webhook service on the box ──► dids.e911_status
                                                          │
                                          read by directory handler (P4)
```

1. **Registration flow.** Billing system orders the DID, submits the subscriber's
   dispatchable address to BulkVS, sets `e911_status='pending'`. BulkVS validates the
   address asynchronously — addresses fail validation regularly, so pending is a real
   state with a real duration, not a formality.
2. **Webhook.** BulkVS calls back with the provisioning result; the handler sets
   `provisioned` or `failed` and stamps `e911_updated_at`. Reuse the same HTTPS
   service that takes the Stripe webhook (P8) — and reuse its discipline: **verify the
   signature, and dedupe on the event id.** A replayed or forged status callback must
   not flip a DID to `provisioned`.
3. **Activation gate.** A DID that is not `provisioned` cannot place ordinary outbound
   calls. The directory handler emits `e911_status`, and P7 blocks non-emergency
   outbound with an announcement telling the user to complete address registration.
   **This gate never applies to 911.**
4. **`933` is left open deliberately** — it is BulkVS's E911 test number, which reads
   back the registered address. It is how a user confirms their own record, so it must
   work even while `e911_status` is `pending`.
5. **Nomadic use is the real risk.** A softphone travels; the registered address is
   where the user *said* they are, not where they are. RAY BAUM's Act wants a
   dispatchable location. At minimum: disclose this plainly at signup, make the update
   path obvious, and prompt for re-confirmation periodically. This is a product
   obligation, not something the dialplan can solve.
6. **Kari's Law notification.** Send an alert (email to the account owner and to you)
   whenever 911 is dialled. Cheap to implement off the same dialplan branch and
   expected of multi-line systems.
7. Do not bill 911 calls — the emergency branch unsets `nibble_account` (P7).

Exact BulkVS endpoint names, webhook payload shape and signature scheme come from
their API docs, not from this plan.

### P7 — Dialplans (the second custom surface)

**`public` context — inbound from BulkVS.** Match the DID → look up the owning
extension → set channel vars → transfer into `default`.

**`default` context.** Order matters — the emergency route is first and
unconditional, then the zero-balance short-circuit, then the three `routing_mode`
branches.

```xml
<extension name="route_emergency" continue="false">
  <condition field="destination_number" expression="^1?(911|933)$">
    <action application="unset" data="nibble_account"/>
    <action application="set" data="effective_caller_id_number=${e911_did}"/>
    <action application="set" data="hangup_after_bridge=true"/>
    <action application="bridge" data="sofia/gateway/bulkvs/${destination_number}"/>
  </condition>
</extension>

<extension name="zero_balance_inbound" continue="false">
  <condition field="${balance_state}" expression="^zero$">
    <action application="answer"/>
    <action application="playback" data="ivr/ivr-user_not_available.wav"/>
    <action application="voicemail" data="default ${domain_name} ${dest_ext}"/>
  </condition>
</extension>

<extension name="route_softphone" continue="true">
  <condition field="${routing_mode}" expression="^softphone$">
    <action application="bridge" data="user/${dest_ext}@${domain_name}"/>
  </condition>
</extension>

<extension name="route_forward">
  <condition field="${routing_mode}" expression="^forward$">
    <action application="set" data="nibble_account=${accountcode}"/>
    <action application="set" data="nibble_rate=${nibble_rate}"/>
    <action application="bridge" data="sofia/gateway/bulkvs/${forward_number}"/>
  </condition>
</extension>

<extension name="route_voicemail">
  <condition field="${routing_mode}" expression="^(voicemail|softphone)$">
    <action application="answer"/>
    <action application="voicemail" data="default ${domain_name} ${dest_ext}"/>
  </condition>
</extension>
```

**Conditions inside one `<extension>` are AND-ed**, so the three routing modes must be
three separate extensions — not three conditions in one.

- `route_softphone` carries `continue="true"`, which is what produces
  fall-through-to-voicemail on no answer, paired with `continue_on_fail=true` and
  `hangup_after_bridge=false`. Ring timeout ~20s.
- **`route_forward` is terminal — no `continue`.** Once the call is handed to the
  forward number, that destination owns the outcome: if it's a mobile, the carrier's
  own voicemail answers and the message lands there. This avoids messages scattering
  across two mailboxes, which is what happens if you try to race a mobile's ~20-25s
  voicemail timeout. Set `continue_on_fail=false` on this branch so an unreachable
  gateway returns a real SIP cause to the caller rather than dead air.
- **`route_forward` must be billed.** It bridges out to the PSTN exactly like a dialled
  call and costs you carrier minutes, so it sets `nibble_account` and `nibble_rate`
  before bridging. Leaving it unbilled would make call-forward a free outbound route —
  and a user could point `forward_number` at an international or premium-rate number
  and pump money out on every inbound call, with no compromised credential required.
  P11's rule holds here: an unbilled path is an unlimited path.
- **`forward_number` is subject to the same destination policy as a dialled number** —
  international and premium-rate prefixes blocked unless allow-listed, not merely
  emergency numbers. Enforced at write time in P12, because the dialplan branch above
  does not re-check it.
- Zero balance is already handled: `zero_balance_inbound` fires first, so a caller
  reaches voicemail rather than triggering an unpayable forward leg.
- `route_voicemail` matches `^(voicemail|softphone)$` — deliberately not `forward`.

**Emergency calling: route it, always.** `route_emergency` is **first in the context
and unconditional**. Every gate in this system sits behind it.

- **Never gated on balance.** A user at $0 reaches 911. The branch is ahead of
  `zero_balance_inbound` for exactly this reason, and it unsets `nibble_account` so
  nibblebill cannot cut the call mid-sentence or charge for it.
- **Never gated on `e911_status`.** An unprovisioned or failed address must still
  route — an unregistered 911 call reaches a national call center, which is vastly
  better than a refusal. `e911_status` gates *ordinary outbound*, below.
- **Caller ID must be the E911-registered DID.** `effective_caller_id_number` =
  `e911_did` from the directory (P4). Get this wrong and dispatch is sent to the wrong
  address — the single most dangerous bug in this file.
- `933` rides the same branch: it is BulkVS's test number and reads the registered
  address back to the caller.
- Trigger the Kari's Law notification (P6) off this branch.
- **`forward_number` must reject emergency numbers at provisioning.** Otherwise a user
  sets call-forward to 911 and the forward branch bridges it to BulkVS with the wrong
  caller ID and no emergency handling. Validate on write, not just in the dialplan.

**Activation gate — ordinary outbound only.** Until the DID's `e911_status` is
`provisioned`, non-emergency outbound is refused with an announcement directing the
user to finish address registration. This goes in the `outbound` extension, ahead of
the balance check, and must never shadow `route_emergency`:

```xml
<condition field="${e911_status}" expression="^provisioned$" break="never">
  <anti-action application="answer"/>
  <anti-action application="playback" data="custom/e911-registration-required.wav"/>
  <anti-action application="hangup" data="SERVICE_UNAVAILABLE"/>
</condition>
```

Both announcements are **custom prompts you must record** — no stock FreeSWITCH file
says either thing.

**Outbound**, with the balance guard and nibblebill vars in one condition —
`anti-action` fires on non-match:

```xml
<extension name="outbound">
  <condition field="${balance_state}" expression="^zero$">
    <action application="playback" data="ivr/ivr-account_balance_is_low.wav"/>
    <action application="hangup" data="CALL_REJECTED"/>
    <anti-action application="set" data="nibble_account=${accountcode}"/>
    <anti-action application="set" data="nibble_rate=0.02"/>
    <anti-action application="bridge" data="sofia/gateway/bulkvs/$1"/>
  </condition>
</extension>
```

Registered softphones only. Plus `vmain` / `*98` for mailbox check — ungated,
voicemail retrieval is not tied to balance.


### P8 — Prepaid balance (`mod_nibblebill`)

Split of responsibility: **nibblebill meters, the dialplan gates.**

nibblebill is a during-call mechanism — it decrements `balance` on a heartbeat and
cuts the call when it hits zero. It does not answer "may this call start at all," so
the pre-call checks in P7 are ours, driven by `balance_state` from P4.

`autoload_configs/nibblebill.conf.xml`:
```xml
<configuration name="nibblebill.conf" description="Nibble Billing">
  <settings>
    <param name="db_table" value="extensions"/>
    <param name="db_column_cash" value="balance"/>
    <param name="db_column_account" value="accountcode"/>
    <param name="global_heartbeat" value="60"/>
    <param name="lowbal_amt" value="1"/>
    <param name="lowbal_action" value="play tone_stream://%(500,0,880)"/>
    <param name="nobal_amt" value="0"/>
    <param name="nobal_action" value="hangup"/>
    <param name="percall_max_amt" value="20"/>
    <param name="percall_action" value="hangup"/>
  </settings>
</configuration>
```

- `percall_max_amt` is a toll-fraud backstop as much as a billing control — it caps
  the damage from a single compromised extension. Keep it low.
- Bill **outbound only** at launch. Inbound is metered by BulkVS against the platform,
  not the user; charging for it is a pricing decision, not an implementation one.
- **Flat rate per extension.** `nibble_rate` is one column on `extensions`, emitted by
  the directory handler (P4). No rate table, no prefix lookup.
  - The margin on a local call and a mobile termination is not the same, and you
    absorb that difference. Acceptable at launch scale; revisit when volume makes the
    spread material.
  - **International will lose money fast at a flat domestic rate.** The hard prefix
    block in P11 is not optional under this model — it is what makes flat rating
    survivable. Treat the two as a single decision.
- Two things to verify on first build:
  1. nibblebill's config takes `odbc-dsn`. Confirm it accepts a native `pgsql://`
     DSN; if not, install unixODBC + psqlodbc alongside `mod_pgsql`.
  2. Balance updates are a plain `UPDATE` on one column — racy across concurrent
     calls for the same account. Acceptable at launch scale; revisit before
     allowing many simultaneous channels per extension.
- Pause billing before any `transfer`, or the transfer re-triggers a balance check
  mid-route. Unset `nibble_account` to make nibblebill ignore a channel entirely.

**Top-up: Stripe payment link + webhook.**

Self-serve, and no card data ever reaches your infrastructure. A hosted payment link
per amount, with `client_reference_id` set to the extension's `accountcode` so the
webhook knows who to credit.

A small HTTPS service on the Vultr box handles the webhook — it needs Postgres, and
it is **off the call path**, so unlike the directory handler its failure delays a
credit rather than breaking calls. That difference is why bringing a web service back
here is fine after removing it from P4. (A Worker plus Cloudflare Tunnel also works;
it is more moving parts for the same result.)

Four things that are not optional:

1. **Verify the `Stripe-Signature` header** against the webhook signing secret before
   doing anything else. Without it the endpoint is a free-money API — anyone can POST
   a fabricated `checkout.session.completed`.
2. **Idempotency.** Stripe retries on any non-2xx, and will redeliver events you have
   already seen. Insert the event id into `stripe_events` as a primary key inside the
   same transaction as the credit; a duplicate key means already processed, return
   200 and do nothing. Without this a retry storm double-credits.
3. **Credit relatively, never absolutely** — `balance = balance + :amount`, never
   `balance = :value`. nibblebill is decrementing the same column concurrently, and an
   absolute write silently erases whatever it billed in between.
4. **One transaction**: insert `topups` row, insert `stripe_events` row, update
   `balance`. All three or none.

Reconcile on a schedule: `sum(topups.amount)` minus billed minutes should track
`balance`. A drift means a webhook succeeded at Stripe and failed here — check for
Stripe events with no matching `stripe_events` row.

Top-up takes effect on the next directory lookup, which is why P4 keeps
`balance_state` out of the cache (or on a few-second TTL). A user who pays should not
wait minutes to make a call.

### P9 — Call detail records

Everything downstream of billing needs call history, and nothing in P8 produces any.
Without CDRs a balance dispute is unanswerable, BulkVS invoices cannot be reconciled,
and every fraud signal in P11 is inert. **Build this before taking customers, not
after the first dispute.**

`mod_odbc_cdr` writes directly to Postgres and is the right fit here — `mod_cdr_csv`
means files to parse and rotate, and `mod_xml_cdr` means an HTTP endpoint to run.

**Schema.** One `cdrs` table, written per leg:

| Column | Notes |
|---|---|
| `uuid`, `bleg_uuid` | correlate the two legs of a bridged call |
| `domain`, `accountcode`, `extension_id` | who to bill and who to answer to |
| `direction` | `inbound` \| `outbound` \| `emergency` \| `internal` |
| `caller_id_number`, `destination_number` | as presented, plus the effective values |
| `start_epoch`, `answer_epoch`, `end_epoch` | integers, **not** timestamps — an unanswered call has an empty answer stamp and `''` will not cast to `timestamptz`, failing the insert and losing the row |
| `duration`, `billsec` | bill on `billsec`, never `duration` |
| `hangup_cause`, `sip_hangup_disposition` | |
| `routing_mode`, `balance_state` at call time | why it routed the way it did |
| `nibble_total` | what nibblebill actually charged |
| `gateway` | which trunk carried it |

- **Record `nibble_total` alongside your own `billsec`.** They should agree; when they
  do not, that discrepancy is the entire value of having CDRs. A nightly job comparing
  the two catches metering bugs before customers do.
- Index on `(accountcode, start_stamp)` — every dispute and every fraud query is
  "this account, this window".
- `direction='emergency'` is worth its own value rather than inferring it later.
  Emergency calls are unbilled by design and must not read as a metering fault.

**Correctness details that bite:**

- **Bill `billsec`, not `duration`.** `duration` includes ring time. Charging for
  unanswered calls is the kind of billing error that ends accounts.
- CDR write failures must not fail the call. Log loudly, spool locally, reconcile —
  a database hiccup should cost you a record, never a conversation.
- Both legs are written for a bridged call. Deduplicate on `uuid` when reporting or
  every outbound call appears twice and revenue looks double.
- Depends on correct system time — NTP is listed in P11 for exactly this reason.

**Retention: 18 months** (decision #17, P15), then purged by a scheduled job that
alerts on failure. CDRs are CPNI — who called whom and when — so the window is a
privacy decision, not a storage one; they carry no audio and cost almost nothing to
keep.

**Reconciliation.** Monthly, compare CDR minutes by gateway against the BulkVS invoice.
A persistent gap means either a metering bug or traffic you did not originate — both
worth knowing about quickly.

### P10 — Voicemail + email via Cloudflare Email Sending

Voicemail is ungated — balance does not affect retrieval or the emailed attachment.
Messages live on the Vultr disk and nowhere else; Cloudflare's only job is delivering
the notification.

FreeSWITCH's `mod_voicemail` has no SMTP client — it shells out to a `sendmail`
binary. So keep that interface and swap only the delivery backend: a relay-only MTA
that hands everything to Cloudflare over authenticated submission. No OpenDKIM, no
direct-to-MX, no IP reputation to build.

1. **Onboard the domain** to Email Service → Email Sending
   (`npx wrangler email sending enable <domain>`, or the dashboard). Cloudflare
   handles SPF/DKIM signing for onboarded domains — the zone is already on Cloudflare
   DNS, so the records provision directly; verify they landed. Add **DMARC** yourself:
   start `p=none; rua=...`, tighten after a week of clean reports. Requires a Workers
   Paid plan; Email Sending is in beta.
2. **API token** with `Email Sending: Edit`. Account-owned preferred. This is the SMTP
   password — store it `0600` root-only, never under `/etc/freeswitch`.
3. **`msmtp` + `msmtp-mta`** (provides `/usr/sbin/sendmail`). Lighter than postfix and
   there is nothing to receive here. `/etc/msmtprc`:
   ```
   account        cloudflare
   host           smtp.mx.cloudflare.net
   port           465
   tls            on
   tls_starttls   off
   auth           on
   user           api_token
   password       <cloudflare-api-token>
   from           voicemail@<domain>
   account default : cloudflare
   ```
   Port 465 with **implicit TLS is the only option** — 587/STARTTLS and 25 are not
   supported for submission, so `tls_starttls off` is required, not optional. The
   username is the literal string `api_token`, not an email address.
4. **`voicemail.conf.xml`**: stock `default` profile; set `email-from` to an address on
   the onboarded domain; `voicemail.tpl` for delivery-with-attachment,
   `notify-voicemail.tpl` for notify-only. Per-user `vm-mailto` comes from the
   directory (P4).

   **Greetings need no code.** mod_voicemail's IVR already does it — `*98` →
   authenticate → `5` (config menu) → `1` record greeting, `2` choose greeting,
   `3` record name, `6` change PIN. These are the stock `config-menu-key`,
   `record-greeting-key`, `choose-greeting-key`, `record-name-key` params. Phone-only
   at launch; a web upload would need a portal that does not exist yet.

   **Two mandatory changes to the stock profile:**
   ```xml
   <param name="allow-empty-password-auth" value="false"/>
   ```
   The stock value is `true`. Left as shipped, and with `vm-password` unset, any
   registered softphone can dial `*98`, key in **someone else's** extension at the
   prompt, and walk straight into that mailbox — listen to messages and re-record
   their greeting. `vm-password` must always be emitted by the directory handler (P4)
   and this flag must be `false`. Treat the pair as one control.

   Also confirm `db-password-override` stays `false` so the directory remains the
   authority on the PIN.
5. **Record to MP3, keep the stock 300s cap.** Cloudflare rejects messages over
   **5 MiB**, and a 300s 8 kHz 16-bit WAV is ~4.6 MiB raw / ~6.1 MiB base64-encoded
   into the MIME part — over the limit, failing with nothing obvious in the
   FreeSWITCH log. At 32 kbps mono, 300s of MP3 is ~1.2 MB (~1.6 MB encoded), which
   clears the limit with room to spare and cuts disk use ~4× (helping step 6).
   - `file-extension` = `mp3` in the voicemail profile; requires **`mod_shout`**,
     built against lame. Add it to the P2 module list.
   - MP3 was chosen over Ogg/Vorbis (which `mod_sndfile` could do without an extra
     module) because the file is an **email attachment** — MP3 plays in every mail
     client, Vorbis does not.
   - `mod_shout` also registers HTTP stream URLs as a file source. Nothing here uses
     that; it is extra surface, so keep it in mind during P11.
   - Verify the encode bitrate is actually what you expect on the first recording —
     confirm the resulting file size rather than assuming the default.
   - `*98` playback decodes MP3 through the same module. Test both directions.
   - Encode cost is a one-off at end of recording, negligible next to RTP.
6. **Retention: 30 days from the retention anchor — messages only.** Nothing prunes
   `storage_dir` on its own. A nightly cron job deletes recordings **and their
   mod_voicemail rows**; deleting files alone leaves rows pointing at nothing and
   `*98` will error on them. Do the row delete through `vm_fsdb_msg_delete`, not raw
   SQL, so MWI counts stay correct.

   **The anchor is the later of deposit and last save — not the deposit date.** A
   message saved on day 29 must survive another 30 days, and saving it again renews
   it again. Keying off `created_epoch` cannot express this, and mod_voicemail's
   `read_epoch` is set on first read and not refreshed, so it cannot either. Hence
   `vm_retention` (P3) as our own clock.

   **Original deposit details are immutable.** `created_epoch`, `cid_name`,
   `cid_number` and the audio are never modified — the user must still see who called
   and when they called, no matter how many times the message has been renewed.
   Renewal moves `retain_until` in *our* table only.

   The nightly job is the sole writer, reconciling against `voicemail_msgs`:

   | Observed | Action |
   |---|---|
   | uuid not in `vm_retention` | insert; `deposited_at` = `created_epoch`, `retain_until` = deposit + 30d |
   | `in_folder` changed to `saved` since last run | `retain_until` = now + 30d, `last_folder` = saved |
   | `retain_until` < now | `vm_fsdb_msg_delete`, then drop the row |
   | uuid gone from `voicemail_msgs` | drop the row (user deleted it themselves) |

   Nightly granularity is fine for a 30-day policy. Add a **1-day grace** (delete at
   31 days) so a message reaching its final day is still saveable for that whole day
   rather than racing the 3am job.

   **Greetings and the recorded name live in the same per-user directory as messages
   and must never be pruned.** Recorded once at signup and then never touched, so any
   "delete everything older than 30 days in `storage_dir`" job wipes them — and nobody
   finds out until a caller hears the generic system prompt. Driving the job from
   `vm_retention` (which only ever contains message uuids) avoids this by
   construction; never let it walk the directory by mtime.
   - ~1.2 MB per full-length message makes the disk cost trivial at this window; the
     reason to keep it short is that these are recordings of third parties who never
     agreed to anything. Holding a month is defensible, holding a year is a liability.
   - **Tell users the window.** Someone who checks voicemail rarely will lose a
     message at 30 days, and that is a support ticket unless it was stated up front.
     The emailed notification already carries the audio, which softens this a lot —
     the email copy is the user's durable record.
7. Verify against real Gmail *and* Outlook inboxes, plus one voicemail recorded at the
   full 300s to confirm both the file size and that the MP3 attachment plays.

Account-wide sending quotas (daily volume, header and content limits) are shared with
the REST API and worth reading before launch — voicemail volume is low, but the cap
applies to the whole account.

### P11 — Abuse, fraud and hardening

A prepaid PBX on a public IP is a fraud target from the hour it boots. This phase is
not optional polish — several items here are what make the rate model in P8 survivable.

**One structural advantage worth naming:** prepaid caps the blast radius. A compromised
extension can only burn its own balance, which is the single biggest protection this
design has over postpaid. Everything below is about tightening that bound, and about
the two places it leaks — the nibblebill heartbeat window and unbilled routes.

#### Destination controls and blacklists

- **International blocked by default**, allow-list per extension. Load-bearing: P8
  bills a flat domestic rate regardless of destination, so an unblocked international
  route loses money every minute. Not a hardening nice-to-have.
- **Premium-rate and high-cost prefix blocklist**, maintained separately from the
  international policy. IRSF (International Revenue Share Fraud) targets specific
  ranges — satellite, premium services, a handful of countries carrying most of the
  abuse. Block by prefix, deny by default, review the list quarterly.
- **Per-extension inbound blocklist** so a user can block a harassing caller, and a
  **global blocklist** for known-bad sources. Both belong in Postgres, checked in the
  `public` context before routing.
- **Outbound destination allow-list is stronger than a blocklist** for a launch of
  this size. You know which countries your customers legitimately call; start closed.

#### Rate limiting and velocity

Use `mod_db`'s `limit` application, backed by the database:

- Concurrent outbound channels per extension (start low — 2).
- Calls per minute and per hour per extension. A compromised credential shows up as
  velocity long before it shows up on an invoice.
- Registration attempts per IP and per extension — `fail2ban` catches brute force,
  but a per-extension cap catches slow distributed attempts fail2ban will not.
- Rate-limit the Stripe and BulkVS webhook endpoints; they are public HTTPS.
- **Exempt `route_emergency` from every limit above.** Any rate limiter that can
  refuse a 911 call is a safety defect. Verify this explicitly, not by inspection.

#### Fraud detection

Fraud detection is impossible without call records. P9 is a hard dependency — build it
first, then alert on:

- Balance burn rate far above an account's history.
- Calls to destinations the account has never called before, especially overnight.
- Registrations from a new country or ASN for an existing extension.
- The same extension registered from multiple IPs simultaneously.
- Long-duration calls to a single destination — the IRSF signature.

Two known leaks to bound explicitly:

1. **The nibblebill heartbeat.** At `global_heartbeat=60`, up to 60 seconds can be
   consumed past zero before the call drops. Bounded by `percall_max_amt`; keep it low.
2. **Unbilled routes.** `route_emergency` unsets `nibble_account` by design — that is
   the *only* path that should. Audit every `bridge` to a gateway and confirm it sets
   `nibble_account` first; `route_forward` was missed once already. An unbilled path is
   an unlimited path.

#### Credentials and secrets

- Generated per-extension SIP passwords, high entropy, never sequential, never derived
  from the extension number.
- `vm_password` likewise — a weak mailbox PIN is a fraud vector in its own right, and
  P10 already requires `allow-empty-password-auth=false`.
- **Inventory the secrets.** Stripe key, Cloudflare Email Sending token, BulkVS API
  credentials, Postgres password, the provisioning API bearer token (P12), and the
  webhook signing secrets. Root-owned `0600`, never under `/etc/freeswitch`, never in
  the repo, and with a written rotation procedure.
- The provisioning API token can create working phone service. It belongs in the same
  risk tier as the Stripe key, not with ordinary config.
- Separate Postgres roles: the directory handler needs **read-only** access to the
  provisioning tables. It should not hold the role that can write `balance`.

#### SIP-layer security

- **Parameterise every query in `directory.lua`.** The SIP username arrives from an
  unauthenticated REGISTER or INVITE and is passed straight to the handler. String
  concatenation into SQL there is pre-authentication SQL injection reachable by anyone
  who can send a packet to 5061. This is the highest-severity issue in the design and
  it is a code-review gate, not a runtime control.
- Do not let auth failures distinguish "unknown extension" from "wrong password" —
  differing responses let a scanner enumerate valid extensions cheaply.
- `sip-trace` off and `loglevel` at `info` in production.
- Strict ACL on the `external` profile (P5), re-verified after any config change.
- `fail2ban` with the FreeSWITCH jail (P0).

#### Inbound spam, outbound reputation

- **Inbound:** robocalls to customer DIDs are a support problem, not a security one.
  If BulkVS passes STIR/SHAKEN attestation results inbound, offer per-extension
  blocking of failed-attestation calls. Depends on the STIR/SHAKEN answer.
- **Outbound:** a customer sending spam damages *your* carrier reputation and your
  DIDs, not just theirs. You need an acceptable-use policy with teeth, outbound
  velocity alerting, and the ability to suspend an account quickly. Decide the
  suspension mechanism before you need it at 2am.

#### Operational

- Backups: nightly `pg_dump` + `/etc/freeswitch` off-box, **encrypted** — the dump
  contains SIP credentials and voicemail PINs. Test a restore before launch.
- NTP. Billing accuracy, CDR correlation and TLS all depend on correct time.
- Log retention: 90 days (P15). Logs contain dialled numbers — they are CPNI too.

### P12 — Provisioning API and onboarding

**Build alongside P6 and P8** — the BulkVS E911 webhook and the Stripe webhook live in
this same service. Numbered last only because it depends on the P3 schema.

One small HTTPS service on the box with three jobs: Stripe webhook (P8), BulkVS E911
webhook (P6), and the provisioning API below. **Postgres stays bound to localhost** and
the billing system never speaks SQL.

The point of the API is not convenience — it is that there is exactly one place where
the system's invariants are enforced. Direct database writes would scatter them across
CHECK constraints, triggers, and the billing system's good intentions.

#### Endpoints

```
POST   /prov/domains
POST   /prov/extensions               → generates credentials, returns them ONCE
PATCH  /prov/extensions/:id           → routing_mode, forward_number, vm_email
POST   /prov/extensions/:id/rotate    → new SIP password
POST   /prov/extensions/:id/suspend   → and /resume
POST   /prov/dids                     → map a DID to an extension
PATCH  /prov/dids/:id/e911            → address + status
```

Auth: bearer token plus an IP allow-list for the billing system, over TLS. Rotate on a
schedule. This endpoint can create working phone service — treat it like the payment
API it effectively is.

**Idempotency.** The billing system will retry. Require an idempotency key per mutating
request and store it, exactly as the Stripe handler dedupes on event id (P8). A retried
extension creation must return the original result, not a second extension.

#### Invariants enforced here — the reason this phase exists

- **`forward_number` passes the full destination policy**, not just an emergency-number
  check: emergency numbers rejected (decision #10 depends on it, or a user forwards to
  911 and routes around the emergency branch), and international/premium-rate prefixes
  rejected unless allow-listed. Call-forward is an outbound route; validating it more
  loosely than a dialled number is how it becomes the cheapest way to attack you.
- **Passwords are generated server-side and never accepted from the caller.** High
  entropy, never sequential, never derived from the extension number (P11). Applies to
  both `sip_password` and `vm_password`; a null `vm_password` is rejected, since P10
  requires `allow-empty-password-auth=false` to mean something.
- **`balance` is not settable.** Credits arrive only through `topups` (P8). The
  provisioning API must have no path that writes the column.
- **`e911_status` transitions are constrained** — `unregistered → pending →
  provisioned|failed`, and only the BulkVS webhook may set `provisioned`. A billing
  system bug must not be able to activate service on an unregistered address.
- `routing_mode='forward'` requires a `forward_number`; DIDs validate as E.164;
  extensions are unique per domain.

#### Credential delivery

Generated credentials are returned **once** at creation and shown in the authenticated
billing portal — reveal on demand, with a rotate button. Never emailed: a SIP password
is a toll-fraud credential, and email is a plaintext store you do not control (and
would land in Cloudflare's sending logs). Never logged, either.

The portal shows server, username, password, and a QR code the softphone can scan.
**Confirm the QR payload format your chosen softphone actually accepts before building
it** — there is no universal standard, and a `sip:` URI carrying the password is a
credential in an image users will screenshot. Pick the client first, then the format.

#### Suspension has a sharp edge

Setting `active=false` does **not** drop an existing registration or an in-progress
call. New authentications fail once the P4 cache expires, but a registered client can
keep working for a while.

To suspend immediately, the API must also flush the registration —
`sofia profile internal flush_inbound_reg <user>@<domain>` over ESL — and optionally
hang up live channels for that account. Wire this into `/suspend` from the start;
discovering it during a fraud incident is the wrong time.

#### Ordering

Extension exists → DID mapped → E911 address registered and `provisioned` → ordinary
outbound enabled (P7). Emergency calling works throughout; only ordinary service is
gated.

### P13 — Availability and recovery

**Decision: single node, accepted deliberately.** One Vultr instance, no standby. The
mitigation is not redundancy — it is that recovery is fast, rehearsed, and never
requires touching the carrier. A warm standby you have never failed over to is a false
sense of security; this is the honest version at launch scale.

Targets, written down so they can be judged: **RTO ~1–2 hours, RPO ~24 hours.**

#### Reserved IP — do this on day one

Provision the PBX behind a **Vultr Reserved IP** from the start, before BulkVS is
configured. This is the single highest-value item in this phase.

BulkVS whitelists your IP for outbound and points DIDs at it for inbound. Changing
that is a carrier-side change measured in hours, and you would be making it during an
outage. With a Reserved IP, recovery is a reassignment to the rebuilt instance and the
carrier never notices.

Retrofitting this later means a coordinated BulkVS reconfiguration for no benefit. It
costs nothing now.

#### Everything reproducible

- **All config in git** — `/etc/freeswitch` in full, `nftables` rules, `msmtprc`
  template, systemd units, cron jobs, the Lua handler, the provisioning service.
  Secrets excluded and referenced, never committed (P11).
- The rebuild must be a runbook someone can follow at 3am, not knowledge in your head.
  Ordered steps, exact commands, expected output at each stage.
- Pin package versions. A rebuild that silently installs a newer FreeSWITCH is a
  different system, discovered under pressure.

#### Backups

- Nightly `pg_dump`, **encrypted**, off-box. It contains SIP credentials, voicemail
  PINs and CDRs (P11).
- Voicemail audio is **not** backed up by default — it is 30-day transient data (P10)
  and the notification email already carries a copy. State this explicitly so nobody
  assumes otherwise during a restore.
- RPO is the backup interval. If ~24 hours of lost `topups` and CDRs is unacceptable,
  the fix is more frequent dumps or WAL archiving — a cheaper change than a standby.

#### Rehearse it before launch

**Build the box a second time from the runbook, on a scratch instance, and make a test
call through it.** This is the whole phase. An untested runbook is a document, not a
recovery plan, and the gaps only appear when you follow it literally.

Re-rehearse after any material change to the stack. Note the actual elapsed time — that
number, not an estimate, is your RTO.

#### Emergency calling during an outage

This is the part architecture cannot solve. If the PBX is down the softphone cannot
register, so it cannot reach 911 through this service at all — and the same is true if
the user's internet or power is out, or their device is dead.

- **Disclose it plainly at signup**, alongside the nomadic-address disclosure (P6), as
  an explicit acknowledgement rather than buried terms: this service is not a
  replacement for a mobile or landline for emergencies.
- Standard for VoIP, and required regardless of how many nines the infrastructure has.
- It is also the reason a warm standby would not change the disclosure — worth
  remembering when the standby question comes back.

#### When to revisit

Move to a warm standby (Postgres streaming replication, promote-and-reassign, RTO
minutes) when any of these is true:

- customers exist who would notice an hour of downtime
- revenue per hour of outage exceeds the cost of a second instance
- you have failed over at least once in a rehearsal, so the standby is real

### P14 — Monitoring and alerting

Two tiers, split by a rule that decides the whole design: **anything that must page you
when the box is down cannot run on the box.**

| Tier | Runs | Path | Wakes you? |
|---|---|---|---|
| Liveness | external service | push / SMS | yes |
| Thresholds | on-box cron | email via Cloudflare (P10) | no |

The on-box tier emails through the same Cloudflare path as voicemail. That is fine for
"disk is at 82%" and useless for "the machine is gone" — which is exactly why the
external tier exists and owns anything urgent.

#### External — liveness

A third-party check (UptimeRobot, Better Stack, similar free tier) probing from
outside, alerting to push or SMS, **not** to the email address the PBX itself sends:

- TCP connect to **5061** — the SIP TLS port. If softphones cannot register, nothing
  else matters.
- HTTPS health endpoint on the provisioning service (P12) returning a real check —
  Postgres reachable, FreeSWITCH answering on ESL — not a static `200`. A health
  endpoint that is green while the database is down is worse than none.
- Certificate expiry, which most uptime services check for free. Belt and braces with
  the cron check below.

#### On-box — thresholds

Cron, one script per check, email on breach. Keep the set small; an alert nobody reads
is worse than no alert.

| Check | Threshold | Why it matters |
|---|---|---|
| TLS cert expiry | < 21 days | Silent renewal failure breaks **every** client at once on day 90 (P5) |
| Backup age | > 36 hours | A backup that quietly stopped is worse than none — you believe you have one (P13) |
| Disk usage | > 80% | Voicemail, CDRs and logs all grow; a full disk on a media server is ugly |
| Registration count | drops > 50% hour-on-hour | The earliest signal that something broke |
| Trunk state | gateway not `REGED`/reachable | `sofia status gateway` — no trunk means no calls, inbound or out |
| DIDs stuck `pending` | > 48 hours | Address validation failed; the customer is paying and cannot call out (P6) |
| Retention job | did not run or errored | Silent failure means unbounded disk and stale rows (P10) |
| CPU steal | sustained > 5% | The dedicated-CPU assumption in P0 quietly not holding — shows up as bad audio |
| Failed CDR writes | any | Billing records being lost (P9) |

#### Fraud alerting shares this path

The signals in P11 — burn rate, new destinations, registrations from new ASNs,
simultaneous registrations — are SQL over `cdrs` (P9) run on the same cron, delivering
to the same inbox. **One alerting path, not two.** Two paths means one of them stops
being read.

#### Discipline

- **Every alert names the action.** "Disk 84%, run the retention job or resize" beats
  "Disk 84%".
- **Tune out anything that fires twice without being acted on.** Alert fatigue is the
  failure mode that makes monitoring decorative, and it arrives fast with a single
  operator.
- **Test each alert by causing it**, once, at setup. An untested alert is a belief.
  Stop Postgres and confirm the health endpoint goes red; backdate the backup and
  confirm the email arrives.
- Revisit when there is traffic worth trending — hosted metrics (node_exporter and
  friends into a free-tier Grafana Cloud) buy history and dashboards, which matter for
  spotting drift rather than incidents. Not needed to launch.

### P15 — Data protection

**Scope: US customers only.** Geo-restrict signup and do not sell into the EU/UK until
GDPR has been deliberately taken on — one EU signup attaches the obligations whether
or not you planned for them. Revisit as a decision, never by drift.

#### CPNI — the obligation that is easy to miss

An interconnected VoIP provider is subject to the FCC's Customer Proprietary Network
Information rules (47 CFR 64.2001–2011). CPNI is precisely what this system stores:
numbers called and received, call times and durations, and service configuration.

Practical consequences, all of which need confirming with counsel — the FCC modernised
the breach rules in 2024 and specifics move:

- **Annual CPNI certification**, filed with an accompanying statement of compliance.
  Historically due 1 March for the prior calendar year. Put it in the calendar now;
  it is the sort of thing that is only remembered late.
- **Authenticate the customer before disclosing call detail** over the phone or by
  email. "They called from the account's number" is not authentication — caller ID is
  trivially spoofed, and this is the exact scenario the rule exists for. Define the
  procedure before support has its first call.
- **Breach notification** to federal law enforcement and to customers, on statutory
  deadlines. Know the reporting path *before* the incident; discovering it during one
  costs days you do not have.
- **Written CPNI safeguards and training**, even for a one-person operation.

#### What is held, and where

| Data | Where | Sensitivity |
|---|---|---|
| Voicemail audio, greetings | box, `storage_dir` | content of communications, mostly **third parties** who never agreed to anything |
| CDRs | Postgres | CPNI — who called whom, when |
| `e911_address` | Postgres | a home address |
| `forward_number` | Postgres | usually a personal mobile |
| `vm_email` | Postgres | contact data |
| `sip_password`, `vm_password` | Postgres | credentials; breach-critical |
| SIP/FreeSWITCH logs | box | dialled numbers |
| Backups | off-box | all of the above |

**Third-party processors** — Cloudflare (Email Sending; note the voicemail attachment
means it handles **content of communications**, not just metadata), BulkVS, Stripe,
Vultr, and the external uptime service (P14). Keep the list current; it is the first
thing anyone asks for after an incident.

#### Retention

| Data | Retention | Notes |
|---|---|---|
| Voicemail audio | 30 days from deposit or last save | decision #9, P10 |
| CDRs | **18 months**, then purge | billing disputes and a full year of seasonality; bounded breach window |
| Logs | 90 days | they contain dialled numbers — they are CPNI too |
| Backups | 35 days | one monthly cycle plus headroom |
| `topups` | keep | financial record |

CDRs are tiny, so 18 months is a privacy decision rather than a storage one — the
reason not to keep seven years is that seven years of call metadata on one box is a
large breach surface for a small operation.

Purges must be **scheduled jobs that alert on failure** (P14), not intentions. A
retention policy nobody enforces is worse than none: it is a written commitment you
are visibly not meeting.

#### Account closure

On close:

- voicemail audio **and greetings** deleted immediately — third-party content with no
  reason to persist
- `sip_password`, `vm_password` deleted
- extension and DID mapping deleted; the DID returns to BulkVS
- **CDRs live out their 18 months** — they are billing records, and disputes tend to
  arrive after closure
- `topups` retained as financial records

Run it through the P12 provisioning API so the same invariants and audit trail apply.

#### Access and hygiene

- **Access control.** Only you should be able to read voicemail or query CDRs. When
  that stops being true, it needs to be a deliberate grant with an audit trail, not a
  shared `psql` login.
- **Minimise what is logged.** `sip-trace` off in production (P11); never log
  passwords, and redact credentials from provisioning-service logs (P12).
- **Backups encrypted** (P11, P13) — they contain credentials, PINs and CPNI.
- **Publish a privacy notice** covering the retention table above, and state the
  voicemail window plainly to users — P10 already requires telling them the 30 days,
  and this is where that promise is recorded.

### P16 — Change safety and staging

No permanent staging environment. Instead, three cheaper things that between them cover
most of what one would buy.

#### The rehearsal instance *is* staging

P13 already requires building a scratch instance from the runbook and proving a
rebuild. Reuse it: spin it up when a change needs testing, tear it down after.

The two jobs reinforce each other — staging validates the runbook, and the runbook
builds staging. A staging box that has drifted from production is the usual failure of
a permanent environment; one built from the runbook every time cannot drift, and if it
fails to build, that is a P13 finding you needed anyway.

It needs its own throwaway DID and a separate BulkVS sub-account or test route. Never
point it at production DIDs.

#### Know which reloads are safe

Most changes do not need a restart, and reaching for the wrong command is how a config
tweak becomes an outage:

| Change | Command | Impact |
|---|---|---|
| Dialplan XML | `reloadxml` | none — takes effect on the next call |
| Lua directory handler | none needed | re-read per lookup; watch for a cached module |
| Sofia profile settings | `sofia profile <name> rescan` | none for most params |
| TLS cert, bindings, transports | `sofia profile <name> restart` | **drops every registration on that profile** |
| Module config | `reload mod_x` | that module only |

`rescan` picks up new gateways and most profile parameters. `restart` is the blunt one
— it is required for certificates and binding changes (P5) and should be scheduled,
never reflexive.

#### Config in git, rollback rehearsed

- Everything from P13 is versioned: `/etc/freeswitch`, nftables, systemd units, cron,
  the Lua handler, the provisioning service.
- **Commit before changing, on the box.** The rollback is a `git checkout` plus the
  right reload from the table above — and it must have been done once deliberately,
  not first attempted during an incident.
- Validate XML before reloading. `reloadxml` on malformed XML leaves the previous
  config live and logs an error, which is survivable but easy to miss; a syntax check
  in the commit path is cheaper than finding out from a customer.
- Change one thing at a time. With a single node and no blue/green, attribution is
  the only debugging tool you have.

#### Test a dialplan change without live traffic

`originate` from `fs_cli` places a call through the real dialplan without waiting for
someone to dial in — enough to prove routing, the balance gate, and the emergency
branch behave, before any customer touches them.

The one thing this cannot rehearse safely is a live 911 call. Use `933` (P6), and
coordinate with BulkVS if a real test is ever needed.

## Verification (end-to-end, in order)

1. `fs_cli -x "sofia status"` — both profiles `RUNNING`.
2. Register a softphone with `fs_cli -x "console loglevel debug"`; confirm
   `directory.lua` is invoked and returns a directory document.
   - inspect the `Contact` header and SDP: both must carry the **Reserved IP**, not
     the instance's primary address (P5). Getting this wrong is the most likely
     first-day fault, and it presents as one-way audio, not as a config error.
   `sofia status profile internal reg` shows the registration.
3. Softphone → softphone call within the domain.
4. Softphone → PSTN via BulkVS, correct caller ID on the far end.
5. E911 — test with `933` before ever testing `911`, and coordinate with BulkVS if a
   live 911 test is needed. Never dial 911 casually to check a config.
   - `933` reads back the address registered for that DID; confirm it matches what the
     billing system submitted
   - `933` at **zero balance** → still connects, and `balance` does not move
   - `933` while `e911_status='pending'` → still connects; ordinary outbound to a
     normal number is refused with the registration announcement
   - once `provisioned`, ordinary outbound works
   - SIP trace on the emergency branch shows `From` carrying the E911-registered DID,
     not the extension's default caller ID
   - attempt to set `forward_number` to `911` → rejected at provisioning
   - dialling 911 fires the Kari's Law notification
6. PSTN → DID for each `routing_mode`: rings the softphone (and falls to voicemail
   unanswered); forwards to the mobile and, left unanswered, lands in the **carrier's**
   voicemail not iqfone's; drops straight to voicemail. Also point `forward_number` at
   an unreachable number and confirm the caller gets a real SIP cause, not dead air.
7. `echo test | sendmail -v you@gmail.com` — msmtp connects to
   `smtp.mx.cloudflare.net:465` and Cloudflare accepts it. Then leave a voicemail →
   MWI lights on the softphone, email arrives with the `.mp3` attached, headers show
   `dkim=pass spf=pass dmarc=pass` in Gmail *and* Outlook, and `*98` plays the same
   message back. Record one at the full 300s to confirm size and that it plays.
8. Mailbox access and greetings:
   - `*98` authenticates against `vm_password`; `5` → `1` records a custom greeting,
     and the next caller hears it instead of the system prompt
   - from a registered softphone, dial `*98` and enter a **different** extension with
     an empty or wrong PIN → denied, confirming `allow-empty-password-auth=false`
   - record a greeting, backdate its mtime past 30 days, run the retention job →
     the greeting still plays and only old messages are gone
   - **renewal**: backdate a message's `deposited_at` to 29 days, save it via `*98`
     (`2`), run the job → it survives, `retain_until` is ~30 days out, and the
     displayed caller ID and original date are unchanged
   - save it again the following day → `retain_until` moves out another 30 days
   - a message past `retain_until` that was never saved → deleted, MWI count drops
     correctly
9. Balance, with a test extension:
   - positive balance → outbound connects; `nibblebill <uuid> check` shows the
     running charge; `balance` in Postgres decrements on the heartbeat
   - set balance to 0 mid-call → call drops within one heartbeat
   - balance 0 → outbound plays the low-balance prompt and rejects
   - balance 0 → inbound plays "not available" and lands in voicemail, and that
     voicemail is retrievable via `*98`
   - top up via a real Stripe test-mode payment → `topups` row written, `balance`
     credited, and outbound works again within seconds and with no restart
   - replay the same Stripe webhook event → 200, and `balance` does **not** move again
   - POST the webhook with a bad signature → rejected, nothing written
10. CDRs, after a mix of calls:
   - one row per leg; deduplicating on `uuid` gives the real call count
   - an **unanswered** call records `billsec=0` and is not charged — `duration` is
     longer, and billing on it would be the expensive mistake
   - `nibble_total` agrees with `billsec` × rate for every billed call
   - **a call-forward leg is billed**, not free — set `routing_mode='forward'`, call
     the DID from outside, and confirm `balance` drops. This was an unbilled route in
     an earlier draft; treat it as a regression test
   - a `933` call is present with `direction='emergency'` and no charge
   - stop Postgres mid-call → the call completes normally and the CDR failure is
     logged, never dropped silently
11. Abuse controls:
   - exceed the per-extension concurrent-channel cap → the next ordinary call is
     refused, and **`933` still connects**; rate limits must never touch the
     emergency path
   - dial a blocked international prefix → refused, no balance movement
   - a blocklisted caller ID inbound → does not reach the extension
   - a REGISTER whose username contains a quote or `--` must not reach Postgres as
     syntax. Review `directory.lua` for concatenated SQL; this is a code gate, not a
     runtime check
12. Provisioning API:
   - create an extension → credentials returned once, high entropy, and **absent from
     the service logs**
   - replay the same request with the same idempotency key → original result, not a
     second extension
   - `PATCH` `forward_number` to `911` → rejected
   - any attempt to set `balance` directly → no such path exists
   - set `e911_status='provisioned'` via the provisioning API → rejected; only the
     BulkVS webhook may do it
   - `/suspend` → registration is flushed immediately and the client cannot place a
     new call without waiting for a cache expiry
13. **Rebuild rehearsal** — the whole of P13. Build a scratch instance from the runbook
   alone, restore the latest backup, reassign the Reserved IP to it, and place a real
   call. Record the elapsed time; that is the RTO, not the estimate. Confirm BulkVS
   needed no change.
14. Monitoring — **cause each alert once rather than assuming it works**:
   - stop FreeSWITCH → the external check pages you by push/SMS, not by email
   - stop Postgres → the health endpoint goes red; a static `200` here is a defect
   - backdate the last backup → the age alert emails within a day
   - set a cert expiry threshold high enough to trip → it fires
   - confirm every alert names the action to take, not just the condition
15. Retention and closure — the policies are only real if the jobs run:
   - backdate CDRs past 18 months → purged on the next run; the job alerts if it fails
   - close a test account → voicemail audio **and greetings** gone, credentials gone,
     DID unmapped, CDRs and `topups` still present
   - confirm log rotation actually expires at 90 days rather than growing forever
16. Change safety:
   - edit the dialplan, `reloadxml`, and confirm the change takes effect **without**
     dropping a registration
   - `git checkout` the previous config and reload — the rollback must have been done
     once on purpose, not first attempted during an incident
   - `originate` a call through the real dialplan and confirm routing, the balance
     gate and the `933` branch all behave with no live traffic involved
17. Fault-inject the directory handler — stop Postgres, then force a syntax error in
   `directory.lua` — and re-register. Both must fail closed with a logged error and a
   not-found document, never a FreeSWITCH crash or a hung registration. Restore and
   confirm clean recovery without restarting FreeSWITCH.

## Decisions

| # | Question | Decision | Lands in |
|---|---|---|---|
| 1 | Tenancy | Tenant-capable schema, one tenant live. No hardcoded realm, ever. | P3 |
| 2 | Directory runtime | `mod_lua` in-process. Nothing on the auth path, no `mod_xml_curl`. | P2, P4 |
| 3 | Media security | TLS + SRTP from day one on `internal`. | P0, P5 |
| 4 | Rate model | Flat `nibble_rate` per extension. | P8 |
| 5 | Top-up | Stripe payment link + webhook, with `topups` audit table. | P3, P8 |
| 6 | Forward fallback | Terminal — the forward target owns the outcome. | P7 |
| 7 | DNS zone | Already on Cloudflare. Nothing blocks P10. | P10 |
| 8 | Voicemail format | MP3 via `mod_shout`, stock 300s cap. | P2, P10 |
| 9 | Retention | 30 days from deposit **or last save**, nightly prune of files *and* rows. | P0, P3, P10 |
| 10 | Emergency calling | **Supported via BulkVS E911.** Always routed; service activation gated on address provisioning. | P3, P6, P7 |
| 11 | Call records | `mod_odbc_cdr` → Postgres, its own phase. Bill on `billsec`. | P2, P3, P9 |
| 12 | Onboarding write path | Provisioning API on the PBX. Billing system never speaks SQL; Postgres stays localhost. | P12 |
| 13 | Credential delivery | Portal display + QR, reveal-on-demand and rotatable. **Never emailed.** | P12 |
| 14 | Availability | Single node, accepted. Reserved IP + rehearsed rebuild. RTO ~1–2h, RPO ~24h. | P0, P6, P13 |
| 15 | Monitoring | External uptime check owns paging; on-box cron owns thresholds. One alerting path. | P14 |
| 16 | Jurisdiction | **US only** at launch. Geo-restrict signup; EU/UK is a deliberate future decision. | P15 |
| 17 | CDR retention | 18 months, then purge. Logs 90 days, backups 35 days. | P9, P15 |
| 18 | Account closure | Voicemail purged immediately; CDRs live out their term. | P12, P15 |
| 19 | Staging | No permanent environment. The P13 rehearsal instance doubles as staging. | P16 |

Two of these are coupled and should not be changed independently:

- **#4 flat rating requires the international block in P11.** A flat domestic rate on
  an international route loses money every minute.
- **#2 mod_lua puts the directory in-process**, so there is no service to restart when
  it fails. That is why P4 mandates `pcall` and a not-found fallback, and why
  verification step 17 fault-injects it.
- **#10 inverts the usual gating direction.** 911 is never gated — not on balance, not
  on E911 provisioning status. What is gated is *ordinary outbound* until the address
  is provisioned. Any change that puts a check ahead of `route_emergency` is a safety
  regression, not a policy tweak.
- **#10 also depends on `forward_number` validation**, which lives in P12. An
  unvalidated forward target set to an emergency number routes around the emergency
  branch entirely.
- **#15 assumes #11.** Every fraud signal in P11 is a query over `cdrs`, so the
  alerting in P14 is inert until P9 exists. Build them in that order.
- **#12 is where the system's invariants live.** Password generation, the
  `balance`-is-not-settable rule, `e911_status` transitions and emergency-number
  rejection are all enforced in one service. Any future path that writes the database
  around it re-opens every one of them.

## To confirm during the build

Carried forward from the phases — none block starting, all block finishing:

- BulkVS trunk hostnames/IPs and DID routing, from the portal (P6).
- Whether `mod_nibblebill` accepts a native `pgsql://` DSN or needs unixODBC (P8).
- The exact `voicemail_msgs` column names and folder value for "saved" in the
  installed FreeSWITCH version — the retention job reconciles against them (P10).
- Actual MP3 encode bitrate and resulting file size on the first recording (P10).
- BulkVS E911 API: endpoint names, address-validation semantics, webhook payload shape
  and signature scheme, and how 911/933 are presented on the trunk (P6).
- Whether BulkVS signs outbound with STIR/SHAKEN on your behalf, or whether you carry
  originating-provider obligations including Robocall Mitigation Database listing.
  *(In progress — raised with BulkVS.)* The answer also determines whether inbound
  attestation results are available for the spam controls in P11.

## Known gaps — not yet planned

Distinct from "to confirm" above: these are things the plan does **not** cover and
that need a decision or a phase of their own. Ordered by what hurts first.

### Blocking for launch

None outstanding. The three that were here — CDRs, the onboarding contract, and the
single point of failure — became P9, P12 and P13.

### Should settle before customers

None outstanding. NAT landed in P5; staging and change safety became P16.

### Known and accepted, revisit later

- **Flat rating absorbs destination cost variance** (decision #4). Fine at launch
  scale; revisit when volume makes the spread material.
- **nibblebill balance updates are racy** across concurrent calls for one account.
  Acceptable while per-extension concurrency is capped low (P11).
- **Voicemail retention granularity is nightly**, with a 1-day grace. Fine for a
  30-day policy.
- **`mod_shout` brings HTTP stream URLs as a file source.** Unused here; noted as
  surface in P11.
