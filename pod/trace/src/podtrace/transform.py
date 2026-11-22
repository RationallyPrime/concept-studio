"""AST rewriting: one tracing decorator on every ``def`` and one on every class.

The decorators are the only change. Line numbers of the original file are kept so tracebacks,
``inspect`` and the ``line`` field of the records point at real lines.
"""

from __future__ import annotations

import ast
import hashlib

from .config import Rule
from .registry import TABLES, FileTable, SiteInfo

PROLOGUE_NAME = "__podtrace_s__"
RT_NAME = "__podtrace_rt__"

# Dunder methods that are traced; every other dunder is skipped (the recorder itself relies on
# several of them, and hooks such as ``__getattr__`` would recurse).
TRACED_DUNDERS = frozenset({"__init__", "__post_init__", "__call__", "__enter__", "__exit__"})


def _is_dunder(name: str) -> bool:
    return len(name) > 4 and name.startswith("__") and name.endswith("__")


def _decorator_names(node: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    names: set[str] = set()
    for dec in node.decorator_list:
        target = dec.func if isinstance(dec, ast.Call) else dec
        if isinstance(target, ast.Name):
            names.add(target.id)
        elif isinstance(target, ast.Attribute):
            names.add(target.attr)
    return names


class _YieldFinder(ast.NodeVisitor):
    """Does this function body contain a ``yield`` of its own (not of a nested scope)?"""

    def __init__(self) -> None:
        self.found = False

    def visit_Yield(self, node: ast.Yield) -> None:
        self.found = True

    def visit_YieldFrom(self, node: ast.YieldFrom) -> None:
        self.found = True

    def visit_FunctionDef(self, node: ast.AST) -> None:
        return

    visit_AsyncFunctionDef = visit_FunctionDef
    visit_ClassDef = visit_FunctionDef
    visit_Lambda = visit_FunctionDef


def _has_yield(node: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    finder = _YieldFinder()
    for stmt in node.body:
        finder.visit(stmt)
        if finder.found:
            return True
    return False


class _Transformer(ast.NodeTransformer):
    def __init__(self, rule: Rule, table: FileTable) -> None:
        self.rule = rule
        self.table = table
        self.scope: list[tuple[str, str]] = []  # ("class" | "func", name)

    def _qual(self, name: str) -> str:
        parts: list[str] = []
        for kind, ident in self.scope:
            parts.append(ident)
            if kind == "func":
                parts.append("<locals>")
        parts.append(name)
        return ".".join(parts)

    def _site(self, shape: str, qual: str, lineno: int, **flags: bool) -> int:
        idx = len(self.table.sites)
        self.table.sites.append(SiteInfo(idx, shape, qual, lineno, **flags))
        return idx

    @staticmethod
    def _deco(method: str, idx: int, ref: ast.AST) -> ast.expr:
        call = ast.Call(
            func=ast.Attribute(
                value=ast.Name(id=PROLOGUE_NAME, ctx=ast.Load()), attr=method, ctx=ast.Load()
            ),
            args=[ast.Constant(value=idx)],
            keywords=[],
        )
        ast.copy_location(call, ref)
        for child in ast.walk(call):
            ast.copy_location(child, ref)
        return call

    def _function(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> ast.AST:
        qual = self._qual(node.name)
        self.scope.append(("func", node.name))
        self.generic_visit(node)
        self.scope.pop()
        if _is_dunder(node.name) and node.name not in TRACED_DUNDERS:
            return node
        if not self.rule.wants(qual):
            return node
        is_async = isinstance(node, ast.AsyncFunctionDef)
        gen = _has_yield(node)
        shape = ("a" if gen else "c") if is_async else ("g" if gen else "f")
        in_class = bool(self.scope) and self.scope[-1][0] == "class"
        decs = _decorator_names(node)
        is_method = in_class and "staticmethod" not in decs and "classmethod" not in decs
        idx = self._site(
            shape,
            qual,
            node.lineno,
            is_method=is_method,
            is_init=is_method and node.name == "__init__",
        )
        # Innermost decorator: the last one in the list is applied first.
        ref = node.decorator_list[-1] if node.decorator_list else node
        node.decorator_list.append(self._deco("d", idx, ref))
        return node

    def visit_FunctionDef(self, node: ast.FunctionDef) -> ast.AST:
        return self._function(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> ast.AST:
        return self._function(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> ast.AST:
        qual = self._qual(node.name)
        self.scope.append(("class", node.name))
        self.generic_visit(node)
        self.scope.pop()
        if not self.rule.wants(qual):
            return node
        idx = self._site("C", qual, node.lineno)
        # Outermost decorator, so that it sees what ``dataclass`` and friends generated. It takes
        # the line of the first existing decorator to keep the class's first line unchanged.
        ref = node.decorator_list[0] if node.decorator_list else node
        node.decorator_list.insert(0, self._deco("c", idx, ref))
        return node


def _prologue(path: str, anchor: ast.AST) -> list[ast.stmt]:
    src = (
        f"from podtrace import runtime as {RT_NAME}\n"
        f"{PROLOGUE_NAME} = {RT_NAME}.register({path!r}, __name__)\n"
    )
    stmts = ast.parse(src).body
    for stmt in stmts:
        for child in ast.walk(stmt):
            ast.copy_location(child, anchor)
    return stmts


def transform(source: bytes | str, path: str, rule: Rule) -> tuple[ast.Module, FileTable]:
    """Parse ``source`` and add the decorators; the table is registered under ``path``."""
    raw = source if isinstance(source, bytes) else source.encode("utf-8")
    tree = ast.parse(raw, filename=path)
    table = FileTable(path=path, sha256=hashlib.sha256(raw).hexdigest(), rule=rule)
    _Transformer(rule, table).visit(tree)
    body = tree.body
    at = 0
    if body and isinstance(body[0], ast.Expr):
        value = body[0].value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            at = 1
    while at < len(body):
        stmt = body[at]
        if isinstance(stmt, ast.ImportFrom) and stmt.module == "__future__":
            at += 1
        else:
            break
    anchor = body[at] if at < len(body) else (body[-1] if body else tree)
    if not hasattr(anchor, "lineno"):
        anchor = ast.Pass(lineno=1, col_offset=0, end_lineno=1, end_col_offset=0)
    tree.body[at:at] = _prologue(path, anchor)
    ast.fix_missing_locations(tree)
    TABLES[path] = table
    return tree, table
