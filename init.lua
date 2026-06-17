local chopping = require "chopping"
local tokenstream = require "tokenstream"

local function anyOf(s, pattern)
    for t in pattern:gmatch("[^%s]+") do
        if s == t then
            return true
        end
    end
    return false
end

local parsers = {}

-- An approximate, non-recursive parser that greps for structures we're interested in without
-- constructing a syntax tree. It acts as a sieve, passing control to a better parser as it
-- recognizes an important construct.
--
-- Parses the input up to and including `until_what`, which can be one of:
-- - `eof`: matches until the end of file.
-- - `]`, `)`, `}`: matches until the first closing bracket not matching any open bracket in the
--   stream.
-- - `end`: matches until the first `end` not matching any open block in the stream.
function parsers.shallow(stream, chopper, until_what)
    local n = 0

    -- Tracks nested blocks/expressions that are finished by the `end` keyword. Used for `as`/`is`
    -- resolution in edge cases. `true` for function expressions, `false` for everything else.
    local nesting_is_function_expr = {}

    local opening_paren = ({
        ["]"] = "[",
        [")"] = "(",
        ["}"] = "{",
    })[until_what]
    local paren_nesting = 0

    while true do
        -- Check exit condition.
        if stream.cur.type == "eof" then
            assert(until_what == "eof", "unexpected EOF")
            break
        end
        if opening_paren then
            if stream.cur.value == opening_paren then
                paren_nesting = paren_nesting + 1
            elseif stream.cur.value == until_what then
                paren_nesting = paren_nesting - 1
                if paren_nesting == -1 then
                    stream.nextToken()
                    break
                end
            end
        end

        if stream.cur.value == "local" then
            parsers.localGlobal(stream, chopper)
        elseif stream.cur.value == "global" then
            -- Since `global` is not a keyword, some occurrences of `global` may be identifiers. In
            -- fact, since `global = 1` is parsed as an assignment, it's not even guaranteed to be
            -- a keyword if it's at the beginning of a statement.
            local is_keyword
            if stream.next.type ~= "alnum" then
                is_keyword = false
            elseif (
                -- Does this position not accept a statement?
                -- An expression (or block end) is expected.
                anyOf(stream.prev.value, "if elseif in while until = [ ( { return , + - * / ^ % & ~ | < # and or not")
                or stream.prev.value == ">" and not stream.prev.is_attribute
                -- An identifier is expected. This should also include `local _` and
                -- `local record _`, etc., but we use a separate parser for that.
                or anyOf(stream.prev.value, "goto function for .")
                -- Method syntax, not a label.
                or stream.prev.value == ":" and stream.prev2.value ~= ":"
                -- Followed by a binary operator.
                or anyOf(stream.next.value, "and or")
            ) then
                is_keyword = false
            elseif anyOf(stream.next.value, "as is") then
                if anyOf(stream.next2.value, "< , : =") then
                    -- Definition of a variable named `is` or `as`.
                    is_keyword = false
                else
                    -- Check or cast.
                    is_keyword = true
                end
            else
                -- This is a keyword, since:
                -- - If the preceeding token is alnum, this is three alnums in a row, which only
                --   permits an identifier `global` in `if global then`, `for global in`, etc.,
                --   which have already been taken into account.
                -- - After a string, `]`, `)`, `}`, or `...`, there is a known statement boundary.
                -- - Label syntax permits two succeeding alnums only after the closing `::`.
                -- - After `;`, `global` can only be an identifier when followed by `and`, `or`,
                --   `is`, or `as`, which have already been handled.
                -- - All remaining tokens form invalid syntax.
                is_keyword = true
            end
            if is_keyword then
                parsers.localGlobal(stream, chopper)
            else
                stream.nextToken()
            end
        elseif stream.cur.value == "as" or stream.cur.value == "is" then
            -- `as|is (type)` may either be an operator use or a function call depending on context.
            local is_keyword
            if stream.prev.type == "string" then
                is_keyword = true
            elseif stream.prev.type == "punct" then
                if anyOf(stream.prev.value, ") ] }") then
                    is_keyword = true
                elseif (
                    -- `...`, split into three tokens.
                    stream.prev.value == "." and stream.prev2.value == "." and stream.prev3.value == "."
                ) then
                    is_keyword = true
                else
                    -- An expression, statement, or identifier is expected.
                    is_keyword = false
                end
            elseif stream.prev.type == "sof" then
                is_keyword = false
            else
                -- alnum
                if (
                    -- An identifier, statement, or expression is expected. This should also include
                    -- `local _` and `local record _`, etc., but we use a separate parser for that.
                    anyOf(stream.prev.value, "goto function for break do while repeat until if then elseif else in return")
                ) then
                    is_keyword = false
                elseif stream.prev.value == "end" then
                    -- Depends on whether `end` corresponds to a function expression.
                    is_keyword = stream.prev.is_function_expr
                else
                    -- Normal identifier.
                    is_keyword = true
                end
            end
            if not is_keyword then
                stream.nextToken()
            elseif stream.cur.value == "as" then
                parsers.as(stream, chopper)
            else
                parsers.is(stream, chopper)
            end
        elseif stream.tryConsume("do") or stream.tryConsume("if") then
            table.insert(nesting_is_function_expr, false)
        elseif stream.tryConsume("function") then
            local has_name = stream.cur.type == "alnum"
            if has_name then
                -- funcname
                stream.nextToken()
                while stream.tryConsume(".") do
                    assert(stream.cur.type == "alnum", "expected identifier after .")
                    stream.nextToken()
                end
                if stream.tryConsume(":") then
                    assert(stream.cur.type == "alnum", "expected identifier after :")
                    stream.nextToken()
                end
            end
            parsers.funcBodySignature(stream, chopper)
            table.insert(nesting_is_function_expr, not has_name)
        elseif stream.tryConsume("end") then
            if not next(nesting_is_function_expr) then
                assert(until_what == "end", "unbalanced end")
                return
            end
            stream.cur.is_function_expr = table.remove(nesting_is_function_expr)
        else
            stream.nextToken()
        end
    end

    assert(not next(nesting_is_function_expr), "unbalanced end")

    -- TODO: `field: type =` in table constructors
