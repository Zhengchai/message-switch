#!/bin/bash

set -ex

COVERAGE_DIR=.coverage
rm -rf $COVERAGE_DIR
mkdir -p $COVERAGE_DIR
pushd $COVERAGE_DIR
if [ -z "$KEEP" ]; then trap "popd; rm -rf $COVERAGE_DIR" EXIT; fi

$(which cp) -r ../* .

opam pin add bisect_ppx 1.3.3 -y
opam install ocveralls -y

# install test deps
opam install message-switch-async cohttp-async -y

export BISECT_ENABLE=YES
jbuilder runtest

outs=($(find . | grep bisect.*.out))
bisect-ppx-report -I $(dirname ${outs[1]}) -text report ${outs[@]}
bisect-ppx-report -I $(dirname ${outs[1]}) -summary-only -text summary ${outs[@]}
if [ -n "$HTML" ]; then bisect-ppx-report -I $(dirname ${outs[1]}) -html ../html-report ${outs[@]}; fi

if [ -n "$TRAVIS" ]; then
  echo "\$TRAVIS set; running ocveralls and sending to coveralls.io..."
  ocveralls --prefix _build/default ${outs[@]} --send
else
  echo "\$TRAVIS not set; displaying results of bisect-report..."
  cat report
  cat summary
fi
