local chopping = require("orangetl.chopping")
local tokenstream = require("orangetl.tokenstream")

local function anyOf(s, pattern)
    for t in pattern:gmatch("[^%s]+") do
        if s == t then
            return true
        end
    end
    return false
end

local Transpiler = {}

local function transpile(code, opts)
    code = code:gsub("^#[^\n]*", "") -- remove shebang
    local transpiler = setmetatable({
        code = code,
        stream = tokenstream.makeTokenStream(code),
        chopper = chopping.makeChopper(code),
        opts = opts or {},
    }, { __index = Transpiler })
    transpiler:parseShallow("eof")
    return transpiler.chopper.finish()
end

-- An approximate, non-recursive parser that greps for structures we're interested in without
-- constructing a syntax tree. It acts as a sieve, passing control to a better parser as it
-- recognizes an important construct.
--
-- Parses the input up to and including `until_what`, which can be one of:
-- - `eof`: matches until the end of file.
-- - `]`, `)`, `}`: matches until the first closing bracket not matching any open bracket in the
--   stream.
-- - `end`: matches until the first `end` not matching any open block in the stream.
function Transpiler:parseShallow(until_what)
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
        if self.stream.cur.type == "eof" then
            assert(until_what == "eof", "unexpected EOF")
            break
        end
        if opening_paren then
            if self.stream.cur.value == opening_paren then
                paren_nesting = paren_nesting + 1
            elseif self.stream.cur.value == until_what then
                paren_nesting = paren_nesting - 1
                if paren_nesting == -1 then
                    self.stream.nextToken()
                    break
                end
            end
        end

        if self.stream.cur.value == "local" then
            self:parseLocalGlobal()
        elseif self.stream.cur.value == "global" then
            -- Since `global` is not a keyword in Teal, some occurrences of `global` may be
            -- identifiers. In fact, since `global = 1` is parsed as an assignment, it's not even
            -- guaranteed to be a keyword if it's at the beginning of a statement.
            local is_keyword
            if self.stream.next.type ~= "alnum" then
                is_keyword = false
            elseif
                -- Does this position not accept a statement?
                -- An expression (or block end) is expected.
                anyOf(
                    self.stream.prev.value,
                    "if elseif in while until = [ ( { return , + - * / ^ % & ~ | < # and or not"
                )
                or self.stream.prev.value == ">" and not self.stream.prev.is_attribute
                -- An identifier is expected. This should also include `local _` and
                -- `local record _`, etc., but we use a separate parser for that.
                or anyOf(self.stream.prev.value, "goto function for .")
                -- Method syntax, not a label.
                or self.stream.prev.value == ":" and self.stream.prev2.value ~= ":"
                -- Followed by a binary operator.
                or anyOf(self.stream.next.value, "and or")
            then
                is_keyword = false
            elseif anyOf(self.stream.next.value, "as is") then
                if anyOf(self.stream.next2.value, "< , : =") then
                    -- Definition of a variable named `is` or `as`.
                    is_keyword = false
                else
                    -- Check or cast.
                    is_keyword = true
                end
            else
                -- This is a keyword, since:
                -- - If the preceding token is alnum, this is three alnums in a row, which only
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
                self:parseLocalGlobal()
            else
                self.stream.nextToken()
            end
        elseif self.stream.cur.value == "as" or self.stream.cur.value == "is" then
            -- `as|is (type)` may either be an operator use or a function call depending on context.
            local is_keyword
            if self.stream.prev.type == "string" then
                is_keyword = true
            elseif self.stream.prev.type == "punct" then
                if anyOf(self.stream.prev.value, ") ] }") then
                    is_keyword = true
                elseif
                    -- `...`, split into three tokens.
                    self.stream.prev.value == "."
                    and self.stream.prev2.value == "."
                    and self.stream.prev3.value == "."
                then
                    is_keyword = true
                else
                    -- An expression, statement, or identifier is expected.
                    is_keyword = false
                end
            elseif self.stream.prev.type == "sof" then
                is_keyword = false
            else
                -- alnum
                if
                    -- An identifier, statement, or expression is expected. This should also include
                    -- `local _` and `local record _`, etc., but we use a separate parser for that.
                    anyOf(
                        self.stream.prev.value,
                        "goto function for break do while repeat until if then elseif else in return"
                    )
                then
                    is_keyword = false
                elseif self.stream.prev.value == "end" then
                    -- Depends on whether `end` corresponds to a function expression.
                    is_keyword = self.stream.prev.is_function_expr
                else
                    -- Normal identifier.
                    is_keyword = true
                end
            end
            if not is_keyword then
                self.stream.nextToken()
            elseif self.stream.cur.value == "as" then
                self:parseAs()
            else
                self:parseIs()
            end
        elseif self.stream.tryConsume("do") or self.stream.tryConsume("if") then
            table.insert(nesting_is_function_expr, false)
        elseif self.stream.tryConsume("function") then
            local has_name = self.stream.cur.type == "alnum"
            if has_name then
                -- funcname
                self.stream.nextToken()
                while self.stream.tryConsume(".") do
                    assert(self.stream.cur.type == "alnum", "expected identifier after .")
                    self.stream.nextToken()
                end
                -- Return type, not a label definition.
                if self.stream.next.value ~= ":" and self.stream.tryConsume(":") then
                    assert(self.stream.cur.type == "alnum", "expected identifier after :")
                    self.stream.nextToken()
                end
            end
            self:parseFuncBodySignature()
            table.insert(nesting_is_function_expr, not has_name)
        elseif self.stream.tryConsume("end") then
            if not next(nesting_is_function_expr) then
                assert(until_what == "end", "unbalanced end")
                return
            end
            self.stream.cur.is_function_expr = table.remove(nesting_is_function_expr)
        elseif
            -- Recognize `field: type =` in tables, ignoring `:` in method calls and labels.
            self.stream.cur.value == ":"
            and self.stream.prev.value ~= ":"
            and self.stream.next.value ~= ":"
            and not (
                self.stream.next.type == "alnum"
                and self.stream.next.value ~= "function"
                and (self.stream.next2.type == "string" or anyOf(self.stream.next2.value, "( {"))
            )
        then
            local first = self.stream.cur.first
            self.stream.nextToken()
            self:parseType()
            self.chopper.cut(first, self.stream.prev.last)
        elseif
            self.stream.cur.value == "("
            and not self.opts.lua_quirks
            and self.stream.isCurPrecededByNewline()
            -- Match parentheses in a function call, but not in grouping. Types
            -- (`function(...)` and `(type)`) and function signatures (`function [name](...)`) are
            -- automatically excluded because they are parsed separately.
            and (
                (
                    self.stream.prev.type == "alnum"
                    -- Exclude grouping after operators and statements, where expressions are
                    -- expected. This erroneously recognizes `where (...)` as a call, but `where` is
                    -- parsed by the `exp` parser, not this one. It also recognizes
                    -- `goto label (...)` as a call, but inserting `;` between statements is fine --
                    -- it's expressions we have to worry about. Note that this list includes `do`
                    -- and `else`, since Lua 5.1 doesn't allow `;` at the beginning of blocks, only
                    -- after statements.
                    and not anyOf(
                        self.stream.prev.value,
                        "and do else elseif end for if in not or repeat return then until while"
                    )
                )
                or self.stream.prev.type == "string"
                or anyOf(self.stream.prev.value, ") ] }")
            )
        then
            -- Teal idiosyncrasy
            self.chopper.insert(self.stream.prev.last + 1, ";")
            self.stream.nextToken()
        else
            self.stream.nextToken()
        end
    end

    assert(not next(nesting_is_function_expr), "unbalanced end")
