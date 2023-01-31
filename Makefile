.PHONY: run
run:
	tl run botch.tl repl

.PHONY: gen
gen:
	tl gen botch.tl
	busybox echo -n "if os.getenv('LOCAL_LUA_DEBUGGER_VSCODE') == '1' then require('lldebugger').start() end; " | busybox cat - botch.lua > botch.lua.new
	busybox mv botch.lua.new botch.lua
	