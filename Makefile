.PHONY: run
run:
	moon botch.moon repl

%.lua: %.moon
	moonc $<

.PHONY: build
build: botch.lua