end

-- Parse a statement starting with `local` or `global`, before returning control to the shallow
-- parser.
function parsers.localGlobal(stream, chopper)
    -- `global` is implicit in Lua.
    if stream.cur.value == "global" then
        chopper.cut(stream.cur.first, stream.next.first - 1)
    end
    stream.nextToken()

    if stream.next.type == "alnum" and anyOf(stream.cur.value, "record interface enum type") then
        -- Parse `local record _`, etc. as a type definition if `_` is alnum. This isn't always
        -- correct per the grammar, but it seems to be the same heuristic that Teal uses:
        -- https://github.com/teal-language/tl/issues/1132
        parsers.typeDefinition(stream, chopper, true)
    elseif stream.cur.value == "function" then
        -- Let the shallow parser deal with this.
        return
    elseif stream.cur.value == "macroexp" then
        -- Change to a function and let the shallow parser deal with it accordingly. This doesn't
        -- need to be handled in the shallow parser alone because keyword `macroexp` is always
        -- preceeded by `local` or `global`.
        stream.cur.value = "function"
        chopper.cut(stream.cur.first, stream.cur.last, "function")
        return
    else
        -- Variable definition. We have to parse this until the type because function types are
        -- syntactically indistinguishable from the start of a closure, but don't require an `end`,
        -- and trying to use the shallow parser on this breaks `end` detection.
        repeat
            assert(stream.cur.type == "alnum", "invalid syntax in definition")
            stream.nextToken()
            -- Handle attributes: we need to remove `<total>` and annotate the closing angle bracket
            -- for the shallow parser.
            if stream.tryConsume("<") then
                local first = stream.prev.first
                assert(stream.cur.type == "alnum", "expected identifier in attribute")
                local name = stream.nextToken()
                assert(stream.tryConsume(">"), "invalid attribute syntax")
                stream.prev.is_attribute = true
                if name == "total" then
                    chopper.cut(first, stream.prev.last)
                end
            end
        until not stream.tryConsume(",")

        if stream.tryConsume(":") then
            local first = stream.prev.first
            repeat
                parsers.type(stream)
            until not stream.tryConsume(",")
            chopper.cut(first, stream.prev.last)
        end
    end
end