end

-- Parse a statement starting with `local` or `global`, before returning control to the shallow
-- parser.
function Transpiler:parseLocalGlobal()
    -- `global` is implicit in Lua, and with Teal semantics it's unsound to keep it even in Lua 5.5.
    local is_global = self.stream.cur.value == "global"
    if is_global then
        self.chopper.cut(self.stream.cur.first, self.stream.next.first - 1)
    end
    self.stream.nextToken()

    if
        self.stream.next.type == "alnum"
        and anyOf(self.stream.cur.value, "record interface enum type macroexp")
        -- Separate `local record <ident>` (type definition) from `local record <keyword>` (empty
        -- `local` definition, followed by another block).
        -- See also: https://github.com/teal-language/tl/issues/1132
        and not anyOf(
            self.stream.next.value,
            "and break do else elseif end false for function goto if in local nil not or repeat return then true until while"
        )
    then
        if self.stream.cur.value == "macroexp" then
            -- Change to a function and let the shallow parser deal with it accordingly. This
            -- doesn't need to be handled in the shallow parser alone because keyword `macroexp` is
            -- always preceded by `local` or `global`.
            self.stream.cur.value = "function"
            self.chopper.cut(self.stream.cur.first, self.stream.cur.last, "function")
        else
            -- Parse `local record _`, etc. as a type definition if `_` is alnum. This isn't always
            -- correct per the grammar, but it seems to be the same heuristic that Teal uses:
            -- https://github.com/teal-language/tl/issues/1132
            self:parseTypeDefinition(true)
        end
    elseif self.stream.cur.value == "function" then
        -- Let the shallow parser deal with this.
        return
    else
        -- Variable definition. We have to parse this until the type because function types are
        -- syntactically indistinguishable from the start of a closure, but don't require an `end`,
        -- and trying to use the shallow parser on this breaks `end` detection.
        local def_first = self.stream.cur.first
        local to_cut = {}

        repeat
            assert(self.stream.cur.type == "alnum", "invalid syntax in definition")
            self.stream.nextToken()
            -- Handle attributes: we need to rewrite `<total>` and annotate the closing angle
            -- bracket for the shallow parser.
            if self.stream.tryConsume("<") then
                local first = self.stream.prev.first
                assert(self.stream.cur.type == "alnum", "expected identifier in attribute")
                local attr = self.stream.cur.value
                self.stream.nextToken()
                assert(self.stream.tryConsume(">"), "invalid attribute syntax")
                self.stream.prev.is_attribute = true
                if self.opts.strip_attributes then
                    -- Stripping `<close>` affects semantics.
                    assert(
                        attr == "const" or attr == "total",
                        "cannot strip attribute '" .. attr .. "'"
                    )
                    -- Delay cutting until we decide if we want to delete the statement altogether.
                    table.insert(to_cut, { first = first, last = self.stream.prev.last })
                elseif attr == "total" then
                    -- Teal translates <total> to <const>.
                    table.insert(
                        to_cut,
                        {
                            first = self.stream.prev2.first,
                            last = self.stream.prev2.last,
                            value = "const",
                        }
                    )
                end
            end
        until not self.stream.tryConsume(",")

        -- Type, not a label definition.
        if self.stream.next.value ~= ":" and self.stream.tryConsume(":") then
            local first = self.stream.prev.first
            repeat
                self:parseType()
            until not self.stream.tryConsume(",")
            table.insert(to_cut, { first = first, last = self.stream.prev.last })
        end

        if is_global and self.stream.cur.value ~= "=" then
            -- Delete `global` definitions without values.
            self.chopper.cut(def_first, self.stream.prev.last)
        else
            -- Apply attribute stripping.
            for _, range in ipairs(to_cut) do
                self.chopper.cut(range.first, range.last, range.value)
            end
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
--
-- This differs from Teal, which only generates such definitions for records, but not interfaces or
-- enums, because we need `__is` to be a runtime method.
function Transpiler:parseTypeDefinition(allow_empty)
    local first = self.stream.cur.first
    local def_type = self.stream.cur.value
    local name_token = self.stream.next
    self.stream.nextToken()
    self.stream.nextToken()

    local typeargs_first = self.stream.cur.first
    self:maybeParseTypeArgs()
    local typeargs_last = self.stream.prev.last

    if def_type == "type" then
        if self.stream.tryConsume("=") then
            -- Remove `type` prefix.
            self.chopper.cut(first, name_token.first - 1)
        else
            -- Removes the entire declaration, including typeargs.
            assert(allow_empty, "expected = <newtype> after 'type _'")
            self.chopper.cut(first, self.stream.prev.last)
            return
        end
    else
        -- Replace `record _` with `_ =` before parsing the rest of the definition.
        self.chopper.cut(first, name_token.first - 1)
        self.chopper.insert(name_token.last + 1, " =")
    end

    -- Cut out typeargs.
    self.chopper.cut(typeargs_first, typeargs_last)

    if def_type == "enum" then
        self:parseEnumBody()
    elseif def_type == "type" then
        -- newtype
        if anyOf(self.stream.cur.value, "record interface") then
            self.chopper.cut(self.stream.cur.first, self.stream.next.first - 1)
            self.stream.nextToken()
            self:parseRecordBody()
        elseif self.stream.tryConsume("enum") then
            self.chopper.cut(self.stream.prev.first, self.stream.cur.first - 1)
            self:parseEnumBody()
        elseif self.stream.tryConsume("require") then
            -- Keep the `require` as-is, since it's already syntactically correct.
            assert(self.stream.tryConsume("("), "expected ( after require in newtype")
            self:parseShallow(")")
            while self.stream.tryConsume(".") do
                assert(self.stream.cur.type == "alnum", "expected identifier after .")
                self.stream.nextToken()
            end
        else
            local first = self.stream.cur.first
            local condition = self:parseType()
            -- TODO: optimize to passthrough
            local def = "{ __is = function(self) return " .. condition:gsub("!", "self") .. " end }"
            self.chopper.cut(first, self.stream.prev.last, def)
        end
    else
        self:parseRecordBody()
    end

    self.chopper.insert(self.stream.prev.last + 1, ";")
