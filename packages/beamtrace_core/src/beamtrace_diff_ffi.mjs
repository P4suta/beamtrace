// SPDX-License-Identifier: Apache-2.0 OR MIT

import {
  get as dictGet,
  has as dictHas,
  insert as dictInsert,
  make as makeDict,
} from "../gleam_stdlib/dict.mjs";

const fingerprintModulus = 2147483647;

export function signatureCacheNew() {
  return [];
}

export function signatureCachePut(cache, position, signature) {
  cache[position] = signature;
}

export function signatureCacheGet(cache, position) {
  return cache[position];
}

export function signatureCacheDelete(cache) {
  cache.length = 0;
}

// JavaScript string iteration yields Unicode code points, matching Erlang's
// UTF-8 pattern and the previous Gleam UtfCodepoint implementation.
function extendFingerprint(hash, value) {
  for (const character of value) {
    hash = (hash * 131 + character.codePointAt(0)) % fingerprintModulus;
  }
  return hash;
}

function extendJoined(hash, values) {
  let first = true;
  for (const value of values) {
    if (!first) hash = extendFingerprint(hash, ",");
    hash = extendFingerprint(hash, value);
    first = false;
  }
  return hash;
}

function getOr(dict, key, fallback) {
  return dictHas(dict, key) ? dictGet(dict, key)[0] : fallback;
}

function compactRefined(current, before, after) {
  let hash = extendFingerprint(17, String(current));
  hash = extendFingerprint(hash, "<");
  hash = extendJoined(hash, before.map(String));
  hash = extendFingerprint(hash, ">");
  return extendJoined(hash, after.map(String));
}

function neighbors(id, adjacency, fingerprints) {
  const values = [];
  for (const neighbor of getOr(adjacency, id, [])) {
    values.push(getOr(fingerprints, neighbor, 0));
  }
  values.sort((left, right) => {
    const leftString = String(left);
    const rightString = String(right);
    return leftString < rightString ? -1 : leftString > rightString ? 1 : 0;
  });
  return values;
}

export function compactBase(root, signature) {
  let hash = extendFingerprint(17, root);
  hash = extendFingerprint(hash, "|");
  return extendFingerprint(hash, signature);
}

export function refineRound(fingerprints, incoming, outgoing, ids) {
  let next = makeDict();
  for (const id of ids) {
    next = dictInsert(
      next,
      id,
      compactRefined(
        getOr(fingerprints, id, 0),
        neighbors(id, incoming, fingerprints),
        neighbors(id, outgoing, fingerprints),
      ),
    );
  }
  return next;
}
