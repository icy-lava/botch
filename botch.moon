inspect = require 'inspect'
lithium = require 'lithium.init'
import string, table, lexer, io, util from lithium
import unpack from table

splitIP = (ip) ->
	i, modname = ip\match '^(%d+):(.*)$'
	i = tonumber i if i
	@blame "corrupted address" unless i
	return i, modname

getLocation = (context, ip) ->
	i, modname = splitIP ip
	module = context.modules[modname]
	line, col = string.positionAt module.source, module.tokens[i].start
	return module.filename, line, col, module.tokens[i]

getLocationString = (context, ip) ->
	filename, line, col, token = getLocation context, ip
	"#{filename}:#{line}:#{col}", token.value

blameNoone = (message) ->
	io.stderr\write "error: #{message}\n"
	os.exit 1

blameModule = (module, message) ->
	io.stderr\write "#{module.filename}: error: #{message}\n"
	os.exit 1

blameByteInModule = (module, i, message) ->
	line, col = string.positionAt module.source, i
	io.stderr\write "#{module.filename}:#{line}:#{col}: error: #{message}\n"
	os.exit 1

blameTokenInModule = (module, token, message) ->
	if 'number' == type token
		token = module.tokens[token]
	-- NOTE: we don't check if token is within the module.tokens
	blameByteInModule module, token.start, message

blameState = (state, message) ->
	io.stderr\write "#{getLocationString state.context, state.ip}: error: #{message}\n"
	fslen = #state.functionStack
	to = math.max 1, fslen - 5 + 1
	for i = fslen, to, -1
		if i == to
			io.stderr\write '    ...\n' if i > 1
			i = 1
		ip = state.functionStack[i]
		location, token = getLocationString state.context, ip
		io.stderr\write "    at #{location} in #{token}\n"
	os.exit 1

loadFile = (filename, context, modname = '') ->
	source, err = io.readBytes filename
	return nil, err unless source
	
	unless context
		context = {
			modules: {}
			labels: {}
		}
	
	return nil, "module '#{modname}' already exists" if context.modules[modname]
	
	module = {
		name: modname
		:filename
		:source
	}
	context.modules[modname] = module

	module.tokens, _, errByte = lexer.lex source, {
		{'whitespace', '%s+'}
		{'literal', '"([^"]*)"', "'([^']*)'", '%d+'}
		{'import', ':([%w%-_/%.]+)'}
		{'label', '([%w%-_]+):'}
		{'address', '@([%w%-_]+)'}
		{'comment', '#[^\n]*'}
		{'identifier', '[^%c%s@:]+'}
	}
	
	blameByteInModule module, errByte, 'unrecognized token' unless module.tokens

	module.tokens = table.ireject module.tokens, (token) ->
		token.type == 'whitespace' or token.type == 'comment'

	module.tokens = table.map module.tokens, (token) ->
		token.value = token.captures[1] or token.captures[0]
		token.captures = nil
		token
	
	directory = filename\gsub '[^/\\]+$', ''
	
	-- Find the index of each label token and load imports
	for i, token in ipairs module.tokens
		switch token.type
			when 'label'
				blameTokenInModule module, token, "redefinition of label '#{token.value}'" if context.labels[token.value]
				context.labels[token.value] = "#{i}:#{module.name}"
			when 'import'
				modname = token.value
				context, err = loadFile "#{directory}#{modname}.bot", context, modname
				context = loadFile "#{directory}#{modname}/init.bot", context, modname unless context
				blameTokenInModule module, token, "could not import module '#{modname}': #{err}" unless context

	-- Check for invalid addressing and convert to literal
	for i, token in ipairs module.tokens
		if token.type == 'address'
			blameTokenInModule module, token, 'no such label exists' unless context.labels[token.value]
			token.type = 'literal'
			token.value = context.labels[token.value]
	
	return context

