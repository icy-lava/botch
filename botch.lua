local lithium = require('lithium.init')
local string, table, lexer, io
string, table, lexer, io = lithium.string, lithium.table, lithium.lexer, lithium.io
local unpack
unpack = table.unpack
local splitIP
splitIP = function(ip)
  local i, modname = ip:match('^(%d+):(.*)$')
  if i then
    i = tonumber(i)
  end
  if not (i) then
    self:blame("corrupted address")
  end
  return i, modname
end
local getLocation
getLocation = function(context, ip)
  local i, modname = splitIP(ip)
  local module = context.modules[modname]
  local line, col = string.positionAt(module.source, module.tokens[i].start)
  return module.filename, line, col, module.tokens[i]
end
local getLocationString
getLocationString = function(context, ip)
  local filename, line, col, token = getLocation(context, ip)
  return tostring(filename) .. ":" .. tostring(line) .. ":" .. tostring(col), token.value
end
local blameNoone
blameNoone = function(message)
  io.stderr:write("error: " .. tostring(message) .. "\n")
  return os.exit(1)
end
local blameModule
blameModule = function(module, message)
  io.stderr:write(tostring(module.filename) .. ": error: " .. tostring(message) .. "\n")
  return os.exit(1)
end
local blameByteInModule
blameByteInModule = function(module, i, message)
  local line, col = string.positionAt(module.source, i)
  io.stderr:write(tostring(module.filename) .. ":" .. tostring(line) .. ":" .. tostring(col) .. ": error: " .. tostring(message) .. "\n")
  return os.exit(1)
end
local blameTokenInModule
blameTokenInModule = function(module, token, message)
  if 'number' == type(token) then
    token = module.tokens[token]
  end
  return blameByteInModule(module, token.start, message)
end
local blameState
blameState = function(state, message)
  io.stderr:write(tostring(getLocationString(state.context, state.ip)) .. ": error: " .. tostring(message) .. "\n")
  local fslen = #state.functionStack
  local to = math.max(1, fslen - 5 + 1)
  for i = fslen, to, -1 do
    if i == to then
      if i > 1 then
        io.stderr:write('    ...\n')
      end
      i = 1
    end
    local ip = state.functionStack[i]
    local location, token = getLocationString(state.context, ip)
    io.stderr:write("    at " .. tostring(location) .. " in " .. tostring(token) .. "\n")
  end
  return os.exit(1)
