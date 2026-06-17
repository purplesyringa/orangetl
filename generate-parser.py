# Generates a recursive parser from an LL(1) grammar.

from abc import ABC
import annotationlib
from collections import defaultdict
from dataclasses import dataclass
from enum import StrEnum
import re

def indent(code: str) -> str:
    if not code:
        return ""
    return "    " + code.replace("\n", "\n    ").rstrip() + "\n"

class Parser(ABC):
    def lookahead_token_like(self) -> Optional[TokenLike]: ...
    def lookahead_condition(self) -> str: ...
    def parse(self) -> str: ...
    # Returns `cond, body` such that `if cond then body end` is equivalent to
    # `if lookahead_condition then parse end`, but possibly shorter.
    def try_parse(self) -> tuple[str, str]:
        return self.lookahead_condition(), self.parse()
    def __add__(self, rhs: ParserLike) -> Parser:
        return sequence(self, rhs)
    def __radd__(self, lhs: ParserLike) -> Parser:
        return sequence(lhs, self)
    def __or__(self, rhs: ParserLike) -> Parser:
        return either(self, rhs)
    def __ror__(self, lhs: ParserLike) -> Parser:
        return either(lhs, self)
    def separated(self, sep: ParserLike) -> Parser:
        return separated(sep, self)
    def terminated(self, term: ParserLike) -> Parser:
        return terminated(term, self)

class TokenType(Parser):
    def __init__(self, name: str, lookahead_condition: str, parse: str, try_parse: str):
        self.name = name
        self._lookahead_condition = lookahead_condition
        self._parse = parse
        self._try_parse = try_parse
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self
    def lookahead_condition(self) -> str:
        return self._lookahead_condition
    def parse(self) -> str:
        return self._parse
    def try_parse(self) -> tuple[str, str]:
        return self._try_parse, ""
    def __str__(self) -> str:
        return f"<{self.name}>"
alnum = TokenType("alnum", 'peekTokenType() == "alnum"', 'assert(tryParseTokenType("alnum"), "Expected <alnum>")\n', 'tryParseTokenType("alnum")')
string = TokenType("string", 'peekTokenType() == "string"', 'assert(tryParseTokenType("string"), "Expected <string>")\n', 'tryParseTokenType("string")')
eof = TokenType("eof", "isEof()", 'assert(isEof(), "Invalid syntax")\n', "isEof()")

TokenLike = str | TokenType
ParserLike = str | Parser

class literal(Parser):
    def __init__(self, token: str):
        self.token = token
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self.token
    def lookahead_condition(self) -> str:
        return f'peekToken() == "{self.token}"'
    def parse(self) -> str:
        return f'assert(tryParseToken("{self.token}"), "Expected {self.token}")\n'
    def try_parse(self) -> tuple[str, str]:
        return f'tryParseToken("{self.token}")', ""

def to_parser(parser_like: ParserLike) -> Parser:
    if isinstance(parser_like, Parser):
        return parser_like
    else:
        assert isinstance(parser_like, str)
        return sequence(*(literal(part) for part in re.split(r"([^a-zA-Z0-9_])", parser_like) if part)).or_single()

class peek(Parser):
    def __init__(self, token_like: TokenLike):
        self.parser = to_parser(token_like)
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self.parser.lookahead_token_like()
    def lookahead_condition(self) -> str:
        return self.parser.lookahead_condition()
    def parse(self) -> str:
        return f'assert({self.parser.lookahead_condition()}, "Invalid syntax")\n'
    def try_parse(self) -> tuple[str, str]:
        return self.parser.lookahead_condition(), ""

class parenthesized(Parser):
    def __init__(self, parens: str):
        self.l, self.r = parens
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self.l
    def lookahead_condition(self) -> str:
        return f'peekToken() == "{self.l}"'
    def parse(self) -> str:
        return f'parseParenthesized("{self.l}", "{self.r}")\n'

class sequence(Parser):
    def __init__(self, *patterns: ParserLike):
        self.patterns = list(map(to_parser, patterns))
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self.patterns[0].lookahead_token_like()
    def lookahead_condition(self) -> str:
        return self.patterns[0].lookahead_condition()
    def parse(self) -> str:
        code = ""
        for pattern in self.patterns:
            code += pattern.parse()
        return code
    def try_parse(self) -> tuple[str, str]:
        cond, body = self.patterns[0].try_parse()
        return cond, body + "".join(pattern.parse() for pattern in self.patterns[1:])
    def or_single(self) -> Parser:
        if len(self.patterns) == 1:
            return self.patterns[0]
        return self
    def __add__(self, rhs: ParserLike) -> Parser:
        return sequence(*self.patterns, rhs)

class repeat(Parser):
    def __init__(self, *patterns: ParserLike):
        self.pattern = sequence(*patterns).or_single()
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        raise ValueError("repeat cannot be subject of a lookahead")
    def parse(self) -> str:
        cond, body = self.pattern.try_parse()
        code = f'while {cond} do\n'
        code += indent(body)
        code += "end\n"
        return code

class terminated(Parser):
    def __init__(self, term: ParserLike, *patterns: ParserLike):
        self.term = to_parser(term)
        self.pattern = sequence(*patterns).or_single()
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        raise ValueError("terminated cannot be subject of a lookahead")
    def parse(self) -> str:
        cond, body = self.term.try_parse()
        code = f'while not ({cond}) do\n'
        code += indent(self.pattern.parse())
        code += "end\n"
        code += body
        return code

