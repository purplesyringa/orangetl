local argparse = require "argparse"
local transpiler = require "orange.transpiler"

local parser = argparse("orange", "A fast Teal-to-Lua transpiler.")
parser:argument("file", "Input file."):target("input")
parser:option("-o", "Output file."):argname("<filename>"):target("output")
parser:option("-l", "Parse code as Lua or Teal."):target("language"):choices { "lua", "teal" }
parser:flag("--strip-attributes", "Strip attributes (for compatibility with Lua < 5.4).")
local args = parser:parse()

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