-- Parse a type definition like `record _ ... end`, replacing it with `_ = { ... };`, where the
-- table literal describes the type. Assumes that the first token is `record`, `interface`, `enum`,
-- or `type`, and the next token is alnum.
--
-- The table description is used for two purposes:
-- - To allow reexports of nested types to evaluate without triggering `nil` dereference, e.g. in
--   `return Type.Nested`.
-- - To populate the `__is` method for the `is` operator.
function parsers.typeDefinition(stream, chopper, allow_empty)
    local first = stream.cur.first
    local def_type = stream.cur.value
    local name_token = stream.next
    stream.nextToken()
    stream.nextToken()

    parsers.maybeTypeArgs(stream)

    if def_type == "type" then
        if stream.tryConsume("=") then
            -- Remove `type` prefix.
            chopper.cut(first, name_token.first - 1)
        else
            assert(allow_empty, "expected = <newtype> after 'type _'")
            chopper.cut(first, stream.prev.last)
            return
        end
    else
        -- Replace `record _` with `_ =` before parsing the rest of the definition.
        chopper.cut(first, name_token.first - 1)
        chopper.insert(name_token.last + 1, " =")
    end

    if def_type == "enum" then
        parsers.enumBody(stream, chopper)
    elseif def_type == "type" then
        -- newtype
        if anyOf(stream.cur.value, "record interface") then
            chopper.cut(stream.cur.first, stream.next.first - 1)
            stream.nextToken()
            parsers.recordBody(stream, chopper)
        elseif stream.tryConsume("enum") then
            chopper.cut(stream.cur.first, stream.next.first - 1)
            parsers.enumBody(stream, chopper)
        elseif stream.tryConsume("require") then
            -- Keep the `require` as-is, since it's already syntactically correct.
            assert(stream.tryConsume("("), "expected ( after require in newtype")
            parsers.shallow(stream, chopper, ")")
            while stream.tryConsume(".") do
                assert(stream.cur.type == "alnum", "expected identifier after .")
                stream.nextToken()
            end
        else
            local first = stream.cur.first
            local condition = parsers.type(stream)
            local def = "{ __is = function(self) return " .. condition:gsub("$", "self") .. " end }"
            chopper.cut(first, stream.prev.last, def)
        end
    else
        parsers.recordBody(stream, chopper)
    end

    chopper.insert(stream.prev.last + 1, ";")
end

-- Parses an `enumbody`. If `chopper` is passed, replaces it with `{ ... }` describing the type as
-- documented in `parsers.typeDefinition`.
function parsers.enumBody(stream, chopper)
    local first = stream.cur.first
    while stream.cur.type == "string" do
        stream.nextToken()
    end
    assert(stream.tryConsume("end"), "enum can only contain strings")
    if chopper then
        chopper.cut(first, stream.prev.last, '{ __is = function(self) return type(self) == "string" end }')
    end
end

-- Parses a `recordbody`. If `chopper` is passed, replaces it with `{ ... }` describing the type as
-- documented in `parsers.typeDefinition`.
function parsers.recordBody(stream, chopper)
    local first = stream.cur.first

    parsers.maybeTypeArgs(stream)

    -- Legacy syntax without `is`. Not documented in grammar, but used in the Teal compiler.
    if stream.cur.value == "{" then
        parsers.parenthesized(stream, "{", "}")
    end

    -- Teal does not consider `is` or `where` valid recordkeys, so there is no
    -- `stream.next.value ~= ":"` check here.
    if stream.tryConsume("is") then
        -- interfacelist
        local first = stream.prev.first
        parsers.baseType(stream)
        while stream.tryConsume(",") do
            parsers.baseType(stream)
        end
    end

    -- Cut carefully so that the `where` expression stays intact.
    if stream.tryConsume("where") then
        if chopper then
            chopper.cut(first, stream.prev.last, "{ __is = function(self) return ")
        end
        parsers.exp(stream, chopper)
        if chopper then
            chopper.insert(stream.prev.last + 1, " end; ")
        end
    else
        if chopper then
            chopper.cut(first, stream.prev.last, "{ ")
        end
    end

    while not stream.tryConsume("end") do
        -- recordentry
        local first = stream.cur.first
        local do_cut = true
        if (
            -- Ignore `userdata` when used as an identifier, e.g. in `userdata: type`.
            stream.cur.value == "userdata" and stream.next.type ~= "alnum"
        ) then
            stream.nextToken()
        elseif anyOf(stream.cur.value, "record interface enum type") and stream.next.type == "alnum" then
            parsers.typeDefinition(stream, chopper)
            do_cut = false
        else
            stream.tryConsume("metamethod")
            -- recordkey
            if stream.cur.value == "[" then
                parsers.parenthesized(stream, "[", "]")
            elseif stream.cur.type == "alnum" then
                stream.nextToken()
            else
                error("invalid recordkey")
            end
            assert(stream.tryConsume(":"), "expected : after recordkey in recordbody")
            parsers.type(stream)
        end
        if do_cut and chopper then
            chopper.cut(first, stream.prev.last)
        end
    end

    if chopper then
        chopper.cut(stream.prev.first, stream.prev.last, "}")
    end
