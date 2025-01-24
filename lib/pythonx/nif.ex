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

  def init(_python_dl_path, _python_home_path, _sys_paths), do: :erlang.nif_error(:not_loaded)
  def terminate(), do: :erlang.nif_error(:not_loaded)
  def janitor_decref(_ptr), do: :erlang.nif_error(:not_loaded)
  def none_new(), do: :erlang.nif_error(:not_loaded)
  def false_new(), do: :erlang.nif_error(:not_loaded)
  def true_new(), do: :erlang.nif_error(:not_loaded)
  def long_from_int64(_integer), do: :erlang.nif_error(:not_loaded)
  def long_from_string(_string, _base), do: :erlang.nif_error(:not_loaded)
  def float_new(_float), do: :erlang.nif_error(:not_loaded)
  def bytes_from_binary(_binary), do: :erlang.nif_error(:not_loaded)
  def unicode_from_string(_string), do: :erlang.nif_error(:not_loaded)
  def unicode_to_string(_object), do: :erlang.nif_error(:not_loaded)
  def dict_new(), do: :erlang.nif_error(:not_loaded)
  def dict_set_item(_object, _key, _value), do: :erlang.nif_error(:not_loaded)
  def tuple_new(_size), do: :erlang.nif_error(:not_loaded)
  def tuple_set_item(_object, _index, _value), do: :erlang.nif_error(:not_loaded)
  def list_new(_size), do: :erlang.nif_error(:not_loaded)
  def list_set_item(_object, _index, _value), do: :erlang.nif_error(:not_loaded)
  def set_new(), do: :erlang.nif_error(:not_loaded)
  def set_add(_object, _key), do: :erlang.nif_error(:not_loaded)
  def object_repr(_object), do: :erlang.nif_error(:not_loaded)
  def format_exception(_error), do: :erlang.nif_error(:not_loaded)
  def decode_once(_object), do: :erlang.nif_error(:not_loaded)

  def eval(_code, _code_md5, _globals, _stdout_device, _stderr_device),
    do: :erlang.nif_error(:not_loaded)
end
