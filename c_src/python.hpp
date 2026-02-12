#pragma once

#include <string>

// ssize_t is non-standard, for MSVC we need to define it
#if defined(_MSC_VER)
#include <BaseTsd.h>
using ssize_t = SSIZE_T;
#endif

namespace pythonx::python {

// We only use the Limited C API, which stays compatible across Python
// minor versions. At the moment we assume Python 3.10+, the list of
// available functions can be found in [1].
//
// Other than the C API functions, we also use Python standard library
// functions via PyObject_Call. This is fine as long as the functions
// are present in the lowest supported Python version and seem stable
// (in particular, they are not deprecated). Keep in mind that the
// C API should be preferred when possible, since invoking lower level
// operations directly should be more efficient in most cases.
//
// Note that we manage the library manually with `dlopen`, instead of
// linking at compile time and loading together with the NIF lib. This
// makes the development slightly more annoying, since we need to
// declare and load the individual symbols ourselves, however it makes
// the overall setup more flexible:
//
//   1. We want the Python library location to be configured by the
//      user. We could do that by: (a) making sure the NIF library
//      depends on a relative libpython.so/python.dll; (b) at runtime,
//      symlink or copy the configured Python library at that relative
//      location; (c) load the NIF only after symlink is in place,
//      rather than upfront. Step (a) requires patching the .so/.dll
//      differently on each platform; on Windows this requires compiling
//      and attaching and extra manifest to the .dll. With `dlopen` we
//      can simply use the configured path.
//
//   2. It prevents from accidentally using symbols out of Limited API.
//      Technically setting Py_LIMITED_API hides a subset of function
//      declarations, but there are at least certain macros that stay
//      visible. By adding the symbols manually, we can make sure they
//      are indeed part of the Limited API.
//
//   3. If necessary, we could conditionally use functions added to
//      Limited API in later versions and have fallback implementations.
//
//   4. Compiling the NIF does not require Python at all, which makes
//      it simpler. Though the main tradeoff is not being able to use
//      the Python library headers.
//
//   5. After uninitializing Python, we should be able to unload the
//      library, though there may not be an actual use case to make
//      this relevant. It is also worth noting that, while in principle
//      it should be possible to reinitialize Python, it can lead to
//      issues in practice. For example, doing so while using numpy
//      simply does not work, see [2] for discussion points.
//
// [1]: https://docs.python.org/3.10/c-api/stable.html#stable-abi-list
// [2]: https://bugs.python.org/issue34309

// Opaque types

using PyInterpreterStatePtr = void *;
using PyObjectPtr = void *;
using PyThreadStatePtr = void *;
using Py_ssize_t = ssize_t;

// Functions

extern PyObjectPtr (*PyBool_FromLong)(long int);
extern int (*PyBytes_AsStringAndSize)(PyObjectPtr, char **, Py_ssize_t *);
extern PyObjectPtr (*PyBytes_FromStringAndSize)(const char *, Py_ssize_t);
extern PyObjectPtr (*PyDict_Copy)(PyObjectPtr);
extern PyObjectPtr (*PyDict_GetItem)(PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PyDict_GetItemString)(PyObjectPtr, const char *);
extern PyObjectPtr (*PyDict_New)();
extern int (*PyDict_Next)(PyObjectPtr, Py_ssize_t *, PyObjectPtr *,
                          PyObjectPtr *);
extern int (*PyDict_SetItem)(PyObjectPtr, PyObjectPtr, PyObjectPtr);
extern int (*PyDict_SetItemString)(PyObjectPtr, const char *, PyObjectPtr);
extern Py_ssize_t (*PyDict_Size)(PyObjectPtr);
extern void (*PyErr_Fetch)(PyObjectPtr *, PyObjectPtr *, PyObjectPtr *);
extern PyObjectPtr (*PyErr_Occurred)();
extern PyObjectPtr (*PyEval_GetBuiltins)();
extern PyObjectPtr (*PyEval_EvalCode)(PyObjectPtr, PyObjectPtr, PyObjectPtr);
extern void (*PyEval_RestoreThread)(PyThreadStatePtr);
extern PyThreadStatePtr (*PyEval_SaveThread)();
extern double (*PyFloat_AsDouble)(PyObjectPtr);
extern PyObjectPtr (*PyFloat_FromDouble)(double);
extern PyObjectPtr (*PyImport_AddModule)(const char *);
extern PyObjectPtr (*PyImport_ImportModule)(const char *);
extern PyInterpreterStatePtr (*PyInterpreterState_Get)();
extern PyObjectPtr (*PyIter_Next)(PyObjectPtr);
extern int (*PyList_Append)(PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PyList_GetItem)(PyObjectPtr, Py_ssize_t);
extern PyObjectPtr (*PyList_New)(Py_ssize_t);
extern Py_ssize_t (*PyList_Size)(PyObjectPtr);
extern int (*PyList_SetItem)(PyObjectPtr, Py_ssize_t, PyObjectPtr);
extern long long (*PyLong_AsLongLongAndOverflow)(PyObjectPtr, int *);
extern PyObjectPtr (*PyLong_FromLongLong)(long long);
extern PyObjectPtr (*PyLong_FromString)(const char *, char **, int);
extern PyObjectPtr (*PyLong_FromUnsignedLongLong)(unsigned long long);
extern PyObjectPtr (*PyModule_GetDict)(PyObjectPtr);
extern PyObjectPtr (*PyObject_Call)(PyObjectPtr, PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PyObject_CallNoArgs)(PyObjectPtr);
extern PyObjectPtr (*PyObject_GetAttrString)(PyObjectPtr, const char *);
extern PyObjectPtr (*PyObject_GetIter)(PyObjectPtr);
extern int (*PyObject_IsInstance)(PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PyObject_Repr)(PyObjectPtr);
extern int (*PyObject_SetAttrString)(PyObjectPtr, const char *, PyObjectPtr);
extern int (*PyObject_SetItem)(PyObjectPtr, PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PyObject_Str)(PyObjectPtr);
extern int (*PySet_Add)(PyObjectPtr, PyObjectPtr);
extern PyObjectPtr (*PySet_New)(PyObjectPtr);
extern Py_ssize_t (*PySet_Size)(PyObjectPtr);
extern PyThreadStatePtr (*PyThreadState_New)(PyInterpreterStatePtr);
extern PyObjectPtr (*PyTuple_GetItem)(PyObjectPtr, Py_ssize_t);
extern PyObjectPtr (*PyTuple_New)(Py_ssize_t);
extern PyObjectPtr (*PyTuple_Pack)(Py_ssize_t, ...);
extern int (*PyTuple_SetItem)(PyObjectPtr, Py_ssize_t, PyObjectPtr);
extern Py_ssize_t (*PyTuple_Size)(PyObjectPtr);
extern const char *(*PyUnicode_AsUTF8AndSize)(PyObjectPtr, Py_ssize_t *);
extern PyObjectPtr (*PyUnicode_FromStringAndSize)(const char *, Py_ssize_t);
extern PyObjectPtr (*Py_BuildValue)(const char *, ...);
extern PyObjectPtr (*Py_CompileString)(const char *, const char *, int);
extern void (*Py_DecRef)(PyObjectPtr);
extern void (*Py_IncRef)(PyObjectPtr);
extern void (*Py_InitializeEx)(int);
extern int (*Py_IsFalse)(PyObjectPtr);
extern int (*Py_IsNone)(PyObjectPtr);
extern int (*Py_IsTrue)(PyObjectPtr);
extern void (*Py_SetPythonHome)(const wchar_t *);
extern void (*Py_SetProgramName)(const wchar_t *);

// Opens Python dynamic library at the given path and looks up all
// relevant symbols.
//
// Raises `std::runtime_error` if loading fails.
void load_python_library(std::string path);

// Closes the Python library.
void unload_python_library();

} // namespace pythonx::python
