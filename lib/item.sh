#!/usr/bin/env bash
# The one place that knows the shape of a manifest item (schema/manifest.schema.json, docs/manifest.md).
# Scanners build items with item_json, or with ITEM_JQ_DEF inside their own bulk jq program; they never spell the
# field names themselves, so a schema change touches this file only.
# shellcheck shell=bash

# jq definition: mkitem($id; $name; $kind; $category; $risk; $install; $version; $method; $conf; $private; $evidence).
# $version "" or null becomes null. Prepend it to a jq program that wants to emit items in bulk.
# shellcheck disable=SC2016 # jq source, not shell
ITEM_JQ_DEF='def mkitem($id; $name; $kind; $category; $risk; $install; $version; $method; $conf; $private; $evidence):
  {id: $id, name: $name, kind: $kind, category: $category, risk: $risk, install: $install,
   version: (if $version == "" then null else $version end),
   provenance: {method: $method, confidence: $conf, evidence: $evidence},
   private: $private};'

# item_json ID NAME KIND CATEGORY RISK INSTALL_JSON VERSION METHOD CONFIDENCE PRIVATE [EVIDENCE...] : one compact item.
# INSTALL_JSON is the install descriptor as JSON; VERSION may be empty (null); PRIVATE is true or false.
# shellcheck disable=SC2016 # jq source, not shell
item_json() {
  local id=$1 name=$2 kind=$3 category=$4 risk=$5 install=$6 version=$7 method=$8 conf=$9 private=${10}
  shift 10
  jq -nc --arg id "$id" --arg name "$name" --arg kind "$kind" --arg category "$category" --arg risk "$risk" \
    --argjson install "$install" --arg version "$version" --arg method "$method" --argjson conf "$conf" \
    --argjson private "$private" --args "$ITEM_JQ_DEF"'
    mkitem($id; $name; $kind; $category; $risk; $install; $version; $method; $conf; $private; $ARGS.positional)' -- "$@"
}

# items_join [JSON...] : the arguments (each a JSON value, usually an item) as one compact JSON array; [] for none
items_join() {
  if (($#)); then printf '%s\n' "$@" | jq -sc '.'; else echo '[]'; fi
}

# json_strings [STR...] : the arguments as a compact JSON array of strings
# shellcheck disable=SC2016 # jq source, not shell
json_strings() { jq -nc '$ARGS.positional' --args -- "$@"; }