end

-- Parses an `enumbody` and replaces it with `{ ... }` describing the type as documented in
-- `parseTypeDefinition`.
function Transpiler:parseEnumBody()
    local first = self.stream.cur.first
    while self.stream.cur.type == "string" do
        self.stream.nextToken()
    end
    assert(self.stream.tryConsume("end"), "enum can only contain strings")
    self.chopper.cut(
        first,
        self.stream.prev.last,
        '{ __is = function(self) return type(self) == "string" end }'
    )
end

-- Parses a `recordbody` and replaces it with `{ ... }` describing the type as documented in
-- `parseTypeDefinition`.
function Transpiler:parseRecordBody()
    local first = self.stream.cur.first

    self:maybeParseTypeArgs()

    -- Legacy syntax without `is`. Not documented in grammar, but used in the Teal compiler.
    if self.stream.cur.value == "{" then
        self:parseParenthesized("{", "}")
    end

    -- Teal does not consider `is` or `where` valid recordkeys, so there is no
    -- `self.stream.next.value ~= ":"` check here.
    if self.stream.tryConsume("is") then
        -- interfacelist
        self:parseBaseType()
        while self.stream.tryConsume(",") do
            self:parseBaseType()
        end
    end

    -- Cut carefully so that the `where` expression stays intact.
    if self.stream.tryConsume("where") then
        self.chopper.cut(first, self.stream.prev.last, "{ __is = function(self) return")
        self:parseExp()
        self.chopper.insert(self.stream.prev.last + 1, " end; ")
    else
        self.chopper.cut(first, self.stream.prev.last, "{ ")
        -- Delay inserting `__is` until we know if this type is `userdata`.
    end

    local is_userdata = false

    while not self.stream.tryConsume("end") do
        -- recordentry
        local first = self.stream.cur.first
        local do_cut = true
        if
            -- Ignore `userdata` when used as an identifier, e.g. in `userdata: type`.
            self.stream.cur.value == "userdata" and self.stream.next.value ~= ":"
        then
            is_userdata = true
            self.stream.nextToken()
        elseif
            anyOf(self.stream.cur.value, "record interface enum type")
            and self.stream.next.type == "alnum"
        then
            self:parseTypeDefinition()
            do_cut = false
        else
            if self.stream.next.value ~= ":" then
                self.stream.tryConsume("metamethod")
            end
            -- recordkey
            if self.stream.cur.value == "[" then
                self:parseParenthesized("[", "]")
            elseif self.stream.cur.type == "alnum" then
                self.stream.nextToken()
            else
                error("invalid recordkey")
            end
            assert(self.stream.tryConsume(":"), "expected : after recordkey in recordbody")
            self:parseType()
            assert(not self.stream.tryConsume("="), "assignments in recordbody are not supported")
        end
        if do_cut then
            self.chopper.cut(first, self.stream.prev.last)
        end
    end

    local condition
    if is_userdata then
        condition = 'type(self) == "userdata"'
    else
        condition = 'type(self) == "table"'
    end
    self.chopper.cut(
        self.stream.prev.first,
        self.stream.prev.last,
        "__is = function(self) return " .. condition .. " end; }"
    )
