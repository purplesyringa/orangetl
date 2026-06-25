# orangetl

A just-in-time [Teal](https://teal-language.org/)-to-Lua transpiler.

`orangetl` does not perform any validation or type checking, so it's incredibly fast and can be used to directly `require` Teal code without a build step, similarly to how NodeJS can execute TypeScript.

## Compatibility

`orangetl` supports all Teal features, with a few exceptions arising from the single-pass design:

- Rust-style macros are not supported.
- `macroexp` methods are not supported (except `where`), and unscoped `macroexp`s are replaced with `function`s.

## Install

```shell
$ luarocks install orangetl
```

## Usage

Transpile a file via CLI:

```shell
$ orangetl gen script.tl -o script.lua
```

---

Run a Teal file:

```shell
$ orangetl run script.tl
```

---

Programmatically register a searcher for `.tl` files (reuses `package.path`, replacing `.lua` with `.tl`), so that `require` works on `.tl` files:

```lua
table.insert(package.searchers or package.loaders, 2, require "orangetl".searcher)
```

---

Transpile a file via API:

```lua
local orangetl = require "orangetl"
local lua_code = orangetl.transpile(teal_code[, opts])
```

The supported options are:

- `strip_attributes: boolean`: whether to drop `<const>` attributes. Useful for compatibility with Lua < 5.4, which doesn't support attributes. This doesn't drop attributes that affect runtime semantics, such as `<close>`.

- `lua_quirks: boolean`: if `true`, assumes that the input code follows Lua syntax rather than Teal syntax; the two disagree about newline handling in edge cases.

The transpiler may throw errors on syntactically invalid code.
