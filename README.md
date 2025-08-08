# Pythonx

[![Docs](https://img.shields.io/badge/hex.pm-docs-8e7ce6.svg)](https://hexdocs.pm/pythonx)
[![Actions Status](https://github.com/livebook-dev/pythonx/workflows/Test/badge.svg)](https://github.com/livebook-dev/pythonx/actions)

<!-- Docs -->

Python interpreter embedded in Elixir.

Pythonx runs a Python interpreter in the same OS process as your Elixir
application, allowing you to evaluate Python code and conveniently
convert between Python and Elixir data structures.

The goal of this project is to better integrate Python workflows within
Livebook and its usage in actual projects must be done with care due to
Python's global interpreter lock (GIL), which prevents multiple threads from
executing Python code at the same time. Consequently, calling `Pythonx`
from multiple Elixir processes does not provide the concurrency you might
expect and thus it can be a source of bottlenecks. However, this concerns
regular Python code. Packages with CPU-intense functionality, such as `numpy`,
have native implementation of many functions and invoking those releases the
GIL. GIL is also released when waiting on I/O operations. In other words,
if you are using this library to integrate with Python, make sure it happens
in a single Elixir process or that its underlying libraries can deal with
concurrent invocation. Otherwise, prefer to use Elixir's `System.cmd/3` or
`Port`s to manage multiple Python programs via I/O.

## Usage (script)

Add Pythonx to your dependencies:

```elixir
Mix.install([
  {:pythonx, "~> 0.4.0"}
])
```

Initialize the interpreter, specifying the desired Python version
and dependencies:

```elixir
Pythonx.uv_init("""
[project]
name = "project"
version = "0.0.0"
requires-python = "==3.13.*"
dependencies = [
  "numpy==2.2.2"
]
""")
```

Evaluate Python code:

```elixir
{result, globals} =
  Pythonx.eval(
    """
    y = 10
    x + y
    """,
    %{"x" => 1}
  )

Pythonx.decode(result)
#=> 11

globals
#=> %{
#=>   "x" => #Pythonx.Object<
#=>     1
#=>   >,
#=>   "y" => #Pythonx.Object<
#=>     10
#=>   >
#=> }
```

In a dynamic evaluation environment, such as IEx and Livebook, you
can also use the `~PY` sigil:

```elixir
import Pythonx

x = 1

~PY"""
y = 10
result = x + y
"""

result
#=> #Pythonx.Object<
#=>   11
#=> >

y
#=> #Pythonx.Object<
#=>   10
#=> >
```

## Usage (application)

Add Pythonx to your dependencies:

```elixir
def deps do
  [
    {:pythonx, "~> 0.4.0"}
  ]
end
```

Configure the desired Python version and dependencies in your
`config/config.exs`:

```elixir
import Config

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "project"
  version = "0.0.0"
  requires-python = "==3.13.*"
  dependencies = [
    "numpy==2.2.2"
  ]
  """
```

Additionally, you can configure a specific version of the uv package manager for Pythonx to use. This can impact the available Python versions.

```elixir
import Config

config :pythonx, :uv_init,
  ...,
  uv_version: "0.7.21"
```

With that, you can use `Pythonx.eval/2` and other APIs in your
application. The downloads will happen at compile time, and the
interpreter will get initialized automatically on boot. All necessary
files are placed in Pythonx priv directory, so it is compatible with
Elixir releases.

Note that currently the `~PY` sigil does not work as part of Mix project
code. This limitation is intentional, since in actual applications it
is preferable to manage the Python globals explicitly.

## How it works

[CPython](https://github.com/python/cpython) (the reference
implementation of the Python programming language) provides a `python`
executable that runs Python code, and that is the usual interface
that developers use to interact with the interpreter. However, most
the CPython functionality is also available as a dynamically linked
library (`.so`, `.dylib` or `.dll`, depending on the platform). The
`python` executable can be thought of as a program build on top of
that library.

With this design, any C/C++ application can link the Python library
and use its API to execute Python code and interact with Python objects
on a low level. Taking this a step further, any language with C/C++
interoperability can interact with Python in the same manner. This
usage of CPython is referred to as embedding Python.

Elixir provides C/C++ interoperability via Erlang NIFs and that is
exactly how Pythonx embeds Python. As a result, the Python interpreter
operates in the same OS process as the BEAM.

For more details refer to the official documentation on
[embedding Python](https://docs.python.org/3/extending/embedding.html).

<!-- Docs -->

## Acknowledgement

Thank you to Cocoa Xu (@cocoa-xu) for building the first prototype of
embedded Python ([source](https://github.com/elixir-pythonx/pythonx)).

## License

    Copyright (c) 2025 Dashbit

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
