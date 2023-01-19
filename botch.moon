#!/usr/bin/env moon

lithium = require 'lithium.init'
import string, table, lexer, io, util from lithium
import pack, unpack from table

major = 0
minor = 1
patch = 1
version = "#{major}.#{minor}.#{patch}"

splitIP = (ip) ->
	i, modname = ip\match '^(%d+):(.*)$'
	i = tonumber i if i
	assert i, 'corrupted address'
	return i, modname

mergeIP = (i, modname) -> "#{i}:#{modname}"

getLocation = (context, ip = context.ip) ->
	i, modname = splitIP ip
	module = context.modules[modname]
	line, col = string.positionAt module.source, module.tokens[i].start
	return module.filename or module.name, line, col, module.tokens[i]

getLocationString = (context, ip) ->
	filename, line, col, token = getLocation context, ip
	"#{filename}:#{line}:#{col}", token.value

botchErrorID = {}
botchError = (message) ->
	coroutine.yield {
		message: message
		:botchErrorID
	}

isBotchError = (errObject) -> ('table' == type errObject) and errObject.botchErrorID == botchErrorID

getBotchError = (cor, status, ...) ->
	if status
		if select('#', ...) == 1 and isBotchError (...)
			return (...)
		return nil
	else
		err = ...
		trace = debug.traceback cor, err, 2
		trace = util.rewriteTraceback trace
		io.stderr\write trace, '\n'
		os.exit 1

blameNoone = (message) ->
	io.stderr\write "error: #{message}\n"
	botchError message

blameModule = (module, message) ->
	io.stderr\write "#{module.filename or module.name}: error: #{message}\n"
	botchError message

blameByteInModule = (module, i, message) ->
	line, col = string.positionAt module.source, i
	io.stderr\write "#{module.filename or module.name}:#{line}:#{col}: error: #{message}\n"
	botchError message

blameTokenInModule = (module, token, message) ->
	if 'number' == type token
		token = module.tokens[token]
	-- NOTE: we don't check if token is within the module.tokens
	blameByteInModule module, token.start, message

blameRuntime = (context, message) ->
	error 'runtime not initialized' unless context.stack and context.functionStack
	io.stderr\write "#{getLocationString context}: error: #{message}\n"
	fslen = #context.functionStack
	to = math.max 1, fslen - 5 + 1
	for i = fslen, to, -1
		if i == to
			io.stderr\write '    ...\n' if i > 1
			i = 1
		ip = context.functionStack[i]
		location, token = getLocationString context, ip
		io.stderr\write "    at #{location} in #{token}\n"
	botchError message

local contextMT

loadSource = (filename, source, context, modname = '') ->
	unless source
		if filename
			source, err = io.readBytes filename
			return nil, err unless source
		else
			error 'either source data or filename must be provided'
	
	if context
		context = context\clone!
	else
		context = setmetatable {
			modules: {}
			labels: {}
		}, contextMT
	
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
	
	directory = filename and filename\gsub('[^/\\]+$', '') or ''
	
	-- Find the index of each label token and load imports
	for i, token in ipairs module.tokens
		switch token.type
			when 'label'
				blameTokenInModule module, token, "redefinition of label '#{token.value}'" if context.labels[token.value]
				context.labels[token.value] = mergeIP i, module.name
			when 'import'
				modname = token.value
				context, err = loadSource "#{directory}#{modname}.bot", nil, context, modname
				context = loadSource "#{directory}#{modname}/init.bot", nil, context, modname unless context
				blameTokenInModule module, token, "could not import module '#{modname}': #{err}" unless context

	-- Check for invalid addressing and convert to literal
	for i, token in ipairs module.tokens
		if token.type == 'address'
			blameTokenInModule module, token, 'no such label exists' unless context.labels[token.value]
			token.type = 'literal'
			token.value = context.labels[token.value]
	
	return context

