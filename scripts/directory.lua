local iq = require("iqfone")

local NOT_FOUND = [[<document type="freeswitch/xml">
  <section name="result">
    <result status="not found"/>
  </section>
</document>]]

local DIAL_STRING =
  "{^^:sip_invite_domain=${dialed_domain}:presence_id=${dialed_user}@${dialed_domain}}" ..
  "${sofia_contact(*/${dialed_user}@${dialed_domain})}"

local SQL = [[
SELECT e.extension, e.sip_password, e.vm_password, e.display_name,
       e.routing_mode, e.forward_number, e.vm_email, e.accountcode,
       e.balance, e.nibble_rate,
       d.e164 AS e911_did, d.e911_status
  FROM extensions e
  JOIN domains dom ON dom.id = e.domain_id
  LEFT JOIN dids d ON d.extension_id = e.id AND d.is_primary
 WHERE dom.domain = '%s' AND e.extension = '%s'
   AND e.active AND dom.active
 LIMIT 1]]

local function param(name, value)
  return string.format('        <param name="%s" value="%s"/>\n', name, iq.xml_escape(value))
end

local function variable(name, value)
  return string.format('        <variable name="%s" value="%s"/>\n', name, iq.xml_escape(value))
end

local function build(domain, row)
  local p = {}
  p[#p + 1] = param("password", row.sip_password)
  p[#p + 1] = param("vm-password", row.vm_password)
  p[#p + 1] = param("vm-mailto", row.vm_email)
  p[#p + 1] = param("vm-email-all-messages", row.vm_email ~= nil and "true" or "false")
  p[#p + 1] = param("vm-attach-file", "true")
  p[#p + 1] = param("dial-string", DIAL_STRING)

  local v = {}
  v[#v + 1] = variable("user_context", "default")
  v[#v + 1] = variable("accountcode", row.accountcode)
  v[#v + 1] = variable("domain_name", domain)
  v[#v + 1] = variable("dest_ext", row.extension)
  v[#v + 1] = variable("effective_caller_id_name", row.display_name)
  v[#v + 1] = variable("routing_mode", row.routing_mode)
  v[#v + 1] = variable("forward_number", row.forward_number)
  v[#v + 1] = variable("balance_state", iq.balance_state(row.balance))
  v[#v + 1] = variable("nibble_rate", row.nibble_rate)
  v[#v + 1] = variable("e911_did", row.e911_did)
  v[#v + 1] = variable("e911_status", row.e911_status or "unregistered")

  return table.concat({
    '<document type="freeswitch/xml">\n',
    '  <section name="directory">\n',
    string.format('    <domain name="%s">\n', iq.xml_escape(domain)),
    string.format('      <user id="%s">\n', iq.xml_escape(row.extension)),
    '        <params>\n', table.concat(p), '        </params>\n',
    '        <variables>\n', table.concat(v), '        </variables>\n',
    '      </user>\n',
    '    </domain>\n',
    '  </section>\n',
    '</document>\n',
  })
end

local function lookup()
  if XML_REQUEST.section ~= "directory" then return nil end

  local user = params:getHeader("user") or params:getHeader("sip_auth_username")
  local domain = params:getHeader("domain") or params:getHeader("sip_auth_realm")

  if not iq.valid_user(user) or not iq.valid_domain(domain) then
    iq.log("warning", "directory: rejected malformed lookup user=%q domain=%q",
           tostring(user), tostring(domain))
    return nil
  end

  local dbh, err = iq.dbh()
  if not dbh then
    iq.log("crit", "directory: %s", err)
    return nil
  end

  local row = iq.query_row(dbh, string.format(SQL, domain, user))
  dbh:release()

  if not row then return nil end
  return build(domain, row)
end

-- an uncaught error here breaks authentication itself; there is no
-- separate service to restart, so always fail closed with not-found
local ok, result = pcall(lookup)
if not ok then
  iq.log("crit", "directory: handler error: %s", tostring(result))
  result = nil
end

XML_STRING = result or NOT_FOUND
