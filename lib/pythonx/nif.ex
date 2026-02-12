defmodule Pythonx.NIF do
  @moduledoc false

  @on_load :__on_load__

  def __on_load__ do
    path = :filename.join(:code.priv_dir(:pythonx), ~c"libpythonx")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> raise "failed to load NIF library, reason: #{inspect(reason)}"
    end
  end

  def init(_python_dl_path, _python_home_path, _python_executable_path, _sys_paths, _envs),
    do: err!()

  def janitor_decref(_ptr), do: err!()
  def none_new(), do: err!()
  def false_new(), do: err!()
  def true_new(), do: err!()
  def long_from_int64(_integer), do: err!()
  def long_from_string(_string, _base), do: err!()
  def float_new(_float), do: err!()
  def bytes_from_binary(_binary), do: err!()
  def unicode_from_string(_string), do: err!()
  def unicode_to_string(_object), do: err!()
  def dict_new(), do: err!()
  def dict_set_item(_object, _key, _value), do: err!()
  def tuple_new(_size), do: err!()
  def tuple_set_item(_object, _index, _value), do: err!()
  def list_new(_size), do: err!()
  def list_set_item(_object, _index, _value), do: err!()
  def set_new(), do: err!()
  def set_add(_object, _key), do: err!()
  def pid_new(_pid), do: err!()
  def object_repr(_object), do: err!()
  def format_exception(_error), do: err!()
  def decode_once(_object), do: err!()
  def eval(_code, _code_md5, _globals, _stdout_device, _stderr_device), do: err!()

  defp err!(), do: :erlang.nif_error(:not_loaded)
end
