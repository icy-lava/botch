-- require 'tl'.loader()

local lithium = require('lithium.init')
local stringx, tablex, lexer, iox = lithium.stringx, lithium.tablex, lithium.lexer, lithium.iox
local unpack = table.unpack

local major = 0
local minor = 3
local patch = 1
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

-- local type BotchStack = {string | BotchStack}
local type BotchValue = string | {BotchValue}
local type LuaStack = {string | boolean | number | LuaStack}
local type LuaValue = string | boolean | number | LuaStack

local record Context
	ip: IP
	labels: {string:IP}
	modules: {string:Module}
	
	-- Runtime
	stack: {BotchValue}
	stacks: {{BotchValue}}
	functionStack: {IP}
	
	-- REPL
	trace: boolean
	
	-- Predefine
	clone: function(self: Context): Context
	-- FIXME: this will not fail with colon syntax even though it's a mistake
	new: function(t: Context): Context
end

local function luaValueToBotch(value: LuaValue): string | {BotchValue}
	if value is string then
		return value
	elseif value is boolean then
		return value and '1' or '0'
	elseif value is number then
		return tostring(value)
	elseif value is LuaStack then
		local newStack: {BotchValue} = {}
		for i, v in ipairs(value) do
			newStack[i] = luaValueToBotch(v)
		end
		return newStack
	end
	error('don\'t know how to convert value ' .. tostring(value))
end

local function botchValueToLua(value: BotchValue): LuaValue
	if value is string then
		local num = tonumber(value)
		if not num then
			return value
		end
		return num
	else
		local newStack: LuaStack = {}
		for i, v in ipairs(value) do
			-- NOTE: sus
			newStack[i] = botchValueToLua(v) as (string | boolean | number | LuaStack)
		end
		return newStack
	end
	error('don\'t know how to convert value ' .. tostring(value))
end

local function stringifyLuaValue(value: LuaValue): string
	if value is string then
		return string.format('%q', value)
	elseif value is number then
		return tostring(value)
	elseif value is boolean then
		return tostring(value)
	elseif value is LuaStack then
		local stack: LuaStack = value
		local arr: {string} = {}
		for i = 1, #stack do
			arr[i] = stringifyLuaValue(stack[i])
		end
		return '{' .. table.concat(arr, ' ') .. '}'
	end
	error('don\'t know how to stringify value ' .. tostring(value))
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
	self.stacks = {}
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

function Context:poprawi(i: integer): BotchValue
	if #self.stack < 1 then
		self:blame("expected a value on the stack, got none")
	end
	local value = self.stack[i]
	if not value then
		error("invalid stack index " .. tostring(i))
	end
	table.remove(self.stack, i)
	return value
end