end

-- Cut `as` casts.
function Transpiler:parseAs()
    local first = self.stream.cur.first
    self.stream.nextToken()
    if self.stream.cur.value == "(" then
        -- Teal supports parenthesized typelists after `as`, which `type` doesn't recognize.
        self:parseParenthesized("(", ")")
    else
        self:parseType()
    end
    self.chopper.cut(first, self.stream.prev.last)
end

-- Lower `is` checks.
function Transpiler:parseIs()
    assert(self.stream.prev.type == "alnum", "'is' is only allowed after names")
    local first = self.stream.prev.first
    local name = self.stream.prev.value
    self.stream.nextToken()
    local condition = self:parseType()
    self.chopper.cut(first, self.stream.prev.last, "(" .. condition:gsub("!", name) .. ")")
end

-- Parse a type, returning a condition similar to `parseBaseType`.
function Transpiler:parseType()
    if self.stream.tryConsume("(") then
        local condition = self:parseType(self.stream)
        assert(self.stream.tryConsume(")"), "expected ) in parenthesized type")
        return condition
    end
    local conditions = { self:parseBaseType() }
    while self.stream.tryConsume("|") do
        table.insert(conditions, self:parseBaseType())
    end
    return table.concat(conditions, " or ")
end

-- Parse a base type, returning a condition checking whether a value is of this type according to
-- the logic of the `is` operator. `!` is substituted for the variable name that is being checked.
function Transpiler:parseBaseType()
    if anyOf(self.stream.cur.value, "string boolean number thread table userdata") then
        self.stream.nextToken()
        return 'type(!) == "' .. self.stream.prev.value .. '"'
    elseif self.stream.tryConsume("any") then
        -- Weird, but that's the way it's lowered.
        return 'type(!) == "table"'
    elseif self.stream.tryConsume("integer") then
        return 'math.type(!) == "integer"'
    elseif self.stream.tryConsume("nil") then
        return '! == nil'
    elseif self.stream.cur.value == "{" then
        self:parseParenthesized("{", "}")
        return 'type(!) == "table"'
    elseif self.stream.tryConsume("function") then
        self:maybeParseTypeArgs()
        -- `function` or `function<...>` alone denotes an arbitrary function.
        if self.stream.cur.value == "(" then
            self:parseParenthesized("(", ")")
            -- Type, not a label definition.
            if self.stream.next.value ~= ":" and self.stream.tryConsume(":") then
                self:parseRetList()
            end
        end
        return 'type(!) == "function"'
    elseif self.stream.cur.type == "alnum" then
        -- nominal type
        local first = self.stream.cur.first
        self.stream.nextToken()
        -- Filter `.<alnum>` to avoid consuming `...` split into three dots.
        while self.stream.next.type == "alnum" and self.stream.tryConsume(".") do
            self.stream.nextToken()
        end
        local last = self.stream.prev.last
        self:maybeParseTypeArgs()
        return self.code:sub(first, last) .. ".__is(!)"
    else
        error("invalid basetype")
    end
