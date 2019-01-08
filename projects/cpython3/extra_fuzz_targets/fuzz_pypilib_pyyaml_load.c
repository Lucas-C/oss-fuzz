/* A fuzz test for https://pyyaml.org/wiki/PyYAMLDocumentation.

  The only exposed function is LLVMFuzzerTestOneInput, which is called by fuzzers.
*/

#include <Python.h>
#include <stdlib.h>
#include <inttypes.h>


static size_t strlen_with_max(const char *str, size_t max) {
    const char *start = str;
    while((str - start) < (long)max && *str) str++;
    return (size_t) (str - start);
}

/*
  Given a char buffer `data` of size `size`,
  returns a new one of length <= `size`, ending with a NULL character,
  but ensured to not contain any other NULL character.
  Its content is identitcal up to the first NULL character met in `data`.

  The returned pointer points to newly "malloc-ed" memory and hence must be "freed". 
 */
static char* truncate_string_to_first_null_character(const char *data, size_t size) {
    const size_t newSize = strlen_with_max(data, size) + 1;
    char* nullTerminatedData = malloc(newSize);
    const size_t copiedSize = (newSize < size) ? newSize : size;
    strncpy(nullTerminatedData, data, copiedSize);
    nullTerminatedData[newSize - 1] = '\0';
    return nullTerminatedData;
}


/* Fuzz test interface. Calls: yaml.load_all(data)

   All fuzz tests must return 0, as all nonzero return codes are reserved for future use
*/
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size <= 0) return 0;
    char* nullTerminatedData = truncate_string_to_first_null_character((const char*) data, size);

    PyObject *args, *pyyamlModule, *loadFunction;

    if (!Py_IsInitialized()) {
        /* LLVMFuzzerTestOneInput is called repeatedly from the same process,
           with no separate initialization phase, sadly, so we need to
           initialize CPython ourselves on the first run. */
        Py_InitializeEx(0);
    }

    pyyamlModule = PyImport_ImportModule("yaml");
    if (PyErr_Occurred()) {
        // An import error here is abnormal, we print the message:
        PyErr_Print();
        PyErr_Clear();
        return 0;
    }

    loadFunction = PyObject_GetAttrString(pyyamlModule, "load_all");
    Py_DECREF(pyyamlModule);

    args = Py_BuildValue("(s)", nullTerminatedData);
    if (PyErr_Occurred() != NULL) {
        PyErr_Clear();
    } else {
        PyEval_CallObject(loadFunction, args);
        if (PyErr_Occurred() != NULL) {
            PyErr_Clear();
        }
        Py_DECREF(args);
    }
    Py_DECREF(loadFunction);

    free(nullTerminatedData);
    return 0;
}
