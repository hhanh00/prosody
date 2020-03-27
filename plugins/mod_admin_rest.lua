local url    = require "socket.url";
local jid    = require "util.jid";
local stanza = require "util.stanza";
local b64    = require "util.encodings".base64;
local sp     = require "util.encodings".stringprep;

local JSON = { };

-- Use lua-cjson if it is available
local ok, error = pcall(function() JSON = require "cjson.safe" end);

-- Fall back to util.json
if not ok or error then JSON = require "util.json" end

local um = require "core.usermanager";
local rm = require "core.rostermanager";
local mm = require "core.modulemanager";
local hm = require "core.hostmanager";
local sm = require "core.storagemanager";

local hostname  = module:get_option_string("admin_rest_hostname", module:get_host());
local secure    = module:get_option_boolean("admin_rest_secure", false);
local base_path = module:get_option_string("admin_rest_base", "/admin_rest");
local whitelist = module:get_option_array("admin_rest_whitelist", nil);

local function to_set(list)
  local l = #list;
  if l == 0 then return nil end
  local set = { };
  for i=1, l do set[list[i]] = true end
  return set;
end

-- Convert whitelist into a whiteset for efficient lookup
if whitelist then whitelist = to_set(whitelist) end

local function split_path(path)
  local result = {};
  local pattern = "(.-)/";
  local last_end = 1;
  local s, e, cap = path:find(pattern, 1);

  while s do
    if s ~= 1 or cap ~= "" then
      table.insert(result, cap);
    end
    last_end = e + 1;
    s, e, cap = path:find(pattern, last_end);
  end

  if last_end <= #path then
    cap = path:sub(last_end);
    table.insert(result, cap);
  end

  return result;
end

local function parse_path(path)
  local split = split_path(url.unescape(path));
  return {
    route     = split[2];
    resource  = split[3];
    attribute = split[4];
  };
end

-- Parse request Authentication headers. Return username, password
local function parse_auth(auth)
  return b64.decode(auth:match("[^ ]*$") or ""):match("([^:]*):(.*)");
end

-- Make a *one-way* subscription. User will see when contact is online,
-- contact will not see when user is online.
local function subscribe(user_jid, contact_jid)
  local user_node, user_host = jid.split(user_jid);
  local contact_username, contact_host = jid.split(contact_jid);
  -- Update user's roster to say subscription request is pending...
  rm.set_contact_pending_out(user_node, user_host, contact_jid);
  -- Update contact's roster to say subscription request is pending...
  rm.set_contact_pending_in(contact_username, contact_host, user_jid);
  -- Update contact's roster to say subscription request approved...
  rm.subscribed(contact_username, contact_host, user_jid);
  -- Update user's roster to say subscription request approved...
  rm.process_inbound_subscription_approval(user_node, user_host, contact_jid);
end

-- Unsubscribes user from contact (not contact from user, if subscribed).
function unsubscribe(user_jid, contact_jid)
  local user_node, user_host = jid.split(user_jid);
  local contact_username, contact_host = jid.split(contact_jid);
  -- Update user's roster to say subscription is cancelled...
  rm.unsubscribe(user_node, user_host, contact_jid);
  -- Update contact's roster to say subscription is cancelled...
  rm.unsubscribed(contact_username, contact_host, user_jid);
end

local function Response(status_code, message, array)
  local response = { };

  local ok, error = pcall(function()
    message = JSON.encode({ result = message });
  end);

  if not ok or error then
    response.status_code = 500
    response.body = "Failed to encode JSON response";
  else
    response.status_code = status_code;
    response.body = message;
  end

  return response;
end

-- Build static responses
local RESPONSES = {
  missing_auth    = Response(400, "Missing authorization header");
  invalid_auth    = Response(400, "Invalid authentication details");
  auth_failure    = Response(401, "Authentication failure");
  unauthorized    = Response(401, "User must be an administrator");
  decode_failure  = Response(400, "Request body is not valid JSON");
  invalid_path    = Response(404, "Invalid request path");
  invalid_method  = Response(405, "Invalid request method");
  invalid_body    = Response(400, "Body does not exist or is malformed");
  invalid_host    = Response(404, "Host does not exist or is malformed");
  invalid_user    = Response(404, "User does not exist or is malformed");
  invalid_contact = Response(404, "Contact does not exist or is malformed");
  drop_message    = Response(501, "Message dropped per configuration");
  internal_error  = Response(500, "Internal server error");
  pong            = Response(200, "PONG");
};

