local lithium = require('lithium.init')
local string, table, lexer, io, util
string, table, lexer, io, util = lithium.string, lithium.table, lithium.lexer, lithium.io, lithium.util
local unpack
unpack = table.unpack
local major = 0
local minor = 1
local patch = 2
local version = tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch)
local splitIP
splitIP = function(ip)
  local i, modname = ip:match('^(%d+):(.*)$')
  if i then
    i = tonumber(i)
  end
  assert(i, 'corrupted address')
  return i, modname
end
local mergeIP
mergeIP = function(i, modname)
  return tostring(i) .. ":" .. tostring(modname)
end
local getLocation
getLocation = function(context, ip)
  if ip == nil then
    ip = context.ip
  end
  local i, modname = splitIP(ip)
  local module = context.modules[modname]
  local line, col = string.positionAt(module.source, module.tokens[i].start)
  return module.filename or module.name, line, col, module.tokens[i]
end
local getLocationString
getLocationString = function(context, ip)
  local filename, line, col, token = getLocation(context, ip)
  return tostring(filename) .. ":" .. tostring(line) .. ":" .. tostring(col), token.value
end
local botchErrorID = { }
local botchError
botchError = function(message)
  return coroutine.yield({
    message = message,
    botchErrorID = botchErrorID
  })
end
local isBotchError
isBotchError = function(errObject)
  return ('table' == type(errObject)) and errObject.botchErrorID == botchErrorID
end
local getBotchError
getBotchError = function(cor, status, ...)
  if status then
    if select('#', ...) == 1 and isBotchError((...)) then
      return (...)
    end
    return nil
  else
    local err = ...
    local trace = debug.traceback(cor, err, 2)
    trace = util.rewriteTraceback(trace)
    io.stderr:write(trace, '\n')
    return os.exit(1)
  end
end
local blameNoone
blameNoone = function(message)
  io.stderr:write("error: " .. tostring(message) .. "\n")
  return botchError(message)
end
local blameModule
blameModule = function(module, message)
  io.stderr:write(tostring(module.filename or module.name) .. ": error: " .. tostring(message) .. "\n")
  return botchError(message)
end
local blameByteInModule
blameByteInModule = function(module, i, message)
  local line, col = string.positionAt(module.source, i)
  io.stderr:write(tostring(module.filename or module.name) .. ":" .. tostring(line) .. ":" .. tostring(col) .. ": error: " .. tostring(message) .. "\n")
  return botchError(message)
end
local blameTokenInModule
blameTokenInModule = function(module, token, message)
  if 'number' == type(token) then
    token = module.tokens[token]
  end
  return blameByteInModule(module, token.start, message)
