local argparse = require("argparse")
local searcher = require("orangetl.searcher")
local transpiler = require("orangetl.transpiler")

local parser = argparse("orangetl", "A fast Teal-to-Lua transpiler.")
parser:command_target("command")

local gen = parser:command("gen", "Generate a Lua file from a Teal file.")
gen:argument("file", "Input file."):target("input")
gen:option("-o", "Output file."):argname("<filename>"):target("output")
gen:option("-l", "Parse code as Lua or Teal."):target("language"):choices({ "lua", "teal" })
gen:flag("--strip-attributes", "Strip attributes (for compatibility with Lua < 5.4).")

local run = parser:command("run", "Run a Teal script.")
run:argument("script", "Path to script."):target("script")
run:argument("args", "Arguments passed to the script."):target("args"):args("*")

local args = parser:parse()

if args.command == "gen" then
    if not args.output then
        local input_without_tl = args.input:gsub("%.tl$", "")
        if input_without_tl == args.input then
            io.stderr:write("Error: cannot infer output file path when input doesn't end with '.tl'\n")
            os.exit(1)
        end
        args.output = input_without_tl .. ".lua"
    end

    local opts = {}
    if args.language == "lua" then
        opts.lua_quirks = true
    elseif args.language == "teal" then
        opts.lua_quirks = false
    else
        opts.lua_quirks = args.input:match("%.tl$") == nil
    end
    opts.strip_attributes = args.strip_attributes

    local f, err = io.open(args.input, "rb")
    if not f then
        io.stderr:write("Error: " .. err .. "\n")
        os.exit(1)
    end
    local teal_code = f:read("*a")
    f:close()

    local lua_code = transpiler.transpile(teal_code, opts)

    f, err = io.open(args.output, "wb")
    if not f then
        io.stderr:write("Error: " .. err .. "\n")
        os.exit(1)
    end
    f:write(lua_code)
    f:close()
elseif args.command == "run" then
    -- luacheck: push ignore
    table.insert(package.searchers or package.loaders, 2, searcher.searcher)
    arg = args.args
    searcher.loadTealFile(args.script, (table.unpack or unpack)(args.args))
    -- luacheck: pop
end
