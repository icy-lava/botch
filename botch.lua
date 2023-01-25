local lithium = require('lithium.init')
local stringx, tablex, lexer, iox = lithium.stringx, lithium.tablex, lithium.lexer, lithium.iox
local unpack = table.unpack

local major = 0
local minor = 1
local patch = 2
local version = tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch)

local splitIP = function(ip)
	local i, modname = ip:match('^(%d+):(.*)$')
	if i then
		i = tonumber(i)
	end
	assert(i, 'corrupted address')
	return i, modname
end

local mergeIP = function(i, modname)
	return tostring(i) .. ":" .. tostring(modname)
end

local getLocation = function(context, ip)
	if ip == nil then
		ip = context.ip
	end
	local i, modname = splitIP(ip)
	local module = context.modules[modname]
	local line, col = stringx.positionAt(module.source, module.tokens[i].start)
	return module.filename or module.name, line, col, module.tokens[i]
end

local getLocationString = function(context, ip)
	local filename, line, col, token = getLocation(context, ip)
	return tostring(filename) .. ":" .. tostring(line) .. ":" .. tostring(col), token.value
end

local botchErrorID = {}
local botchError = function(message)
	return coroutine.yield({
		message = message,
		botchErrorID = botchErrorID
	})
end

local isBotchError = function(errObject)
	return ('table' == type(errObject)) and errObject.botchErrorID == botchErrorID
end

local getBotchError = function(cor, status, ...)
	if status then
		if select('#', ...) == 1 and isBotchError((...)) then
			return (...)
		end
		return nil
	else
		local err = ...
		local trace = debug.traceback(cor, err, 2)
		io.stderr:write(trace, '\n')
		return os.exit(1)
	end
end

local blameNoone = function(message)
	io.stderr:write("error: " .. tostring(message) .. "\n")
	return botchError(message)
end

local blameModule = function(module, message)
	io.stderr:write(tostring(module.filename or module.name) .. ": error: " .. tostring(message) .. "\n")
	return botchError(message)
end

local blameByteInModule = function(module, i, message)
	local line, col = stringx.positionAt(module.source, i)
	io.stderr:write(tostring(module.filename or module.name) .. ":" .. tostring(line) .. ":" .. tostring(col) .. ": error: " .. tostring(message) .. "\n")
	return botchError(message)
end

local blameTokenInModule = function(module, token, message)
	if 'number' == type(token) then
		token = module.tokens[token]
	end
	return blameByteInModule(module, token.start, message)
end

local blameRuntime = function(context, message)
	if not (context.stack and context.functionStack) then
		error('runtime not initialized')
	end
	io.stderr:write(tostring(getLocationString(context)) .. ": error: " .. tostring(message) .. "\n")
	local fslen = #context.functionStack
	local to = math.max(1, fslen - 5 + 1)
	for i = fslen, to, -1 do
		if i == to then
			if i > 1 then
				io.stderr:write('    ...\n')
			end
			i = 1
		end
		local ip = context.functionStack[i]
		local location, token = getLocationString(context, ip)
		io.stderr:write("    at " .. tostring(location) .. " in " .. tostring(token) .. "\n")
	end
	return botchError(message)
end

local contextMT
local loadSource = function(filename, source, context, modname)
	if modname == nil then modname = '' end
	
	if not (source) then
		if filename then
			local err
			source, err = iox.readBytes(filename)
			if not (source) then
				return nil, err
			end
		else
			error('either source data or filename must be provided')
		end
	end
	
	if context then
		context = context:clone()
	else
		context = setmetatable({
			modules = {},
			labels = {}
		}, contextMT)
	end
	
	if context.modules[modname] then
		return nil, "module '" .. tostring(modname) .. "' already exists"
	end
	
	local module = {
		name = modname,
		filename = filename,
		source = source
	}
	
	context.modules[modname] = module
	local _, errByte
	module.tokens, _, errByte = lexer.lex(source, {
		{'whitespace','%s+'},
		{'literal','"([^"]*)"',"'([^']*)'",'%d+'},
		{'import',':([%w%-_/%.]+)'},
		{'label','([%w%-_]+):'},
		{'address','@([%w%-_]+)'},
		{'comment','#[^\n]*'},
		{'identifier','[^%c%s@:]+'}
	})
	
	if not (module.tokens) then
		blameByteInModule(module, errByte, 'unrecognized token')
	end
	
	module.tokens = tablex.ireject(module.tokens, function(token)
		return token.type == 'whitespace' or token.type == 'comment'
	end)
	
	module.tokens = tablex.map(module.tokens, function(token)
		token.value = token.captures[1] or token.captures[0]
		token.captures = nil
		return token
	end)
	
	local directory = filename and filename:gsub('[^/\\]+$', '') or ''
	for i, token in ipairs(module.tokens) do
		if 'label' == token.type then
			if context.labels[token.value] then
				blameTokenInModule(module, token, "redefinition of label '" .. tostring(token.value) .. "'")
			end
			context.labels[token.value] = mergeIP(i, module.name)
		elseif 'import' == token.type then
			modname = token.value
			local err
			context, err = loadSource(tostring(directory) .. tostring(modname) .. ".bot", nil, context, modname)
			if not (context) then
				context = loadSource(tostring(directory) .. tostring(modname) .. "/init.bot", nil, context, modname)
			end
			if not (context) then
				blameTokenInModule(module, token, "could not import module '" .. tostring(modname) .. "': " .. tostring(err))
			end
		end
	end
	
	for i, token in ipairs(module.tokens) do
		if token.type == 'address' then
			if not (context.labels[token.value]) then
				blameTokenInModule(module, token, 'no such label exists')
			end
			token.type = 'literal'
			token.value = context.labels[token.value]
		end
	end
	
	return context
