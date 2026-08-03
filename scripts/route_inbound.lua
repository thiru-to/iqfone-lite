local iq = require("iqfone")

-- An inbound PSTN call is not authenticated as a user, so none of the directory
-- variables are on the channel. Resolve DID -> owner in one query and set them here;
-- dialplan/default.xml then branches on plain channel variables.

local SQL = [[
SELECT e.extension, e.routing_mode, e.forward_number, e.accountcode,
       e.balance, e.nibble_rate, dom.domain,
       p.e164 AS e911_did, p.e911_status
  FROM dids d
  JOIN extensions e ON e.id = d.extension_id
  JOIN domains dom ON dom.id = e.domain_id
  LEFT JOIN dids p ON p.extension_id = e.id AND p.is_primary
 WHERE d.e164 = '%s' AND e.active AND dom.active
 LIMIT 1]]

local function route()
  local did = session:getVariable("inbound_did")
  if not iq.valid_did(did) then
    iq.log("warning", "route_inbound: malformed DID %q", tostring(did))
    return false
  end

  local dbh, err = iq.dbh()
  if not dbh then
    iq.log("crit", "route_inbound: %s", err)
    return false
  end

  local row = iq.query_row(dbh, string.format(SQL, did))
  dbh:release()

  if not row then
    iq.log("warning", "route_inbound: no mapping for DID %s", did)
    return false
  end

  session:setVariable("dest_ext", row.extension)
  session:setVariable("domain_name", row.domain)
  session:setVariable("accountcode", row.accountcode)
  session:setVariable("routing_mode", row.routing_mode)
  session:setVariable("forward_number", row.forward_number)
  session:setVariable("balance_state", iq.balance_state(row.balance))
  session:setVariable("nibble_rate", row.nibble_rate)
  session:setVariable("e911_did", row.e911_did)
  session:setVariable("e911_status", row.e911_status or "unregistered")
  return true
end

local ok, routed = pcall(route)
if not ok then
  iq.log("crit", "route_inbound: handler error: %s", tostring(routed))
  routed = false
end

if not routed then
  session:hangup("NO_ROUTE_DESTINATION")
end
