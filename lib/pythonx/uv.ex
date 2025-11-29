defmodule Pythonx.Uv do
  @moduledoc false

  require Logger

  def default_uv_version(), do: "0.8.5"

  @doc """
  Fetches Python and dependencies based on the given configuration.
  """
  @spec fetch(String.t(), boolean(), keyword()) :: :ok
  def fetch(pyproject_toml, priv?, opts \\ []) do
    opts = Keyword.validate!(opts, force: false, uv_version: default_uv_version())

    project_dir = project_dir(pyproject_toml, priv?, opts[:uv_version])
    python_install_dir = python_install_dir(priv?, opts[:uv_version])

    if opts[:force] || priv? do
      _ = File.rm_rf(project_dir)
    end

    if priv? do
      _ = File.rm_rf(python_install_dir)
    end

    if not File.dir?(project_dir) do
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "pyproject.toml"), pyproject_toml)

      # We always use uv-managed Python, so the paths are predictable.
      if run!(["sync", "--managed-python", "--no-config"],
           cd: project_dir,
           env: %{"UV_PYTHON_INSTALL_DIR" => python_install_dir},
           uv_version: opts[:uv_version]
         ) != 0 do
        _ = File.rm_rf(project_dir)
        raise "fetching Python and dependencies failed, see standard output for details"
      end
    end

    :ok
  end

  defp python_install_dir(priv?, uv_version) do
    if priv? do
      Path.join(:code.priv_dir(:pythonx), "uv/python")
    else
      Path.join(cache_dir(uv_version), "python")
    end
  end

  defp project_dir(pyproject_toml, priv?, uv_version) do
    if priv? do
      Path.join(:code.priv_dir(:pythonx), "uv/project")
    else
      cache_id =
        pyproject_toml
        |> :erlang.md5()
        |> Base.encode32(case: :lower, padding: false)

      Path.join([cache_dir(uv_version), "projects", cache_id])
    end
  end

  @doc """
  Initializes the interpreter using Python and dependencies previously
  fetched by `fetch/3`.
  """
  @spec init(String.t(), boolean()) :: Pythonx.init_state()
  def init(pyproject_toml, priv?, opts \\ []) do
    opts = Keyword.validate!(opts, uv_version: default_uv_version())
    project_dir = project_dir(pyproject_toml, priv?, opts[:uv_version])

    # Uv stores Python installations in versioned directories in the
    # Python install dir. To find the versioned name for this project,
    # we look at pyvenv.cfg. We could use the "home" path altogether,
    # however it is an absolute path, so we cannot rely on it for priv
    # in releases anyway, and for consistency we handle both cases the
    # same way.

    pyenv_cfg_path = Path.join(project_dir, ".venv/pyvenv.cfg")

    abs_executable_dir =
      pyenv_cfg_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_value(fn "home = " <> path -> path end)
      |> Path.expand()

    versioned_dir_name =
      case :os.type() do
        {:win32, _osname} -> Path.basename(abs_executable_dir)
        {:unix, _osname} -> Path.basename(Path.dirname(abs_executable_dir))
      end

    root_dir = Path.join(python_install_dir(priv?, opts[:uv_version]), versioned_dir_name)

    init_state =
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

          python_executable_path =
            project_dir
            |> Path.join(".venv/Scripts/python.exe")
            |> make_windows_slashes()

          venv_packages_path =
            project_dir
            |> Path.join(".venv/Lib/site-packages")
            |> make_windows_slashes()

          %Pythonx{
            python_dl_path: python_dl_path,
            python_home_path: python_home_path,
            python_executable_path: python_executable_path,
            sys_paths: [venv_packages_path]
          }

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

          python_executable_path = Path.join(project_dir, ".venv/bin/python")

          venv_packages_path =
            project_dir
            |> Path.join(".venv/lib/python3*/site-packages")
            |> wildcard_one!()

          %Pythonx{
            python_dl_path: python_dl_path,
            python_home_path: python_home_path,
            python_executable_path: python_executable_path,
            sys_paths: [venv_packages_path]
          }
      end

    Pythonx.init(init_state)
    init_state
  end

  defp wildcard_one!(path) do
    case Path.wildcard(path) do
      [path] -> path
      other -> raise "expected one path to match #{inspect(path)}, got: #{inspect(other)}"
    end
  end

  defp make_windows_slashes(path), do: String.replace(path, "/", "\\")

  defp run!(args, opts) do
    {uv_version, opts} = Keyword.pop(opts, :uv_version, default_uv_version())
    path = uv_path(uv_version)

    if not File.exists?(path) do
      download!(uv_version)
    end

    {_stream, status} =
      System.cmd(path, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts)

    status
  end

  defp uv_path(uv_version) do
    Path.join([cache_dir(uv_version), "bin", "uv"])
  end

  @version Mix.Project.config()[:version]

  defp cache_dir(uv_version) do
    base_dir =
      if dir = System.get_env("PYTHONX_CACHE_DIR") do
        Path.expand(dir)
      else
        :filename.basedir(:user_cache, "pythonx")
      end

    Path.join([base_dir, @version, "uv", uv_version])
  end

  defp download!(uv_version) do
    {archive_type, archive_name} = archive_name()

    url = "https://github.com/astral-sh/uv/releases/download/#{uv_version}/#{archive_name}"
    Logger.debug("Downloading uv archive from #{url}")
    archive_binary = Pythonx.Utils.fetch_body!(url)

    path = uv_path(uv_version)
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
