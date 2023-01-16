inspect = require 'inspect'
lithium = require 'lithium.init'
import string, table, lexer, io, util from lithium
import unpack from table

filename = 'test.bot'
str = io.readBytes filename

blameByte = (i, message) ->
	line, col = string.positionAt str, i
	if line
		io.stderr\write "#{filename}:#{line}:#{col}: error: #{message}\n"
	else
		io.stderr\write "#{filename}:byte #{i}: error: #{message}\n"
	os.exit 1

blameToken = (token, message) -> blameByte token.start, message

tokens, _, errByte = lexer.lex str, {
	{'whitespace', '%s+'}
	{'literal', '"([^"]*)"', "'([^']*)'", '%d+'}
	{'import', ':([%w%-_/%.]+)'}
	{'label', '([%w%-_]+):'}
	{'address', '@([%w%-_]+)'}
	{'comment', '#[^\n]*'}
	{'identifier', '[^%c%s@:]+'}
}

blameByte errByte, 'unrecognized token' unless tokens

tokens = table.ireject tokens, (token) ->
	token.type == 'whitespace' or token.type == 'comment'

tokens = table.map tokens, (token) ->
	token.value = token.captures[1] or token.captures[0]
	token.captures = nil
	token

table.insert tokens, {
	start: #str + 1,
	stop: #str + 1,
	type: 'label',
	value: 'exit'
}

labels = {}

-- Find the index of each label token
for i, token in ipairs tokens
	if token.type == 'label'
		blameToken token, 'label redefinition' if labels[token.value]
		labels[token.value] = i

blameByte 1, "start label not found" unless labels.start

-- Check for invalid addressing and convert to literal
for i, token in ipairs tokens
	if token.type == 'address'
		blameToken token, 'no such label exists' unless labels[token.value]
		token.type = 'literal'
		token.value = labels[token.value]

-- Execute tokens

state = {
	:tokens
	:labels
	tokenCount: #tokens
	ip: labels.start + 1
	stack: {}
	functionStack: {}
	
	blameToken: (message) => blameToken @tokens[@ip], message
	popn: (n) =>
		blameToken @tokens[@ip], "expected at least #{n} values on the stack, got #{#@stack}" if #@stack < n
		values = {}
		for i = n, 1, -1
			values[i] = @pop!
		values
	pop: =>
		@blameToken "expected a value on the stack, got none" if #@stack < 1
		value = @stack[#@stack]
		@stack[#@stack] = nil
		value
	popnum: =>
		value = @pop!
		value = tonumber value
		@blameToken 'expected a number as argument' unless value
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
		blameToken @tokens[@ip], 'function stack overflow' if #@functionStack >= 1024
		table.insert @functionStack, @ip
		@ip = ip
}
tokens, labels = nil, nil

with state
	while .ip < .labels.exit
		assert .ip >= 1
		token = .tokens[.ip]
		switch token.type
			when 'literal'
				\push token.value
			when 'identifier'
				address = .labels[token.value]
				-- Check if label is defined
				if address
					\call address
				else
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
							blameToken token, value
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
							value = .labels[value]
							blameToken token, 'no such label exists' unless value
							\push value
						when 'jump'
							value = \popnum!
							.ip = value
							-- it's ok to not continue here and let the ip increment
							-- since we would land on a label anyway, which would be a noop
						when 'cond-jump'
							address = \popnum!
							condition = \popbool!
							.ip = address if condition
						when 'return'
							fslen = #.functionStack
							blameToken token, 'function stack already empty' if fslen == 0
							.ip = .functionStack[fslen]
							.functionStack[fslen] = nil
						when 'exit'
							.ip = .labels.exit
							continue
						else
							blameToken token, 'unrecognised symbol'
		.ip += 1