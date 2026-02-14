defmodule Pythonx do
  @external_resource "README.md"

  [_, readme_docs, _] =
    "README.md"
    |> File.read!()
    |> String.split("<!-- Docs -->")

  @moduledoc readme_docs

  alias Pythonx.Object

  @install_env_name "PYTHONX_INIT_STATE"

  @type encoder :: (term(), encoder() -> Object.t())

  @doc ~s'''
  Installs Python and dependencies using [uv](https://docs.astral.sh/uv)
  package manager and initializes the interpreter.

  The interpreter is automatically initialized using the installed
  Python. The dependency packages are added to the module search path.

  Expects a string with `pyproject.toml` file content, which is used
  to configure the project environment. The config requires `project.name`
  and `project.version` fields to be set. It is also a good idea to
  specify the Python version by setting `project.requires-python`.

      Pythonx.uv_init("""
      [project]
      name = "project"
      version = "0.0.0"
      requires-python = "==3.13.*"
      """)

  To install Python packages, set the `project.dependencies` field:

      Pythonx.uv_init("""
      [project]
      name = "project"
      version = "0.0.0"
      requires-python = "==3.13.*"
      dependencies = [
        "numpy==2.2.2"
      ]
      """)

  For more configuration options, refer to the [uv documentation](https://docs.astral.sh/uv/concepts/projects/dependencies/).

  > #### Environment variables {: .info}
  >
  > Python `os.environ` is initialized using the OS process environment.
  > Consequently, it does not account for env vars modified with
  > `System.put_env/2` and similar. If you want to mirror certain env
  > vars, you need to set them on `os.environ` using `Pythonx.eval/2`.

  ## Options

    * `:force` - if true, runs with empty project cache. Defaults to `false`.

    * `:uv_version` - select the version of the uv package manager to use.
      Defaults to `#{inspect(Pythonx.Uv.default_uv_version())}`.

    * `:native_tls` - if true, uses the system's native TLS implementation instead
      of vendored rustls. This is useful in corporate environments where the system
      certificate store must be used. Defaults to `false`.

    * `:python` - specifies the Python version to install, passed as `--python` to uv.
      This can be used to request a free-threaded Python build (e.g., `"3.14t"`).
      Defaults to `nil` (uses the version from `requires-python` in `pyproject.toml`).

  '''
  @spec uv_init(String.t(), keyword()) :: :ok
  def uv_init(pyproject_toml, opts \\ []) when is_binary(pyproject_toml) and is_list(opts) do
    opts =
      Keyword.validate!(opts,
        force: false,
        uv_version: Pythonx.Uv.default_uv_version(),
        native_tls: false,
        python: nil
      )

    Pythonx.Uv.fetch(pyproject_toml, false, opts)

    install_paths =
      Pythonx.Uv.init(pyproject_toml, false, Keyword.take(opts, [:uv_version, :python]))

    init_state = %{
      type: :uv_init,
      pyproject_toml: pyproject_toml,
      opts: Keyword.drop(opts, [:force]),
      install_paths: install_paths
    }

    :persistent_term.put(:pythonx_init_state, init_state)
  end

  @spec init_state() :: map()
  defp init_state() do
    :persistent_term.get(:pythonx_init_state)
  end

  @spec init_state_from_env() :: String.t() | nil
  defp init_state_from_env(), do: System.get_env(@install_env_name)

  @doc ~s'''
  Returns a map with opaque environment variables to initialize Pythonx in
  the same way as the current initialization.

  When those environment variables are set, Pythonx is initialized on boot.

  In particular, this can be used to make Pythonx initialize on `FLAME` nodes.
  '''
  @spec install_env() :: map()
  def install_env() do
    init_state = init_state()

    if init_state == nil do
      raise "before calling Pythonx.install_env/0, you must initialize Pythonx"
    end

    init_state =
      init_state
      |> :erlang.term_to_binary()
      |> Base.encode64()

    %{@install_env_name => init_state}
  end

  @doc ~s'''
  Returns a list of paths that `install_env/0` initialization depends on.

  In particular, this can be used to make Pythonx initialize on `FLAME` nodes.
  '''
  @spec install_paths() :: list(String.t())
  def install_paths() do
    init_state = init_state()

    if init_state == nil do
      raise "before calling Pythonx.install_paths/0, you must initialize Pythonx"
    end

    init_state.install_paths
  end

  @doc false
  def maybe_init_from_env() do
    case init_state_from_env() do
      nil ->
        :noop

      init_state_env_value ->
        %{
          type: :uv_init,
          pyproject_toml: pyproject_toml,
          opts: opts
        } =
          init_state_env_value
          |> Base.decode64!()
          |> :erlang.binary_to_term()

        uv_init(pyproject_toml, opts)
    end
  end

  # Initializes the Python interpreter.
  #
  # > #### Reproducibility {: .info}
  # >
  # > This function can be called to use a custom Python installation,
  # > however in most cases it is more convenient to call `uv_init/2`,
  # > which installs Python and dependencies, and then automatically
  # > initializes the interpreter using the correct paths.
  #
  # `python_dl_path` is the Python dynamically linked library file.
  # The usual file name is `libpython3.x.so` (Linux), `libpython3.x.dylib`
  # (macOS), `python3x.dll` (Windows).
  #
  # `python_home_path` is the Python home directory, where the Python
  # built-in modules reside. Specifically, the modules should be
  # located in `{python_home_path}/lib/pythonx.y` (Linux and macOS)
  # or `{python_home_path}/Lib` (Windows).
  #
  # `python_executable_path` is the Python executable file. When using
  # venv, it is preferable to point to an executable in the venv
  # directory, which is relevant if additional packages are installed
  # at runtime.
  #
  # ## Options
  #
  #   * `:sys_paths` - directories to be added to the module search path
  #     (`sys.path`). Defaults to `[]`.
  #
  @doc false
  @spec init(String.t(), String.t(), String.t(), keyword()) :: :ok
  def init(python_dl_path, python_home_path, python_executable_path, opts \\ [])
      when is_binary(python_dl_path) and is_binary(python_home_path)
      when is_binary(python_executable_path) and is_list(opts) do
    opts = Keyword.validate!(opts, sys_paths: [])

    if not File.exists?(python_dl_path) do
      raise ArgumentError, "the given dynamic library file does not exist: #{python_dl_path}"
    end

    if not File.dir?(python_home_path) do
      raise ArgumentError, "the given python home directory does not exist: #{python_home_path}"
    end

    if not File.exists?(python_home_path) do
      raise ArgumentError, "the given python executable does not exist: #{python_executable_path}"
    end

    Pythonx.NIF.init(python_dl_path, python_home_path, python_executable_path, opts[:sys_paths])
  end

  @doc ~S'''
  Evaluates the Python `code`.

  The `globals` argument is a map with global variables to be set for
  the evaluation. The map keys are strings, while the values can be
  any terms and they are automatically converted to Python objects
  by calling `encode!/1`.

  The function returns the evaluation result and a map with the updated
  global variables. Note that the result is an object only if `code`
  ends with an expression, otherwise it is `nil`.

  If the Python code raises an exception, `Pythonx.Error` is raised and
  the message includes the usual Python error message with traceback.

  All writes to the Python standard output are sent to caller's group
  leader, while writes to the standard error are sent to the
  `:standard_error` process. Reading from the standard input is not
  supported and raises and error.

  > #### Concurrency {: .info}
  >
  > The Python interpreter has a mechanism known as global interpreter
  > lock (GIL), which prevents from multiple threads executing Python
  > code at the same time. Consequently, calling `eval/2` from multiple
  > Elixir processes does not provide the concurrency you might expect
  > and thus it can be a source of bottlenecks. However, this concerns
  > regular Python code. Packages with CPU-intense functionality, such
  > as `numpy`, have native implementation of many functions and invoking
  > those releases the GIL. GIL is also released when waiting on I/O
  > operations.

  ## Options

    * `:stdout_device` - IO process to send Python stdout output to.
      Defaults to the caller's group leader.

    * `:stderr_device` - IO process to send Python stderr output to.
      Defaults to the global `:standard_error`.

  ## Examples

      iex> {result, globals} =
      ...>   Pythonx.eval(
      ...>     """
      ...>     y = 10
      ...>     x + y
      ...>     """,
      ...>     %{"x" => 1}
      ...>   )
      iex> result
      #Pythonx.Object<
        11
      >
      iex> globals["x"]
      #Pythonx.Object<
        1
      >
      iex> globals["y"]
      #Pythonx.Object<
        10
      >

  You can carry evaluation state by passing globals from one evaluation
  to the next:

      iex> {_result, globals} = Pythonx.eval("x = 1", %{})
      iex> {result, _globals} = Pythonx.eval("x + 1", globals)
      iex> result
      #Pythonx.Object<
        2
      >

  ### Mutability

  Reassigning variables will have no effect on the given `globals`,
  the returned globals will simply hold different objects:

      iex> {_result, globals1} = Pythonx.eval("x = 1", %{})
      iex> {_result, globals2} = Pythonx.eval("x = 2", globals1)
      iex> globals1["x"]
      #Pythonx.Object<
        1
      >
      iex> globals2["x"]
      #Pythonx.Object<
        2
      >

  However, objects in `globals` are not automatically cloned, so if
  you explicitly mutate an object, it changes across all references:

      iex> {_result, globals1} = Pythonx.eval("x = []", %{})
      iex> {_result, globals2} = Pythonx.eval("x.append(1)", globals1)
      iex> globals1["x"]
      #Pythonx.Object<
        [1]
      >
      iex> globals2["x"]
      #Pythonx.Object<
        [1]
      >

  '''
  @spec eval(String.t(), %{optional(String.t()) => term()}, keyword()) ::
          {Object.t() | nil, %{optional(String.t()) => Object.t()}}
  def eval(code, globals, opts \\ [])
      when is_binary(code) and is_map(globals) and is_list(opts) do
    if not pythonx_started?() do
      raise RuntimeError,
            "the :pythonx application needs to be started before calling Pythonx.eval/3"
    end

    opts = Keyword.validate!(opts, [:stdout_device, :stderr_device])

    globals =
      for {key, value} <- globals do
        if not is_binary(key) do
          raise ArgumentError, "expected globals keys to be strings, got: #{inspect(key)}"
        end

        {key, encode!(value)}
      end

    code_md5 = :erlang.md5(code)

    stdout_device = Keyword.get_lazy(opts, :stdout_device, fn -> Process.group_leader() end)

    stderr_device =
      Keyword.get_lazy(opts, :stderr_device, fn -> Process.whereis(:standard_error) end)

    result = Pythonx.NIF.eval(code, code_md5, globals, stdout_device, stderr_device)

    # Wait for the janitor to process all output messages received
    # during the evaluation, so that they are not perceived overly
    # late.
    Pythonx.Janitor.ping()

    result
  end

  defp pythonx_started?() do
    Process.whereis(Pythonx.Supervisor) != nil
  end

  @doc ~S'''
  Convenience macro for Python code evaluation.

  This has all the characteristics of `eval/2`, except that globals
  are handled implicitly. This means that any Elixir variables
  referenced in the Python code will automatically get encoded and
  passed as globals for evaluation. Similarly, any globals assigned
  in the code will result in Elixir variables being defined.

  > #### Compilation {: .warning}
  >
  > This macro evaluates Python code at compile time, so it requires
  > the Python interpreter to be already initialized. In practice,
  > this means that you can use this sigil in environments with
  > dynamic evaluation, such as IEx and Livebook, but not in regular
  > application code. In application code it is preferable to use
  > `eval/2` regardless, to make the globals management explicit.

  ## Examples

      iex> import Pythonx
      iex> x = 1
      iex> ~PY"""
      ...> y = 10
      ...> x + y
      ...> """
      #Pythonx.Object<
        11
      >
      iex> x
      1
      iex> y
      #Pythonx.Object<
        10
      >

  '''
  defmacro sigil_PY({:<<>>, _meta, [code]}, []) when is_binary(code) do
    %{referenced: referenced, defined: defined} = Pythonx.AST.scan_globals(code)

    caller = __CALLER__

    globals_entries =
      for name <- referenced,
          name_atom = String.to_atom(name),
          # We only reference variables that are actually defined.
          # This way, if an undefined variable is referenced in the
          # Python code, it results in an informative Python error,
          # rather than Elixir compile error.
          Macro.Env.has_var?(caller, {name_atom, nil}) do
        {name, {name_atom, [], nil}}
      end

    assignments =
      for name <- defined do
        quote do
          # We include :generated to avoid unused variable warnings,
          # if the variables are not referenced later on.
          unquote({String.to_atom(name), [generated: true], nil}) =
            Map.get(globals, unquote(name), nil)
        end
      end

    quote do
      {result, globals} = Pythonx.eval(unquote(code), unquote({:%{}, [], globals_entries}))
      unquote({:__block__, [], assignments})
      result
    end
  rescue
    error in RuntimeError ->
      message = Exception.message(error)

      if message =~ "has not been initialized" do
        raise RuntimeError,
              Exception.message(error) <>
                "using ~PY sigil requires the Python interpreter to be already initialized. " <>
                "This sigil is designed for dynamic evaluation environments, such as IEx or Livebook. " <>
                "If that is your case, make sure you initialized the interpreter first, otherwise " <>
                "use Pythonx.eval/2 instead. For more details see Pythonx.sigil_PY/2 docs"
      else
        reraise(error, __STACKTRACE__)
      end
  end

  @doc """
  Encodes the given term to a Python object.

  Encoding can be extended to support custom data structures, see
  `Pythonx.Encoder`.

  ## Examples

      iex> Pythonx.encode!({1, true, "hello world"})
      #Pythonx.Object<
        (1, True, b'hello world')
      >

  """
  @spec encode!(term(), encoder()) :: Object.t()
  def encode!(term, encoder \\ &Pythonx.Encoder.encode/2) do
    encoder.(term, encoder)
  end

  @doc """
  Decodes a Python object to a term.

  Converts the following Python types to the corresponding Elixir terms:

    * `NoneType`
    * `bool`
    * `int`
    * `float`
    * `str`
    * `bytes`
    * `tuple`
    * `list`
    * `dict`
    * `set`
    * `frozenset`
    * `pythonx.PID`

  For all other types `Pythonx.Object` is returned.

  ## Examples

      iex> {result, %{}} = Pythonx.eval("(1, True, 'hello world')", %{})
      iex> Pythonx.decode(result)
      {1, true, "hello world"}

      iex> {result, %{}} = Pythonx.eval("print", %{})
      iex> Pythonx.decode(result)
      #Pythonx.Object<
        <built-in function print>
      >

  """
  @spec decode(Object.t()) :: term()
  def decode(%Object{} = object) do
    # We call decode_once, which returns either an Elixir term, such
    # as a string or a container with %Object{} items for us to recur
    # over.
    #
    # We could make decode as a single NIF call, where objects are
    # recursively converted to Elixir terms. The advantages of that
    # approach are: (a) less overhead (single NIF and GIL acquisition);
    # (b) less memory usage, since we don't build intermediate lists,
    # just to map over them in Elixir. However, this comes with a hard
    # limitation that all terms need to be fully built in the NIF,
    # which means we cannot build MapSet, and even big integers are
    # tricky to build (though possible by calling enif_binary_to_term
    # with hand-crafted binary). On a sidenote, in the future we may
    # want to make decoding extensible, such that user could provide
    # a custom decoder function, and that would also not be possible
    # under this limitation. That said, encoding also requires multiple
    # NIF calls and Enum.map/2 is a usual occurrence, so in practice
    # neither (a) or (b) makes the limitation worth it.

    case Pythonx.NIF.decode_once(object) do
      {:list, items} ->
        Enum.map(items, &decode/1)

      {:tuple, items} ->
        items
        |> Enum.map(&decode/1)
        |> List.to_tuple()

      {:map, items} ->
        Map.new(items, fn {key, value} -> {decode(key), decode(value)} end)

      {:map_set, items} ->
        MapSet.new(items, &decode/1)

      {:integer, string} ->
        String.to_integer(string)

      term ->
        term
    end
  end

  def decode(nil) do
    raise ArgumentError,
          "Pythonx.decode/1 expects a %Pythonx.Object{}, but got nil. " <>
            "Note that Pythonx.eval/2 or the ~PY sigil result in nil, if the " <>
            "evaluated code ends with a statement, rather than expression"
  end
end
