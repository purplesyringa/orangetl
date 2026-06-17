local chopper = require "chopper"
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
function parsers.shallow(stream, chopper, until_end)
    local n = 0

    -- Tracks nested blocks/expressions that are finished by the `end` keyword. Used for `as`/`is`
    -- resolution in edge cases. `true` for function expressions, `false` for everything else.
    local nesting_is_function_expr = {}

    while stream.cur.type ~= "eof" do
        if stream.cur.value == "local" then
            parsers.localGlobal(stream, chopper)
            goto next
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
                -- `local record _`, but we use a separate parser for that.
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
                goto next
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
                    -- `local _` and `local record _`, but we use a separate parser for that.
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
            if is_keyword then
                if stream.cur.value == "as" then
                    parsers.as(stream, chopper)
                    goto next
                else
                    parsers.is(stream, chopper)
                    goto next
                end
            end
        elseif stream.cur.value == "do" or stream.cur.value == "if" then
            table.insert(nesting_is_function_expr, false)
        elseif stream.cur.value == "function" then
            table.insert(nesting_is_function_expr, stream.next.type == "punct")
            -- TODO: remove types
        elseif stream.cur.value == "end" then
            -- TODO: uncomment
            -- if not next(nesting_is_function_expr) then
            --     assert(until_end, "unbalanced end")
            --     return
            -- end
            stream.cur.is_function_expr = table.remove(nesting_is_function_expr)
        end

        stream.nextToken()

        ::next::
    end

    print(table.unpack(nesting_is_function_expr))

    if not until_end then
        assert(not next(nesting_is_function_expr), "missing 'end'")
    end

    -- for token in tokens.peek do
    --     -- We're interested in:
    --     -- - `as`, `is`
    --     -- - `field: type =`
    --     -- - `function [name] <...> (...)`
    --     -- - `local`/`global` ...
    --     if token == "function" then
    --         -- `function` is a keyword, so it being present anywhere indicates a function signature.
    --         parse.function_()
    --     end
    --     n = n + 1
    -- end

    -- print(n)
end

-- Parse a statement starting with `local` or `global`, before returning control to the shallow
-- parser.
function parsers.localGlobal(stream, chopper)
    local first = stream.cur.first
    local is_global = stream.cur.value == "global"
    stream.nextToken()

    if stream.next.type == "alnum" and anyOf(stream.cur.value, "record interface enum type") then
        -- Parse `local record _`, etc. as a type definition if `_` is alnum. This isn't always
        -- correct per grammar, but it seems to be the same heuristic that Teal uses:
        -- https://github.com/teal-language/tl/issues/1132
        parsers.typeDefinition(stream)
        -- chopper.cut(first, stream.prev.last)
    else
        -- Variable definition. We have to parse this until `:` or `=` to resolve attributes: both
        -- to remove `<total>` and to annotate the closing angle bracket for the shallow parser.
    end
end

-- Parses a type definition like `record ...`, returning code to replace it with. Assumes that the
-- first token is `record`, `interface`, `enum`, or `type`, and the next token is alnum.
function parsers.typeDefinition(stream)
    local def_type = stream.cur.value
    local name = stream.next.value
    stream.nextToken()
    stream.nextToken()

    -- TODO: Convert the type definition to a value assignment for two purposes:
    -- - To allow reexports of nested types to evaluate without triggering `nil` dereference,
    --   e.g. in `return Type.Nested`.
    -- - To populate the `__is` method for the `is` operator.

    if def_type == "enum" then
        parsers.enumBody(stream)
    elseif def_type == "type" then
        if stream.cur.value == "=" then
            stream.nextToken()
            -- newtype
            if anyOf(stream.cur.value, "record interface") then
                stream.nextToken()
                parsers.recordBody(stream)
            elseif stream.cur.value == "enum" then
                stream.nextToken()
                parsers.enumBody(stream)
            elseif stream.cur.value == "require" then
                stream.nextToken()
                assert(stream.cur.value == "(", "expected ( after require in newtype")
                parsers.parenthesized(stream, "(", ")")
                while stream.cur.value == "." do
                    stream.nextToken()
                    assert(stream.cur.type == "alnum", "expected identifier after .")
                    stream.nextToken()
                end
            else
                parsers.type(stream)
            end
        end
    else
        parsers.recordBody(stream)
    end

    -- chopper.cut(first, stream.prev.last)
end

function parsers.enumBody(stream)
    while stream.cur.type == "string" do
        stream.nextToken()
    end
    assert(stream.cur.value == "end", "enum can only contain strings")
    stream.nextToken()
end