end

contextMT = {
	__index = {
		clone = function(self)
			return setmetatable(table.clone(self), contextMT)
		end,
		nextIP = function(self)
			local i, modname = splitIP(self.ip)
			self.ip = tostring(i + 1) .. ":" .. tostring(modname)
		end,
		getToken = function(self, ip)
			if ip == nil then
				ip = self.ip
			end
			local i, modname = splitIP(ip)
			local module = self.modules[modname]
			assert(module, "module '" .. tostring(modname) .. "' does not exist in the context")
			local token = module.tokens[i]
			if not (token) then
				return nil, "token " .. tostring(i) .. " in module '" .. tostring(modname) .. "' does not exist"
			end
			return token
		end,
		blame = function(self, message)
			return blameRuntime(self, message)
		end,
		popi = function(self, i)
			if #self.stack < 1 then
				self:blame("expected a value on the stack, got none")
			end
			local value = self.stack[i]
			if not (value) then
				error("invalid stack index " .. tostring(i))
			end
			table.remove(self.stack, i)
			return value
		end,
		popn = function(self, n)
			if #self.stack < n then
				self:blame("expected at least " .. tostring(n) .. " values on the stack, got " .. tostring(#self.stack))
			end
			local values = {}
			for i = n, 1, -1 do
				values[i] = self:pop()
			end
			return values
		end,
		pop = function(self)
			return self:popi(#self.stack)
		end,
		popnum = function(self)
			local value = self:pop()
			value = tonumber(value)
			if not (value) then
				self:blame('expected a number as argument')
			end
			return value
		end,
		popbool = function(self)
			return self:pop() ~= '0'
		end,
		pushi = function(self, i, value)
			local typ = type(value)
			if 'boolean' == typ then
				value = value and '1' or '0'
			elseif 'nil' == typ or 'table' == typ then
				error("atempted to push a " .. tostring(type(value)) .. " value onto the stack", 2)
			end
			return table.insert(self.stack, i, tostring(value))
		end,
		push = function(self, value)
			return self:pushi(#self.stack + 1, value)
		end,
		canReturn = function(self)
			return #self.functionStack > 0
		end,
		call = function(self, ip)
			if #self.functionStack >= 1024 then
				self:blame('function stack overflow')
			end
			table.insert(self.functionStack, self.ip)
			self.ip = ip
		end,
		execute = function(self, symbol, repl)
			if repl == nil then repl = false end
			
			if 'write' == symbol then
				local value = self:pop()
				io.stdout:write(value)
			elseif 'write-line' == symbol then
				local value = self:pop()
				io.stdout:write(value, '\n')
			elseif 'ewrite' == symbol then
				local value = self:pop()
				io.stderr:write(value)
			elseif 'ewrite-line' == symbol then
				local value = self:pop()
				io.stderr:write(value, '\n')
			elseif 'read-line' == symbol then
				self:push(io.stdin:read('*l'))
			elseif 'read-all' == symbol then
				self:push(io.stdin:read('*a'))
			elseif 'read-bytes' == symbol then
				local count = self:popnum()
				self:push(io.stdin:read(count))
			elseif 'stack-count' == symbol then
				self:push(#self.stack)
			elseif 'store' == symbol then
				self:pushi(1, self:pop())
			elseif 'load' == symbol then
				self:push(self:popi(1))
			elseif 'swap' == symbol then
				local a, b = unpack(self:popn(2))
				self:push(b)
				self:push(a)
			elseif 'dup' == symbol then
				local value = self:pop()
				self:push(value)
				self:push(value)
			elseif 'dup2' == symbol then
				local a, b = unpack(self:popn(2))
				self:push(a)
				self:push(b)
				self:push(a)
				self:push(b)
			elseif 'delete' == symbol then
				self:pop()
			elseif 'delete2' == symbol then
				self:popn(2)
			elseif 'error' == symbol then
				self:blame(self:pop())
			elseif 'trace' == symbol then
				local values = {}
				for i, value in ipairs(self.stack) do
					values[i] = string.format('%q', value)
				end
				io.stderr:write("stack (" .. tostring(#self.stack) .. "): ", table.concat(values, ', '), '\n')
			elseif 'concat' == symbol then
				local a, b = unpack(self:popn(2))
				self:push(a .. b)
			elseif 'length' == symbol then
				self:push(#self:pop())
			elseif '+' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a + b)
			elseif '-' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a - b)
			elseif '*' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a * b)
			elseif '**' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(math.pow(a, b))
			elseif '/' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a / b)
			elseif '//' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(math.floor(a / b))
			elseif '%' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a % b)
			elseif '++' == symbol then
				self:push(self:popnum() + 1)
			elseif '--' == symbol then
				self:push(self:popnum() - 1)
			elseif '<' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a < b)
			elseif '>' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a > b)
			elseif '<=' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a <= b)
			elseif '>=' == symbol then
				local b, a = self:popnum(), self:popnum()
				self:push(a >= b)
			elseif '=' == symbol then
				local a, b = unpack(self:popn(2))
				self:push(a == b)
			elseif 'or' == symbol then
				local b, a = self:popbool(), self:popbool()
				self:push(a or b)
			elseif 'and' == symbol then
				local b, a = self:popbool(), self:popbool()
				self:push(a and b)
			elseif 'xor' == symbol then
				local b, a = self:popbool(), self:popbool()
				self:push((a or b) and not (a and b))
			elseif 'not' == symbol then
				self:push(not self:popbool())
			elseif 'call' == symbol then
				self:call(self:popnum())
			elseif 'address' == symbol then
				local value = self:pop()
				value = self.labels[value]
				if not (value) then
					self:blame('no such label exists')
				end
				self:push(value)
			elseif 'jump' == symbol then
				local value = self:popnum()
				self.ip = value
			elseif 'cond-jump' == symbol then
				local address = self:pop()
				local condition = self:popbool()
				if condition then
					self.ip = address
				end
			elseif 'return' == symbol then
				local fslen = #self.functionStack
				if fslen == 0 then
					self:blame('function stack already empty')
				end
				self.ip = self.functionStack[fslen]
				self.functionStack[fslen] = nil
			elseif 'exit' == symbol then
				os.exit()
			else
				local replOK = repl
				if repl then
					if 'trace-on' == symbol then
						self.trace = nil
					elseif 'trace-off' == symbol then
						self.trace = false
					elseif 'help' == symbol then
						io.stderr:write("Help is not implemented yet. Sorry :(\n")
					else
						replOK = false
					end
				end
				if not (replOK) then
					local address = self.labels[symbol]
					if address then
						self:call(address)
					else
						self:blame('unrecognised symbol')
					end
				end
			end
			return self
		end
	}
}

