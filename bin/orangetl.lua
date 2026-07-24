local argparse = require("argparse")
local searcher = require("orangetl.searcher")
local orangetl = require("orangetl")

local parser = argparse("orangetl", "A fast Teal-to-Lua transpiler.")
parser:command_target("command")

local gen = parser:command("gen", "Generate a Lua file from a Teal file.")
gen:argument("file", "Input file."):target("input")
gen:option("-o", "Output file."):argname("<filename>"):target("output")
gen:option("-l", "Parse code as Lua or Teal."):target("language"):choices({ "lua", "teal" })
gen:flag("--keep-hashbang", "Preserve hashbang, if present.")
gen:flag("--strip-attributes", "Strip attributes (for compatibility with Lua < 5.4).")
gen:option("--replace-named-varargs", "Replace named varargs (for compatibility with Lua < 5.5).")
    :choices({ "5.2", "5.1" })
gen:flag(
    "--rewrite-for-reassignments",
    "Rewrite assignments to 'for' control variables (for compatibility with Lua >= 5.4)."
)
gen:flag(
    "--rewrite-string-escapes",
    "Support \\z, \\x, and \\u string escapes (for compatibility with Lua < 5.3)."
)
gen:flag(
    "--localize-implicit-globals",
    "Prepend 'local <name> = <name>' for globals accessed by the generated code."
)

local gen_dtl = parser:command("gen-dtl", "Generate a Lua file from a .d.tl file.")
gen_dtl:argument("dtl-file", "Input .d.tl file."):target("dtl_input")
gen_dtl:argument("lua-file", "Matching .lua file."):target("lua_input")
gen_dtl:option("-o", "Output file."):argname("<filename>"):target("output")

local run = parser:command("run", "Run a Teal script.")
run:argument("script", "Path to script."):target("script")
run:argument("args", "Arguments passed to the script."):target("args"):args("*")

local args = parser:parse()

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then
        io.stderr:write("Error: " .. err .. "\n")
        os.exit(1)
    end
    local code = f:read("*a")
    assert(code, "cannot read " .. path)
    f:close()
    return code
end

local function writeFile(path, contents)
    local f, err = io.open(path, "wb")
    if not f then
        io.stderr:write("Error: " .. err .. "\n")
        os.exit(1)
    end
    f:write(contents)
    f:close()
end

if args.command == "gen" then
    if not args.output then
        local input_without_tl = args.input:gsub("%.tl$", "")
        if input_without_tl == args.input then
            io.stderr:write(
                "Error: cannot infer output file path when input doesn't end with '.tl'\n"
            )
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
    opts.keep_hashbang = args.keep_hashbang
    opts.strip_attributes = args.strip_attributes
    opts.replace_named_varargs = args.replace_named_varargs
    opts.rewrite_for_reassignments = args.rewrite_for_reassignments
    opts.rewrite_string_escapes = args.rewrite_string_escapes
    opts.localize_implicit_globals = args.localize_implicit_globals

    local teal_code = readFile(args.input)
    local transpiled_code = orangetl.transpile(teal_code, opts)
    writeFile(args.output, transpiled_code)
elseif args.command == "gen-dtl" then
    if not args.output then
        io.stderr:write("Error: gen-dtl requires an explicit output path\n")
        os.exit(1)
    end

    local dtl_code = readFile(args.dtl_input)
    local lua_code = readFile(args.lua_input)
    local transpiled_code = orangetl.transpileDef(dtl_code, lua_code)
    writeFile(args.output, transpiled_code)
elseif args.command == "run" then
    -- luacheck: push ignore
    table.insert(package.searchers or package.loaders, 2, searcher.searcher)
    arg = args.args
    searcher.loadTealFile(args.script, (table.unpack or unpack)(args.args))
    -- luacheck: pop
end
