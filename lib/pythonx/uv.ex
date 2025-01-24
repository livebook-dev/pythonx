defmodule Pythonx.Uv do
  @moduledoc false

  require Logger

  @uv_version "0.5.21"

  @doc """
  Fetches Python and dependencies based on the given configuration.
  """
  @spec fetch(String.t(), boolean(), keyword()) :: :ok
  def fetch(pyproject_toml, priv?, opts \\ []) do
    opts = Keyword.validate!(opts, force: false)

    project_dir = project_dir(pyproject_toml, priv?)

    if opts[:force] || priv? do
      _ = File.rm_rf(project_dir)
    end

    if not File.dir?(project_dir) do
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "pyproject.toml"), pyproject_toml)

      # We always use uv-managed Python, so the paths are predictable.
      if run!(["sync", "--python-preference", "only-managed"],
           cd: project_dir,
           env: %{"UV_PYTHON_INSTALL_DIR" => python_install_dir(priv?)}
         ) != 0 do
        _ = File.rm_rf(project_dir)
        raise "fetching Python and dependencies failed, see standard output for details"
      end
    end

    :ok
  end

  defp python_install_dir(priv?) do
    if priv? do
      Path.join(:code.priv_dir(:pythonx), "uv/python")
    else
      Path.join(cache_dir(), "python")
    end
  end

  defp project_dir(pyproject_toml, priv?) do
    if priv? do
      Path.join(:code.priv_dir(:pythonx), "uv/project")
    else
      cache_id =
        pyproject_toml
        |> :erlang.md5()
        |> Base.encode32(case: :lower, padding: false)

      Path.join([cache_dir(), "projects", cache_id])
    end
  end

  @doc """
  Initializes the interpreter using Python and dependencies previously
  fetched by `fetch/3`.
  """
  @spec init(String.t(), boolean()) :: :ok
  def init(pyproject_toml, priv?) do
    project_dir = project_dir(pyproject_toml, priv?)

    # Uv stores Python installations in versioned directories in the
    # Python install dir. We find the specific one by looking at
    # pyvenv.cfg. It stores an absolute path, so we cannot rely on
    # that in releases. However, releases should use priv, and in
    # that case we know there is only a single Python version, so we
    # can resolve it directly.
    root_dir =
      if priv? do
        python_install_dir(priv?) |> Path.join("*") |> wildcard_one!()
      else
        pyenv_cfg_path = Path.join(project_dir, ".venv/pyvenv.cfg")

        executable_dir =
          pyenv_cfg_path
          |> File.read!()
          |> String.split("\n")
          |> Enum.find_value(fn "home = " <> path -> path end)
          |> Path.expand()

        case :os.type() do
          {:win32, _osname} -> executable_dir
          {:unix, _osname} -> Path.dirname(executable_dir)
        end
      end

    case :os.type() do
      {:win32, _osname} ->
        # Note that we want the version-specific DLL, rather than the
        # "forwarder DLL" python3.dll, otherwise symbols cannot be
        # found directly.
        python_dl_path =
          root_dir
          |> Path.join("python3?*.dll")
          |> wildcard_one!()
          |> make_windows_slashes()

        python_home_path = make_windows_slashes(root_dir)

        venv_packages_path =
          project_dir
          |> Path.join(".venv/Lib/site-packages")
          |> make_windows_slashes()

        Pythonx.init(python_dl_path, python_home_path, sys_paths: [venv_packages_path])

      {:unix, osname} ->
        dl_extension =
          case osname do
            :darwin -> ".dylib"
            :linux -> ".so"
          end

        python_dl_path =
          root_dir
          |> Path.join("lib/libpython3.*" <> dl_extension)
          |> wildcard_one!()
          |> Path.expand()

        python_home_path = root_dir

        venv_packages_path =
          project_dir
          |> Path.join(".venv/lib/python3*/site-packages")
          |> wildcard_one!()

        Pythonx.init(python_dl_path, python_home_path, sys_paths: [venv_packages_path])
    end
  end

  defp wildcard_one!(path) do
    case Path.wildcard(path) do
      [path] -> path
      other -> raise "expected one path to match #{inspect(path)}, got: #{inspect(other)}"
    end
  end

  defp make_windows_slashes(path), do: String.replace(path, "/", "\\")

  defp run!(args, opts) do
    path = uv_path()

    if not File.exists?(path) do
      download!()
    end

    {_stream, status} =
      System.cmd(path, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts)

    status
  end

  defp uv_path() do
    Path.join([cache_dir(), "bin", "uv"])
  end

  @version Mix.Project.config()[:version]

  defp cache_dir() do
    base_dir = :filename.basedir(:user_cache, "pythonx")
    Path.join([base_dir, @version, "uv", @uv_version])
  end

  defp download!() do
    {archive_type, archive_name} = archive_name()

    url = "https://github.com/astral-sh/uv/releases/download/#{@uv_version}/#{archive_name}"
    Logger.debug("Downloading uv archive from #{url}")
    archive_binary = Pythonx.Utils.fetch_body!(url)

    path = uv_path()
    {:ok, uv_binary} = extract_executable(archive_type, archive_binary)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, uv_binary)
    File.chmod!(path, 0o755)
  end

  defp extract_executable(:zip, binary) do
    {:ok, entries} = :zip.extract(binary, [:memory])
    find_uv_entry(entries)
  end

  defp extract_executable(:tar_gz, binary) do
    {:ok, entries} = :erl_tar.extract({:binary, binary}, [:compressed, :memory])
    find_uv_entry(entries)
  end

  defp find_uv_entry(archive_entries) do
    Enum.find_value(archive_entries, :error, fn {name, binary} ->
      if Path.basename(name, Path.extname(name)) == "uv" do
        {:ok, binary}
      end
    end)
  end

  defp archive_name() do
    arch_string = :erlang.system_info(:system_architecture) |> List.to_string()
    destructure [arch, _vendor, _os, abi], String.split(arch_string, "-")
    wordsize = :erlang.system_info(:wordsize) * 8

    target =
      case :os.type() do
        {:win32, _osname} when wordsize == 64 ->
          "x86_64-pc-windows-msvc"

        {:win32, _osname} when wordsize == 32 ->
          "i686-pc-windows-msvc"

        {:unix, :darwin} when arch in ~w(arm aarch64) ->
          "aarch64-apple-darwin"

        {:unix, :darwin} when arch == "x86_64" ->
          "x86_64-apple-darwin"

        {:unix, :linux}
        when {arch, abi} in [
               {"aarch64", "gnu"},
               {"aarch64", "musl"},
               {"arm", "musleabihf"},
               {"armv7", "gnueabihf"},
               {"armv7", "musleabihf"},
               {"i686", "gnu"},
               {"i686", "musl"},
               {"powerpc64", "gnu"},
               {"powerpc64le", "gnu"},
               {"s390x", "gnu"},
               {"x86_64", "gnu"},
               {"x86_64", "musl"}
             ] ->
          "#{arch}-unknown-linux-#{abi}"

        _other ->
          raise "uv is not available for architecture: #{arch_string}"
      end

    if target =~ "-windows-" do
      {:zip, "uv-#{target}.zip"}
    else
      {:tar_gz, "uv-#{target}.tar.gz"}
    end
  end
end
