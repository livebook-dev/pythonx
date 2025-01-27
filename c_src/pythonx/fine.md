# Fine

Fine is a C++ library streamlining Erlang NIFs implementation, focused
on Elixir.

Erlang provides C API for implementing native functions
([`erl_nif`](https://www.erlang.org/doc/apps/erts/erl_nif.html)).
Fine is not a replacement of the C API, instead it is designed as a
complementary API, enhancing the developer experience when implementing
NIFs in C++.

## Features

- Automatic encoding/decoding of NIF arguments and return value,
  inferred from function signatures.

- Smart pointer enabling safe management of resource objects.

- Registering NIFs and resource types via simple annotations. Creating
  all static atoms at load time.

- Support for encoding/decoding Elixir structs based on compile time
  metadata.

- Propagating C++ exceptions as Elixir exceptions, with support for
  raising custom Elixir exceptions.

## Motivation

Some projects make extensive use of NIFs, where using the C API results
in a lot of boilerplate code and a set of ad-hoc helper functions that
get copied from project to project. The main idea behind Fine is to
reduce the friction of getting from Elixir to C++ and vice versa, so
that developers can focus on writing the actual native code.

## Requirements

Currently Fine requires C++17. The supported compilers include GCC,
Clang and MSVC.

## Usage

A minimal NIF adding two numbers can be implemented like so:

```cpp
#include <fine.hpp>

int64_t add(ErlNifEnv *env, int64_t x, int64_t y) {
  return x + y;
}

FINE_NIF(add, 0);

FINE_INIT("Elixir.MyLib.NIF");
```

### Encoding/Decoding

Terms are automatically encoded and decoded at the NIF boundary based
on the function signature. In some cases, you may also want to invoke
encode/decode directly:

```cpp
// Encode
auto message = std::string("hello world");
auto term = fine::encode(env, message);

// Decode
auto message = fine::decode<std::string>(env, term);
```

You can extend encoding/decoding to work on custom types by defining
the following specializations:

```cpp
// Note that the specialization must be defined in the `fine` namespace.
namespace fine {
  template <> struct Decoder<MyType> {
    static MyType decode(ErlNifEnv *env, const ERL_NIF_TERM &term) {
      // ...
    }
  };

  template <> struct Encoder<MyType> {
    static ERL_NIF_TERM encode(ErlNifEnv *env, const MyType &value) {
      // ...
    }
  };
}
```

> #### ERL_NIF_TERM {: .warning}
>
> In some cases, you may want to define a NIF that accepts or returns
> a term and effectively skip the encoding/decoding. However, the NIF
> C API defines `ERL_NIF_TERM` as an alias for an integer type, which
> may introduce an ambiguity for encoding/decoding. For this reason
> Fine provides a wrapper type `fine::Term` and it should be used in
> the NIF signature in those cases. `fine::Term` defines implicit
> conversion to and from `ERL_NIF_TERM`, so it can be used with all
> `enif_*` functions with no changes.

### Resource objects

Resource objects is a mechanism for passing pointers to C++ data
structures to and from NIFs, and around your Elixir code. On the Elixir
side those pointer surface as reference terms (`#Reference<...>`).

Fine provides a construction function `fine::make_resource<T>(...)`,
similar to `std::make_unique` and `std::make_shared` available in the
C++ standard library. This function creates a new object of the type
`T`, invoking its constructor with the given arguments and it returns
a smart pointer of type `fine::ResourcePtr<T>`. The pointer is
automatically decoded and encoded as a reference term. It can also be
passed around C++ code, automatically managing the reference count.

You need to indicate that a given class can be used as a resource type
via the `FINE_RESOURCE` macro.;

```cpp
#include <fine.hpp>

class Generator {
public:
  Generator(uint64_t seed) { /* ... */ }
  int64_t random_integer() { /* ... */ }
  // ...
};

FINE_RESOURCE(Generator);

fine::ResourcePtr<Generator> create_generator(ErlNifEnv *env, uint64_t seed) {
  return fine::make_resource<Generator>(seed);
}

FINE_NIF(create_generator, 0);

int64_t random_integer(ErlNifEnv *env, fine::ResourcePtr<Generator> generator) {
  return generator->random_integer();
}

FINE_NIF(random_integer, 0);

FINE_INIT("Elixir.MyLib.NIF");
```

Once neither Elixir nor C++ holds a reference to the resource object,
it gets destroyed. By default only the `T` type destructor is called.
However, in some cases you may want to interact with NIF APIs as part
of the destructor. In that case, you can implement a `destructor`
callback on `T`, which receives the relevant `ErlNifEnv`:

```cpp
class Generator {
  // ...

  void destructor(ErlNifEnv *env) {
    // Example: send a message to some process using env
  }
};
```

If defined, the `destructor` callback is called first, and then the
`T` destructor is called as usual.

Oftentimes NIFs deal with classes from third-party packages, in which
case, you may not control how the objects are created and you cannot
add callbacks such as `destructor` to the implementation. If you run
into any of these limitations, you can define your own wrapper class,
holding an object of the third-party class and implementing the desired
construction/destruction on top.

### Structs

Elixir structs can be passed to and from NIFs. To do that, you need to
define a corresponding C++ class that includes metadata fields used
for automatic encoding and decoding. The metadata consists of:

- `module` - the Elixir struct name as an atom reference

- `fields` - a mapping between Elixir struct and C++ class fields

- `is_exception` (optional) - when defined as true, indicates the
  Elixir struct is an exception

For example, given an Elixir struct `%MyLib.Point{x: integer, y: integer}`,
you could operate on it in the NIF, like this:

```cpp
#include <fine.hpp>

namespace atoms {
  auto ElixirMyLibPoint = fine::Atom("Elixir.MyLib.Point");
  auto x = fine::Atom("x");
  auto y = fine::Atom("y");
}

struct ExPoint {
  int64_t x;
  int64_t y;

  static constexpr auto module = &atoms::ElixirMyLibPoint;

  static constexpr auto fields() {
    return std::make_tuple(std::make_tuple(&atoms::x, &ExPoint::x),
                           std::make_tuple(&atoms::y, &ExPoint::y));
  }
};

ExPoint point_reflection(ErlNifEnv *env, ExPoint point) {
  return ExPoint{-point.x, -point.y};
}

FINE_NIF(point_reflection, 0);

FINE_INIT("Elixir.MyLib.NIF");
```

Structs can be particularly convenient when using NIF resource objects.
When working with resources, it is common to have an Elixir struct
corresponding to the resource. In the previous `Generator` example,
you may define an Elixir struct such as `%MyLib.Generator{resource: reference}`.
Instead of passing and returning the reference from the NIF, you can
pass and return the struct itself:

```cpp
#include <fine.hpp>

class Generator {
public:
  Generator(uint64_t seed) { /* ... */ }
  int64_t random_integer() { /* ... */ }
  // ...
};

namespace atoms {
  auto ElixirMyLibGenerator = fine::Atom("Elixir.MyLib.Generator");
  auto resource = fine::Atom("resource");
}

struct ExGenerator {
  fine::ResourcePtr<Generator> resource;

  static constexpr auto module = &atoms::ElixirMyLibPoint;

  static constexpr auto fields() {
    return std::make_tuple(
      std::make_tuple(&atoms::resource, &ExGenerator::resource),
    );
  }
};

ExGenerator create_generator(ErlNifEnv *env, uint64_t seed) {
  return ExGenerator{fine::make_resource<Generator>(seed)};
}

FINE_NIF(create_generator, 0);

int64_t random_integer(ErlNifEnv *env, ExGenerator ex_generator) {
  return ex_generator.resource->random_integer();
}

FINE_NIF(random_integer, 0);

FINE_INIT("Elixir.MyLib.NIF");
```

### Exceptions

All C++ exceptions thrown within the NIF are caught and raised as
Elixir exceptions.

```cpp
throw std::runtime_error("something went wrong");
// ** (RuntimeError) something went wrong

throw std::invalid_argument("expected x, got y");
// ** (ArgumentError) expected x, got y

throw OtherError(...);
// ** (RuntimeError) unknown exception
```

Additionally, you can use `fine::raise(env, value)` to raise exception,
where `value` is encoded into a term and used as the exception. This
is not particularly useful with regular types, however it can be used
to raise custom Elixir exceptions. Consider the following exception:

```elixir
defmodule MyLib.MyError do
  defexception [:data]

  @impl true
  def message(error) do
    "got error with data #{data}"
  end
end
```

First, we need to implement the corresponding C++ class:

```cpp
namespace atoms {
  auto ElixirMyLibMyError = fine::Atom("Elixir.MyLib.MyError");
  auto data = fine::Atom("data");
}

struct ExMyError {
  int64_t data;

  static constexpr auto module = &atoms::ElixirMyLibMyError;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&atoms::data, &ExMyError::data));
  }

  static constexpr auto is_exception = true;
};
```

Then, we can raise it anywhere in a NIF:

```cpp
fine::raise(env, ExMyError{42})
// ** (MyLib.MyError) got error with data 42
```

### Atoms

It is preferable to define atoms as static variables, this way the
corresponding terms are created once, at NIF load time.

```cpp
namespace atoms {
  auto hello_world = fine::Atom("hello_world");
}
```

## Prior work

Some of the ideas have been previously explored by Serge Aleynikov (@saleyn)
and Daniel Goertzen (@goertzenator) ([source](https://github.com/saleyn/nifpp)).
