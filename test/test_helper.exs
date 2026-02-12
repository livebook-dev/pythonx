python_minor = System.get_env("PYTHONX_TEST_PYTHON_MINOR", "13") |> String.to_integer()

System.put_env("PYTHONX_TEST_ENV_VAR", "value")

Pythonx.uv_init("""
[project]
name = "project"
version = "0.0.0"
requires-python = "==3.#{python_minor}.*"
dependencies = [
  "numpy==2.1.2"
]
""")

ExUnit.start()
