-- require 'tl'.loader()

local lithium = require('lithium.init')
local stringx, tablex, lexer, iox = lithium.stringx, lithium.tablex, lithium.lexer, lithium.iox
local unpack = table.unpack

local major = 0
local minor = 2
local patch = 0
local version = tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch)

local type common = require 'lithium.common'
local type Packed = common.Packed

local type Token = record
	-- From lithium.lexer
	type: string
	start: integer
	stop: integer
	match: string
	captures: Packed<string>
	-- Additional fields
	value: string
end

local type IP = string

local record Module
	source: string
	filename: string
	name: string
	tokens: {Token}
end

local record Context
	ip: IP
	labels: {string:IP}
	modules: {string:Module}
	
	-- Runtime
	stack: {string}
	functionStack: {IP}
	
	-- REPL
	trace: boolean
	
	-- Predefine
	clone: function(self: Context): Context
	-- FIXME: this will not fail with colon syntax even though it's a mistake
	new: function(t: Context): Context
end

local function splitIP(ip: IP): integer, string
	local istr, modname = ip:match('^(%d+):(.*)$')
	local i: integer
	if istr then
		i = tonumber(istr)
	end
	assert(i, 'corrupted address')
	return i, modname
end

local function mergeIP(i: integer, modname: string): IP
	return tostring(i) .. ":" .. tostring(modname)
end

local function getLocation(context: Context, ip: IP): string, integer, integer, Token
	if ip == nil then
		ip = context.ip
	end
	local i, modname = splitIP(ip)
	local module = context.modules[modname]
	local line, col = stringx.positionAt(module.source, module.tokens[i].start)
	return module.filename or module.name, line, col, module.tokens[i]
end

local function getLocationString(context: Context, ip: IP): string, string
	local filename, line, col, token = getLocation(context, ip)
	return tostring(filename) .. ":" .. tostring(line) .. ":" .. tostring(col), token.value
end

local botchErrorID = {}
local record BotchError
	botchErrorID: table
	message: string
end

local function createBotchError(message: string): BotchError
	return {
		botchErrorID = botchErrorID,
		message = message,
	}
end

local function isBotchError(errObject: any): boolean
	return errObject is table and errObject.botchErrorID == botchErrorID
end

local function botchError(message: string)
	coroutine.yield(createBotchError(message))
end

local function getBotchError(cor: thread, status: boolean, ...: any): BotchError
	if status then
		if select('#', ...) == 1 and isBotchError((...)) then
			return (...) as BotchError
		end
		return nil
	else
		local err = ...
		local trace = debug.traceback(cor, tostring(err), 2)
		io.stderr:write(trace, '\n')
		return os.exit(1)
	end
end

local function blameNoone(message: string)
	io.stderr:write("error: " .. tostring(message) .. "\n")
	botchError(message)
end

local function blameByteInModule(module: Module, i: integer, message: string)
	local line, col = stringx.positionAt(module.source, i)
	io.stderr:write(tostring(module.filename or module.name) .. ":" .. tostring(line) .. ":" .. tostring(col) .. ": error: " .. tostring(message) .. "\n")
	botchError(message)
end

local function blameTokenInModule(module: Module, token: Token | integer, message: string)
	local tokenObj : Token
	if token is integer then
		tokenObj = module.tokens[token]
	else
		tokenObj = token
	end
	blameByteInModule(module, tokenObj.start, message)
end

