#!/bin/bash
# Copyright 2019 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################
set -o pipefail -o errexit -o nounset

if [ -n "${DEBUG:-}" ]
then
    # We enable insertion of the full debug symbols:
    CFLAGS=$(echo "$CFLAGS" | sed -e 's/-O1/-O0/' -e 's/-gline-tables-only/-g/')
    CXXFLAGS=$(echo "$CXXFLAGS" | sed -e 's/-O1/-O0/' -e 's/-gline-tables-only/-g/')
    # The following sets the Py_DEBUG macro which - among other things -
    # will remove the -O3 argument from the compiler flags in the Makefile
    CONFIGURE_ARGS=--with-pydebug
fi

export ASAN_OPTIONS=detect_leaks=0

# If /src/cpython3 has been mounted from host, we alias it to /src/cpython,
# else we download the latest sources from GitHub:
if [ -d cpython3/ ]
then
    ln -s cpython3 cpython
else
    git clone --depth 1 https://github.com/python/cpython.git cpython
fi
cd cpython

# This helps a lot when developing new fuzz targets:
# no need to recompile CPython if it has already been done once and exists in $OUT.
if ! [ -n "${NO_CPYTHON_RECOMPILE:-}" ]
then
    rm -rf $OUT/*
    mkdir $OUT/bin
    ./configure ${CONFIGURE_ARGS:-} --without-pymalloc --disable-shared --prefix=$OUT \
        LINKCC="$CXX" LDFLAGS="$CXXFLAGS"
    make -j$(nproc)
    make install
fi

if [ -f $OUT/lib/libpython3.8d.a ] && ! [ -f $OUT/lib/libpython3.8.a ]
then
    mv $OUT/lib/libpython3.8d.a $OUT/lib/libpython3.8.a
fi

# We ensure the compiled binary works:
$OUT/bin/python3 -c 'import math'

# We install extra fuzz targets dependencies, recompiling C extensions with the fuzzer engine flags:
LINKCC="$CXX" LDFLAGS="$CXXFLAGS" $OUT/bin/pip3 install --no-binary :all: -r ../extra_fuzz_targets/requirements.txt
$OUT/bin/python3 -c 'import yaml'
$OUT/bin/python3 -c 'import simplejson'

# We use the Python standard lib as a starting corpus for the fuzz_builtin_exec target:
mkdir -p ../corpus/fuzz_builtin_exec
# We exclude modules whose __main__ entrypoint time out:
cp -r $(find Lib -name '*.py' | grep -Ev '__init__|__main__|crashers|py_compile|pprint') ../corpus/fuzz_builtin_exec || true

function compile_prog () {
    local c_src_filepath="${1?'c_src_filepath 1st arg missing'}"; shift
    local out_prog_name="${1?'out_prog_name 2nd arg mising'}"; shift
    if [ -d ../corpus/$out_prog_name ]
    then
        zip -j $OUT/${out_prog_name}_seed_corpus.zip ../corpus/$out_prog_name/*
    fi
    $CC -D _Py_FUZZ_ONE -D _Py_FUZZ_$fuzz_target $CXXFLAGS $c_src_filepath \
        $OUT/lib/libpython3.8.a $($OUT/bin/python3-config --includes) -Xlinker -export-dynamic -ldl -lutil \
        -lm -lFuzzingEngine -lc++ "$@" -o $OUT/$out_prog_name
}

c_src_filepath=Modules/_xxtestfuzz/fuzzer.c
for fuzz_target in $(cat Modules/_xxtestfuzz/fuzz_tests.txt)
do
    compile_prog $c_src_filepath $fuzz_target

    if [ "$fuzz_target" = "fuzz_builtin_json_decode" ]
    then
        # We use the same corpus:
        cp -r ../corpus/${fuzz_target} ../corpus/fuzz_pypilib_simplejson_decode
        # We compile fuzz_pypilib_simplejson_decode the same way, only specifying JSON_DECODER_MODULE:
        compile_prog $c_src_filepath fuzz_pypilib_simplejson_decode -DJSON_DECODER_MODULE=simplejson.decoder
    fi
done

for c_src_filepath in ../extra_fuzz_targets/*.c
do
    fuzz_target=$(basename $c_src_filepath | sed 's/\.c$//')
    compile_prog $c_src_filepath $fuzz_target
done