function parsers.recordBody(stream)
    if stream.cur.value == "<" then
        parsers.parenthesized(stream, "<", ">")
    end

    -- Teal does not consider `is` or `where` valid recordkeys, so there is no
    -- `stream.next.value ~= ":"` check here.
    if stream.cur.value == "is" then
        stream.nextToken()
        -- interfacelist
        parsers.baseType(stream)
        while stream.cur.value == "," do
            stream.nextToken()
            parsers.baseType(stream)
        end
    end
    if stream.cur.value == "where" then
        stream.nextToken()
        -- oopsie daisy, exp
        print("oopsie daisy, where!")
    end

    while stream.cur.value ~= "end" do
        -- recordentry
        if (
            -- Ignore `userdata` when used as an identifier, e.g. in `userdata: type`.
            stream.cur.value == "userdata" and stream.next.type ~= "alnum"
        ) then
            stream.nextToken()
        elseif anyOf(stream.cur.value, "record interface enum type") and stream.next.type == "alnum" then
            parsers.typeDefinition(stream)
        else
            if stream.cur.value == "metamethod" then
                stream.nextToken()
            end
            -- recordkey
            if stream.cur.value == "[" then
                parsers.parenthesized(stream, "[", "]")
            elseif stream.cur.type == "alnum" then
                stream.nextToken()
            else
                error("invalid recordkey")
            end
            assert(stream.cur.value == ":", "expected : after recordkey in recordbody")
            stream.nextToken()
            parsers.type(stream)
        end
    end
    stream.nextToken()
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
    local base_types = parsers.type(stream)

    local conditions = {}
    for i, base_type in ipairs(base_types) do
        if type(base_type) == "string" then
            conditions[i] = ('type(%s) == "%s"'):format(name, base_type)
        else
            base_type = stream.code:sub(base_type.first, base_type.last)
            conditions[i] = ('%s.__is(%s)'):format(base_type, name)
        end
    end
    chopper.cut(first, stream.prev.last, table.concat(conditions, " or "))
end

-- Parse a type, returning a list of base types as parsed by `parsers.baseType`.
function parsers.type(stream)
    if stream.cur.value == "(" then
        stream.nextToken()
        local type = parsers.type(stream)
        assert(stream.cur.value == ")", "expected ) in parenthesized type")
        stream.nextToken()
        return type
    end
    local base_types = { parsers.baseType(stream) }
    while stream.cur.value == "|" do
        stream.nextToken()
        table.insert(base_types, parsers.baseType(stream))
    end
    return base_types
end

-- Parse a base type, returning "string", "boolean", "nil", "number", "table", or "function" for
-- structured types, and `{ first = _, last = _ }` for nominal types (ignoring typeargs).
function parsers.baseType(stream)
    if anyOf(stream.cur.value, "string boolean nil number") then
        stream.nextToken()
        return stream.prev.value
    elseif stream.cur.value == "{" then
        stream.nextToken()
        parsers.type(stream)
        if stream.cur.value == ":" then
            -- map
            stream.nextToken()
            parsers.type(stream)
        else
            -- array or tuple
            while stream.cur.value == "," do
                stream.nextToken()
                parsers.type(stream)
            end
        end
        assert(stream.cur.value == "}", "missing } in basetype")
        stream.nextToken()
        return "table"
    elseif stream.cur.value == "function" then
        stream.nextToken()
        if stream.cur.value == "<" then
            parsers.parenthesized(stream, "<", ">")
        end
        assert(stream.cur.value == "(", "missing ( after function in function type")
        parsers.parenthesized(stream, "(", ")")
        if stream.cur.value == ":" then
            stream.nextToken()
            parsers.retList(stream)
        end
        return "function"
    elseif stream.cur.type == "alnum" then
        -- nominal type
        local first = stream.cur.first
        stream.nextToken()
        while stream.cur.value == "." do
            stream.nextToken()
            assert(stream.cur.type == "alnum", "expected identifier after .")
            stream.nextToken()
        end
        local last = stream.prev.last
        if stream.cur.value == "<" then
            parsers.parenthesized(stream, "<", ">")
        end
        return { first = first, last = last }
    else
        error("invalid basetype")
    end
end

function parsers.retList(stream)
    if stream.cur.value == "(" then
        parsers.parenthesized(stream, "(", ")")
    else
        parsers.type(stream)
        while stream.cur.value == "," do
            stream.nextToken()
            parsers.type(stream)
        end
        if stream.cur.value == "..." then
            stream.nextToken()
        end
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

parsers.shallow(tokenstream.makeTokenStream(content), chopper.makeChopper(content))