local function respond(event, res, headers)
	local response = event.response;

  if headers then
    for header, data in pairs(headers) do
      response.headers[header] = data;
    end
  end

  response.headers.content_type = "application/json";
  response.status_code = res.status_code;
  response:send(res.body);
end

local function get_host(hostname)
  return hosts[hostname];
end

local function get_sessions(hostname)
  local host = get_host(hostname);
  return host and host.sessions;
end

local function get_session(hostname, username)
  local sessions = get_sessions(hostname);
  return sessions and sessions[username];
end

local function get_connected_users(hostname)
  local sessions = get_sessions(hostname);
  local users = { };

  for username, user in pairs(sessions or {}) do
    for resource, _ in pairs(user.sessions or {}) do
      table.insert(users, {
        username = username,
        resource = resource
      });
    end
  end

  return users;
end

local function get_recipient(hostname, username)
  local session = get_session(hostname, username)
  local offline = not session and um.user_exists(username, hostname);
  return session, offline;
end

local function normalize_user(user)
  local cleaned = { };
  cleaned.connected = user.connected or false;
  cleaned.sessions  = { };
  cleaned.roster    = { };

  for resource, session in pairs(user.sessions or {}) do
    local c_session = {
      resource = resource;
      id       = session.conn.id;
      ip       = session.conn._ip;
      port     = session.conn._port;
      secure   = session.secure;
    }
    table.insert(cleaned.sessions, c_session);
  end

  if user.roster and #user.roster > 0 then
    cleaned.roster = user.roster;
  end

  return cleaned;
end