end

-- Cut `as` casts.
function parsers.as(stream, chopper)
    local first = stream.cur.first
    stream.nextToken()
    if stream.cur.value == "(" then
        -- Teal supports parenthesized typelists after `as`, which `type` doesn't recognize.
        parsers.parenthesized(stream, "(", ")")
    else
        parsers.type(stream)
    end
    chopper.cut(first, stream.prev.last)
end

-- Lower `is` checks.
function parsers.is(stream, chopper)
    assert(stream.prev.type == "alnum", "'is' is only allowed after names")
    local first = stream.prev.first
    local name = stream.prev.value
    stream.nextToken()
    local condition = parsers.type(stream)
    chopper.cut(first, stream.prev.last, "(" .. condition:gsub("$", name) .. ")")
end

-- Parse a type, returning a condition similar to `parsers.baseType`.
function parsers.type(stream)
    if stream.tryConsume("(") then
        local condition = parsers.type(stream)
        assert(stream.tryConsume(")"), "expected ) in parenthesized type")
        return condition
    end
    local conditions = { parsers.baseType(stream) }
    while stream.tryConsume("|") do
        table.insert(conditions, parsers.baseType(stream))
    end
    return table.concat(conditions, " or ")
end

-- Parse a base type, returning a condition checking whether a value is of this type according to
-- the logic of the `is` operator. `$` is substituted for the variable name that is being checked.
function parsers.baseType(stream)
    if anyOf(stream.cur.value, "string boolean nil number thread table") then
        stream.nextToken()
        return 'type($) == "' .. stream.prev.value .. '"'
    elseif stream.tryConsume("any") then
        -- Weird, but that's the way it's lowered.
        return 'type($) == "table"'
    elseif stream.tryConsume("integer") then
        return 'math.type($) == "integer"'
    elseif stream.tryConsume("{") then
        parsers.type(stream)
        if stream.tryConsume(":") then
            -- map
            parsers.type(stream)
        else
            -- array or tuple
            while stream.tryConsume(",") do
                parsers.type(stream)
            end
        end
        assert(stream.tryConsume("}"), "missing } in basetype")
        return 'type($) == "table"'
    elseif stream.tryConsume("function") then
        parsers.maybeTypeArgs(stream)
        assert(stream.cur.value == "(", "missing ( after function in function type")
        parsers.parenthesized(stream, "(", ")")
        if stream.tryConsume(":") then
            parsers.retList(stream)
        end
        return 'type($) == "function"'
    elseif stream.cur.type == "alnum" then
        -- nominal type
        local first = stream.prev.first
        stream.nextToken()
        -- Filter `.<alnum>` to avoid consuming `...` split into three dots.
        while stream.next.type == "alnum" and stream.tryConsume(".") do
            stream.nextToken()
        end
        local last = stream.prev.last
        parsers.maybeTypeArgs(stream)
        return stream.code:sub(first, last)
    else
        error("invalid basetype")
    end
end

-- Parse `funcbody`, cutting out type annotations, stopping just before the block.
function parsers.funcBodySignature(stream, chopper)
    parsers.maybeTypeArgs(stream, chopper)

    assert(stream.tryConsume("("), "expected ( in function definition")
    while not stream.tryConsume(")") do
        if stream.tryConsume(":") then
            local first = stream.prev.first
            parsers.type(stream)
            chopper.cut(first, stream.prev.last)
        elseif stream.tryConsume("?") then
            chopper.cut(stream.prev.first, stream.prev.last)
        else
            -- Keep names and commas as is without wasting time parsing the exact grammar.
            stream.nextToken()
        end
    end

    if stream.tryConsume(":") then
        local first = stream.prev.first
        parsers.retList(stream)
        chopper.cut(first, stream.prev.last)
    end
end

function parsers.retList(stream)
    if stream.cur.value == "(" then
        parsers.parenthesized(stream, "(", ")")
    else
        parsers.type(stream)
        while stream.tryConsume(",") do
            parsers.type(stream)
        end
        if stream.tryConsume(".") then
            -- ... split into three tokens
            assert(stream.tryConsume("."), "expected ... in rettype")
            assert(stream.tryConsume("."), "expected ... in rettype")
        end
    end
end

