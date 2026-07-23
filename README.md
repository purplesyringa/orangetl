# orangetl

A just-in-time [Teal](https://teal-language.org/)-to-Lua transpiler.

`orangetl` does not perform any validation or type checking, so it's incredibly fast and can be used to directly `require` Teal code without a build step, similarly to how NodeJS can execute TypeScript.

## Compatibility

`orangetl` supports all Teal features, with a few exceptions arising from the single-pass design:

- Rust-style macros are not supported.
- `macroexp` methods are not supported (except `where`), and unscoped `macroexp`s are replaced with `function`s.
- New operators like `&`, `|`, `~`, and `//` are not backported to Lua < 5.3.
- Some compatibility features have a performance impact and thus have to be enabled manually:
  - `--rewrite-for-reassignments`: allow assignments to `for` control variables (Teal and Lua < 5.3 semantics, workaround for Lua >= 5.4).

`orangetl` is not a replacement for `tl`, since it doesn't perform any validation, so it's unsuitable for development. In addition, the transpiler may throw errors on syntactically invalid code.

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

- `replace_named_varargs: boolean`: whether to replace `...<name>` varargs with `...` and a manual `table.pack` call. Useful for compatibility with Lua < 5.5, but has a performance impact when sued.

- `rewrite_for_reassignments: boolean`: add `local <name> = <name>` to the beginning of all `for` loops to prevent the `attempt to assign to const variable '<name>'` error added in Lua >= 5.4. Teal enables this rewrite by default, but in `orangetl` it has performance implications for all `for` loops, not just those with reassignments, so it's off by default in `orangetl`.

- `rewrite_string_escapes: boolean`: rewrite `\z`, `\x`, and `\u` escapes in strings with escapes supported by Lua < 5.3.

- `lua_quirks: boolean`: if `true`, assumes that the input code follows Lua syntax rather than Teal syntax; the two disagree about newline handling in edge cases.

The transpiler may throw errors on syntactically invalid code.