local function loadSource(filename: string, source: string, context: Context, modname: string): Context, string
	if modname == nil then modname = '' end
	
	if not (source) then
		if filename then
			local err: string
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
		context = Context.new {
			modules = {},
			labels = {}
		}
	end
	
	if context.modules[modname] then
		return nil, "module '" .. tostring(modname) .. "' already exists"
	end
	
	local module : Module = {
		name = modname,
		filename = filename,
		source = source
	}
	
	context.modules[modname] = module
	local tokens, _, errByte: {lexer.Token}, string, integer
	tokens, _, errByte = lexer.lexString(source, {
		{'whitespace','%s+'},
		{'literal','"([^"]*)"',"'([^']*)'",'%d+'},
		{'import',':([%w%-_/%.]+)'},
		{'label','([%w%-_]+):'},
		{'address','@([%w%-_]+)'},
		{'comment','#[^\n]*'},
		{'identifier','[^%c%s@:]+'}
	})
	
	module.tokens = tokens as {Token} -- NOTE: sus
	
	if not (module.tokens) then
		blameByteInModule(module, errByte, 'unrecognized token')
	end
	
	module.tokens = tablex.ireject(module.tokens, function(token: Token): boolean
		return token.type == 'whitespace' or token.type == 'comment'
	end)
	
	module.tokens = tablex.map(module.tokens, function(token: Token): Token
		token.value = token.captures and token.captures[1] or token.match
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
			local err: string
			context, err = loadSource(tostring(directory) .. tostring(modname) .. ".bot", nil, context, modname)
			if not (context) then
				context = loadSource(tostring(directory) .. tostring(modname) .. "/init.bot", nil, context, modname)
			end
			if not (context) then
				blameTokenInModule(module, token, "could not import module '" .. tostring(modname) .. "': " .. tostring(err))
			end
		end
	end
	
	for _, token in ipairs(module.tokens) do
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

local ContextMT : metatable<Context> = {__index = Context}

function Context.new(t: Context): Context
	return setmetatable(t or {}, ContextMT)
end

function Context:clone(): Context
	return setmetatable(tablex.clone(self), ContextMT)
end

function Context:initializeRuntime(startIP: IP)
	self.ip = startIP or self.labels.start
	if not self.ip then
		blameNoone("start label not found")
	end
	self.stack = {}
	self.functionStack = {}
end

function Context:nextIP()
	local i, modname = splitIP(self.ip)
	self.ip = mergeIP(i + 1, modname)
end

function Context:getToken(ip: IP): Token, string
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
end

function Context:blame(message: string)
	if not (self.stack and self.functionStack) then
		error('runtime not initialized')
	end
	io.stderr:write(tostring((getLocationString(self))) .. ": error: " .. tostring(message) .. "\n")
	local fslen = #self.functionStack
	local to = math.max(1, fslen - 5 + 1)
	for i = fslen, to, -1 do
		if i == to then
			if i > 1 then
				io.stderr:write('    ...\n')
			end
			i = 1
		end
		local ip = self.functionStack[i]
		local location, token = getLocationString(self, ip)
		io.stderr:write("    at " .. tostring(location) .. " in " .. tostring(token) .. "\n")
	end
	botchError(message)
end

function Context:popi(i: integer): string
	if #self.stack < 1 then
		self:blame("expected a value on the stack, got none")
	end
	local value = self.stack[i]
	if not (value) then
		error("invalid stack index " .. tostring(i))
	end
	table.remove(self.stack, i)
	return value
end

function Context:pop(): string
	return self:popi(#self.stack)
end

function Context:popn(n: integer): {string}
	if #self.stack < n then
		self:blame("expected at least " .. tostring(n) .. " values on the stack, got " .. tostring(#self.stack))
	end
	local values: {string} = {}
	for i = n, 1, -1 do
		values[i] = self:pop()
	end
	return values
end

function Context:popnum(): number
	local value = tonumber(self:pop())
	if not value then
		self:blame('expected a number as argument')
	end
	return value
end

function Context:popbool(): boolean
	return self:pop() ~= '0'
end

function Context:pushi(i: integer, value: string | boolean | number)
	if value is boolean then
		value = value and '1' or '0'
	end
	table.insert(self.stack, i, tostring(value))
end

function Context:push(value: string | boolean | number)
	self:pushi(#self.stack + 1, value)
end

function Context:canReturn(): boolean
	return #self.functionStack > 0
end

function Context:call(ip: IP)
	if #self.functionStack >= 1024 then
		self:blame('function stack overflow')
	end
	table.insert(self.functionStack, self.ip)
	self.ip = ip
end

function Context:execute(symbol: string, repl: boolean)
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
		local line, err = io.stdin:read('*l')
		if not line then
			self:blame(err)
		end
		self:push(line)
	elseif 'read-all' == symbol then
		local all, err = io.stdin:read('*a')
		if not all then
			self:blame(err)
		end
		self:push(all)
	elseif 'read-bytes' == symbol then
		local count = self:popnum()
		local bytes, err = io.stdin:read(count)
		if not bytes then
			self:blame(err)
		end
		self:push(bytes)
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
		local address = self:pop()
		self:call(address)
	elseif 'address' == symbol then
		local value = self:pop()
		local address = self.labels[value]
		if not address then
			self:blame('no such label exists')
		end
		self:push(address)
	elseif 'jump' == symbol then
		local address = self:pop()
		self.ip = address
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
		local replOK : boolean = repl
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
end

function Context:run(startIP: IP, repl: boolean)
	if startIP then
		self.ip = startIP
	end
	while true do
		local _continue_0 = false
		repeat
			local token = self:getToken()
			if not (token) then
				if self:canReturn() then
					self:execute('return', repl)
					self:nextIP()
					_continue_0 = true
					break
				else
					break
				end
			end
			local typ = token.type
			if 'literal' == typ then
				self:push(token.value)
			elseif 'identifier' == typ then
				self:execute(token.value, repl)
			end
			self:nextIP()
			_continue_0 = true
		until true
		if not _continue_0 then
			break
		end
	end
end

-------------------
--- CLI Section ---

local function usage()
	io.stderr:write("usage: " .. tostring(arg[0]) .. " run <source>\n")
	io.stderr:write("   or: " .. tostring(arg[0]) .. " repl\n")
	os.exit()
end

local command = arg[1] and arg[1]:lower()
if 'run' == command then
	if not arg[2] then
		usage()
	end
	local cor = coroutine.create(function()
		local context, err = loadSource(arg[2])
		if not (context) then
			blameNoone(err)
		end
		context:initializeRuntime()
		context:run()
	end)
	while 'suspended' == coroutine.status(cor) do
		local err = getBotchError(cor, coroutine.resume(cor))
		if err then
			os.exit(1)
		end
	end
elseif 'repl' == command then
	local id = 1
	local context: Context = nil
	io.stderr:write("Welcome to Botch " .. tostring(version) .. "\n")
	while true do
		local name = "repl-" .. tostring(id)
		io.stderr:write("(" .. tostring(id) .. ") $ ")
		io.stderr:flush()
		local input = assert(io.stdin:read('*l'))
		local cor = coroutine.create(function()
			local newContext, err = loadSource(nil, input, context, name)
			newContext:initializeRuntime(mergeIP(1, name))
			if newContext then
				newContext.stack = context and tablex.icopy(context.stack) or newContext.stack
				newContext:run(nil, true)
				context = newContext
				io.stdout:flush()
				if context.trace ~= false then
					context:execute('trace')
				end
			else
				io.stderr:write(tostring(err) .. "\n")
			end
			io.stderr:flush()
		end)
		while 'suspended' == coroutine.status(cor) do
			local err = getBotchError(cor, coroutine.resume(cor))
			if err then break end
		end
		id = id + 1
	end
else
	usage()
end