class separated(Parser):
    def __init__(self, sep: ParserLike, *patterns: ParserLike):
        self.sep = to_parser(sep)
        self.pattern = sequence(*patterns).or_single()
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return self.pattern.lookahead_token_like()
    def lookahead_condition(self) -> str:
        return self.pattern.lookahead_condition()
    def parse(self) -> str:
        cond, body = self.sep.try_parse()
        if not body:
            code = "repeat\n"
            code += indent(self.pattern.parse())
            code += f"until not ({cond})\n"
            return code
        code = "while true do\n"
        code += indent(self.pattern.parse())
        code += f"    if not ({cond}) then\n"
        code += "        break\n"
        code += "    end\n"
        code += indent(body)
        code += "end\n"
        return code

class empty(Parser):
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        raise ValueError("empty cannot be subject of a lookahead")
    def parse(self) -> str:
        return ""

class maybe(Parser):
    def __init__(self, *patterns: ParserLike):
        self.pattern = sequence(*patterns).or_single()
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        raise ValueError("maybe cannot be subject of a lookahead")
    def parse(self) -> str:
        if isinstance(self.pattern, either):
            return either(*self.pattern.arms, empty()).parse()
        cond, body = self.pattern.try_parse()
        if not body:
            return cond + "\n"
        code = f"if {cond} then\n"
        code += indent(body)
        code += "end\n"
        return code

class either(Parser):
    def __init__(self, *arms: ParserLike):
        self.arms = list(map(to_parser, arms))
        self.group_by_prefix = defaultdict(list)
        self.wildcard_arm = None
        for arm in self.arms:
            prefix = arm.lookahead_token_like()
            if prefix:
                assert not self.wildcard_arm, "wildcard arm must be last"
                self.group_by_prefix[prefix].append(arm)
            else:
                assert not self.wildcard_arm, "more than one wildcard arm is not allowed"
                self.wildcard_arm = arm
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        conditions = [
            to_parser(prefix).lookahead_condition()
            for prefix in self.group_by_prefix.keys()
        ]
        if self.wildcard_arm:
            conditions.append(self.wildcard_arm.lookahead_condition())
        return "(" + ") or (".join(conditions) + ")"
    def parse(self) -> str:
        def key(token_like: TokenLike) -> int:
            # Try to match exact tokens before token types.
            if isinstance(token_like, str):
                return 1
            else:
                return 2
        code = ""
        for prefix, group in sorted(self.group_by_prefix.items(), key = key):
            if len(group) == 1:
                cond, body = group[0].try_parse()
                code += f"if {cond} then\n"
                code += indent(body)
            else:
                code += f'if {to_parser(prefix).try_parse()[0]} then\n'
                stripped_arms = []
                for arm in group:
                    if isinstance(arm, (literal, TokenType)):
                        stripped_arms.append(empty())
                    elif isinstance(arm, sequence) and isinstance(arm.patterns[0], (literal, TokenType)):
                        stripped_arms.append(sequence(*arm.patterns[1:]))
                    else:
                        raise ValueError(f"multiple arms start with {prefix} and cannot be truncated")
                code += indent(either(*stripped_arms).parse())
            code += "else"
        code += "\n"
        if self.wildcard_arm:
            code += indent(self.wildcard_arm.parse())
        else:
            code += '    error("Invalid syntax")\n'
        code += "end\n"
        return code
    def try_parse(self) -> tuple[str, str]:
        conds = []
        for arm in self.arms:
            cond, body = arm.try_parse()
            if body:
                return super().try_parse()
            conds.append(cond)
        return "(" + ") or (".join(conds) + ")", ""
    def __or__(self, rhs: ParserLike) -> Parser:
        return either(*self.arms, rhs)

class custom(Parser):
    def __init__(self, code: str):
        self.code = code
    def lookahead_token_like(self) -> Optional[TokenLike]:
        return None
    def lookahead_condition(self) -> str:
        raise ValueError("custom parser cannot be subject of a lookahead")
    def parse(self) -> str:
        return self.code + "\n"

referenced_parsers = set()

class ref(Parser):
    def __init__(self, name: str, actual: Optional[Parser] = None):
        self.name = name
        self.actual = actual
        referenced_parsers.add(name)
    def lookahead_token_like(self) -> Optional[TokenLike]:
        if not self.actual:
            return None
        return self.actual.lookahead_token_like()
    def lookahead_condition(self) -> str:
        if not self.actual:
            raise ValueError('backref cannot be subject of lookahead')
        return self.actual.lookahead_condition()
    def parse(self) -> str:
        return f"parsers.{self.name}()\n"

# Adjusted from https://teal-language.org/book/latest/grammar.html.
class grammar:
    # Type usage.
    type = custom("parseType()")
    retlist = custom("parseRetlist()")
    exp = custom("parseExp()")

    # parlist = "(" + (":" + type | "?" | custom("skipToken()")).terminated(")")
    funcbody = maybe(parenthesized("<>")) + parenthesized("()") + maybe(":", retlist) + custom("parseUntilEnd()")

    field = maybe("[" + ref("exp") + "]" + "=" | alnum + maybe(":", type) + "=") + ref("exp")

    local_global_stat = (
        "function" + alnum + ref("funcbody")
        | alnum.separated(",") + maybe(":", type.separated(",")) + maybe("=", ref("exp").separated(","))
    )
    stat = (
        "function" + alnum + repeat(".", alnum) + maybe(":", alnum) + ref("funcbody")
    )

def generate_code():
    # referenced_parsers.add("block")
    code = ""
    for name in sorted(referenced_parsers):
        code += f"function parsers.{name}()\n"
        code += indent(getattr(grammar, name).parse())
        code += "end\n\n"
    code = code.rstrip() + "\n"
    return code

print(generate_code())
