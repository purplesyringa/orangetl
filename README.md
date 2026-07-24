# orangetl

A just-in-time [Teal](https://teal-language.org/)-to-Lua transpiler.

`orangetl` does not perform any validation or type checking, so it's incredibly fast and can be used to directly `require` Teal code without a build step, similarly to how NodeJS can execute TypeScript.

## Compatibility

`orangetl` is not a full replacement for `tl`. While `orangetl` supports most language-level Teal features, there are a couple exceptions for the trickier details, arising from the single-pass design:

- Rust-style macros are not supported.
- `macroexp` methods are not supported (except `where`), and unscoped `macroexp`s are replaced with `function`s.
- Some aspects of the type system are implemented in runtime:
  - The `is` operator requires `where` definitions to be compiled to an `__is` method, so type-only files still need to be transpiled.
  - `.d.tl` files are not supported with JIT transpilation, since "two files per module" doesn't mesh well with how `require` works. Ahead-of-time transpilation supports `.d.tl`, but not for external modules, for similar reasons.
- Some compatibility features don't work as well:
  - Assignments to `for` control variables don't work by default on Lua >= 5.4 and have to be enabled with `--rewrite-for-reassignments`. This may slightly slow down all `for` loops, so it's off by default.
  - New operators like `&`, `|`, `~`, and `//` are not backported to Lua < 5.3, since parsing them is slow.
- `orangetl` doesn't perform any validation, so it's unsuitable for development. In addition, the transpiler may throw errors on syntactically invalid code.

## Install

```shell
$ luarocks install orangetl
```

## Usage

### CLI

```shell
# Run a Teal file, converting it on the fly.
orangetl run script.tl

# Transpile a Teal file.
orangetl gen src/script.tl -o build/script.lua

# Transpile a Lua file with Teal annotations (annotated .lua files have subtly different semantics
# from .tl files, mirrors tl behavior).
orangetl gen src/script.lua -o build/script.lua

# Merge a .d.tl file with a Lua module. The generated script contains both the Lua code and runtime
# representations of the types.
orangetl gen-dtl src/script.d.tl src/script.lua -o build/script.lua

# Transpile a .d.tl file without an associated Lua module (e.g. used exclusively in `type = ...`).
orangetl gen src/script.d.tl -o build/script.lua
```

### Programmatic

Install a searcher so that `require` works on Teal files, reusing `package.path`:

```lua
table.insert(package.searchers or package.loaders, 2, require("orangetl").searcher)
```

Transpile a Teal or annotated Lua file, or a pure `.d.tl` file:

```lua
local generated_code = require("orangetl").transpile(source_code[, opts])
```

Transpile a `.d.tl` file, embedding the corresponding Lua source:

```lua
local generated_code = require("orangetl").transpileDef(dtl_source_code, lua_source_code)
```

The supported options are:

- `keep_hashbang: boolean`: don't delete the `#!` line, if present.

- `strip_attributes: boolean`: whether to drop `<const>` attributes. Useful for compatibility with Lua < 5.4, which doesn't support attributes. This doesn't drop attributes that affect runtime semantics, such as `<close>`.

- `replace_named_varargs: string`: replace `...<name>` varargs with `...` and a manual assignment to `<name>`. Useful for compatibility with Lua < 5.5, but has a performance impact when used. The following values are supported:
  - `nil` (absent): don't replace.
  - `"5.2"`: implement via `table.pack` (works for Lua >= 5.2).
  - `"5.1"`: choose between `table.pack` and `select` in runtime (universal).

- `rewrite_for_reassignments: boolean`: add `local <name> = <name>` to the beginning of all `for` loops to prevent the `attempt to assign to const variable '<name>'` error added in Lua >= 5.4. Teal enables this rewrite by default, but in `orangetl` it has performance implications for all `for` loops, not just those with reassignments, so it's off by default in `orangetl`.

- `rewrite_string_escapes: boolean`: rewrite `\z`, `\x`, and `\u` escapes in strings with escapes supported by Lua < 5.3.

- `localize_implicit_globals: boolean`: prepend `local <name> = <name>` definitions for globals accessed by the generated code. Useful for code that uses `local _ENV = nil` to protect against implicit global access.

- `lua_quirks: boolean`: if `true`, assumes that the input code follows Lua syntax rather than Teal syntax; the two disagree about newline handling in edge cases.

The transpiler may throw errors on syntactically invalid code.
