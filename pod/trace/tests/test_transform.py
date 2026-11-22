import ast
import sys
import textwrap

import pytest

from podtrace import config, transform


def rule(**kw):
    return config.Rule(path="**/x.py", **kw)


def tr(src, **kw):
    tree, table = transform.transform(textwrap.dedent(src), "/virtual/x.py", rule(**kw))
    return tree, table


def decorators(tree, name):
    for node in ast.walk(tree):
        if (
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
            and node.name == name
        ):
            return [ast.unparse(d) for d in node.decorator_list]
    raise KeyError(name)


def test_function_decorator_is_innermost_and_class_decorator_outermost():
    tree, table = tr(
        """
        import functools
        @functools.cache
        @staticmethod
        def f(): pass
        @dataclass
        class C:
            @property
            def p(self): return 1
        """
    )
    assert decorators(tree, "f") == ["functools.cache", "staticmethod", "__podtrace_s__.d(0)"]
    assert decorators(tree, "C")[0].startswith("__podtrace_s__.c(")
    assert decorators(tree, "C")[-1] == "dataclass"
    assert decorators(tree, "p")[-1].startswith("__podtrace_s__.d(")
    assert [s.qualname for s in table.sites] == ["f", "C.p", "C"]


def test_qualified_names_and_shapes():
    _, table = tr(
        """
        def outer():
            def inner():
                yield 1
            class K:
                def m(self): pass
            return inner
        async def co(): await x
        async def ag():
            yield 1
        def not_gen():
            def g():
                yield 1
            return 2
        """
    )
    got = {s.qualname: s.shape for s in table.sites}
    assert got == {
        "outer": "f",
        "outer.<locals>.inner": "g",
        "outer.<locals>.K.m": "f",
        "outer.<locals>.K": "C",
        "co": "c",
        "ag": "a",
        "not_gen": "f",
        "not_gen.<locals>.g": "g",
    }


def test_lambdas_and_most_dunders_are_skipped():
    _, table = tr(
        """
        f = lambda x: x
        class C:
            def __init__(self): pass
            def __post_init__(self): pass
            def __call__(self): pass
            def __enter__(self): pass
            def __exit__(self, *a): pass
            def __getattr__(self, n): pass
            def __repr__(self): return ''
            def __len__(self): return 0
            def __new__(cls): pass
            def _private(self): pass
        """
    )
    names = {s.qualname for s in table.sites}
    assert names == {
        "C",
        "C.__init__",
        "C.__post_init__",
        "C.__call__",
        "C.__enter__",
        "C.__exit__",
        "C._private",
    }
    assert {s.qualname for s in table.sites if s.is_init} == {"C.__init__"}


def test_method_flags():
    _, table = tr(
        """
        class C:
            def m(self): pass
            @staticmethod
            def s(): pass
            @classmethod
            def c(cls): pass
            def outer(self):
                def inner(): pass
        """
    )
    flags = {s.qualname: s.is_method for s in table.sites if s.shape != "C"}
    assert flags == {
        "C.m": True,
        "C.s": False,
        "C.c": False,
        "C.outer": True,
        "C.outer.<locals>.inner": False,
    }


def test_include_and_exclude_patterns():
    _, table = tr(
        """
        class BaseModel:
            def a(self): pass
        class Other:
            def b(self): pass
        def sample_euler(): 
            def step(): pass
        def helper(): pass
        """,
        names=("BaseModel", "BaseModel.*", "sample_*"),
        exclude=("*.step",),
    )
    assert {s.qualname for s in table.sites} == {"BaseModel", "BaseModel.a", "sample_euler"}


def test_prologue_goes_after_docstring_and_future_imports_and_lines_are_kept():
    src = '"""doc"""\nfrom __future__ import annotations\nimport os\n\n\ndef f():\n    raise RuntimeError("x")\n'
    tree, _ = tr(src)
    kinds = [type(n).__name__ for n in tree.body[:4]]
    assert kinds == ["Expr", "ImportFrom", "ImportFrom", "Assign"]
    code = compile(tree, "/virtual/x.py", "exec")
    ns = {"__name__": "m"}
    # The runtime is not configured, so decorators are identity: only the line numbers matter.
    exec(code, ns)
    with pytest.raises(RuntimeError) as info:
        ns["f"]()
    assert info.traceback[-1].lineno == 6  # 0-based line of the raise


def test_syntax_error_propagates():
    with pytest.raises(SyntaxError):
        tr("def (:\n")


@pytest.mark.parametrize(
    "mod",
    ["json.decoder", "enum", "dataclasses", "typing", "asyncio.tasks", "argparse", "unittest.mock"],
)
def test_stdlib_modules_transform_and_compile(mod):
    __import__(mod)
    path = sys.modules[mod].__file__
    with open(path, "rb") as fh:
        tree, table = transform.transform(fh.read(), path, config.Rule(path="**/*.py"))
    compile(tree, path, "exec")
    assert table.sites
