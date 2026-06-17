local lex = require "lex"
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
function parsers.shallow(stream, until_end)
    local n = 0

    -- Tracks nested blocks/expressions that are finished by the `end` keyword. Used for `as`/`is`
    -- resolution in edge cases. `true` for function expressions, `false` for everything else.
    local nesting_is_function_expr = {}

    while stream.cur.type ~= "eof" do
        if stream.cur.value == "local" then
            parsers.localGlobal(stream)
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
                parsers.localGlobal(stream)
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
                    -- An identifier, statement, or expression is expected.
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
        elseif stream.cur.value == "do" or stream.cur.value == "if" then
            table.insert(nesting_is_function_expr, false)
        elseif stream.cur.value == "function" then
            table.insert(nesting_is_function_expr, stream.next.type == "punct")
            -- recordbody
            -- enumbody
        elseif stream.cur.value == "end" then
            -- if not next(nesting_is_function_expr) then
            --     assert(until_end, "unbalanced end")
            --     return
            -- end
            stream.cur.is_function_expr = table.remove(nesting_is_function_expr)
        end

        if stream.cur.is_local_global and anyOf(stream.next.value, "record interface enum type") then
            table.remove(nesting_is_function_expr)
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
    --     elseif token == "record" or token == "interface" then
    --         -- These keywords are contextual, so they may also be names. Check if there's sufficient
    --         -- context for these to be keywords. Real records/interfaces are defined as
    --         --     local|global record|interface Name recordbody
    --         -- ...where the presence of `local|global` before this token and an alnum token after
    --         -- ensures this can't be anything but a keyword.
    --         local prev_token, _, prev_first, _ = lastToken()
    --         tokens()
    --         if prev_token == "local" or prev_token == "global" then
    --             local _, next_key = peekToken()
    --             if next_key == "alnum" then
    --                 -- This is a real definition.
    --                 startCut(prev_first)
    --                 tokens()
    --                 parse.recordbody()
    --                 endCut()
    --             end
    --         end
    --     else
    --         tokens()
    --     end
    --     n = n + 1
    -- end

    -- print(n)
end

-- Parse a statement starting with `local` or `global`, before returning control to the shallow
-- parser.
function parsers.localGlobal(stream)
    local first = stream.cur.first
    local is_global = stream.cur.value == "global"
    stream.nextToken()

    if stream.next.type == "alnum" and anyOf(stream.cur.value, "record interface enum type") then
        -- Parse `local record _`, etc. as a type definition if `_` is alnum. This isn't always
        -- correct per grammar, but it seems to be the same heuristic that Teal uses:
        -- https://github.com/teal-language/tl/issues/1132
        local def_type = stream.cur.value
        local name = stream.next.value
        stream.nextToken()
        stream.nextToken()

        if def_type == "enum" then
            -- parsers.enumBody(stream)
        elseif def_type == "type" then
            if stream.cur.value == "=" then
                stream.nextToken()
                -- parsers.newType(stream)
            end
        else
            -- parsers.recordBody(stream)
        end

        -- stream.cut(first, stream.prev.last)
    else
        -- Variable definition. We have to parse this until `:` or `=` to resolve attributes: both
        -- to remove `<total>` and to annotate the closing angle bracket for the shallow parser.
    end
end

-- local function transpile(code)
--     local tokens, peekToken, lastToken = lex(code)

--     local cut_first = nil
--     local cut_nesting = 0
--     local function startCut(pos)
--         if cut_nesting == 0 then
--             if pos then
--                 cut_first = pos
--             else
--                 local _, _, first, _ = lastToken()
--                 cut_first = first
--             end
--         end
--         cut_nesting = cut_nesting + 1
--     end
--     local function endCut()
--         cut_nesting = cut_nesting - 1
--         if cut_nesting == 0 then
--             local _, _, _, last = lastToken()
--             print("Cut", cut_first, "to", last, code:sub(cut_first, last))
--         end
--     end

--     local parse = {}

--     function parse.parenthesized(open, close)
--         local nesting = 0
--         for token in tokens do
--             if token == open then
--                 nesting = nesting + 1
--             elseif token == close then
--                 nesting = nesting - 1
--                 if nesting == 0 then
--                     return
--                 end
--             end
--         end
--     end

--     local n = 0
--     while true do
--         local token = peekToken()
--         if not token then
--             break
--         elseif token == "function" then
--             -- `function` is a keyword, so it being present anywhere indicates a function signature.
--             parse.function_()
--         elseif token == "record" or token == "interface" then
--             -- These keywords are contextual, so they may also be names. Check if there's sufficient
--             -- context for these to be keywords. Real records/interfaces are defined as
--             --     local|global record|interface Name recordbody
--             -- ...where the presence of `local|global` before this token and an alnum token after
--             -- ensures this can't be anything but a keyword.
--             local prev_token, _, prev_first, _ = lastToken()
--             tokens()
--             if prev_token == "local" or prev_token == "global" then
--                 local _, next_key = peekToken()
--                 if next_key == "alnum" then
--                     -- This is a real definition.
--                     startCut(prev_first)
--                     tokens()
--                     parse.recordbody()
--                     endCut()
--                 end
--             end
--         else
--             tokens()
--         end
--         n = n + 1
--     end

--     print(n)
-- end

-- local vfs = require "vfs"
-- local content = vfs.read("acc.lua")
-- local start = os.clock()
-- parse(content)
-- print(os.clock() - start)

local f = io.open(arg[1], "rb")
local content = f:read("*a")
f:close()

parsers.shallow(tokenstream.lexerToTokenStream(lex.lex(content)))