local function get_user_connected(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end

  local jid = jid.join(username, hostname);
  local connected = get_session(hostname, username);
  local response;

  if connected then
    response = Response(200, { connected = true });
  else
    response = Response(404, { connected = false });
  end

  respond(event, response);
end

local function get_user(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end

  if not um.user_exists(username, hostname) then
    local joined = jid.join(username, hostname)
    return respond(event, Response(404, "User does not exist: " .. joined));
  end

  if path.attribute == "connected" then
    return get_user_connected(event, path, body);
  end

  local user = { hostname = hostname, username = username };
  local session = get_session(hostname, username);

  if session then
    user.connected = true;
    user.roster = session.roster;
    user.sessions = session.sessions;
  else
    user.roster = rm.load_roster(username, hostname);
  end

  local response = { user = normalize_user(user) };
  respond(event, Response(200, response));
end

local function get_users(event, path, body)
  local sessions = get_sessions(hostname);

  if path.resource == "count" then
    local count = 0;
    for _ in pairs(sessions or {}) do
      count = count + 1;
    end
    respond(event, Response(200, { count = count }));
  else
    local users = { };
    for username, user in pairs(sessions or {}) do
      for resource, _ in pairs(user.sessions or {}) do
        table.insert(users, {
          username = username,
          resource = resource
        });
      end
    end
    respond(event, Response(200, { users = users, count = #users }));
  end
end

local function get_roster(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end

  if not um.user_exists(username, hostname) then
    local joined = jid.join(username, hostname)
    return respond(event, Response(404, "User does not exist: " .. joined));
  end

  local roster = rm.load_roster(username, hostname);

  local query = {};
  for jid in pairs(roster) do
    if jid then
      local grouplist = {};
      for group in pairs(roster[jid].groups) do
        table.insert(grouplist, group);
      end
      table.insert(query, {"item", {
        jid = jid,
        subscription = roster[jid].subscription,
        ask = roster[jid].ask,
        name = roster[jid].name,
        group = grouplist
      }});
    end
  end

  respond(event, Response(200, { roster = query, count = #query }));
end

local function add_roster(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end
  local user_jid = jid.join(username, hostname);

  local contact_jid = body["contact"];

  if not contact_jid then
    return respond(event, RESPONSES.invalid_contact);
  end

  if not um.user_exists(username, hostname) then
    return respond(event, Response(404, "User does not exist: " .. user_jid));
  end

-- Make a mutual subscription between jid1 and jid2. Each JID will see
-- when the other one is online.
  subscribe(user_jid, contact_jid);
  subscribe(contact_jid, user_jid);

  local result = 'Roster registered: ' .. user_jid .. ' and ' .. contact_jid;

  respond(event, Response(200, result));

  module:fire_event("roster-registered", {
    username = username;
    hostname = hostname;
    contact_jid = contact_jid;
    source   = "mod_admin_rest";
  })

  module:log("info", result);
end

local function remove_roster(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end

  local user_jid = jid.join(username, hostname)

  if not um.user_exists(username, hostname) then
    return respond(event, Response(404, "User does not exist: " .. user_jid));
  end

  local contact_jid = body["contact"];

  if not contact_jid then
    return respond(event, RESPONSES.invalid_contact);
  end

-- Make a mutual subscription between jid1 and jid2. Each JID will see
-- when the other one is online.
  unsubscribe(user_jid, contact_jid);
  unsubscribe(contact_jid, user_jid);

  local roster = rm.load_roster(username, hostname);
  roster[contact_jid] = nil;
  rm.save_roster(username, hostname, roster);

  local result = 'Roster deleted: ' .. user_jid .. ' and ' .. contact_jid;

  respond(event, Response(200, result));

  module:fire_event("roster-deleted", {
    username = username;
    hostname = hostname;
    contact_jid = contact_jid;
    source   = "mod_admin_rest";
  })

  module:log("info", result);
end

local function add_user(event, path, body)
  local username = sp.nodeprep(path.resource);
  local password = body["password"];
  local regip = body["regip"];

  if not username then
    return respond(event, RESPONSES.invalid_path);
  end

  if not password then
    return respond(event, RESPONSES.invalid_body);
  end

  local jid = jid.join(username, hostname);

  if um.user_exists(username, hostname) then
    return respond(event, Response(409, "User already exists: " .. jid));
  end

  if not um.create_user(username, password, hostname) then
    return respond(event, RESPONSES.internal_error);
  end

  local result = "User registered: " .. jid;

  respond(event, Response(201, result));

  module:fire_event("user-registered", {
    username = username,
    host = hostname,
    ip = regip,
    source   = "mod_admin_rest"
  })

  module:log("info", result);
end

local function remove_user(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    return respond(event, RESPONSES.invalid_user);
  end

  local jid = jid.join(username, hostname);

  if not um.user_exists(username, hostname) then
    return respond(event, Response(404, "User does not exist: " .. jid));
  end

  if not um.delete_user(username, hostname) then
    return respond(event, RESPONSES.internal_error);
  end

  respond(event, Response(200, "User deleted: " .. jid));

  module:fire_event("user-deleted", {
    username = username;
    hostname = hostname;
    source = "mod_admin_rest";
  });

  module:log("info", "Deregistered user: " .. jid);
end

local function patch_user(event, path, body)
  local username = sp.nodeprep(path.resource);
  local attribute = path.attribute;

  if not (username and attribute)  then
    return respond(event, RESPONSES.invalid_path);
  end

  local jid = jid.join(username, hostname);

  if not um.user_exists(username, hostname) then
    return respond(event, Response(404, "User does not exist: " .. jid));
  end

  if attribute == "password" then
    local password = body.password;
    if not password then
      return respond(event, RESPONSES.invalid_body);
    end
    if not um.set_password(username, password, hostname) then
      return respond(event, RESPONSES.internal_error);
    end
  end

  local result = "User modified: " .. jid;

  respond(event, Response(200, result));

  module:log("info", result);
end

local function offline_enabled()
  return mm.is_loaded(hostname, "offline")
      or mm.is_loaded(hostname, "offline_bind")
      or false;
end

local multicast_prefix = module:get_option_string("admin_rest_multicast_prefix", nil);

local function send_multicast(event, path, body)
  local recipients = body.recipients;
  local sent = 0;
  local delayed = 0;

  for i=1, #recipients do
    repeat
      local recipient = recipients[i];
      local msg = recipient.message;
      local node = recipient.to;

      if not node or not msg then break end

      if multicast_prefix then
        msg = multicast_prefix .. msg;
      end

      local session, offline = get_recipient(hostname, node);

      if not session and not offline then break end

      local attrs = { from = hostname, to = jid.join(node, hostname) };

      local message = stanza.message(attrs, msg);

      if offline and offline_enabled() then
        module:fire_event("message/offline/handle", {
          stanza = stanza.deserialize(message);
        });
        delayed = delayed + 1;
      elseif session then
        for _, session in pairs(session.sessions or {}) do
          session.send(message);
        end
        sent = sent + 1;
      end

    until true
  end

  local result;

  if sent + delayed > 0 then
    result = "Message multicasted to users: " .. sent .. "/" .. delayed;
    respond(event, Response(200, result));
  else
    result = "No multicast recipients";
    respond(event, Response(404, result));
  end

  module:log("info", result);
end

local message_prefix = module:get_option_string("admin_rest_message_prefix", nil);

local function send_message(event, path, body)
  local username = sp.nodeprep(path.resource);

  if not username then
    if body.recipients then
      return send_multicast(event, path, body);
    else
      return respond(event, RESPONSES.invalid_user);
    end
  end

  local session, offline = get_recipient(hostname, username);

  if not session and not offline then
    return respond(event, RESPONSES.invalid_user);
  end

  if message_prefix then
    body.message = message_prefix .. body.message;
  end

  local jid = jid.join(username, hostname);
  local message = stanza.message({ to = jid, from = hostname}, body.message);

  if offline then
    if not offline_enabled() then
      respond(event, RESPONSES.drop_message);
      return
    else
      respond(event, Response(202, "Message sent to offline queue: " .. jid));
      module:fire_event("message/offline/handle", {
        stanza = stanza.deserialize(message)
      });
      return
    end
  end

  for resource, session in pairs(session.sessions or {}) do
    session.send(message)
  end

  local result = "Message sent to user: " .. jid;

  respond(event, Response(200, result));

  module:log("info", result);
end

local broadcast_prefix = module:get_option_string("admin_rest_broadcast_prefix", nil);

local function broadcast_message(event, path, body)
  local attrs = { from = hostname };
  local count = 0;

  if broadcast_prefix then
    body.message = broadcast_prefix .. body.message;
  end

  for username, session in pairs(get_sessions(hostname) or {}) do
    attrs.to = jid.join(username, hostname);
    local message = stanza.message(attrs, body.message);

    for _, session in pairs(session.sessions or {}) do
      session.send(message);
    end

    count = count + 1;
  end

  respond(event, Response(200, { count = count }));

  if count > 0 then
    module:log("info", "Message broadcasted to users: " .. count);
  end
end

function get_module(event, path, body)
  local modulename = path.resource;

  if not modulename then
    return respond(event, RESPONSES.invalid_path);
  end

  local result = { module = modulename };
  local status;

  if not mm.is_loaded(hostname, modulename) then
    result.loaded = false;
    status = 404;
  else
    result.loaded = true;
    status = 200;
  end

  respond(event, Response(status, result))
end

function get_modules(event, path, body)
  local modules = mm.get_modules(hostname);

  local list = { }

  for name in pairs(modules or {}) do
    table.insert(list, name);
  end

  local result = { count = #list };

  if path.resource ~= "count" then
    result.modules = list;
  end

  respond(event, Response(200, result));
end

function load_module(event, path, body)
  local modulename = path.resource;
  local fn = "load";

  if mm.is_loaded(hostname, modulename) then fn = "reload" end

  if not mm[fn](hostname, modulename) then
    return respond(event, RESPONSES.internal_error);
  end

  local result = "Module loaded: " .. modulename;

  respond(event, Response(200, result));

  module:log("info", result);
end

function unload_module(event, path, body)
  local modulename = path.resource;

  if not mm.is_loaded(hostname, modulename) then
    return respond(event, Response(404, "Module is not loaded:" .. modulename));
  end

  mm.unload(hostname, modulename);

  local result = "Module unloaded: " .. modulname;

  respond(event, Response(200, result));

  module:log("info", result);
end

local function get_whitelist(event, path, body)
  local list = { };

  if whitelist then
    for ip, _ in pairs(whitelist) do
      table.insert(list, ip);
    end
  end

  respond(event, Response(200, { whitelist = list, count = #list }));
end

local function add_whitelisted(event, path, body)
  local ip = path.resource;
  if not whitelist then whitelist = { } end

  whitelist[ip] = true;

  local result = "IP added to whitelist: " .. ip;

  respond(event, Response(200, result));

  module:log("warn", result);
end

local function remove_whitelisted(event, path, body)
  local ip = path.resource;

  if not whitelist or not whitelist[ip] then
    return respond(event, Response(404, "IP is not whitelisted: " .. ip));
  end

  local new_list = { };
  for whitelisted, _ in pairs(whitelist) do
    if whitelisted ~= ip then
      new_list[whitelisted] = true;
    end
  end
  whitelist = new_list;

  local result = "IP removed from whtielist: " .. ip;

  respond(event, Response(200, result));

  module:log("warn", result);
end

local function ping(event, path, body)
  return respond(event, RESPONSES.pong);
end

--Routes and suitable request methods
local ROUTES = {
  ping = {
    GET = ping;
  };

  user = {
    GET    = get_user;
    POST   = add_user;
    DELETE = remove_user;
    PATCH  = patch_user;
  };

  user_connected = {
    GET = get_user_connected;
  };

  users = {
    GET = get_users;
  };

  roster = {
    GET = get_roster;
    POST = add_roster;
    DELETE = remove_roster;
  };

  message = {
    POST = send_message;
  };

  broadcast = {
    POST = broadcast_message;
  };

  modules = {
    GET = get_modules;
  };

  module = {
    GET    = get_module;
    PUT    = load_module;
    DELETE = unload_module;
  };

  whitelist = {
    GET    = get_whitelist;
    PUT    = add_whitelisted;
    DELETE = remove_whitelisted;
  }
};

--Reserved top-level request routes
local RESERVED = to_set({ "admin" });

--Entry point for incoming requests.
--Authenticate admin and route request.
local function handle_request(event)
  local request = event.request;

  -- Check whitelist for IP
  if whitelist and not whitelist[request.conn._ip] then
    return respond(event, { status_code = 401, message = nil });
  end

  -- ********** Authenticate ********** --

  -- Prevent insecure requests
  if secure and not request.secure then return end

  -- Request must have authorization header
  if not request.headers["authorization"] then
    return respond(event, RESPONSES.missing_auth);
  end

  local auth = request.headers.authorization;
  local username, password = parse_auth(auth);

  username = jid.prep(username);

  -- Validate authentication details
  if not username or not password then
    return respond(event, RESPONSES.invalid_auth);
  end

  local user_node, user_host = jid.split(username);

  -- Validate host
  if not hosts[user_host] then
    return respond(event, RESPONSES.invalid_host);
  end

  -- Authenticate user
  if not um.test_password(user_node, user_host, password) then
    return respond(event, RESPONSES.auth_failure);
  end

  -- ********** Route ********** --

  local path = parse_path(request.path);
  local route, hostname = path.route, hostname;

  -- Restrict to admin
  if not um.is_admin(username, hostname) then
    return respond(event, RESPONSES.unauthorized);
  end

  local handlers = ROUTES[route];

  -- Confirm that route exists
  if not route or not handlers then
    return respond(event, RESPONSES.invalid_path);
  end

  -- Confirm that the host exists
  if not RESERVED[route] then
    if not hostname or not hosts[hostname] then
      return respond(event, RESPONSES.invalid_host);
    end
  end

  local handler = handlers[request.method];

  -- Confirm that handler exists for method
  if not handler then
    return respond(event, RESPONSES.invalid_method);
  end

  local body = { };

  -- Parse JSON request body
  if request.body and #request.body > 0 then
    if not pcall(function() body = JSON.decode(request.body) end) then
      return respond(event, RESPONSES.decode_failure);
    end
    if not body["regip"] then
      body["regip"] = request.conn._ip;
    end
  end

  return handler(event, path, body);
end

module:depends("http");

module:provides("http", {
  name = base_path:gsub("^/", "");
  route = {
    ["GET /*"]    = handle_request;
    ["POST /*"]   = handle_request;
    ["PUT /*"]    = handle_request;
    ["DELETE /*"] = handle_request;
    ["PATCH /*"]  = handle_request;
  };
})
