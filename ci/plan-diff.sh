#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The diff program ci/plan.sh gives `kubectl diff` (KUBECTL_EXTERNAL_DIFF): it prints the unified diff of each
# object that differs, and appends "add|change|remove <object>" for each to PLAN_OBJECTS, where <object> is
# kubectl's file name for it (group.version.Kind.namespace.name). Exit 1 when anything differs, as diff does.
#
#   KUBECTL_EXTERNAL_DIFF=ci/plan-diff.sh PLAN_OBJECTS=FILE kubectl diff -f ...
set -uo pipefail
live=${1:?usage: plan-diff.sh LIVE MERGED} merged=${2:?usage: plan-diff.sh LIVE MERGED}
objects=${PLAN_OBJECTS:?PLAN_OBJECTS is not set}
status=0
for name in $( (ls "$live"; ls "$merged") | sort -u); do
  if [ ! -e "$live/$name" ]; then what=add
  elif [ ! -e "$merged/$name" ]; then what=remove
  elif cmp -s "$live/$name" "$merged/$name"; then continue
  else what=change
  fi
  echo "$what $name" >> "$objects"
  diff -u -N --label "live/$name" --label "render/$name" "$live/$name" "$merged/$name"
  status=1
done
exit "$status"
