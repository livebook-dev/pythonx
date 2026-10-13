defmodule Pythonx.FinalizeError do
  @moduledoc """
  An exception returned by `Pythonx.finalize/0` when finalization fails.

  Carries both the `return_code` from `Py_FinalizeEx` and the
  `resource_count` of `PyObjectResource` instances that survived
  finalization. Either being non-zero indicates a problem:

    * A non-zero `return_code` means CPython's shutdown sequence
      encountered an error (e.g., flushing buffered data failed).
    * A non-zero `resource_count` means resource-backed binaries
      may reference freed Python memory. This is only a concern
      when `binaries` is configured as `:fast` (the default).
  """

  defexception [:return_code, :resource_count]

  @type t :: %__MODULE__{
          return_code: integer(),
          resource_count: integer()
        }

  @impl true
  def message(%__MODULE__{return_code: return_code, resource_count: resource_count}) do
    parts = []

    parts =
      if return_code != 0 do
        ["Py_FinalizeEx returned exit code #{return_code}" | parts]
      else
        parts
      end

    parts =
      if resource_count > 0 do
        ["#{resource_count} PyObjectResource instances survived finalization" | parts]
      else
        parts
      end

    case parts do
      [] -> "Pythonx finalization completed"
      _ -> "Pythonx finalization failed: " <> Enum.join(parts, ", ")
    end
  end
end
