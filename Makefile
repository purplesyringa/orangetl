orangetl.min.lua: orangetl.lua
# luamin -f is borked when stdin is empty (https://github.com/mathiasbynens/luamin/pull/60 is
# still not released)
	npm exec -- luamin -c <$< >$@
orangetl.lua: bin/orangetl.lua $(wildcard lua/orangetl/*.lua)
	npm exec -- luabundler bundle -p lua/?.lua -p lua/?/init.lua -o $@ $<