function Context:popraw(): BotchValue
	return self:poprawi(#self.stack)
end

function Context:popstri(i: integer): string
	local value = self:poprawi(i)
	if value is string then
		return value
	end
	self:blame("expected a string value on the stack")
end

function Context:popstr(): string
	return self:popstri(#self.stack)
end

function Context:popaddr(): IP
	local value = self:popraw()
	if value is string then
		if splitIP(value) then
			return value
		end
	end
	self:blame("expected an address on the stack")
end

function Context:popi(i: integer): LuaValue
	return botchValueToLua(self:poprawi(i))
end

function Context:pop(): LuaValue
	return self:popi(#self.stack)
end

function Context:popstack(): {BotchValue}
	local value = self:popraw()
	if value is {BotchValue} then
		return value
	end
	self:blame("expected a stack on the stack")
end

function Context:popn(n: integer): {LuaValue}
	if #self.stack < n then
		self:blame("expected at least " .. tostring(n) .. " values on the stack, got " .. tostring(#self.stack))
	end
	local values: {LuaValue} = {}
	for i = n, 1, -1 do
		values[i] = self:pop()
	end
	return values
end

function Context:popnum(): number
	local value = self:pop()
	if value is number then
		return value
	else
		self:blame('expected a number as argument')
	end
end

function Context:popbool(): boolean
	local value = self:popnum()
	return value ~= 0
end

function Context:pushrawi(i: integer, value: BotchValue)
	table.insert(self.stack, i, value)
end

function Context:pushraw(value: BotchValue)
	self:pushrawi(#self.stack + 1, value)
end

function Context:pushi(i: integer, value: LuaValue)
	local botchValue = luaValueToBotch(value)
	table.insert(self.stack, i, botchValue)
end

function Context:push(value: LuaValue)
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
	
	if 'new-stack' == symbol then
		self:push({})
	elseif 'enter' == symbol then
		-- FIXME: ideally we want a peek function and a type checking helper
		local stack = self:popstack()
		self:pushraw(stack)
		
		table.insert(self.stacks, self.stack)
		self.stack = stack
	elseif 'leave' == symbol then
		local stack = self.stacks[#self.stacks]
		-- FIXME: this is a botch error, not a lua error
		assert(stack, 'stack is empty')
		self.stacks[#self.stacks] = nil
		self.stack = stack
	elseif 'write' == symbol then
		local value = self:pop()
		io.stdout:write(stringifyLuaValue(value))
	elseif 'write-line' == symbol then
		local value = self:pop()
		io.stdout:write(stringifyLuaValue(value), '\n')
	elseif 'ewrite' == symbol then
		local value = self:pop()
		io.stderr:write(stringifyLuaValue(value))
	elseif 'ewrite-line' == symbol then
		local value = self:pop()
		io.stderr:write(stringifyLuaValue(value), '\n')
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
		-- FIXME: if it's a stack we want to clone it
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
		local value = self:pop()
		if value is string then
			self:blame(value)
		else
			self:blame(stringifyLuaValue(value))
		end
	elseif 'trace' == symbol then
		local values = {}
		for i, value in ipairs(self.stack) do
			values[i] = stringifyLuaValue(botchValueToLua(value))
		end
		io.stderr:write("stack (" .. tostring(#self.stack) .. "): ", table.concat(values, ' '), '\n')
	elseif 'concat' == symbol then
		local b = self:popstr()
		local a = self:popstr()
		self:push(a .. b)
	elseif 'length' == symbol then
		local value = self:popraw()
		if value is string then
			self:push(#value)
		else
			self:push(#value)
		end
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
		local address = self:popaddr()
		self:call(address)
	elseif 'address' == symbol then
		local value = self:popstr()
		local address = self.labels[value]
		if not address then
			self:blame('no such label exists')
		end
		self:push(address)
	elseif 'jump' == symbol then
		local address = self:popaddr()
		self.ip = address
	elseif 'cond-jump' == symbol then
		local address = self:popaddr()
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
		local replOK: boolean = repl
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
		if not replOK then
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
			if newContext then
				newContext:initializeRuntime(mergeIP(1, name))
				
				local stacks: {{BotchValue}}
				if context then
					stacks = tablex.imerge(context.stacks, {context.stack}) as {{BotchValue}}
					
					-- print(#newContext.stacks)
					-- local references: {{BotchValue}:boolean} = {}
					-- for _, stack in ipairs(stacks) do
					-- 	references[stack] = true
					-- end
					
					local newReferences: {{BotchValue}:{BotchValue}} = {}
					local function cloneStack(stack: {BotchValue}): {BotchValue}
						if not newReferences[stack] then
							local newStack: {BotchValue} = {}
							newReferences[stack] = newStack
							for i, v in ipairs(stack) do
								if v is {BotchValue} then
									newStack[i] = cloneStack(v)
								else
									newStack[i] = v
								end
							end
						end
						return newReferences[stack]
					end
					
					for i, stack in ipairs(stacks) do
						stacks[i] = cloneStack(stack)
					end
					
					newContext.stack = stacks[#stacks]
					stacks[#stacks] = nil
					newContext.stacks = stacks
				end
				
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
