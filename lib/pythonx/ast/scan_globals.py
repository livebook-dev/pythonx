import ast


class GlobalsVisitor(ast.NodeVisitor):
  def __init__(self):
    # References to undefined globals.
    self.refs = set()
    # Scope information, including definitions.
    self.scopes = []
    # Add the global scope to the stack.
    self._push_scope()

  def _push_scope(self, is_comprehension=False):
    self.scopes.append({"defs": set(), "is_comprehension": is_comprehension})

  def _pop_scope(self):
    self.scopes.pop()

  def _handle_ref(self, name):
    is_defined = any(name in scope["defs"] for scope in self.scopes)

    if not is_defined:
      self.refs.add(name)

  def visit_Name(self, node):
    if isinstance(node.ctx, ast.Store):
      self.scopes[-1]["defs"].add(node.id)
    elif isinstance(node.ctx, ast.Load):
      self._handle_ref(node.id)

  def visit_FunctionDef(self, node):
    self._visit_function_def(node)

  def visit_AsyncFunctionDef(self, node):
    self._visit_function_def(node)

  def _visit_function_def(self, node):
    self.scopes[-1]["defs"].add(node.name)
    self._push_scope()
    self.generic_visit(node)
    self._pop_scope()

  def visit_arguments(self, node):
    # Scan defaults for refs before adding defs from args.

    for default in node.defaults:
      self.visit(default)

    for default in node.kw_defaults:
      if default is not None:
        self.visit(default)

    for arg in node.posonlyargs:
      self.visit(arg)

    for arg in node.args:
      self.visit(arg)

    if node.vararg is not None:
      self.visit(node.vararg)

    for arg in node.kwonlyargs:
      self.visit(arg)

    if node.kwarg is not None:
      self.visit(node.kwarg)

  def visit_arg(self, node):
    self.scopes[-1]["defs"].add(node.arg)

  def visit_ClassDef(self, node):
    self.scopes[-1]["defs"].add(node.name)
    self._push_scope()
    self.generic_visit(node)
    self._pop_scope()

  def visit_Lambda(self, node):
    self._push_scope()
    self.generic_visit(node)
    self._pop_scope()

  def visit_ListComp(self, node):
    self._visit_comprehension_expr(node)

  def visit_SetComp(self, node):
    self._visit_comprehension_expr(node)

  def visit_GeneratorExp(self, node):
    self._visit_comprehension_expr(node)

  def _visit_comprehension_expr(self, node):
    self._push_scope(is_comprehension=True)

    # Scan the generator for defs first.
    for generator in node.generators:
      self.visit(generator)

    self.visit(node.elt)
    self._pop_scope()

  def visit_DictComp(self, node):
    self._push_scope(is_comprehension=True)

    # Scan the generator for defs first.
    for generator in node.generators:
      self.visit(generator)

    self.visit(node.key)
    self.visit(node.value)
    self._pop_scope()

  def visit_comprehension(self, node):
    # Scan iter for refs before adding defs from target.
    self.visit(node.iter)
    self.visit(node.target)

    for if_node in node.ifs:
      self.visit(if_node)

  def visit_Import(self, node):
    for alias in node.names:
      name = alias.asname or alias.name.split(".")[0]
      self.scopes[-1]["defs"].add(name)

  def visit_ImportFrom(self, node):
    for alias in node.names:
      name = alias.asname or alias.name
      self.scopes[-1]["defs"].add(name)

  def visit_Assign(self, node):
    # Scan the right side for refs before adding defs from the left side.
    self.visit(node.value)

    for target in node.targets:
      self.visit(target)

  def visit_AugAssign(self, node):
    # Scan the right side for refs before adding defs from the left side.
    self.visit(node.value)

    # Name on the left is also referenced.
    if isinstance(node.target, ast.Name):
      self._handle_ref(node.target.id)

    self.visit(node.target)

  def visit_NamedExpr(self, node):
    # Scan the right side for refs before adding defs from the left side.
    self.visit(node.value)

    # Walrus operator leaks out of comprehensions into the outer scope.
    if self.scopes[-1]["is_comprehension"] and isinstance(node.target, ast.Name):
      outer_scope = next(
        scope for scope in reversed(self.scopes) if not scope["is_comprehension"]
      )
      outer_scope["defs"].add(node.target.id)
    else:
      self.visit(node.target)

  def visit_AnnAssign(self, node):
    # Scan the right side for refs before adding defs from the left side.
    if node.value is not None:
      self.visit(node.value)

    self.visit(node.target)

  def visit_MatchAs(self, node):
    if node.name is not None:
      self.scopes[-1]["defs"].add(node.name)

    if node.pattern is not None:
      self.visit(node.pattern)

  def visit_MatchStar(self, node):
    if node.name is not None:
      self.scopes[-1]["defs"].add(node.name)

  def visit_MatchMapping(self, node):
    for key in node.keys:
      self.visit(key)

    for pattern in node.patterns:
      self.visit(pattern)

    if node.rest is not None:
      self.scopes[-1]["defs"].add(node.rest)


tree = ast.parse(code)
visitor = GlobalsVisitor()
visitor.visit(tree)

builtin_names = globals()["__builtins__"].keys()

(visitor.refs - builtin_names, visitor.scopes[0]["defs"])
