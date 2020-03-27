local log = require "util.logger".init("sasl");

local _ENV = nil;
-- luacheck: std none

-- ================================
-- SASL PLAIN according to RFC 4616

--[[
Supported Authentication Backends

plain:
	function(username, realm)
		return password, state;
	end

plain_test:
	function(username, password, realm)
		return true or false, state;
	end
]]

local function token(self, message)
	if not message then
		return "failure", "malformed-request";
	end

	local token = message;
	local correct, username = self.profile.token_test(self, token);
	self.username = username

	if correct then
		return "success";
	else
		return "failure";
	end
end

local function init(registerMechanism)
	registerMechanism("TOKEN", {"token_test"}, token);
end

return {
	init = init;
}