end

-- Parse `funcbody`, cutting out type annotations, stopping just before the block.
function Transpiler:parseFuncBodySignature()
    local first = self.stream.cur.first
    self:maybeParseTypeArgs()
    self.chopper.cut(first, self.stream.prev.last)

    assert(self.stream.tryConsume("("), "expected ( in function definition")
    while not self.stream.tryConsume(")") do
        if self.stream.tryConsume(":") then
            local first = self.stream.prev.first
            self:parseType()
            self.chopper.cut(first, self.stream.prev.last)
        elseif self.stream.tryConsume("?") then
            self.chopper.cut(self.stream.prev.first, self.stream.prev.last)
        else
            -- Keep names and commas as is without wasting time parsing the exact grammar.
            self.stream.nextToken()
        end
    end

    -- Type, not a label definition.
    if self.stream.next.value ~= ":" and self.stream.tryConsume(":") then
        local first = self.stream.prev.first
        self:parseRetList()
        self.chopper.cut(first, self.stream.prev.last)
    end
end

function Transpiler:parseRetList()
    if self.stream.cur.value == "(" then
        self:parseParenthesized("(", ")")
    else
        self:parseType()
        while self.stream.tryConsume(",") do
            self:parseType()
        end
        if self.stream.tryConsume(".") then
            -- ... split into three tokens
            assert(self.stream.tryConsume("."), "expected ... in rettype")
            assert(self.stream.tryConsume("."), "expected ... in rettype")
        end
    end