contextMT = {
	__index: {
		clone: => setmetatable table.clone(@), contextMT
		nextIP: =>
			i, modname = splitIP @ip
			@ip = "#{i + 1}:#{modname}"
		getToken: (ip = @ip) =>
			i, modname = splitIP ip
			module = @modules[modname]
			assert module, "module '#{modname}' does not exist in the context"
			token = module.tokens[i]
			return nil, "token #{i} in module '#{modname}' does not exist" unless token
			return token
		blame: (message) => blameRuntime @, message
		popi: (i) =>
			@blame "expected a value on the stack, got none" if #@stack < 1
			value = @stack[i]
			error "invalid stack index #{i}" unless value
			table.remove @stack, i
			value
		popn: (n) =>
			@blame "expected at least #{n} values on the stack, got #{#@stack}" if #@stack < n
			values = {}
			for i = n, 1, -1
				values[i] = @pop!
			values
		pop: => @popi #@stack
		popnum: =>
			value = @pop!
			value = tonumber value
			@blame 'expected a number as argument' unless value
			value
		popbool: => @pop! != '0'
		pushi: (i, value) =>
			switch type value
				when 'boolean'
					value = value and '1' or '0'
				when 'nil', 'table'
					error "atempted to push a #{type value} value onto the stack", 2
			table.insert @stack, i, tostring value
		push: (value) => @pushi #@stack + 1, value
		canReturn: => #@functionStack > 0
		call: (ip) =>
			@blame 'function stack overflow' if #@functionStack >= 1024
			table.insert @functionStack, @ip
			@ip = ip
		execute: (symbol, repl = false) =>
			with @ -- Due to earlier code
				switch symbol
					-- Check for built-ins first
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
						\pushi 1, \pop!
					when 'load'
						\push \popi 1
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
						\blame \pop!
					when 'trace'
						values = {}
						for i, value in ipairs .stack
							values[i] = string.format '%q', value
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
						value = .labels[value]
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
						os.exit!
					else
						replOK = repl
						if repl
							-- REPL specific built-ins
							switch symbol
								when 'trace-on'
									@trace = nil
								when 'trace-off'
									@trace = false
								when 'help'
									io.stderr\write "Help is not implemented yet. Sorry :(\n"
								else
									replOK = false
						unless replOK
							-- Check if label is defined
							address = .labels[symbol]
							if address
								\call address
							else
								\blame 'unrecognised symbol'
	}
}

initializeRuntime = (context, startIP) ->
	with context
		.ip = startIP or .labels.start
		blameNoone "start label not found" unless .ip
		.stack = {}
		.functionStack = {}
	
	setmetatable context, contextMT

runContext = (context, startIP, repl) ->
	context.ip = startIP if startIP
	
	with context
		while true
			token = \getToken!
			unless token
				if \canReturn!
					\execute 'return', repl
					\nextIP!
					continue
				else
					break
			switch token.type
				when 'literal'
					\push token.value
				when 'identifier'
					\execute token.value, repl
			\nextIP!
			
	return context

usage = ->
	io.stderr\write "usage: #{arg[0]} run <source>\n"
	io.stderr\write "   or: #{arg[0]} repl\n"
	os.exit!

switch arg[1] and arg[1]\lower!
	when 'run'
		usage! unless arg[2]
		cor = coroutine.create ->
			context, err = loadSource arg[2]
			blameNoone err unless context
			initializeRuntime context
			runContext context
		while 'suspended' == coroutine.status cor
			err = getBotchError cor, coroutine.resume cor
			if err
				os.exit 1
	when 'repl'
		id = 1
		context = nil
		io.stderr\write "Welcome to Botch #{version}\n"
		while true
			name = "repl-#{id}"
			
			io.stderr\write "(#{id}) $ "
			io.stderr\flush!
			
			input = assert io.stdin\read '*l'
			cor = coroutine.create ->
				newContext, err = loadSource nil, input, context, name
				initializeRuntime newContext, mergeIP 1, name
				if newContext
					newContext.stack = context and table.icopy(context.stack) or newContext.stack
					runContext newContext, nil, true
					context = newContext
					context\execute 'trace' if context.trace != false
				else
					io.stderr\write "#{err}\n"
			
			while 'suspended' == coroutine.status cor
				err = getBotchError cor, coroutine.resume cor
				if err
					break
			
			id += 1
	else
		usage!