local initializeRuntime = function(context, startIP)
	context.ip = startIP or context.labels.start
	if not (context.ip) then
		blameNoone("start label not found")
	end
	context.stack = {}
	context.functionStack = {}
	
	return setmetatable(context, contextMT)
end

local runContext = function(context, startIP, repl)
	if startIP then
		context.ip = startIP
	end
	do
		while true do
			local _continue_0 = false
			repeat
				local token = context:getToken()
				if not (token) then
					if context:canReturn() then
						context:execute('return', repl)
						context:nextIP()
						_continue_0 = true
						break
					else
						break
					end
				end
				local typ = token.type
				if 'literal' == typ then
					context:push(token.value)
				elseif 'identifier' == typ then
					context:execute(token.value, repl)
				end
				context:nextIP()
				_continue_0 = true
			until true
			if not _continue_0 then
				break
			end
		end
	end
	return context
end

local usage = function()
	io.stderr:write("usage: " .. tostring(arg[0]) .. " run <source>\n")
	io.stderr:write("   or: " .. tostring(arg[0]) .. " repl\n")
	return os.exit()
end

local command = arg[1] and arg[1]:lower()
if 'run' == command then
	if not (arg[2]) then
		usage()
	end
	local cor = coroutine.create(function()
		local context, err = loadSource(arg[2])
		if not (context) then
			blameNoone(err)
		end
		initializeRuntime(context)
		return runContext(context)
	end)
	while 'suspended' == coroutine.status(cor) do
		local err = getBotchError(cor, coroutine.resume(cor))
		if err then
			os.exit(1)
		end
	end
elseif 'repl' == command then
	local id = 1
	local context = nil
	io.stderr:write("Welcome to Botch " .. tostring(version) .. "\n")
	while true do
		local name = "repl-" .. tostring(id)
		io.stderr:write("(" .. tostring(id) .. ") $ ")
		io.stderr:flush()
		local input = assert(io.stdin:read('*l'))
		local cor = coroutine.create(function()
			local newContext, err = loadSource(nil, input, context, name)
			initializeRuntime(newContext, mergeIP(1, name))
			if newContext then
				newContext.stack = context and table.icopy(context.stack) or newContext.stack
				runContext(newContext, nil, true)
				context = newContext
				io.stdout:flush()
				if context.trace ~= false then
					context:execute('trace')
				end
			else
				io.stderr:write(tostring(err) .. "\n")
			end
			return io.stderr:flush()
		end)
		while 'suspended' == coroutine.status(cor) do
			local err = getBotchError(cor, coroutine.resume(cor))
			if err then
				break
			end
		end
		id = id + 1
	end
else
	return usage()
end