end

-- Parse an expression until the end. This function is not supposed to be invoked often: it's slow,
-- and most of the time `parseShallow` suffices. It should only be used when there's no other way to
-- figure out when to stop parsing, e.g. if there's no `end` or `then` after the expression.
function Transpiler:parseExp()
    while true do
        -- Unary operators
        while
            self.stream.tryConsume("-")
            or self.stream.tryConsume("not")
            or self.stream.tryConsume("#")
            or self.stream.tryConsume("~")
        do
        end
        -- Basic expression
        if self.stream.cur.type == "string" then
            self.stream.nextToken()
        elseif self.stream.tryConsume(".") then
            -- ... split into three tokens
            assert(self.stream.tryConsume("."), "expected ... in expression context")
            assert(self.stream.tryConsume("."), "expected ... in expression context")
        elseif self.stream.tryConsume("function") then
            self:parseFuncBodySignature()
            self:parseShallow("end")
        elseif self.stream.tryConsume("{") then
            self:parseShallow("}")
        else
            if self.stream.tryConsume("(") then
                self:parseShallow(")")
            elseif self.stream.cur.type == "alnum" then
                self.stream.nextToken()
            else
                error("invalid expression")
            end
            while true do
                if self.stream.tryConsume("[") then
                    self:parseShallow("]")
                elseif self.stream.tryConsume(".") then
                    assert(self.stream.cur.type == "alnum", "expected identifier after .")
                    self.stream.nextToken()
                elseif self.stream.next.value ~= ":" and self.stream.tryConsume(":") then
                    assert(self.stream.cur.type == "alnum", "expected identifier after :")
                    self.stream.nextToken()
                    self:parseArgs()
                elseif
                    self.stream.cur.value == "("
                    and not self.opts.lua_quirks
                    and self.stream.isCurPrecededByNewline()
                then
                    -- Teal idiosyncrasy
                    self.chopper.insert(self.stream.prev.last + 1, ";")
                    break
                elseif anyOf(self.stream.cur.value, "( {") or self.stream.cur.type == "string" then
                    self:parseArgs()
                else
                    break
                end
            end
        end
        while true do
            if self.stream.cur.value == "as" then
                self:parseAs()
            elseif self.stream.cur.value == "is" then
                self:parseIs()
            else
                break
            end
        end
        if
            self.stream.tryConsume("+")
            or self.stream.tryConsume("-")
            or self.stream.tryConsume("*")
            or self.stream.tryConsume("^")
            or self.stream.tryConsume("%")
            or self.stream.tryConsume("&")
            or self.stream.tryConsume("|")
            or self.stream.tryConsume("and")
            or self.stream.tryConsume("or")
        then
            -- pass
        elseif self.stream.tryConsume("/") then
            self.stream.tryConsume("/") -- / or //
        elseif self.stream.tryConsume(">") then
            local _ = self.stream.tryConsume(">") or self.stream.tryConsume("=") -- >, >>, or >=
        elseif self.stream.tryConsume("<") then
            local _ = self.stream.tryConsume("<") or self.stream.tryConsume("=") -- <, <<, or <=
        elseif self.stream.tryConsume(".") then
            assert(self.stream.tryConsume("."), "unexpected . in expression")
        elseif self.stream.tryConsume("=") then
            assert(self.stream.tryConsume("="), "unexpected = in expression")
        elseif self.stream.tryConsume("~") then
            self.stream.tryConsume("=") -- ~ or ~=
        else
            break
        end
    end
end

function Transpiler:parseArgs()
    if self.stream.tryConsume("(") then
        self:parseShallow(")")
    elseif self.stream.tryConsume("{") then
        self:parseShallow("}")
    elseif self.stream.cur.type == "string" then
        self.stream.nextToken()
    else
        error("invalid function call syntax")
    end
end

function Transpiler:parseParenthesized(open, close)
    local nesting = 0
    while self.stream.cur.type ~= "eof" do
        local value = self.stream.cur.value
        self.stream.nextToken()
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

-- Tries to parse `<...>` at the given location.
function Transpiler:maybeParseTypeArgs()
    if self.stream.cur.value == "<" then
        self:parseParenthesized("<", ">")
    end
end

return {
    transpile = transpile,
}
