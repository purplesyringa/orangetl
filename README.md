# Orange

A just-in-time [Teal](https://teal-language.org/)-to-Lua transpiler.

Orange does not perform any validation or type checking, so it's incredibly fast and can be used to directly `require` Teal code without a build step, similarly to how NodeJS can execute TypeScript.

## Compatibility

Orange supports all Teal features, with a few exceptions arising from the single-pass design:

- Rust-style macros are not supported.
- `macroexp` methods are not supported (except `where`), and unscoped `macroexp`s are replaced with `function`s.

## Install

```shell
$ luarocks install orange
```

## Usage

Transpile a file via CLI:

```shell
$ orange script.tl -o script.lua
```

Transpile a file via API:

```lua
local orange = require "orange"
local lua_code = orange.transpile(teal_code[, opts])
```

The supported options are:

- `strip_attributes: boolean`: whether to drop `<const>` attributes. Useful for compatibility with Lua < 5.4, which doesn't support attributes. This doesn't drop attributes that affect runtime semantics, such as `<close>`.

- `lua_quirks: boolean`: if `true`, assumes that the input code follows Lua syntax rather than Teal syntax; the two disagree about newline handling in edge cases.

The transpiler may throw errors on syntactically invalid code.