-- Parse an expression until the end. This function is not supposed to be invoked often: it's slow,
-- and most of the time `parsers.shallow` suffices. It should only be used when there's no other way
-- to figure out when to stop parsing, e.g. if there's no `end` or `then` after the expression.
function parsers.exp(stream, chopper)
    while true do
        -- Unary operators
        while stream.tryConsume("-") or stream.tryConsume("not") or stream.tryConsume("#") or stream.tryConsume("~") do
        end
        -- Basic expression
        if stream.cur.type == "string" then
            stream.nextToken()
        elseif stream.tryConsume(".") then
            -- ... split into three tokens
            assert(stream.tryConsume("."), "expected ... in expression context")
            assert(stream.tryConsume("."), "expected ... in expression context")
        elseif stream.tryConsume("function") then
            parsers.funcBodySignature(stream, chopper)
            parsers.shallow(stream, chopper, "end")
        elseif stream.tryConsume("{") then
            parsers.shallow(stream, chopper, "}")
        else
            if stream.tryConsume("(") then
                parsers.shallow(stream, chopper, ")")
            elseif stream.cur.type == "alnum" then
                stream.nextToken()
            else
                error("invalid expression")
            end
            while true do
                if stream.tryConsume("[") then
                    parsers.shallow(stream, chopper, "]")
                elseif stream.tryConsume(".") then
                    assert(stream.cur.type == "alnum", "expected identifier after .")
                    stream.nextToken()
                elseif stream.tryConsume(":") then
                    assert(stream.cur.type == "alnum", "expected identifier after :")
                    stream.nextToken()
                    parsers.args(stream, chopper)
                elseif anyOf(stream.cur.value, "( {") or stream.cur.type == "string" then
                    parsers.args(stream, chopper)
                else
                    break
                end
            end
        end
        while true do
            if stream.cur.value == "as" then
                parsers.as(stream, chopper)
            elseif stream.cur.value == "is" then
                parsers.is(stream, chopper)
            else
                break
            end
        end
        if (
            stream.tryConsume("+")
            or stream.tryConsume("-")
            or stream.tryConsume("*")
            or stream.tryConsume("^")
            or stream.tryConsume("%")
            or stream.tryConsume("&")
            or stream.tryConsume("|")
            or stream.tryConsume("and")
            or stream.tryConsume("or")
        ) then
            -- pass
        elseif stream.tryConsume("/") then
            stream.tryConsume("/") -- / or //
        elseif stream.tryConsume(">") then
            local _ = stream.tryConsume(">") or stream.tryConsume("=") -- >, >>, or >=
        elseif stream.tryConsume("<") then
            local _ = stream.tryConsume("<") or stream.tryConsume("=") -- <, <<, or <=
        elseif stream.tryConsume(".") then
            assert(stream.tryConsume("."), "unexpected . in expression")
        elseif stream.tryConsume("=") then
            assert(stream.tryConsume("="), "unexpected = in expression")
        elseif stream.tryConsume("~") then
            stream.tryConsume("=") -- ~ or ~=
        else
            break
        end
    end
end

function parsers.args(stream, chopper)
    if stream.tryConsume("(") then
        parsers.shallow(stream, chopper, ")")
    elseif stream.tryConsume("{") then
        parsers.shallow(stream, chopper, "}")
    elseif stream.cur.type == "string" then
        stream.nextToken()
    else
        error("invalid function call syntax")
    end
end

function parsers.parenthesized(stream, open, close)
    local nesting = 0
    while stream.cur.type ~= "eof" do
        local value = stream.cur.value
        stream.nextToken()
        if value == open then
            nesting = nesting + 1
        elseif value == close then
            nesting = nesting - 1
            if nesting == 0 then
                return
            end
        end
    end
    assert("eof before " .. close)
end

-- Tries to parse `<...>` at the given location. If a chopper is passed, removes the matched part.
function parsers.maybeTypeArgs(stream, chopper)
    if stream.cur.value ~= "<" then
        return
    end
    local first = stream.cur.first
    parsers.parenthesized(stream, "<", ">")
    if chopper then
        chopper.cut(first, stream.prev.last)
    end
end

--         elseif token == "function" then
--             -- `function` is a keyword, so it being present anywhere indicates a function signature.
--             parse.function_()

-- local vfs = require "vfs"
-- local content = vfs.read("acc.lua")
-- local start = os.clock()
-- parse(content)
-- print(os.clock() - start)

local f = io.open(arg[1], "rb")
local content = f:read("*a")
f:close()

local chopper = chopping.makeChopper(content)
parsers.shallow(tokenstream.makeTokenStream(content), chopper, "eof")
print(chopper.finish())
