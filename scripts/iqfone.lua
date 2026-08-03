local M = {}

-- freeswitch.Dbh has no parameter binding, so untrusted input is allow-listed
-- before it can reach SQL. These values arrive from unauthenticated SIP packets.
function M.valid_user(s)
  return type(s) == "string" and #s > 0 and #s <= 64 and s:match("^[%w%._%-]+$") ~= nil
end

function M.valid_domain(s)
  return type(s) == "string" and #s > 0 and #s <= 253 and s:match("^[%w%.%-]+$") ~= nil
end

function M.valid_did(s)
  return type(s) == "string" and #s > 0 and #s <= 20 and s:match("^%d+$") ~= nil
end

local escapes = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }

function M.xml_escape(s)
  if s == nil then return "" end
  return tostring(s):gsub("[&<>\"']", escapes)
end

function M.dbh()
  local dsn = freeswitch.getGlobalVariable("pg_dsn")
  if not dsn or dsn == "" then return nil, "pg_dsn global is unset" end
  local h = freeswitch.Dbh(dsn)
  if not h:connected() then return nil, "database not reachable" end
  return h
end

-- one row or nil; caller has already validated every interpolated value
function M.query_row(dbh, sql)
  local out
  dbh:query(sql, function(row)
    out = row
  end)
  return out
end

function M.balance_state(balance)
  local n = tonumber(balance) or 0
  if n > 0 then return "ok" end
  return "zero"
end

function M.log(level, fmt, ...)
  freeswitch.consoleLog(level, string.format(fmt, ...) .. "\n")
end

return M
