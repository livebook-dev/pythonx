#include <stdexcept>

#include "dl.hpp"
#include "python.hpp"

namespace pythonx::python {

#define DEF_SYMBOL(name) decltype(name) name = nullptr;

#define LOAD_SYMBOL(library, name)                                             \
  name = reinterpret_cast<decltype(name)>(dl::get_symbol(library, #name));     \
  if (!name) {                                                                 \
    auto message = dl::error();                                                \
    dl::close_library(library);                                                \
    throw std::runtime_error(                                                  \
        ("failed to load library symbol: " #name ", reason: ") + message);     \
  }

DEF_SYMBOL(PyBool_FromLong)
DEF_SYMBOL(PyBytes_AsStringAndSize)
DEF_SYMBOL(PyBytes_FromStringAndSize)
DEF_SYMBOL(PyDict_Copy)
DEF_SYMBOL(PyDict_GetItem)
DEF_SYMBOL(PyDict_GetItemString)
DEF_SYMBOL(PyDict_New)
DEF_SYMBOL(PyDict_Next)
DEF_SYMBOL(PyDict_SetItem)
DEF_SYMBOL(PyDict_SetItemString)
DEF_SYMBOL(PyDict_Size)
DEF_SYMBOL(PyErr_Fetch)
DEF_SYMBOL(PyErr_Occurred)
DEF_SYMBOL(PyEval_GetBuiltins)
DEF_SYMBOL(PyEval_EvalCode)
DEF_SYMBOL(PyEval_RestoreThread)
DEF_SYMBOL(PyEval_SaveThread)
DEF_SYMBOL(PyFloat_AsDouble)
DEF_SYMBOL(PyFloat_FromDouble)
DEF_SYMBOL(PyImport_AddModule)
DEF_SYMBOL(PyImport_ImportModule)
DEF_SYMBOL(PyInterpreterState_Get)
DEF_SYMBOL(PyIter_Next)
DEF_SYMBOL(PyList_Append)
DEF_SYMBOL(PyList_GetItem)
DEF_SYMBOL(PyList_New)
DEF_SYMBOL(PyList_SetItem)
DEF_SYMBOL(PyList_Size)
DEF_SYMBOL(PyLong_AsLongLongAndOverflow)
DEF_SYMBOL(PyLong_FromLongLong)
DEF_SYMBOL(PyLong_FromString)
DEF_SYMBOL(PyLong_FromUnsignedLongLong)
DEF_SYMBOL(PyModule_GetDict)
DEF_SYMBOL(PyObject_Call)
DEF_SYMBOL(PyObject_CallNoArgs)
DEF_SYMBOL(PyObject_GetAttrString)
DEF_SYMBOL(PyObject_GetIter)
DEF_SYMBOL(PyObject_IsInstance)
DEF_SYMBOL(PyObject_Repr)
DEF_SYMBOL(PyObject_SetAttrString)
DEF_SYMBOL(PyObject_SetItem)
DEF_SYMBOL(PyObject_Str)
DEF_SYMBOL(PySet_Add)
DEF_SYMBOL(PySet_New)
DEF_SYMBOL(PySet_Size)
DEF_SYMBOL(PyThreadState_New)
DEF_SYMBOL(PyTuple_GetItem)
DEF_SYMBOL(PyTuple_New)
DEF_SYMBOL(PyTuple_Pack)
DEF_SYMBOL(PyTuple_SetItem)
DEF_SYMBOL(PyTuple_Size)
DEF_SYMBOL(PyUnicode_AsUTF8AndSize)
DEF_SYMBOL(PyUnicode_FromStringAndSize)
DEF_SYMBOL(Py_BuildValue)
DEF_SYMBOL(Py_CompileString)
DEF_SYMBOL(Py_DecRef)
DEF_SYMBOL(Py_IncRef)
DEF_SYMBOL(Py_InitializeEx)
DEF_SYMBOL(Py_IsFalse)
DEF_SYMBOL(Py_IsNone)
DEF_SYMBOL(Py_IsTrue)
DEF_SYMBOL(Py_SetPythonHome)
DEF_SYMBOL(Py_SetProgramName)

dl::LibraryHandle python_library;

void load_python_library(std::string path) {
  python_library = dl::open_library(path.c_str());

  if (!python_library) {
    auto message = dl::error();
    throw std::runtime_error("failed to open Python dynamic library, path: " +
                             path + ", reason: " + message);
  }

  LOAD_SYMBOL(python_library, PyBool_FromLong)
  LOAD_SYMBOL(python_library, PyBytes_AsStringAndSize)
  LOAD_SYMBOL(python_library, PyBytes_FromStringAndSize)
  LOAD_SYMBOL(python_library, PyDict_Copy)
  LOAD_SYMBOL(python_library, PyDict_GetItem)
  LOAD_SYMBOL(python_library, PyDict_GetItemString)
  LOAD_SYMBOL(python_library, PyDict_New)
  LOAD_SYMBOL(python_library, PyDict_Next)
  LOAD_SYMBOL(python_library, PyDict_SetItem)
  LOAD_SYMBOL(python_library, PyDict_SetItemString)
  LOAD_SYMBOL(python_library, PyDict_Size)
  LOAD_SYMBOL(python_library, PyErr_Fetch)
  LOAD_SYMBOL(python_library, PyErr_Occurred)
  LOAD_SYMBOL(python_library, PyEval_GetBuiltins)
  LOAD_SYMBOL(python_library, PyEval_EvalCode)
  LOAD_SYMBOL(python_library, PyEval_RestoreThread)
  LOAD_SYMBOL(python_library, PyEval_SaveThread)
  LOAD_SYMBOL(python_library, PyFloat_AsDouble)
  LOAD_SYMBOL(python_library, PyFloat_FromDouble)
  LOAD_SYMBOL(python_library, PyImport_AddModule)
  LOAD_SYMBOL(python_library, PyImport_ImportModule)
  LOAD_SYMBOL(python_library, PyInterpreterState_Get)
  LOAD_SYMBOL(python_library, PyIter_Next)
  LOAD_SYMBOL(python_library, PyList_Append)
  LOAD_SYMBOL(python_library, PyList_GetItem)
  LOAD_SYMBOL(python_library, PyList_New)
  LOAD_SYMBOL(python_library, PyList_SetItem)
  LOAD_SYMBOL(python_library, PyList_Size)
  LOAD_SYMBOL(python_library, PyLong_AsLongLongAndOverflow)
  LOAD_SYMBOL(python_library, PyLong_FromLongLong)
  LOAD_SYMBOL(python_library, PyLong_FromString)
  LOAD_SYMBOL(python_library, PyLong_FromUnsignedLongLong)
  LOAD_SYMBOL(python_library, PyModule_GetDict)
  LOAD_SYMBOL(python_library, PyObject_Call)
  LOAD_SYMBOL(python_library, PyObject_CallNoArgs)
  LOAD_SYMBOL(python_library, PyObject_GetAttrString)
  LOAD_SYMBOL(python_library, PyObject_GetIter)
  LOAD_SYMBOL(python_library, PyObject_IsInstance)
  LOAD_SYMBOL(python_library, PyObject_Repr)
  LOAD_SYMBOL(python_library, PyObject_SetAttrString)
  LOAD_SYMBOL(python_library, PyObject_SetItem)
  LOAD_SYMBOL(python_library, PyObject_Str)
  LOAD_SYMBOL(python_library, PySet_Add)
  LOAD_SYMBOL(python_library, PySet_New)
  LOAD_SYMBOL(python_library, PySet_Size)
  LOAD_SYMBOL(python_library, PyThreadState_New)
  LOAD_SYMBOL(python_library, PyTuple_GetItem)
  LOAD_SYMBOL(python_library, PyTuple_New)
  LOAD_SYMBOL(python_library, PyTuple_Pack)
  LOAD_SYMBOL(python_library, PyTuple_SetItem)
  LOAD_SYMBOL(python_library, PyTuple_Size)
  LOAD_SYMBOL(python_library, PyUnicode_AsUTF8AndSize)
  LOAD_SYMBOL(python_library, PyUnicode_FromStringAndSize)
  LOAD_SYMBOL(python_library, Py_BuildValue)
  LOAD_SYMBOL(python_library, Py_CompileString)
  LOAD_SYMBOL(python_library, Py_DecRef)
  LOAD_SYMBOL(python_library, Py_IncRef)
  LOAD_SYMBOL(python_library, Py_InitializeEx)
  LOAD_SYMBOL(python_library, Py_IsFalse)
  LOAD_SYMBOL(python_library, Py_IsNone)
  LOAD_SYMBOL(python_library, Py_IsTrue)
  LOAD_SYMBOL(python_library, Py_SetPythonHome)
  LOAD_SYMBOL(python_library, Py_SetProgramName)
}

void unload_python_library() {
  if (!dl::close_library(python_library)) {
    auto message = dl::error();
    throw std::runtime_error(
        "failed to close Python dynamic library, reason: " + message);
  }
}

} // namespace pythonx::python