runContext = (context) ->
	blameNoone "start label not found" unless context.labels.start
	
	state = {
		:context
		ip: context.labels.start
		stack: {}
		functionStack: {}
		
		nextIP: =>
			i, modname = splitIP @ip
			@ip = "#{i + 1}:#{modname}"
		getToken: (ip = @ip) =>
			i, modname = splitIP ip
			module = context.modules[modname]
			assert module, "module '#{modname}' does not exist in the context"
			token = module.tokens[i]
			assert token, "token #{i} in module '#{modname}' does not exist"
			return token
		blame: (message) => blameState @, message
		popn: (n) =>
			@blame "expected at least #{n} values on the stack, got #{#@stack}" if #@stack < n
			values = {}
			for i = n, 1, -1
				values[i] = @pop!
			values
		pop: =>
			@blame "expected a value on the stack, got none" if #@stack < 1
			value = @stack[#@stack]
			@stack[#@stack] = nil
			value
		popnum: =>
			value = @pop!
			value = tonumber value
			@blame 'expected a number as argument' unless value
			value
		popbool: => @pop! != '0'
		push: (value) =>
			switch type value
				when 'boolean'
					value = value and '1' or '0'
				when 'nil', 'table'
					error "atempted to push a #{type value} value onto the stack", 2
			table.insert @stack, tostring value
		call: (ip) =>
			@blame 'function stack overflow' if #@functionStack >= 1024
			table.insert @functionStack, @ip
			@ip = ip
	}
	
	with state
		while true
			token = \getToken!
			switch token.type
				when 'literal'
					\push token.value
				when 'identifier'
					-- Check for built-ins
					switch token.value
						when 'write'
							value = \pop!
							io.stdout\write value
						when 'write-line'
							value = \pop!
							io.stdout\write value, '\n'
						when 'ewrite'
							value = \pop!
							io.stderr\write value
						when 'ewrite-line'
							value = \pop!
							io.stderr\write value, '\n'
						when 'read-line'
							\push io.stdin\read '*l'
						when 'read-all'
							\push io.stdin\read '*a'
						when 'read-bytes'
							count = \popnum!
							\push io.stdin\read count
						when 'stack-count'
							\push #.stack
						when 'store'
							value = \pop!
							table.insert .stack, 1, tostring value
						when 'load'
							-- FIXME: this does not check if the stack has a value like pop does
							value = .stack[1]
							table.remove .stack, 1
							table.insert .stack, tostring value
						when 'swap'
							a, b = unpack \popn 2
							\push b
							\push a
						when 'dup'
							value = \pop!
							\push value
							\push value
						when 'dup2'
							a, b = unpack \popn 2
							\push a
							\push b
							\push a
							\push b
						when 'delete'
							\pop!
						when 'delete2'
							\popn 2
						when 'error'
							value = \pop!
							\blame value
						when 'trace'
							values = {}
							for i, value in ipairs .stack
								values[i] = inspect value
							io.stderr\write "stack (#{#.stack}): ", table.concat(values, ', '), '\n'
						when 'concat'
							a, b = unpack \popn 2
							\push a .. b
						when 'length'
							\push #\pop!
						when '+'
							b, a = \popnum!, \popnum!
							\push a + b
						when '-'
							b, a = \popnum!, \popnum!
							\push a - b
						when '*'
							b, a = \popnum!, \popnum!
							\push a * b
						when '**'
							b, a = \popnum!, \popnum!
							\push math.pow a, b
						when '/'
							b, a = \popnum!, \popnum!
							\push a / b
						when '//'
							b, a = \popnum!, \popnum!
							\push math.floor a / b
						when '%'
							b, a = \popnum!, \popnum!
							\push a % b
						when '++'
							\push \popnum! + 1
						when '--'
							\push \popnum! - 1
						when 'or'
							b, a = \popbool!, \popbool!
							\push a or b
						when 'and'
							b, a = \popbool!, \popbool!
							\push a and b
						when 'xor'
							b, a = \popbool!, \popbool!
							\push (a or b) and not (a and b)
						when 'not'
							\push not \popbool!
						when 'call'
							\call \popnum!
						when 'address'
							value = \pop!
							value = .context.labels[value]
							\blame 'no such label exists' unless value
							\push value
						when 'jump'
							value = \popnum!
							.ip = value
							-- it's ok to not continue here and let the ip increment
							-- since we would land on a label anyway, which would be a noop
						when 'cond-jump'
							address = \pop!
							condition = \popbool!
							.ip = address if condition
						when 'return'
							fslen = #.functionStack
							\blame 'function stack already empty' if fslen == 0
							.ip = .functionStack[fslen]
							.functionStack[fslen] = nil
						when 'exit'
							break
						else
							-- Check if label is defined
							address = .context.labels[token.value]
							if address
								\call address
							else
								\blame 'unrecognised symbol'
			\nextIP!
	return state.stack

context, err = loadFile 'test.bot'
blameNoone err unless context
runContext context