end
local loadFile
loadFile = function(filename, context, modname)
  if modname == nil then
    modname = ''
  end
  local source, err = io.readBytes(filename)
  if not (source) then
    return nil, err
  end
  if not (context) then
    context = {
      modules = { },
      labels = { }
    }
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
  local directory = filename:gsub('[^/\\]+$', '')
  for i, token in ipairs(module.tokens) do
    local _exp_0 = token.type
    if 'label' == _exp_0 then
      if context.labels[token.value] then
        blameTokenInModule(module, token, "redefinition of label '" .. tostring(token.value) .. "'")
      end
      context.labels[token.value] = tostring(i) .. ":" .. tostring(module.name)
    elseif 'import' == _exp_0 then
      modname = token.value
      context, err = loadFile(tostring(directory) .. tostring(modname) .. ".bot", context, modname)
      if not (context) then
        context = loadFile(tostring(directory) .. tostring(modname) .. "/init.bot", context, modname)
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
local runContext
runContext = function(context)
  if not (context.labels.start) then
    blameNoone("start label not found")
  end
  local state = {
    context = context,
    ip = context.labels.start,
    stack = { },
    functionStack = { },
    nextIP = function(self)
      local i, modname = splitIP(self.ip)
      self.ip = tostring(i + 1) .. ":" .. tostring(modname)
    end,
    getToken = function(self, ip)
      if ip == nil then
        ip = self.ip
      end
      local i, modname = splitIP(ip)
      local module = context.modules[modname]
      assert(module, "module '" .. tostring(modname) .. "' does not exist in the context")
      local token = module.tokens[i]
      assert(token, "token " .. tostring(i) .. " in module '" .. tostring(modname) .. "' does not exist")
      return token
    end,
    blame = function(self, message)
      return blameState(self, message)
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
      if #self.stack < 1 then
        self:blame("expected a value on the stack, got none")
      end
      local value = self.stack[#self.stack]
      self.stack[#self.stack] = nil
      return value
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
    push = function(self, value)
      local _exp_0 = type(value)
      if 'boolean' == _exp_0 then
        value = value and '1' or '0'
      elseif 'nil' == _exp_0 or 'table' == _exp_0 then
        error("atempted to push a " .. tostring(type(value)) .. " value onto the stack", 2)
      end
      return table.insert(self.stack, tostring(value))
    end,
    call = function(self, ip)
      if #self.functionStack >= 1024 then
        self:blame('function stack overflow')
      end
      table.insert(self.functionStack, self.ip)
      self.ip = ip
    end
  }
  do
    while true do
      local token = state:getToken()
      local _exp_0 = token.type
      if 'literal' == _exp_0 then
        state:push(token.value)
      elseif 'identifier' == _exp_0 then
        local _exp_1 = token.value
        if 'write' == _exp_1 then
          local value = state:pop()
          io.stdout:write(value)
        elseif 'write-line' == _exp_1 then
          local value = state:pop()
          io.stdout:write(value, '\n')
        elseif 'ewrite' == _exp_1 then
          local value = state:pop()
          io.stderr:write(value)
        elseif 'ewrite-line' == _exp_1 then
          local value = state:pop()
          io.stderr:write(value, '\n')
        elseif 'read-line' == _exp_1 then
          state:push(io.stdin:read('*l'))
        elseif 'read-all' == _exp_1 then
          state:push(io.stdin:read('*a'))
        elseif 'read-bytes' == _exp_1 then
          local count = state:popnum()
          state:push(io.stdin:read(count))
        elseif 'stack-count' == _exp_1 then
          state:push(#state.stack)
        elseif 'store' == _exp_1 then
          local value = state:pop()
          table.insert(state.stack, 1, tostring(value))
        elseif 'load' == _exp_1 then
          local value = state.stack[1]
          table.remove(state.stack, 1)
          table.insert(state.stack, tostring(value))
        elseif 'swap' == _exp_1 then
          local a, b = unpack(state:popn(2))
          state:push(b)
          state:push(a)
        elseif 'dup' == _exp_1 then
          local value = state:pop()
          state:push(value)
          state:push(value)
        elseif 'dup2' == _exp_1 then
          local a, b = unpack(state:popn(2))
          state:push(a)
          state:push(b)
          state:push(a)
          state:push(b)
        elseif 'delete' == _exp_1 then
          state:pop()
        elseif 'delete2' == _exp_1 then
          state:popn(2)
        elseif 'error' == _exp_1 then
          local value = state:pop()
          state:blame(value)
        elseif 'trace' == _exp_1 then
          local values = { }
          for i, value in ipairs(state.stack) do
            values[i] = string.format('%q', value)
          end
          io.stderr:write("stack (" .. tostring(#state.stack) .. "): ", table.concat(values, ', '), '\n')
        elseif 'concat' == _exp_1 then
          local a, b = unpack(state:popn(2))
          state:push(a .. b)
        elseif 'length' == _exp_1 then
          state:push(#state:pop())
        elseif '+' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(a + b)
        elseif '-' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(a - b)
        elseif '*' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(a * b)
        elseif '**' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(math.pow(a, b))
        elseif '/' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(a / b)
        elseif '//' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(math.floor(a / b))
        elseif '%' == _exp_1 then
          local b, a = state:popnum(), state:popnum()
          state:push(a % b)
        elseif '++' == _exp_1 then
          state:push(state:popnum() + 1)
        elseif '--' == _exp_1 then
          state:push(state:popnum() - 1)
        elseif 'or' == _exp_1 then
          local b, a = state:popbool(), state:popbool()
          state:push(a or b)
        elseif 'and' == _exp_1 then
          local b, a = state:popbool(), state:popbool()
          state:push(a and b)
        elseif 'xor' == _exp_1 then
          local b, a = state:popbool(), state:popbool()
          state:push((a or b) and not (a and b))
        elseif 'not' == _exp_1 then
          state:push(not state:popbool())
        elseif 'call' == _exp_1 then
          state:call(state:popnum())
        elseif 'address' == _exp_1 then
          local value = state:pop()
          value = state.context.labels[value]
          if not (value) then
            state:blame('no such label exists')
          end
          state:push(value)
        elseif 'jump' == _exp_1 then
          local value = state:popnum()
          state.ip = value
        elseif 'cond-jump' == _exp_1 then
          local address = state:pop()
          local condition = state:popbool()
          if condition then
            state.ip = address
          end
        elseif 'return' == _exp_1 then
          local fslen = #state.functionStack
          if fslen == 0 then
            state:blame('function stack already empty')
          end
          state.ip = state.functionStack[fslen]
          state.functionStack[fslen] = nil
        elseif 'exit' == _exp_1 then
          break
        else
          local address = state.context.labels[token.value]
          if address then
            state:call(address)
          else
            state:blame('unrecognised symbol')
          end
        end
      end
      state:nextIP()
    end
  end
  return state.stack
end
if not (arg[1]) then
  io.stderr:write("usage: " .. tostring(arg[0]) .. " <source>\n")
  return 
end
local context, err = loadFile(arg[1])
if not (context) then
  blameNoone(err)
end
return runContext(context)