end
local blameRuntime
blameRuntime = function(context, message)
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
local loadSource
loadSource = function(filename, source, context, modname)
  if modname == nil then
    modname = ''
  end
  if not (source) then
    if filename then
      local err
      source, err = io.readBytes(filename)
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
      modules = { },
      labels = { }
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
    {
      'whitespace',
      '%s+'
    },
    {
      'literal',
      '"([^"]*)"',
      "'([^']*)'",
      '%d+'
    },
    {
      'import',
      ':([%w%-_/%.]+)'
    },
    {
      'label',
      '([%w%-_]+):'
    },
    {
      'address',
      '@([%w%-_]+)'
    },
    {
      'comment',
      '#[^\n]*'
    },
    {
      'identifier',
      '[^%c%s@:]+'
    }
  })
  if not (module.tokens) then
    blameByteInModule(module, errByte, 'unrecognized token')
  end
  module.tokens = table.ireject(module.tokens, function(token)
    return token.type == 'whitespace' or token.type == 'comment'
  end)
  module.tokens = table.map(module.tokens, function(token)
    token.value = token.captures[1] or token.captures[0]
    token.captures = nil
    return token
  end)
  local directory = filename and filename:gsub('[^/\\]+$', '') or ''
  for i, token in ipairs(module.tokens) do
    local _exp_0 = token.type
    if 'label' == _exp_0 then
      if context.labels[token.value] then
        blameTokenInModule(module, token, "redefinition of label '" .. tostring(token.value) .. "'")
      end
      context.labels[token.value] = mergeIP(i, module.name)
    elseif 'import' == _exp_0 then
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
      local values = { }
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
      local _exp_0 = type(value)
      if 'boolean' == _exp_0 then
        value = value and '1' or '0'
      elseif 'nil' == _exp_0 or 'table' == _exp_0 then
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
      if repl == nil then
        repl = false
      end
      do
        local _with_0 = self
        local _exp_0 = symbol
        if 'write' == _exp_0 then
          local value = _with_0:pop()
          io.stdout:write(value)
        elseif 'write-line' == _exp_0 then
          local value = _with_0:pop()
          io.stdout:write(value, '\n')
        elseif 'ewrite' == _exp_0 then
          local value = _with_0:pop()
          io.stderr:write(value)
        elseif 'ewrite-line' == _exp_0 then
          local value = _with_0:pop()
          io.stderr:write(value, '\n')
        elseif 'read-line' == _exp_0 then
          _with_0:push(io.stdin:read('*l'))
        elseif 'read-all' == _exp_0 then
          _with_0:push(io.stdin:read('*a'))
        elseif 'read-bytes' == _exp_0 then
          local count = _with_0:popnum()
          _with_0:push(io.stdin:read(count))
        elseif 'stack-count' == _exp_0 then
          _with_0:push(#_with_0.stack)
        elseif 'store' == _exp_0 then
          _with_0:pushi(1, _with_0:pop())
        elseif 'load' == _exp_0 then
          _with_0:push(_with_0:popi(1))
        elseif 'swap' == _exp_0 then
          local a, b = unpack(_with_0:popn(2))
          _with_0:push(b)
          _with_0:push(a)
        elseif 'dup' == _exp_0 then
          local value = _with_0:pop()
          _with_0:push(value)
          _with_0:push(value)
        elseif 'dup2' == _exp_0 then
          local a, b = unpack(_with_0:popn(2))
          _with_0:push(a)
          _with_0:push(b)
          _with_0:push(a)
          _with_0:push(b)
        elseif 'delete' == _exp_0 then
          _with_0:pop()
        elseif 'delete2' == _exp_0 then
          _with_0:popn(2)
        elseif 'error' == _exp_0 then
          _with_0:blame(_with_0:pop())
        elseif 'trace' == _exp_0 then
          local values = { }
          for i, value in ipairs(_with_0.stack) do
            values[i] = string.format('%q', value)
          end
          io.stderr:write("stack (" .. tostring(#_with_0.stack) .. "): ", table.concat(values, ', '), '\n')
        elseif 'concat' == _exp_0 then
          local a, b = unpack(_with_0:popn(2))
          _with_0:push(a .. b)
        elseif 'length' == _exp_0 then
          _with_0:push(#_with_0:pop())
        elseif '+' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a + b)
        elseif '-' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a - b)
        elseif '*' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a * b)
        elseif '**' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(math.pow(a, b))
        elseif '/' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a / b)
        elseif '//' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(math.floor(a / b))
        elseif '%' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a % b)
        elseif '++' == _exp_0 then
          _with_0:push(_with_0:popnum() + 1)
        elseif '--' == _exp_0 then
          _with_0:push(_with_0:popnum() - 1)
        elseif '<' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a < b)
        elseif '>' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a > b)
        elseif '<=' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a <= b)
        elseif '>=' == _exp_0 then
          local b, a = _with_0:popnum(), _with_0:popnum()
          _with_0:push(a >= b)
        elseif '=' == _exp_0 then
          local a, b = unpack(_with_0:popn(2))
          _with_0:push(a == b)
        elseif 'or' == _exp_0 then
          local b, a = _with_0:popbool(), _with_0:popbool()
          _with_0:push(a or b)
        elseif 'and' == _exp_0 then
          local b, a = _with_0:popbool(), _with_0:popbool()
          _with_0:push(a and b)
        elseif 'xor' == _exp_0 then
          local b, a = _with_0:popbool(), _with_0:popbool()
          _with_0:push((a or b) and not (a and b))
        elseif 'not' == _exp_0 then
          _with_0:push(not _with_0:popbool())
        elseif 'call' == _exp_0 then
          _with_0:call(_with_0:popnum())
        elseif 'address' == _exp_0 then
          local value = _with_0:pop()
          value = _with_0.labels[value]
          if not (value) then
            _with_0:blame('no such label exists')
          end
          _with_0:push(value)
        elseif 'jump' == _exp_0 then
          local value = _with_0:popnum()
          _with_0.ip = value
        elseif 'cond-jump' == _exp_0 then
          local address = _with_0:pop()
          local condition = _with_0:popbool()
          if condition then
            _with_0.ip = address
          end
        elseif 'return' == _exp_0 then
          local fslen = #_with_0.functionStack
          if fslen == 0 then
            _with_0:blame('function stack already empty')
          end
          _with_0.ip = _with_0.functionStack[fslen]
          _with_0.functionStack[fslen] = nil
        elseif 'exit' == _exp_0 then
          os.exit()
        else
          local replOK = repl
          if repl then
            local _exp_1 = symbol
            if 'trace-on' == _exp_1 then
              self.trace = nil
            elseif 'trace-off' == _exp_1 then
              self.trace = false
            elseif 'help' == _exp_1 then
              io.stderr:write("Help is not implemented yet. Sorry :(\n")
            else
              replOK = false
            end
          end
          if not (replOK) then
            local address = _with_0.labels[symbol]
            if address then
              _with_0:call(address)
            else
              _with_0:blame('unrecognised symbol')
            end
          end
        end
        return _with_0
      end
    end
  }
}
local initializeRuntime
initializeRuntime = function(context, startIP)
  do
    context.ip = startIP or context.labels.start
    if not (context.ip) then
      blameNoone("start label not found")
    end
    context.stack = { }
    context.functionStack = { }
  end
  return setmetatable(context, contextMT)
end
local runContext
runContext = function(context, startIP, repl)
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
        local _exp_0 = token.type
        if 'literal' == _exp_0 then
          context:push(token.value)
        elseif 'identifier' == _exp_0 then
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
local usage
usage = function()
  io.stderr:write("usage: " .. tostring(arg[0]) .. " run <source>\n")
  io.stderr:write("   or: " .. tostring(arg[0]) .. " repl\n")
  return os.exit()
end
local _exp_0 = arg[1] and arg[1]:lower()
if 'run' == _exp_0 then
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
elseif 'repl' == _exp_0 then
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
