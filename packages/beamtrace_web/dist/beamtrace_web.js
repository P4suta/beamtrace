// build/dev/javascript/prelude.mjs
class CustomType {
  withFields(fields) {
    let properties = Object.keys(this).map((label) => (label in fields) ? fields[label] : this[label]);
    return new this.constructor(...properties);
  }
}

class List {
  static fromArray(array, tail) {
    return toList(array, tail);
  }
  [Symbol.iterator]() {
    return new ListIterator(this);
  }
  toArray() {
    return [...this];
  }
  atLeastLength(desired) {
    let current = this;
    while (desired-- > 0 && current)
      current = current.tail;
    return current !== undefined;
  }
  hasLength(desired) {
    let current = this;
    while (desired-- > 0 && current)
      current = current.tail;
    return desired === -1 && current instanceof Empty;
  }
  countLength() {
    let current = this;
    let length = 0;
    while (current) {
      current = current.tail;
      length++;
    }
    return length - 1;
  }
}
function prepend(element, tail) {
  return new NonEmpty(element, tail);
}
function toList(elements, tail) {
  let t = tail || List$Empty$const;
  for (let i = elements.length - 1;i >= 0; --i) {
    t = new NonEmpty(elements[i], t);
  }
  return t;
}

class ListIterator {
  #current;
  constructor(current) {
    this.#current = current;
  }
  next() {
    if (this.#current instanceof Empty) {
      return { done: true };
    } else {
      let { head, tail } = this.#current;
      this.#current = tail;
      return { value: head, done: false };
    }
  }
}

class Empty extends List {
}
var List$Empty$const = new Empty;
var List$Empty = () => List$Empty$const;
var List$isEmpty = (value) => value instanceof Empty;

class NonEmpty extends List {
  constructor(head, tail) {
    super();
    this.head = head;
    this.tail = tail;
  }
}
var List$NonEmpty = (head, tail) => new NonEmpty(head, tail);
var List$isNonEmpty = (value) => value instanceof NonEmpty;
var List$NonEmpty$first = (value) => value.head;
var List$NonEmpty$rest = (value) => value.tail;

class BitArray {
  bitSize;
  byteSize;
  bitOffset;
  rawBuffer;
  constructor(buffer, bitSize, bitOffset) {
    if (!(buffer instanceof Uint8Array)) {
      throw globalThis.Error("BitArray can only be constructed from a Uint8Array");
    }
    this.bitSize = bitSize ?? buffer.length * 8;
    this.byteSize = Math.trunc((this.bitSize + 7) / 8);
    this.bitOffset = bitOffset ?? 0;
    if (this.bitSize < 0) {
      throw globalThis.Error(`BitArray bit size is invalid: ${this.bitSize}`);
    }
    if (this.bitOffset < 0 || this.bitOffset > 7) {
      throw globalThis.Error(`BitArray bit offset is invalid: ${this.bitOffset}`);
    }
    if (buffer.length !== Math.trunc((this.bitOffset + this.bitSize + 7) / 8)) {
      throw globalThis.Error("BitArray buffer length is invalid");
    }
    this.rawBuffer = buffer;
  }
  byteAt(index) {
    if (index < 0 || index >= this.byteSize) {
      return;
    }
    return bitArrayByteAt(this.rawBuffer, this.bitOffset, index);
  }
  equals(other) {
    if (this.bitSize !== other.bitSize) {
      return false;
    }
    const wholeByteCount = Math.trunc(this.bitSize / 8);
    if (this.bitOffset === 0 && other.bitOffset === 0) {
      for (let i = 0;i < wholeByteCount; i++) {
        if (this.rawBuffer[i] !== other.rawBuffer[i]) {
          return false;
        }
      }
      const trailingBitsCount = this.bitSize % 8;
      if (trailingBitsCount) {
        const unusedLowBitCount = 8 - trailingBitsCount;
        if (this.rawBuffer[wholeByteCount] >> unusedLowBitCount !== other.rawBuffer[wholeByteCount] >> unusedLowBitCount) {
          return false;
        }
      }
    } else {
      for (let i = 0;i < wholeByteCount; i++) {
        const a = bitArrayByteAt(this.rawBuffer, this.bitOffset, i);
        const b = bitArrayByteAt(other.rawBuffer, other.bitOffset, i);
        if (a !== b) {
          return false;
        }
      }
      const trailingBitsCount = this.bitSize % 8;
      if (trailingBitsCount) {
        const a = bitArrayByteAt(this.rawBuffer, this.bitOffset, wholeByteCount);
        const b = bitArrayByteAt(other.rawBuffer, other.bitOffset, wholeByteCount);
        const unusedLowBitCount = 8 - trailingBitsCount;
        if (a >> unusedLowBitCount !== b >> unusedLowBitCount) {
          return false;
        }
      }
    }
    return true;
  }
  get buffer() {
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error("BitArray.buffer does not support unaligned bit arrays");
    }
    return this.rawBuffer;
  }
  get length() {
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error("BitArray.length does not support unaligned bit arrays");
    }
    return this.rawBuffer.length;
  }
}
function bitArrayByteAt(buffer, bitOffset, index) {
  if (bitOffset === 0) {
    return buffer[index] ?? 0;
  } else {
    const a = buffer[index] << bitOffset & 255;
    const b = buffer[index + 1] >> 8 - bitOffset;
    return a | b;
  }
}

class UtfCodepoint {
  constructor(value) {
    this.value = value;
  }
}
class Result extends CustomType {
  static isResult(data) {
    return data instanceof Result;
  }
}

class Ok extends Result {
  constructor(value) {
    super();
    this[0] = value;
  }
  isOk() {
    return true;
  }
}
var Result$Ok = (value) => new Ok(value);
var Result$isOk = (value) => value instanceof Ok;
var Result$Ok$0 = (value) => value[0];

class Error2 extends Result {
  constructor(detail) {
    super();
    this[0] = detail;
  }
  isOk() {
    return false;
  }
}
var Result$Error = (detail) => new Error2(detail);
var Result$isError = (value) => value instanceof Error2;
function isEqual(x, y) {
  let values = [x, y];
  while (values.length) {
    let a = values.pop();
    let b = values.pop();
    if (a === b)
      continue;
    if (!isObject(a) || !isObject(b))
      return false;
    let unequal = !structurallyCompatibleObjects(a, b) || unequalDates(a, b) || unequalBuffers(a, b) || unequalArrays(a, b) || unequalMaps(a, b) || unequalSets(a, b) || unequalRegExps(a, b);
    if (unequal)
      return false;
    const proto = Object.getPrototypeOf(a);
    if (proto !== null && typeof proto.equals === "function") {
      try {
        if (a.equals(b))
          continue;
        else
          return false;
      } catch {}
    }
    let [keys, get] = getters(a);
    const ka = keys(a);
    const kb = keys(b);
    if (ka.length !== kb.length)
      return false;
    for (let k of ka) {
      values.push(get(a, k), get(b, k));
    }
  }
  return true;
}
function getters(object) {
  if (object instanceof Map) {
    return [(x) => x.keys(), (x, y) => x.get(y)];
  } else {
    let extra = object instanceof globalThis.Error ? ["message"] : [];
    return [(x) => [...extra, ...Object.keys(x)], (x, y) => x[y]];
  }
}
function unequalDates(a, b) {
  return a instanceof Date && (a > b || a < b);
}
function unequalBuffers(a, b) {
  return !(a instanceof BitArray) && a.buffer instanceof ArrayBuffer && a.BYTES_PER_ELEMENT && !(a.byteLength === b.byteLength && a.every((n, i) => n === b[i]));
}
function unequalArrays(a, b) {
  return Array.isArray(a) && a.length !== b.length;
}
function unequalMaps(a, b) {
  return a instanceof Map && a.size !== b.size;
}
function unequalSets(a, b) {
  return a instanceof Set && (a.size != b.size || [...a].some((e) => !b.has(e)));
}
function unequalRegExps(a, b) {
  return a instanceof RegExp && (a.source !== b.source || a.flags !== b.flags);
}
function isObject(a) {
  return typeof a === "object" && a !== null;
}
function structurallyCompatibleObjects(a, b) {
  if (typeof a !== "object" && typeof b !== "object" && (!a || !b))
    return false;
  let nonstructural = [Promise, WeakSet, WeakMap, Function];
  if (nonstructural.some((c) => a instanceof c))
    return false;
  return a.constructor === b.constructor;
}
function makeError(variant, file, module, line, fn, message, extra) {
  let error = new globalThis.Error(message);
  error.gleam_error = variant;
  error.file = file;
  error.module = module;
  error.line = line;
  error.function = fn;
  error.fn = fn;
  for (let k in extra)
    error[k] = extra[k];
  return error;
}
// build/dev/javascript/gleam_stdlib/gleam/option.mjs
class Some extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
var Option$isSome = (value) => value instanceof Some;
var Option$Some$0 = (value) => value[0];

class None extends CustomType {
}
var Option$None$const = new None;

// build/dev/javascript/gleam_stdlib/dict.mjs
var referenceMap = /* @__PURE__ */ new WeakMap;
var tempDataView = /* @__PURE__ */ new DataView(/* @__PURE__ */ new ArrayBuffer(8));
var referenceUID = 0;
function hashByReference(o) {
  const known = referenceMap.get(o);
  if (known !== undefined) {
    return known;
  }
  const hash = referenceUID++;
  if (referenceUID === 2147483647) {
    referenceUID = 0;
  }
  referenceMap.set(o, hash);
  return hash;
}
function hashMerge(a, b) {
  return a ^ b + 2654435769 + (a << 6) + (a >> 2) | 0;
}
function hashString(s) {
  let hash = 0;
  const len = s.length;
  for (let i = 0;i < len; i++) {
    hash = Math.imul(31, hash) + s.charCodeAt(i) | 0;
  }
  return hash;
}
function hashNumber(n) {
  tempDataView.setFloat64(0, n);
  const i = tempDataView.getInt32(0);
  const j = tempDataView.getInt32(4);
  return Math.imul(73244475, i >> 16 ^ i) ^ j;
}
function hashBigInt(n) {
  return hashString(n.toString());
}
function hashObject(o) {
  const proto = Object.getPrototypeOf(o);
  if (proto !== null && typeof proto.hashCode === "function") {
    try {
      const code = o.hashCode(o);
      if (typeof code === "number") {
        return code;
      }
    } catch {}
  }
  if (o instanceof Promise || o instanceof WeakSet || o instanceof WeakMap) {
    return hashByReference(o);
  }
  if (o instanceof Date) {
    return hashNumber(o.getTime());
  }
  let h = 0;
  if (o instanceof ArrayBuffer) {
    o = new Uint8Array(o);
  }
  if (Array.isArray(o) || o instanceof Uint8Array) {
    for (let i = 0;i < o.length; i++) {
      h = Math.imul(31, h) + getHash(o[i]) | 0;
    }
  } else if (o instanceof Set) {
    o.forEach((v) => {
      h = h + getHash(v) | 0;
    });
  } else if (o instanceof Map) {
    o.forEach((v, k) => {
      h = h + hashMerge(getHash(v), getHash(k)) | 0;
    });
  } else {
    const keys = Object.keys(o);
    for (let i = 0;i < keys.length; i++) {
      const k = keys[i];
      const v = o[k];
      h = h + hashMerge(getHash(v), hashString(k)) | 0;
    }
  }
  return h;
}
function getHash(u) {
  if (u === null)
    return 1108378658;
  if (u === undefined)
    return 1108378659;
  if (u === true)
    return 1108378657;
  if (u === false)
    return 1108378656;
  switch (typeof u) {
    case "number":
      return hashNumber(u);
    case "string":
      return hashString(u);
    case "bigint":
      return hashBigInt(u);
    case "object":
      return hashObject(u);
    case "symbol":
      return hashByReference(u);
    case "function":
      return hashByReference(u);
    default:
      return 0;
  }
}

class Dict {
  constructor(size, root) {
    this.size = size;
    this.root = root;
  }
}
var bits = 5;
var mask = (1 << bits) - 1;
var noElementMarker = Symbol();

class Node {
  constructor(generation, datamap, nodemap, data) {
    this.datamap = datamap;
    this.nodemap = nodemap;
    this.data = data;
    this.generation = generation;
  }
  equals(other) {
    if (this === other)
      return true;
    if (!(other instanceof Node))
      return false;
    if (this.datamap !== other.datamap || this.nodemap !== other.nodemap) {
      return false;
    }
    const leftData = this.data;
    const rightData = other.data;
    if (leftData.length !== rightData.length)
      return false;
    if (this.datamap === 0 && this.nodemap === 0) {
      return this.#equalsOverflowEntries(rightData);
    }
    const edgesStart = leftData.length - popcount(this.nodemap);
    for (let i = 0;i < edgesStart; i += 2) {
      if (!isEqual(leftData[i], rightData[i]) || !isEqual(leftData[i + 1], rightData[i + 1])) {
        return false;
      }
    }
    for (let i = edgesStart;i < leftData.length; ++i) {
      if (!leftData[i].equals(rightData[i]))
        return false;
    }
    return true;
  }
  #equalsOverflowEntries(otherData) {
    const data = this.data;
    entries:
      for (let i = 0;i < data.length; i += 2) {
        for (let j = 0;j < otherData.length; j += 2) {
          if (isEqual(data[i], otherData[j])) {
            if (!isEqual(data[i + 1], otherData[j + 1]))
              return false;
            continue entries;
          }
        }
        return false;
      }
    return true;
  }
  hashCode() {
    const data = this.data;
    const edgesStart = data.length - popcount(this.nodemap);
    let hash = 0;
    for (let i = 0;i < edgesStart; i += 2) {
      hash = hash + hashMerge(getHash(data[i + 1]), getHash(data[i])) | 0;
    }
    for (let i = edgesStart;i < data.length; ++i) {
      hash = hash + data[i].hashCode() | 0;
    }
    return hash;
  }
}
var emptyNode = /* @__PURE__ */ newNode(0);
var emptyDict = /* @__PURE__ */ new Dict(0, emptyNode);
var errorNil = /* @__PURE__ */ Result$Error(undefined);
function newNode(generation) {
  return new Node(generation, 0, 0, []);
}
function copyNode(node, generation) {
  if (node.generation === generation) {
    return node;
  }
  const newData = node.data.slice(0);
  return new Node(generation, node.datamap, node.nodemap, newData);
}
function copyAndSet(node, generation, idx, val) {
  if (node.data[idx] === val) {
    return node;
  }
  node = copyNode(node, generation);
  node.data[idx] = val;
  return node;
}
function copyAndInsertPair(node, generation, bit, idx, key, val) {
  const data = node.data;
  const length = data.length;
  const newData = new Array(length + 2);
  let readIndex = 0;
  let writeIndex = 0;
  while (readIndex < idx)
    newData[writeIndex++] = data[readIndex++];
  newData[writeIndex++] = key;
  newData[writeIndex++] = val;
  while (readIndex < length)
    newData[writeIndex++] = data[readIndex++];
  return new Node(generation, node.datamap | bit, node.nodemap, newData);
}
function copyAndRemovePair(node, generation, bit, idx) {
  node = copyNode(node, generation);
  const data = node.data;
  const length = data.length;
  for (let w = idx, r = idx + 2;r < length; ++r, ++w) {
    data[w] = data[r];
  }
  data.pop();
  data.pop();
  node.datamap ^= bit;
  return node;
}
function make() {
  return emptyDict;
}
function get(dict, key) {
  const result = lookup(dict.root, key, getHash(key));
  return result !== noElementMarker ? Result$Ok(result) : errorNil;
}
function lookup(node, key, hash) {
  for (let shift = 0;shift < 32; shift += bits) {
    const data = node.data;
    const bit = hashbit(hash, shift);
    if (node.nodemap & bit) {
      node = data[data.length - 1 - index(node.nodemap, bit)];
    } else if (node.datamap & bit) {
      const dataidx = Math.imul(index(node.datamap, bit), 2);
      return isEqual(key, data[dataidx]) ? data[dataidx + 1] : noElementMarker;
    } else {
      return noElementMarker;
    }
  }
  const overflow = node.data;
  for (let i = 0;i < overflow.length; i += 2) {
    if (isEqual(key, overflow[i])) {
      return overflow[i + 1];
    }
  }
  return noElementMarker;
}
function toTransient(dict) {
  return {
    generation: nextGeneration(dict),
    root: dict.root,
    size: dict.size,
    dict
  };
}
function fromTransient(transient) {
  if (transient.root === transient.dict.root) {
    return transient.dict;
  }
  return new Dict(transient.size, transient.root);
}
function nextGeneration(dict) {
  const root = dict.root;
  if (root.generation < Number.MAX_SAFE_INTEGER) {
    return root.generation + 1;
  }
  const queue = [root];
  while (queue.length) {
    const node = queue.pop();
    node.generation = 0;
    const nodeStart = node.data.length - popcount(node.nodemap);
    for (let i = nodeStart;i < node.data.length; ++i) {
      queue.push(node.data[i]);
    }
  }
  return 1;
}
var globalTransient = /* @__PURE__ */ toTransient(emptyDict);
function insert(dict, key, value) {
  globalTransient.generation = nextGeneration(dict);
  globalTransient.size = dict.size;
  const hash = getHash(key);
  const root = insertIntoNode(globalTransient, dict.root, key, value, hash, 0);
  if (root === dict.root) {
    return dict;
  }
  return new Dict(globalTransient.size, root);
}
function insertIntoNode(transient, node, key, value, hash, shift) {
  const data = node.data;
  const generation = transient.generation;
  if (shift > 32) {
    for (let i = 0;i < data.length; i += 2) {
      if (isEqual(key, data[i])) {
        return copyAndSet(node, generation, i + 1, value);
      }
    }
    transient.size += 1;
    return copyAndInsertPair(node, generation, 0, data.length, key, value);
  }
  const bit = hashbit(hash, shift);
  if (node.nodemap & bit) {
    const nodeidx2 = data.length - 1 - index(node.nodemap, bit);
    let child2 = data[nodeidx2];
    child2 = insertIntoNode(transient, child2, key, value, hash, shift + bits);
    return copyAndSet(node, generation, nodeidx2, child2);
  }
  const dataidx = Math.imul(index(node.datamap, bit), 2);
  if ((node.datamap & bit) === 0) {
    transient.size += 1;
    return copyAndInsertPair(node, generation, bit, dataidx, key, value);
  }
  if (isEqual(key, data[dataidx])) {
    return copyAndSet(node, generation, dataidx + 1, value);
  }
  const childShift = shift + bits;
  let child = emptyNode;
  child = insertIntoNode(transient, child, key, value, hash, childShift);
  const key2 = data[dataidx];
  const value2 = data[dataidx + 1];
  const hash2 = getHash(key2);
  child = insertIntoNode(transient, child, key2, value2, hash2, childShift);
  transient.size -= 1;
  const length = data.length;
  const nodeidx = length - 1 - index(node.nodemap, bit);
  const newData = new Array(length - 1);
  let readIndex = 0;
  let writeIndex = 0;
  while (readIndex < dataidx)
    newData[writeIndex++] = data[readIndex++];
  readIndex += 2;
  while (readIndex <= nodeidx)
    newData[writeIndex++] = data[readIndex++];
  newData[writeIndex++] = child;
  while (readIndex < length)
    newData[writeIndex++] = data[readIndex++];
  return new Node(generation, node.datamap ^ bit, node.nodemap | bit, newData);
}
function destructiveTransientDelete(key, transient) {
  const hash = getHash(key);
  transient.root = deleteFromNode(transient, transient.root, key, hash, 0);
  return transient;
}
function deleteFromNode(transient, node, key, hash, shift) {
  const data = node.data;
  const generation = transient.generation;
  if (shift > 32) {
    for (let i = 0;i < data.length; i += 2) {
      if (isEqual(key, data[i])) {
        transient.size -= 1;
        return copyAndRemovePair(node, generation, 0, i);
      }
    }
    return node;
  }
  const bit = hashbit(hash, shift);
  const dataidx = Math.imul(index(node.datamap, bit), 2);
  if ((node.nodemap & bit) !== 0) {
    const nodeidx = data.length - 1 - index(node.nodemap, bit);
    let child = data[nodeidx];
    child = deleteFromNode(transient, child, key, hash, shift + bits);
    if (child.nodemap !== 0 || child.data.length > 2) {
      return copyAndSet(node, generation, nodeidx, child);
    }
    const length = data.length;
    const newData = new Array(length + 1);
    let readIndex = 0;
    let writeIndex = 0;
    while (readIndex < dataidx)
      newData[writeIndex++] = data[readIndex++];
    newData[writeIndex++] = child.data[0];
    newData[writeIndex++] = child.data[1];
    while (readIndex < nodeidx)
      newData[writeIndex++] = data[readIndex++];
    readIndex++;
    while (readIndex < length)
      newData[writeIndex++] = data[readIndex++];
    return new Node(generation, node.datamap | bit, node.nodemap ^ bit, newData);
  }
  if ((node.datamap & bit) === 0 || !isEqual(key, data[dataidx])) {
    return node;
  }
  transient.size -= 1;
  return copyAndRemovePair(node, generation, bit, dataidx);
}
function fold(dict, state, fun) {
  const queue = [dict.root];
  while (queue.length) {
    const node = queue.pop();
    const data = node.data;
    const edgesStart = data.length - popcount(node.nodemap);
    for (let i = 0;i < edgesStart; i += 2) {
      state = fun(state, data[i], data[i + 1]);
    }
    for (let i = edgesStart;i < data.length; ++i) {
      queue.push(data[i]);
    }
  }
  return state;
}
function popcount(n) {
  n -= n >>> 1 & 1431655765;
  n = (n & 858993459) + (n >>> 2 & 858993459);
  return Math.imul(n + (n >>> 4) & 252645135, 16843009) >>> 24;
}
function index(bitmap, bit) {
  return popcount(bitmap & bit - 1);
}
function hashbit(hash, shift) {
  return 1 << (hash >>> shift & mask);
}

// build/dev/javascript/gleam_stdlib/gleam/dict.mjs
function keys(dict) {
  return fold(dict, List$Empty$const, (acc, key, _) => {
    return prepend(key, acc);
  });
}
function delete$(dict, key) {
  let _pipe = toTransient(dict);
  let _pipe$1 = ((_capture) => {
    return destructiveTransientDelete(key, _capture);
  })(_pipe);
  return fromTransient(_pipe$1);
}

// build/dev/javascript/gleam_stdlib/gleam/order.mjs
class Lt extends CustomType {
}
var Order$Lt$const = new Lt;
var Order$Lt = () => Order$Lt$const;
class Eq extends CustomType {
}
var Order$Eq$const = new Eq;
var Order$Eq = () => Order$Eq$const;
class Gt extends CustomType {
}
var Order$Gt$const = new Gt;
var Order$Gt = () => Order$Gt$const;

// build/dev/javascript/gleam_stdlib/gleam/float.mjs
function max(a, b) {
  let $ = a > b;
  if ($) {
    return a;
  } else {
    return b;
  }
}
function min(a, b) {
  let $ = a < b;
  if ($) {
    return a;
  } else {
    return b;
  }
}
function clamp(x, min_bound, max_bound) {
  let $ = min_bound >= max_bound;
  if ($) {
    let _pipe = x;
    let _pipe$1 = min(_pipe, min_bound);
    return max(_pipe$1, max_bound);
  } else {
    let _pipe = x;
    let _pipe$1 = min(_pipe, max_bound);
    return max(_pipe$1, min_bound);
  }
}

// build/dev/javascript/gleam_stdlib/gleam/int.mjs
function max2(a, b) {
  let $ = a > b;
  if ($) {
    return a;
  } else {
    return b;
  }
}
function min2(a, b) {
  let $ = a < b;
  if ($) {
    return a;
  } else {
    return b;
  }
}

// build/dev/javascript/gleam_stdlib/gleam/list.mjs
class Ascending extends CustomType {
}
var Sorting$Ascending$const = new Ascending;

class Descending extends CustomType {
}
var Sorting$Descending$const = new Descending;
function length_loop(loop$list, loop$count) {
  while (true) {
    let list = loop$list;
    let count = loop$count;
    if (list instanceof Empty) {
      return count;
    } else {
      let list$1 = list.tail;
      loop$list = list$1;
      loop$count = count + 1;
    }
  }
}
function length(list) {
  return length_loop(list, 0);
}
function reverse_and_prepend(loop$prefix, loop$suffix) {
  while (true) {
    let prefix = loop$prefix;
    let suffix = loop$suffix;
    if (prefix instanceof Empty) {
      return suffix;
    } else {
      let first$1 = prefix.head;
      let rest$1 = prefix.tail;
      loop$prefix = rest$1;
      loop$suffix = prepend(first$1, suffix);
    }
  }
}
function reverse(list) {
  return reverse_and_prepend(list, List$Empty$const);
}
function contains(loop$list, loop$elem) {
  while (true) {
    let list = loop$list;
    let elem = loop$elem;
    if (list instanceof Empty) {
      return false;
    } else {
      let first$1 = list.head;
      if (isEqual(first$1, elem)) {
        return true;
      } else {
        let rest$1 = list.tail;
        loop$list = rest$1;
        loop$elem = elem;
      }
    }
  }
}
function filter_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list instanceof Empty) {
      return reverse(acc);
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      let _block;
      let $ = fun(first$1);
      if ($) {
        _block = prepend(first$1, acc);
      } else {
        _block = acc;
      }
      let new_acc = _block;
      loop$list = rest$1;
      loop$fun = fun;
      loop$acc = new_acc;
    }
  }
}
function filter(list, predicate) {
  return filter_loop(list, predicate, List$Empty$const);
}
function map_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list instanceof Empty) {
      return reverse(acc);
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      loop$list = rest$1;
      loop$fun = fun;
      loop$acc = prepend(fun(first$1), acc);
    }
  }
}
function map2(list, fun) {
  return map_loop(list, fun, List$Empty$const);
}
function drop(loop$list, loop$n) {
  while (true) {
    let list = loop$list;
    let n = loop$n;
    let $ = n <= 0;
    if ($) {
      return list;
    } else {
      if (list instanceof Empty) {
        return list;
      } else {
        let rest$1 = list.tail;
        loop$list = rest$1;
        loop$n = n - 1;
      }
    }
  }
}
function take_loop(loop$list, loop$n, loop$acc) {
  while (true) {
    let list = loop$list;
    let n = loop$n;
    let acc = loop$acc;
    let $ = n <= 0;
    if ($) {
      return reverse(acc);
    } else {
      if (list instanceof Empty) {
        return reverse(acc);
      } else {
        let first$1 = list.head;
        let rest$1 = list.tail;
        loop$list = rest$1;
        loop$n = n - 1;
        loop$acc = prepend(first$1, acc);
      }
    }
  }
}
function take(list, n) {
  return take_loop(list, n, List$Empty$const);
}
function append_loop(loop$first, loop$second) {
  while (true) {
    let first = loop$first;
    let second = loop$second;
    if (first instanceof Empty) {
      return second;
    } else {
      let first$1 = first.head;
      let rest$1 = first.tail;
      loop$first = rest$1;
      loop$second = prepend(first$1, second);
    }
  }
}
function append(first, second) {
  return append_loop(reverse(first), second);
}
function prepend2(list, item) {
  return prepend(item, list);
}
function flatten_loop(loop$lists, loop$acc) {
  while (true) {
    let lists = loop$lists;
    let acc = loop$acc;
    if (lists instanceof Empty) {
      return reverse(acc);
    } else {
      let list = lists.head;
      let further_lists = lists.tail;
      loop$lists = further_lists;
      loop$acc = reverse_and_prepend(list, acc);
    }
  }
}
function flatten(lists) {
  return flatten_loop(lists, List$Empty$const);
}
function flat_map(list, fun) {
  return flatten(map2(list, fun));
}
function fold2(loop$list, loop$initial, loop$fun) {
  while (true) {
    let list = loop$list;
    let initial = loop$initial;
    let fun = loop$fun;
    if (list instanceof Empty) {
      return initial;
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      loop$list = rest$1;
      loop$initial = fun(initial, first$1);
      loop$fun = fun;
    }
  }
}
function find(loop$list, loop$is_desired) {
  while (true) {
    let list = loop$list;
    let is_desired = loop$is_desired;
    if (list instanceof Empty) {
      return new Error2(undefined);
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      let $ = is_desired(first$1);
      if ($) {
        return new Ok(first$1);
      } else {
        loop$list = rest$1;
        loop$is_desired = is_desired;
      }
    }
  }
}
function all(loop$list, loop$predicate) {
  while (true) {
    let list = loop$list;
    let predicate = loop$predicate;
    if (list instanceof Empty) {
      return true;
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      let $ = predicate(first$1);
      if ($) {
        loop$list = rest$1;
        loop$predicate = predicate;
      } else {
        return $;
      }
    }
  }
}
function any(loop$list, loop$predicate) {
  while (true) {
    let list = loop$list;
    let predicate = loop$predicate;
    if (list instanceof Empty) {
      return false;
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      let $ = predicate(first$1);
      if ($) {
        return $;
      } else {
        loop$list = rest$1;
        loop$predicate = predicate;
      }
    }
  }
}
function merge_descendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare2 = loop$compare;
    let acc = loop$acc;
    if (list1 instanceof Empty) {
      let list = list2;
      return reverse_and_prepend(list, acc);
    } else if (list2 instanceof Empty) {
      let list = list1;
      return reverse_and_prepend(list, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list2.head;
      let rest2 = list2.tail;
      let $ = compare2(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare2;
        loop$acc = prepend(first2, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare2;
        loop$acc = prepend(first1, acc);
      } else {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare2;
        loop$acc = prepend(first1, acc);
      }
    }
  }
}
function merge_descending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences = loop$sequences;
    let compare2 = loop$compare;
    let acc = loop$acc;
    if (sequences instanceof Empty) {
      return reverse(acc);
    } else {
      let $ = sequences.tail;
      if ($ instanceof Empty) {
        let sequence = sequences.head;
        return reverse(prepend(reverse(sequence), acc));
      } else {
        let descending1 = sequences.head;
        let descending2 = $.head;
        let rest$1 = $.tail;
        let ascending = merge_descendings(descending1, descending2, compare2, List$Empty$const);
        loop$sequences = rest$1;
        loop$compare = compare2;
        loop$acc = prepend(ascending, acc);
      }
    }
  }
}
function merge_ascendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare2 = loop$compare;
    let acc = loop$acc;
    if (list1 instanceof Empty) {
      let list = list2;
      return reverse_and_prepend(list, acc);
    } else if (list2 instanceof Empty) {
      let list = list1;
      return reverse_and_prepend(list, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list2.head;
      let rest2 = list2.tail;
      let $ = compare2(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare2;
        loop$acc = prepend(first1, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare2;
        loop$acc = prepend(first2, acc);
      } else {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare2;
        loop$acc = prepend(first2, acc);
      }
    }
  }
}
function merge_ascending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences = loop$sequences;
    let compare2 = loop$compare;
    let acc = loop$acc;
    if (sequences instanceof Empty) {
      return reverse(acc);
    } else {
      let $ = sequences.tail;
      if ($ instanceof Empty) {
        let sequence = sequences.head;
        return reverse(prepend(reverse(sequence), acc));
      } else {
        let ascending1 = sequences.head;
        let ascending2 = $.head;
        let rest$1 = $.tail;
        let descending = merge_ascendings(ascending1, ascending2, compare2, List$Empty$const);
        loop$sequences = rest$1;
        loop$compare = compare2;
        loop$acc = prepend(descending, acc);
      }
    }
  }
}
function merge_all(loop$sequences, loop$direction, loop$compare) {
  while (true) {
    let sequences = loop$sequences;
    let direction = loop$direction;
    let compare2 = loop$compare;
    if (sequences instanceof Empty) {
      return sequences;
    } else if (direction instanceof Ascending) {
      let $ = sequences.tail;
      if ($ instanceof Empty) {
        let sequence = sequences.head;
        return sequence;
      } else {
        let sequences$1 = merge_ascending_pairs(sequences, compare2, List$Empty$const);
        loop$sequences = sequences$1;
        loop$direction = Sorting$Descending$const;
        loop$compare = compare2;
      }
    } else {
      let $ = sequences.tail;
      if ($ instanceof Empty) {
        let sequence = sequences.head;
        return reverse(sequence);
      } else {
        let sequences$1 = merge_descending_pairs(sequences, compare2, List$Empty$const);
        loop$sequences = sequences$1;
        loop$direction = Sorting$Ascending$const;
        loop$compare = compare2;
      }
    }
  }
}
function sequences(loop$list, loop$compare, loop$growing, loop$direction, loop$prev, loop$acc) {
  while (true) {
    let list = loop$list;
    let compare2 = loop$compare;
    let growing = loop$growing;
    let direction = loop$direction;
    let prev = loop$prev;
    let acc = loop$acc;
    let growing$1 = prepend(prev, growing);
    if (list instanceof Empty) {
      if (direction instanceof Ascending) {
        return prepend(reverse(growing$1), acc);
      } else {
        return prepend(growing$1, acc);
      }
    } else {
      let new$1 = list.head;
      let rest$1 = list.tail;
      let $ = compare2(prev, new$1);
      if (direction instanceof Ascending) {
        if ($ instanceof Lt) {
          loop$list = rest$1;
          loop$compare = compare2;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        } else if ($ instanceof Eq) {
          loop$list = rest$1;
          loop$compare = compare2;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        } else {
          let _block;
          if (direction instanceof Ascending) {
            _block = prepend(reverse(growing$1), acc);
          } else {
            _block = prepend(growing$1, acc);
          }
          let acc$1 = _block;
          if (rest$1 instanceof Empty) {
            return prepend(toList([new$1]), acc$1);
          } else {
            let next = rest$1.head;
            let rest$2 = rest$1.tail;
            let _block$1;
            let $1 = compare2(new$1, next);
            if ($1 instanceof Lt) {
              _block$1 = Sorting$Ascending$const;
            } else if ($1 instanceof Eq) {
              _block$1 = Sorting$Ascending$const;
            } else {
              _block$1 = Sorting$Descending$const;
            }
            let direction$1 = _block$1;
            loop$list = rest$2;
            loop$compare = compare2;
            loop$growing = toList([new$1]);
            loop$direction = direction$1;
            loop$prev = next;
            loop$acc = acc$1;
          }
        }
      } else if ($ instanceof Lt) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1 instanceof Empty) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare2(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare2;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else if ($ instanceof Eq) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1 instanceof Empty) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare2(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare2;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else {
        loop$list = rest$1;
        loop$compare = compare2;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      }
    }
  }
}
function sort(list, compare2) {
  if (list instanceof Empty) {
    return list;
  } else {
    let $ = list.tail;
    if ($ instanceof Empty) {
      return list;
    } else {
      let x = list.head;
      let y = $.head;
      let rest$1 = $.tail;
      let _block;
      let $1 = compare2(x, y);
      if ($1 instanceof Lt) {
        _block = Sorting$Ascending$const;
      } else if ($1 instanceof Eq) {
        _block = Sorting$Ascending$const;
      } else {
        _block = Sorting$Descending$const;
      }
      let direction = _block;
      let sequences$1 = sequences(rest$1, compare2, toList([x]), direction, y, List$Empty$const);
      return merge_all(sequences$1, Sorting$Ascending$const, compare2);
    }
  }
}
function each(loop$list, loop$f) {
  while (true) {
    let list = loop$list;
    let f = loop$f;
    if (list instanceof Empty) {
      return;
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      f(first$1);
      loop$list = rest$1;
      loop$f = f;
    }
  }
}

// build/dev/javascript/gleam_stdlib/gleam/string_tree.mjs
class All extends CustomType {
}
var Direction$All$const = new All;

// build/dev/javascript/gleam_stdlib/gleam/string.mjs
class Leading extends CustomType {
}
var Direction$Leading$const = new Leading;

class Trailing extends CustomType {
}
var Direction$Trailing$const = new Trailing;
function split2(x, substring) {
  if (substring === "") {
    return graphemes(x);
  } else {
    let _pipe = x;
    let _pipe$1 = identity(_pipe);
    let _pipe$2 = split(_pipe$1, substring);
    return map2(_pipe$2, identity);
  }
}
function concat_loop(loop$strings, loop$accumulator) {
  while (true) {
    let strings = loop$strings;
    let accumulator = loop$accumulator;
    if (strings instanceof Empty) {
      return accumulator;
    } else {
      let string = strings.head;
      let strings$1 = strings.tail;
      loop$strings = strings$1;
      loop$accumulator = accumulator + string;
    }
  }
}
function concat2(strings) {
  return concat_loop(strings, "");
}
function join_loop(loop$strings, loop$separator, loop$accumulator) {
  while (true) {
    let strings = loop$strings;
    let separator = loop$separator;
    let accumulator = loop$accumulator;
    if (strings instanceof Empty) {
      return accumulator;
    } else {
      let string = strings.head;
      let strings$1 = strings.tail;
      loop$strings = strings$1;
      loop$separator = separator;
      loop$accumulator = accumulator + separator + string;
    }
  }
}
function join(strings, separator) {
  if (strings instanceof Empty) {
    return "";
  } else {
    let first$1 = strings.head;
    let rest = strings.tail;
    return join_loop(rest, separator, first$1);
  }
}
function trim(string) {
  let _pipe = string;
  let _pipe$1 = trim_start(_pipe);
  return trim_end(_pipe$1);
}
function inspect2(term) {
  let _pipe = term;
  let _pipe$1 = inspect(_pipe);
  return identity(_pipe$1);
}

// build/dev/javascript/gleam_stdlib/gleam/dynamic/decode.mjs
class DecodeError extends CustomType {
  constructor(expected, found, path) {
    super();
    this.expected = expected;
    this.found = found;
    this.path = path;
  }
}
var DecodeError$DecodeError = (expected, found, path) => new DecodeError(expected, found, path);
class Decoder extends CustomType {
  constructor(function$) {
    super();
    this.function = function$;
  }
}
var float2 = /* @__PURE__ */ new Decoder(decode_float);
var int2 = /* @__PURE__ */ new Decoder(decode_int);
var string2 = /* @__PURE__ */ new Decoder(decode_string);
var bool = /* @__PURE__ */ new Decoder(decode_bool);
function run(data, decoder) {
  let $ = decoder.function(data);
  let maybe_invalid_data = $[0];
  let errors = $[1];
  if (errors instanceof Empty) {
    return new Ok(maybe_invalid_data);
  } else {
    return new Error2(errors);
  }
}
function run_dynamic_function(data, name, f) {
  let $ = f(data);
  if ($ instanceof Ok) {
    let data$1 = $[0];
    return [data$1, List$Empty$const];
  } else {
    let placeholder = $[0];
    return [
      placeholder,
      toList([new DecodeError(name, classify_dynamic(data), List$Empty$const)])
    ];
  }
}
function decode_float(data) {
  return run_dynamic_function(data, "Float", float);
}
function map3(decoder, transformer) {
  return new Decoder((d) => {
    let $ = decoder.function(d);
    let data = $[0];
    let errors = $[1];
    return [transformer(data), errors];
  });
}
function decode_int(data) {
  return run_dynamic_function(data, "Int", int);
}
function decode_string(data) {
  return run_dynamic_function(data, "String", string);
}
function run_decoders(loop$data, loop$failure, loop$decoders) {
  while (true) {
    let data = loop$data;
    let failure = loop$failure;
    let decoders = loop$decoders;
    if (decoders instanceof Empty) {
      return failure;
    } else {
      let decoder = decoders.head;
      let decoders$1 = decoders.tail;
      let $ = decoder.function(data);
      let layer = $;
      let errors = $[1];
      if (errors instanceof Empty) {
        return layer;
      } else {
        loop$data = data;
        loop$failure = failure;
        loop$decoders = decoders$1;
      }
    }
  }
}
function one_of(first, alternatives) {
  return new Decoder((dynamic_data) => {
    let $ = first.function(dynamic_data);
    let layer = $;
    let errors = $[1];
    if (errors instanceof Empty) {
      return layer;
    } else {
      return run_decoders(dynamic_data, layer, alternatives);
    }
  });
}
function path_segment_to_string(key) {
  let decoder = one_of(string2, toList([
    (() => {
      let _pipe = int2;
      return map3(_pipe, to_string);
    })(),
    (() => {
      let _pipe = float2;
      return map3(_pipe, float_to_string);
    })()
  ]));
  let $ = run(key, decoder);
  if ($ instanceof Ok) {
    let key$1 = $[0];
    return key$1;
  } else {
    return "<" + classify_dynamic(key) + ">";
  }
}
function push_path(layer, path) {
  let path$1 = map2(path, (key) => {
    let _pipe = key;
    let _pipe$1 = identity(_pipe);
    return path_segment_to_string(_pipe$1);
  });
  let errors = map2(layer[1], (error) => {
    return new DecodeError(error.expected, error.found, append(path$1, error.path));
  });
  return [layer[0], errors];
}
function list2(inner) {
  return new Decoder((data) => {
    return list(data, inner.function, (p, k) => {
      return push_path(p, toList([k]));
    }, 0, List$Empty$const);
  });
}
function index3(loop$path, loop$position, loop$inner, loop$data, loop$handle_miss) {
  while (true) {
    let path = loop$path;
    let position = loop$position;
    let inner = loop$inner;
    let data = loop$data;
    let handle_miss = loop$handle_miss;
    if (path instanceof Empty) {
      let _pipe = data;
      let _pipe$1 = inner(_pipe);
      return push_path(_pipe$1, reverse(position));
    } else {
      let key = path.head;
      let path$1 = path.tail;
      let $ = index2(data, key);
      if ($ instanceof Ok) {
        let $1 = $[0];
        if ($1 instanceof Some) {
          let data$1 = $1[0];
          loop$path = path$1;
          loop$position = prepend(key, position);
          loop$inner = inner;
          loop$data = data$1;
          loop$handle_miss = handle_miss;
        } else {
          return handle_miss(data, prepend(key, position));
        }
      } else {
        let kind = $[0];
        let $1 = inner(data);
        let default$ = $1[0];
        let _pipe = [
          default$,
          toList([
            new DecodeError(kind, classify_dynamic(data), List$Empty$const)
          ])
        ];
        return push_path(_pipe, reverse(position));
      }
    }
  }
}
function subfield(field_path, field_decoder, next) {
  return new Decoder((data) => {
    let $ = index3(field_path, List$Empty$const, field_decoder.function, data, (data2, position) => {
      let $12 = field_decoder.function(data2);
      let default$ = $12[0];
      let _pipe = [
        default$,
        toList([new DecodeError("Field", "Nothing", List$Empty$const)])
      ];
      return push_path(_pipe, reverse(position));
    });
    let out = $[0];
    let errors1 = $[1];
    let $1 = next(out).function(data);
    let out$1 = $1[0];
    let errors2 = $1[1];
    return [out$1, append(errors1, errors2)];
  });
}
function success(data) {
  return new Decoder((_) => {
    return [data, List$Empty$const];
  });
}
function decode_error(expected, found) {
  return toList([
    new DecodeError(expected, classify_dynamic(found), List$Empty$const)
  ]);
}
function field(field_name, field_decoder, next) {
  return subfield(toList([field_name]), field_decoder, next);
}
function optional_field(key, default$, field_decoder, next) {
  return new Decoder((data) => {
    let _block;
    let _block$1;
    let $1 = index2(data, key);
    if ($1 instanceof Ok) {
      let $22 = $1[0];
      if ($22 instanceof Some) {
        let data$1 = $22[0];
        _block$1 = field_decoder.function(data$1);
      } else {
        _block$1 = [default$, List$Empty$const];
      }
    } else {
      let kind = $1[0];
      _block$1 = [
        default$,
        toList([
          new DecodeError(kind, classify_dynamic(data), List$Empty$const)
        ])
      ];
    }
    let _pipe = _block$1;
    _block = push_path(_pipe, toList([key]));
    let $ = _block;
    let out = $[0];
    let errors1 = $[1];
    let $2 = next(out).function(data);
    let out$1 = $2[0];
    let errors2 = $2[1];
    return [out$1, append(errors1, errors2)];
  });
}
function decode_bool(data) {
  let $ = isEqual(identity(true), data);
  if ($) {
    return [true, List$Empty$const];
  } else {
    let $1 = isEqual(identity(false), data);
    if ($1) {
      return [false, List$Empty$const];
    } else {
      return [false, decode_error("Bool", data)];
    }
  }
}
function optional(inner) {
  return new Decoder((data) => {
    let $ = is_null(data);
    if ($) {
      return [Option$None$const, List$Empty$const];
    } else {
      let $1 = inner.function(data);
      let data$1 = $1[0];
      let errors = $1[1];
      return [new Some(data$1), errors];
    }
  });
}
function failure(placeholder, name) {
  return new Decoder((d) => {
    return [placeholder, decode_error(name, d)];
  });
}

// build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
var Nil = undefined;
function identity(x) {
  return x;
}
function parse_int(value) {
  if (/^[-+]?(\d+)$/.test(value)) {
    return Result$Ok(parseInt(value));
  } else {
    return Result$Error(Nil);
  }
}
function to_string(term) {
  return term.toString();
}
function graphemes(string3) {
  const iterator = graphemes_iterator(string3);
  if (iterator) {
    return arrayToList(Array.from(iterator).map((item) => item.segment));
  } else {
    return arrayToList(string3.match(/./gsu));
  }
}
var segmenter = undefined;
function graphemes_iterator(string3) {
  if (globalThis.Intl && Intl.Segmenter) {
    segmenter ||= new Intl.Segmenter;
    return segmenter.segment(string3)[Symbol.iterator]();
  }
}
function lowercase(string3) {
  return string3.toLowerCase();
}
function split(xs, pattern) {
  return arrayToList(xs.split(pattern));
}
function contains_string(haystack, needle) {
  return haystack.indexOf(needle) >= 0;
}
function starts_with(haystack, needle) {
  return haystack.startsWith(needle);
}
function ends_with(haystack, needle) {
  return haystack.endsWith(needle);
}
var unicode_whitespaces = [
  " ",
  "\t",
  `
`,
  "\v",
  "\f",
  "\r",
  "",
  "\u2028",
  "\u2029"
].join("");
var trim_start_regex = /* @__PURE__ */ new RegExp(`^[${unicode_whitespaces}]*`);
var trim_end_regex = /* @__PURE__ */ new RegExp(`[${unicode_whitespaces}]*$`);
function trim_start(string3) {
  return string3.replace(trim_start_regex, "");
}
function trim_end(string3) {
  return string3.replace(trim_end_regex, "");
}
function classify_dynamic(data) {
  if (typeof data === "string") {
    return "String";
  } else if (typeof data === "boolean") {
    return "Bool";
  } else if (isResult(data)) {
    return "Result";
  } else if (isList(data)) {
    return "List";
  } else if (data instanceof BitArray) {
    return "BitArray";
  } else if (data instanceof Dict) {
    return "Dict";
  } else if (Number.isInteger(data)) {
    return "Int";
  } else if (Array.isArray(data)) {
    return `Array`;
  } else if (typeof data === "number") {
    return "Float";
  } else if (data === null) {
    return "Nil";
  } else if (data === undefined) {
    return "Nil";
  } else {
    const type = typeof data;
    return type.charAt(0).toUpperCase() + type.slice(1);
  }
}
var MIN_I32 = -(2 ** 31);
var MAX_I32 = 2 ** 31 - 1;
var U32 = 2 ** 32;
var MAX_SAFE = Number.MAX_SAFE_INTEGER;
var MIN_SAFE = Number.MIN_SAFE_INTEGER;
function inspect(v) {
  return new Inspector().inspect(v);
}
function float_to_string(float3) {
  const string3 = float3.toString().replace("+", "");
  if (string3.indexOf(".") >= 0) {
    return string3;
  } else {
    const index4 = string3.indexOf("e");
    if (index4 >= 0) {
      return string3.slice(0, index4) + ".0" + string3.slice(index4);
    } else {
      return string3 + ".0";
    }
  }
}

class Inspector {
  #references = new Set;
  inspect(v) {
    const t = typeof v;
    if (v === true)
      return "True";
    if (v === false)
      return "False";
    if (v === null)
      return "//js(null)";
    if (v === undefined)
      return "Nil";
    if (t === "string")
      return this.#string(v);
    if (t === "bigint" || Number.isInteger(v))
      return v.toString();
    if (t === "number")
      return float_to_string(v);
    if (v instanceof UtfCodepoint)
      return this.#utfCodepoint(v);
    if (v instanceof BitArray)
      return this.#bit_array(v);
    if (v instanceof RegExp)
      return `//js(${v})`;
    if (v instanceof Date)
      return `//js(Date("${v.toISOString()}"))`;
    if (v instanceof globalThis.Error)
      return `//js(${v.toString()})`;
    if (v instanceof Function) {
      const args = [];
      for (const i of Array(v.length).keys())
        args.push(String.fromCharCode(i + 97));
      return `//fn(${args.join(", ")}) { ... }`;
    }
    if (this.#references.size === this.#references.add(v).size) {
      return "//js(circular reference)";
    }
    let printed;
    if (Array.isArray(v)) {
      printed = `#(${v.map((v2) => this.inspect(v2)).join(", ")})`;
    } else if (isList(v)) {
      printed = this.#list(v);
    } else if (v instanceof CustomType) {
      printed = this.#customType(v);
    } else if (v instanceof Dict) {
      printed = this.#dict(v);
    } else if (v instanceof Set) {
      return `//js(Set(${[...v].map((v2) => this.inspect(v2)).join(", ")}))`;
    } else {
      printed = this.#object(v);
    }
    this.#references.delete(v);
    return printed;
  }
  #object(v) {
    const name = Object.getPrototypeOf(v)?.constructor?.name || "Object";
    const props = [];
    for (const k of Object.keys(v)) {
      props.push(`${this.inspect(k)}: ${this.inspect(v[k])}`);
    }
    const body = props.length ? " " + props.join(", ") + " " : "";
    const head = name === "Object" ? "" : name + " ";
    return `//js(${head}{${body}})`;
  }
  #dict(map4) {
    let body = "dict.from_list([";
    let first = true;
    body = fold(map4, body, (body2, key, value) => {
      if (!first)
        body2 = body2 + ", ";
      first = false;
      return body2 + "#(" + this.inspect(key) + ", " + this.inspect(value) + ")";
    });
    return body + "])";
  }
  #customType(record) {
    const props = Object.keys(record).map((label) => {
      const value = this.inspect(record[label]);
      return isNaN(parseInt(label)) ? `${label}: ${value}` : value;
    }).join(", ");
    return props ? `${record.constructor.name}(${props})` : record.constructor.name;
  }
  #list(list3) {
    if (List$isEmpty(list3)) {
      return "[]";
    }
    let char_out = 'charlist.from_string("';
    let list_out = "[";
    let current = list3;
    while (List$isNonEmpty(current)) {
      let element = current.head;
      current = current.tail;
      if (list_out !== "[") {
        list_out += ", ";
      }
      list_out += this.inspect(element);
      if (char_out) {
        if (Number.isInteger(element) && element >= 32 && element <= 126) {
          char_out += String.fromCharCode(element);
        } else {
          char_out = null;
        }
      }
    }
    if (char_out) {
      return char_out + '")';
    } else {
      return list_out + "]";
    }
  }
  #string(str) {
    let new_str = '"';
    for (let i = 0;i < str.length; i++) {
      const char = str[i];
      switch (char) {
        case `
`:
          new_str += "\\n";
          break;
        case "\r":
          new_str += "\\r";
          break;
        case "\t":
          new_str += "\\t";
          break;
        case "\f":
          new_str += "\\f";
          break;
        case "\\":
          new_str += "\\\\";
          break;
        case '"':
          new_str += "\\\"";
          break;
        default:
          if (char < " " || char > "~" && char < " ") {
            new_str += "\\u{" + char.charCodeAt(0).toString(16).toUpperCase().padStart(4, "0") + "}";
          } else {
            new_str += char;
          }
      }
    }
    new_str += '"';
    return new_str;
  }
  #utfCodepoint(codepoint2) {
    return `//utfcodepoint(${String.fromCodePoint(codepoint2.value)})`;
  }
  #bit_array(bits2) {
    if (bits2.bitSize === 0) {
      return "<<>>";
    }
    let acc = "<<";
    for (let i = 0;i < bits2.byteSize - 1; i++) {
      acc += bits2.byteAt(i).toString();
      acc += ", ";
    }
    if (bits2.byteSize * 8 === bits2.bitSize) {
      acc += bits2.byteAt(bits2.byteSize - 1).toString();
    } else {
      const trailingBitsCount = bits2.bitSize % 8;
      acc += bits2.byteAt(bits2.byteSize - 1) >> 8 - trailingBitsCount;
      acc += `:size(${trailingBitsCount})`;
    }
    acc += ">>";
    return acc;
  }
}
function index2(data, key) {
  if (data instanceof Dict) {
    const result = get(data, key);
    return Result$Ok(result.isOk() ? new Some(result[0]) : new None);
  }
  if (data instanceof WeakMap || data instanceof Map) {
    const token = {};
    const entry = data.get(key, token);
    if (entry === token)
      return Result$Ok(new None);
    return Result$Ok(new Some(entry));
  }
  const key_is_int = Number.isInteger(key);
  if (key_is_int && key >= 0 && key < 8 && isList(data)) {
    let i = 0;
    for (const value of data) {
      if (i === key)
        return Result$Ok(new Some(value));
      i++;
    }
    return Result$Error("Indexable");
  }
  if (key_is_int && Array.isArray(data) || data && typeof data === "object" || data && Object.getPrototypeOf(data) === Object.prototype) {
    if (key in data)
      return Result$Ok(new Some(data[key]));
    return Result$Ok(new None);
  }
  return Result$Error(key_is_int ? "Indexable" : "Dict");
}
function list(data, decode, pushPath, index4, emptyList) {
  if (!(isList(data) || Array.isArray(data))) {
    const error = DecodeError$DecodeError("List", classify_dynamic(data), emptyList);
    return [emptyList, arrayToList([error])];
  }
  const decoded = [];
  for (const element of data) {
    const layer = decode(element);
    const [out, errors] = layer;
    if (List$isNonEmpty(errors)) {
      const [_, errors2] = pushPath(layer, index4.toString());
      return [emptyList, errors2];
    }
    decoded.push(out);
    index4++;
  }
  return [arrayToList(decoded), emptyList];
}
function float(data) {
  if (typeof data === "number")
    return Result$Ok(data);
  return Result$Error(0);
}
function int(data) {
  if (Number.isInteger(data))
    return Result$Ok(data);
  return Result$Error(0);
}
function string(data) {
  if (typeof data === "string")
    return Result$Ok(data);
  return Result$Error("");
}
function is_null(data) {
  return data === null || data === undefined;
}
function arrayToList(array) {
  let list3 = List$Empty();
  let i = array.length;
  while (i--) {
    list3 = List$NonEmpty(array[i], list3);
  }
  return list3;
}
function isList(data) {
  return List$isEmpty(data) || List$isNonEmpty(data);
}
function isResult(data) {
  return Result$isOk(data) || Result$isError(data);
}
// build/dev/javascript/gleam_erlang/gleam/erlang/process.mjs
class Normal extends CustomType {
}
var ExitReason$Normal$const = new Normal;
class Killed extends CustomType {
}
var ExitReason$Killed$const = new Killed;
class Anything extends CustomType {
}
var AnythingSelectorTag$Anything$const = new Anything;

class Process extends CustomType {
}
var ProcessMonitorFlag$Process$const = new Process;
class TimerNotFound extends CustomType {
}
var Cancelled$TimerNotFound$const = new TimerNotFound;
class Kill extends CustomType {
}
var KillFlag$Kill$const = new Kill;

// build/dev/javascript/gleam_stdlib/gleam/result.mjs
function map_error(result, fun) {
  if (result instanceof Ok) {
    return result;
  } else {
    let error = result[0];
    return new Error2(fun(error));
  }
}
function try$(result, fun) {
  if (result instanceof Ok) {
    let x = result[0];
    return fun(x);
  } else {
    return result;
  }
}
// build/dev/javascript/gleam_otp/gleam/otp/system.mjs
class Running extends CustomType {
}
var Mode$Running$const = new Running;
class Suspended extends CustomType {
}
var Mode$Suspended$const = new Suspended;
class NoDebug extends CustomType {
}
var DebugOption$NoDebug$const = new NoDebug;

// build/dev/javascript/gleam_otp/gleam/otp/actor.mjs
class InitTimeout extends CustomType {
}
var StartError$InitTimeout$const = new InitTimeout;

// build/dev/javascript/gleam_otp/gleam/otp/supervision.mjs
class Permanent extends CustomType {
}
var Restart$Permanent$const = new Permanent;
class Transient extends CustomType {
}
var Restart$Transient$const = new Transient;
class Temporary extends CustomType {
}
var Restart$Temporary$const = new Temporary;
class Supervisor extends CustomType {
}
var ChildType$Supervisor$const = new Supervisor;

// build/dev/javascript/gleam_otp/gleam/otp/factory_supervisor.mjs
class SimpleOneForOne extends CustomType {
}
var Strategy$SimpleOneForOne$const = new SimpleOneForOne;

// build/dev/javascript/gleam_stdlib/gleam/bool.mjs
function guard(requirement, consequence, alternative) {
  if (requirement) {
    return consequence;
  } else {
    return alternative();
  }
}

// build/dev/javascript/gleam_stdlib/gleam/function.mjs
function identity2(x) {
  return x;
}
// build/dev/javascript/gleam_json/gleam_json_ffi.mjs
function json_to_string(json) {
  return JSON.stringify(json);
}
function object(entries) {
  return Object.fromEntries(entries);
}
function identity3(x) {
  return x;
}
function array(list3) {
  const array2 = [];
  while (List$isNonEmpty(list3)) {
    array2.push(List$NonEmpty$first(list3));
    list3 = List$NonEmpty$rest(list3);
  }
  return array2;
}
function decode(string3) {
  try {
    const result = JSON.parse(string3);
    return Result$Ok(result);
  } catch (err) {
    return Result$Error(getJsonDecodeError(err, string3));
  }
}
function getJsonDecodeError(stdErr, json) {
  if (isUnexpectedEndOfInput(stdErr))
    return DecodeError$UnexpectedEndOfInput();
  return toUnexpectedByteError(stdErr, json);
}
function isUnexpectedEndOfInput(err) {
  const unexpectedEndOfInputRegex = /((unexpected (end|eof))|(end of data)|(unterminated string)|(json( parse error|\.parse)\: expected '(\:|\}|\])'))/i;
  return unexpectedEndOfInputRegex.test(err.message);
}
function toUnexpectedByteError(err, json) {
  let converters = [
    v8UnexpectedByteError,
    oldV8UnexpectedByteError,
    jsCoreUnexpectedByteError,
    spidermonkeyUnexpectedByteError
  ];
  for (let converter of converters) {
    let result = converter(err, json);
    if (result)
      return result;
  }
  return DecodeError$UnexpectedByte("");
}
function v8UnexpectedByteError(err) {
  const regex = /unexpected token '(.)', ".+" is not valid JSON/i;
  const match = regex.exec(err.message);
  if (!match)
    return null;
  const byte = toHex(match[1]);
  return DecodeError$UnexpectedByte(byte);
}
function oldV8UnexpectedByteError(err) {
  const regex = /unexpected token (.) in JSON at position (\d+)/i;
  const match = regex.exec(err.message);
  if (!match)
    return null;
  const byte = toHex(match[1]);
  return DecodeError$UnexpectedByte(byte);
}
function spidermonkeyUnexpectedByteError(err, json) {
  const regex = /(unexpected character|expected .*) at line (\d+) column (\d+)/i;
  const match = regex.exec(err.message);
  if (!match)
    return null;
  const line = Number(match[2]);
  const column = Number(match[3]);
  const position = getPositionFromMultiline(line, column, json);
  const byte = toHex(json[position]);
  return DecodeError$UnexpectedByte(byte);
}
function jsCoreUnexpectedByteError(err) {
  const regex = /unexpected (identifier|token) "(.)"/i;
  const match = regex.exec(err.message);
  if (!match)
    return null;
  const byte = toHex(match[2]);
  return DecodeError$UnexpectedByte(byte);
}
function toHex(char) {
  return "0x" + char.charCodeAt(0).toString(16).toUpperCase();
}
function getPositionFromMultiline(line, column, string3) {
  if (line === 1)
    return column - 1;
  let currentLn = 1;
  let position = 0;
  string3.split("").find((char, idx) => {
    if (char === `
`)
      currentLn += 1;
    if (currentLn === line) {
      position = idx + column;
      return true;
    }
    return false;
  });
  return position;
}

// build/dev/javascript/gleam_json/gleam/json.mjs
class UnexpectedEndOfInput extends CustomType {
}
var DecodeError$UnexpectedEndOfInput$const = new UnexpectedEndOfInput;
var DecodeError$UnexpectedEndOfInput = () => DecodeError$UnexpectedEndOfInput$const;
class UnexpectedByte extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
var DecodeError$UnexpectedByte = ($0) => new UnexpectedByte($0);
class UnableToDecode extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
function do_parse(json, decoder) {
  return try$(decode(json), (dynamic_value) => {
    let _pipe = run(dynamic_value, decoder);
    return map_error(_pipe, (var0) => {
      return new UnableToDecode(var0);
    });
  });
}
function parse(json, decoder) {
  return do_parse(json, decoder);
}
function to_string2(json) {
  return json_to_string(json);
}
function string3(input) {
  return identity3(input);
}
function bool2(input) {
  return identity3(input);
}
function int3(input) {
  return identity3(input);
}
function object2(entries) {
  return object(entries);
}
function preprocessed_array(from2) {
  return array(from2);
}
function array2(entries, inner_type) {
  let _pipe = entries;
  let _pipe$1 = map2(_pipe, inner_type);
  return preprocessed_array(_pipe$1);
}
// build/dev/javascript/houdini/houdini.ffi.mjs
function escape(string4) {
  return string4.replaceAll(/[><&"']/g, (replaced) => {
    switch (replaced) {
      case ">":
        return "&gt;";
      case "<":
        return "&lt;";
      case "'":
        return "&#39;";
      case "&":
        return "&amp;";
      case '"':
        return "&quot;";
      default:
        return replaced;
    }
  });
}

// build/dev/javascript/lustre/lustre/internals/constants.mjs
var empty_list = List$Empty$const;
var error_nil = /* @__PURE__ */ new Error2(undefined);
function singleton_list(item) {
  return prepend(item, empty_list);
}

// build/dev/javascript/lustre/lustre/vdom/vattr.ffi.mjs
var GT = /* @__PURE__ */ Order$Gt();
var LT = /* @__PURE__ */ Order$Lt();
var EQ = /* @__PURE__ */ Order$Eq();
function compare2(a, b) {
  if (a.name === b.name) {
    return EQ;
  } else if (a.name < b.name) {
    return LT;
  } else {
    return GT;
  }
}

// build/dev/javascript/lustre/lustre/vdom/vattr.mjs
class Attribute extends CustomType {
  constructor(kind, name, value) {
    super();
    this.kind = kind;
    this.name = name;
    this.value = value;
  }
}
class Property extends CustomType {
  constructor(kind, name, value) {
    super();
    this.kind = kind;
    this.name = name;
    this.value = value;
  }
}
class Event2 extends CustomType {
  constructor(kind, name, handler, include, prevent_default, stop_propagation, debounce, throttle) {
    super();
    this.kind = kind;
    this.name = name;
    this.handler = handler;
    this.include = include;
    this.prevent_default = prevent_default;
    this.stop_propagation = stop_propagation;
    this.debounce = debounce;
    this.throttle = throttle;
  }
}
class Handler extends CustomType {
  constructor(prevent_default, stop_propagation, message) {
    super();
    this.prevent_default = prevent_default;
    this.stop_propagation = stop_propagation;
    this.message = message;
  }
}
class Never extends CustomType {
  constructor(kind) {
    super();
    this.kind = kind;
  }
}
var attribute_kind = 0;
var property_kind = 1;
var event_kind = 2;
var never_kind = 0;
var never = /* @__PURE__ */ new Never(never_kind);
var always_kind = 2;
function attribute(name, value) {
  return new Attribute(attribute_kind, name, value);
}
function property(name, value) {
  return new Property(property_kind, name, value);
}
function event(name, handler, include, prevent_default, stop_propagation, debounce, throttle) {
  return new Event2(event_kind, name, handler, include, prevent_default, stop_propagation, debounce, throttle);
}
function merge(loop$attributes, loop$merged) {
  while (true) {
    let attributes = loop$attributes;
    let merged = loop$merged;
    if (attributes instanceof Empty) {
      return merged;
    } else {
      let $ = attributes.head;
      if ($ instanceof Attribute) {
        let $1 = $.name;
        if ($1 === "") {
          let rest = attributes.tail;
          loop$attributes = rest;
          loop$merged = merged;
        } else if ($1 === "class") {
          let $2 = $.value;
          if ($2 === "") {
            let rest = attributes.tail;
            loop$attributes = rest;
            loop$merged = merged;
          } else {
            let $3 = attributes.tail;
            if ($3 instanceof Empty) {
              let attribute$1 = $;
              let rest = $3;
              loop$attributes = rest;
              loop$merged = prepend(attribute$1, merged);
            } else {
              let $4 = $3.head;
              if ($4 instanceof Attribute) {
                let $5 = $4.name;
                if ($5 === "class") {
                  let kind = $.kind;
                  let class1 = $2;
                  let rest = $3.tail;
                  let class2 = $4.value;
                  let value = class1 + " " + class2;
                  let attribute$1 = new Attribute(kind, "class", value);
                  loop$attributes = prepend(attribute$1, rest);
                  loop$merged = merged;
                } else {
                  let attribute$1 = $;
                  let rest = $3;
                  loop$attributes = rest;
                  loop$merged = prepend(attribute$1, merged);
                }
              } else {
                let attribute$1 = $;
                let rest = $3;
                loop$attributes = rest;
                loop$merged = prepend(attribute$1, merged);
              }
            }
          }
        } else if ($1 === "style") {
          let $2 = $.value;
          if ($2 === "") {
            let rest = attributes.tail;
            loop$attributes = rest;
            loop$merged = merged;
          } else {
            let $3 = attributes.tail;
            if ($3 instanceof Empty) {
              let attribute$1 = $;
              let rest = $3;
              loop$attributes = rest;
              loop$merged = prepend(attribute$1, merged);
            } else {
              let $4 = $3.head;
              if ($4 instanceof Attribute) {
                let $5 = $4.name;
                if ($5 === "style") {
                  let kind = $.kind;
                  let style1 = $2;
                  let rest = $3.tail;
                  let style2 = $4.value;
                  let value = style1 + ";" + style2;
                  let attribute$1 = new Attribute(kind, "style", value);
                  loop$attributes = prepend(attribute$1, rest);
                  loop$merged = merged;
                } else {
                  let attribute$1 = $;
                  let rest = $3;
                  loop$attributes = rest;
                  loop$merged = prepend(attribute$1, merged);
                }
              } else {
                let attribute$1 = $;
                let rest = $3;
                loop$attributes = rest;
                loop$merged = prepend(attribute$1, merged);
              }
            }
          }
        } else {
          let attribute$1 = $;
          let rest = attributes.tail;
          loop$attributes = rest;
          loop$merged = prepend(attribute$1, merged);
        }
      } else {
        let attribute$1 = $;
        let rest = attributes.tail;
        loop$attributes = rest;
        loop$merged = prepend(attribute$1, merged);
      }
    }
  }
}
function prepare(attributes) {
  if (attributes instanceof Empty) {
    return attributes;
  } else {
    let $ = attributes.tail;
    if ($ instanceof Empty) {
      return attributes;
    } else {
      let _pipe = attributes;
      let _pipe$1 = sort(_pipe, (a, b) => {
        return compare2(b, a);
      });
      return merge(_pipe$1, empty_list);
    }
  }
}

// build/dev/javascript/lustre/lustre/attribute.mjs
function attribute2(name, value) {
  return attribute(name, value);
}
function property2(name, value) {
  return property(name, value);
}
function boolean_attribute(name, value) {
  if (value) {
    return attribute2(name, "");
  } else {
    return property2(name, bool2(false));
  }
}
function class$(name) {
  return attribute2("class", name);
}
function id(value) {
  return attribute2("id", value);
}
function disabled(is_disabled) {
  return boolean_attribute("disabled", is_disabled);
}
function placeholder(text) {
  return attribute2("placeholder", text);
}
function type_(control_type) {
  return attribute2("type", control_type);
}
function value(control_value) {
  return attribute2("value", control_value);
}
function aria(name, value2) {
  return attribute2("aria-" + name, value2);
}
function role(name) {
  return attribute2("role", name);
}
function aria_hidden(value2) {
  return aria("hidden", (() => {
    if (value2) {
      return "true";
    } else {
      return "false";
    }
  })());
}
function aria_keyshortcuts(value2) {
  return aria("keyshortcuts", value2);
}
function aria_label(value2) {
  return aria("label", value2);
}
function aria_live(value2) {
  return aria("live", value2);
}
function aria_modal(value2) {
  return aria("modal", (() => {
    if (value2) {
      return "true";
    } else {
      return "false";
    }
  })());
}
function aria_pressed(value2) {
  return aria("pressed", value2);
}

// build/dev/javascript/lustre/lustre/effect.mjs
class Effect extends CustomType {
  constructor(synchronous, before_paint, after_paint) {
    super();
    this.synchronous = synchronous;
    this.before_paint = before_paint;
    this.after_paint = after_paint;
  }
}

class Actions extends CustomType {
  constructor(dispatch, emit, select, root, provide, subscribe, unsubscribe) {
    super();
    this.dispatch = dispatch;
    this.emit = emit;
    this.select = select;
    this.root = root;
    this.provide = provide;
    this.subscribe = subscribe;
    this.unsubscribe = unsubscribe;
  }
}
var empty = /* @__PURE__ */ new Effect(empty_list, empty_list, empty_list);
function none() {
  return empty;
}
function from2(effect) {
  let task = (actions) => {
    let dispatch = actions.dispatch;
    return effect(dispatch);
  };
  return new Effect(singleton_list(task), empty.before_paint, empty.after_paint);
}
function before_paint(effect) {
  let task = (actions) => {
    let root = actions.root();
    let dispatch = actions.dispatch;
    return effect(dispatch, root);
  };
  return new Effect(empty.synchronous, singleton_list(task), empty.after_paint);
}
function batch(effects) {
  return fold2(effects, empty, (acc, eff) => {
    return new Effect(fold2(eff.synchronous, acc.synchronous, prepend2), fold2(eff.before_paint, acc.before_paint, prepend2), fold2(eff.after_paint, acc.after_paint, prepend2));
  });
}
function perform(effect, dispatch, emit, select, root, provide, subscribe, unsubscribe) {
  let actions = new Actions(dispatch, emit, select, root, provide, subscribe, unsubscribe);
  return each(effect.synchronous, (run2) => {
    return run2(actions);
  });
}

// build/dev/javascript/lustre/lustre/internals/mutable_map.ffi.mjs
function empty2() {
  return null;
}
function get2(map4, key) {
  return map4?.get(key);
}
function get_or_compute(map4, key, compute) {
  return map4?.get(key) ?? compute();
}
function has_key(map4, key) {
  return map4 && map4.has(key);
}
function insert2(map4, key, value2) {
  map4 ??= new Map;
  map4.set(key, value2);
  return map4;
}
function remove(map4, key) {
  map4?.delete(key);
  return map4;
}

// build/dev/javascript/lustre/lustre/internals/ref.ffi.mjs
function sameValueZero(x, y) {
  if (typeof x === "number" && typeof y === "number") {
    return x === y || x !== x && y !== y;
  }
  return x === y;
}

// build/dev/javascript/lustre/lustre/internals/ref.mjs
function equal_lists(loop$xs, loop$ys) {
  while (true) {
    let xs = loop$xs;
    let ys = loop$ys;
    if (xs instanceof Empty) {
      if (ys instanceof Empty) {
        return true;
      } else {
        return false;
      }
    } else if (ys instanceof Empty) {
      return false;
    } else {
      let x = xs.head;
      let xs$1 = xs.tail;
      let y = ys.head;
      let ys$1 = ys.tail;
      let $ = sameValueZero(x, y);
      if ($) {
        loop$xs = xs$1;
        loop$ys = ys$1;
      } else {
        return $;
      }
    }
  }
}

// build/dev/javascript/lustre/lustre/vdom/vnode.mjs
class Fragment extends CustomType {
  constructor(kind, key, children, keyed_children) {
    super();
    this.kind = kind;
    this.key = key;
    this.children = children;
    this.keyed_children = keyed_children;
  }
}
class Element extends CustomType {
  constructor(kind, key, namespace, tag, attributes, children, keyed_children, self_closing, void$) {
    super();
    this.kind = kind;
    this.key = key;
    this.namespace = namespace;
    this.tag = tag;
    this.attributes = attributes;
    this.children = children;
    this.keyed_children = keyed_children;
    this.self_closing = self_closing;
    this.void = void$;
  }
}
class Text extends CustomType {
  constructor(kind, key, content) {
    super();
    this.kind = kind;
    this.key = key;
    this.content = content;
  }
}
class UnsafeInnerHtml extends CustomType {
  constructor(kind, key, namespace, tag, attributes, inner_html) {
    super();
    this.kind = kind;
    this.key = key;
    this.namespace = namespace;
    this.tag = tag;
    this.attributes = attributes;
    this.inner_html = inner_html;
  }
}
class Map2 extends CustomType {
  constructor(kind, key, mapper, child) {
    super();
    this.kind = kind;
    this.key = key;
    this.mapper = mapper;
    this.child = child;
  }
}
class Memo extends CustomType {
  constructor(kind, key, dependencies, view) {
    super();
    this.kind = kind;
    this.key = key;
    this.dependencies = dependencies;
    this.view = view;
  }
}
var fragment_kind = 0;
var element_kind = 1;
var text_kind = 2;
var unsafe_inner_html_kind = 3;
var map_kind = 4;
var memo_kind = 5;
function fragment(key, children, keyed_children) {
  return new Fragment(fragment_kind, key, children, keyed_children);
}
function element(key, namespace, tag, attributes, children, keyed_children, self_closing, void$) {
  return new Element(element_kind, key, namespace, tag, prepare(attributes), children, keyed_children, self_closing, void$);
}
function is_void_html_element(tag, namespace) {
  if (namespace === "") {
    if (tag === "area") {
      return true;
    } else if (tag === "base") {
      return true;
    } else if (tag === "br") {
      return true;
    } else if (tag === "col") {
      return true;
    } else if (tag === "embed") {
      return true;
    } else if (tag === "hr") {
      return true;
    } else if (tag === "img") {
      return true;
    } else if (tag === "input") {
      return true;
    } else if (tag === "link") {
      return true;
    } else if (tag === "meta") {
      return true;
    } else if (tag === "param") {
      return true;
    } else if (tag === "source") {
      return true;
    } else if (tag === "track") {
      return true;
    } else if (tag === "wbr") {
      return true;
    } else {
      return false;
    }
  } else {
    return false;
  }
}
function text(key, content) {
  return new Text(text_kind, key, content);
}
function map4(element2, mapper) {
  if (element2 instanceof Map2) {
    let child_mapper = element2.mapper;
    return new Map2(map_kind, element2.key, (handler) => {
      return identity2(mapper)(child_mapper(handler));
    }, identity2(element2.child));
  } else {
    return new Map2(map_kind, element2.key, identity2(mapper), identity2(element2));
  }
}
function memo(key, dependencies, view) {
  return new Memo(memo_kind, key, dependencies, view);
}
function to_keyed(key, node) {
  if (node instanceof Fragment) {
    return new Fragment(node.kind, key, node.children, node.keyed_children);
  } else if (node instanceof Element) {
    return new Element(node.kind, key, node.namespace, node.tag, node.attributes, node.children, node.keyed_children, node.self_closing, node.void);
  } else if (node instanceof Text) {
    return new Text(node.kind, key, node.content);
  } else if (node instanceof UnsafeInnerHtml) {
    return new UnsafeInnerHtml(node.kind, key, node.namespace, node.tag, node.attributes, node.inner_html);
  } else if (node instanceof Map2) {
    let child = node.child;
    return new Map2(node.kind, key, node.mapper, to_keyed(key, child));
  } else {
    let view = node.view;
    return new Memo(node.kind, key, node.dependencies, () => {
      return to_keyed(key, view());
    });
  }
}

// build/dev/javascript/lustre/lustre/element.mjs
class Html extends CustomType {
}
var DocumentType$Html$const = new Html;

class HeadOnly extends CustomType {
}
var DocumentType$HeadOnly$const = new HeadOnly;

class BodyOnly extends CustomType {
}
var DocumentType$BodyOnly$const = new BodyOnly;

class HeadAndBody extends CustomType {
}
var DocumentType$HeadAndBody$const = new HeadAndBody;

class Other extends CustomType {
}
var DocumentType$Other$const = new Other;
function element2(tag, attributes, children) {
  return element("", "", tag, attributes, children, empty2(), false, is_void_html_element(tag, ""));
}
function text2(content) {
  return text("", content);
}
function none2() {
  return text("", "");
}
function memo2(dependencies, view) {
  return memo("", dependencies, view);
}
function ref(value2) {
  return identity2(value2);
}
function map5(element3, f) {
  return map4(element3, f);
}

// build/dev/javascript/lustre/lustre/element/html.mjs
function text3(content) {
  return text2(content);
}
function aside(attrs, children) {
  return element2("aside", attrs, children);
}
function footer(attrs, children) {
  return element2("footer", attrs, children);
}
function header(attrs, children) {
  return element2("header", attrs, children);
}
function h1(attrs, children) {
  return element2("h1", attrs, children);
}
function h2(attrs, children) {
  return element2("h2", attrs, children);
}
function h3(attrs, children) {
  return element2("h3", attrs, children);
}
function main(attrs, children) {
  return element2("main", attrs, children);
}
function nav(attrs, children) {
  return element2("nav", attrs, children);
}
function section(attrs, children) {
  return element2("section", attrs, children);
}
function div(attrs, children) {
  return element2("div", attrs, children);
}
function li(attrs, children) {
  return element2("li", attrs, children);
}
function p(attrs, children) {
  return element2("p", attrs, children);
}
function ul(attrs, children) {
  return element2("ul", attrs, children);
}
function span(attrs, children) {
  return element2("span", attrs, children);
}
function strong(attrs, children) {
  return element2("strong", attrs, children);
}
function canvas(attrs) {
  return element2("canvas", attrs, empty_list);
}
function table(attrs, children) {
  return element2("table", attrs, children);
}
function tbody(attrs, children) {
  return element2("tbody", attrs, children);
}
function td(attrs, children) {
  return element2("td", attrs, children);
}
function th(attrs, children) {
  return element2("th", attrs, children);
}
function thead(attrs, children) {
  return element2("thead", attrs, children);
}
function tr(attrs, children) {
  return element2("tr", attrs, children);
}
function button(attrs, children) {
  return element2("button", attrs, children);
}
function datalist(attrs, children) {
  return element2("datalist", attrs, children);
}
function input(attrs) {
  return element2("input", attrs, empty_list);
}
function label(attrs, children) {
  return element2("label", attrs, children);
}
function option(attrs, label2) {
  return element2("option", attrs, toList([text2(label2)]));
}
function output(attrs, children) {
  return element2("output", attrs, children);
}
function select(attrs, children) {
  return element2("select", attrs, children);
}
function textarea(attrs, content) {
  return element2("textarea", prepend(property2("value", string3(content)), attrs), toList([text2(content)]));
}
function dialog(attrs, children) {
  return element2("dialog", attrs, children);
}

// build/dev/javascript/lustre/lustre/vdom/patch.mjs
class Patch extends CustomType {
  constructor(index4, path, removed, changes, children) {
    super();
    this.index = index4;
    this.path = path;
    this.removed = removed;
    this.changes = changes;
    this.children = children;
  }
}
class ReplaceText extends CustomType {
  constructor(kind, content) {
    super();
    this.kind = kind;
    this.content = content;
  }
}
class ReplaceInnerHtml extends CustomType {
  constructor(kind, inner_html) {
    super();
    this.kind = kind;
    this.inner_html = inner_html;
  }
}
class Update extends CustomType {
  constructor(kind, added, removed) {
    super();
    this.kind = kind;
    this.added = added;
    this.removed = removed;
  }
}
class Move extends CustomType {
  constructor(kind, key, before) {
    super();
    this.kind = kind;
    this.key = key;
    this.before = before;
  }
}
class Replace extends CustomType {
  constructor(kind, index4, with$) {
    super();
    this.kind = kind;
    this.index = index4;
    this.with = with$;
  }
}
class Remove extends CustomType {
  constructor(kind, index4) {
    super();
    this.kind = kind;
    this.index = index4;
  }
}
class Insert extends CustomType {
  constructor(kind, children, before) {
    super();
    this.kind = kind;
    this.children = children;
    this.before = before;
  }
}
var replace_text_kind = 0;
var replace_inner_html_kind = 1;
var update_kind = 2;
var move_kind = 3;
var remove_kind = 4;
var replace_kind = 5;
var insert_kind = 6;
function new$3(index4, removed, changes, children) {
  return new Patch(index4, empty_list, removed, changes, children);
}
function replace_text(content) {
  return new ReplaceText(replace_text_kind, content);
}
function replace_inner_html(inner_html) {
  return new ReplaceInnerHtml(replace_inner_html_kind, inner_html);
}
function update(added, removed) {
  return new Update(update_kind, added, removed);
}
function move(key, before) {
  return new Move(move_kind, key, before);
}
function remove2(index4) {
  return new Remove(remove_kind, index4);
}
function replace2(index4, with$) {
  return new Replace(replace_kind, index4, with$);
}
function insert3(children, before) {
  return new Insert(insert_kind, children, before);
}
function add_parent(child, index4) {
  return new Patch(index4, prepend(child.index, child.path), child.removed, child.changes, child.children);
}

// build/dev/javascript/lustre/lustre/runtime/transport.mjs
class Mount extends CustomType {
  constructor(kind, open_shadow_root, will_adopt_styles, observed_attributes, observed_properties, requested_contexts, provided_contexts, vdom, memos) {
    super();
    this.kind = kind;
    this.open_shadow_root = open_shadow_root;
    this.will_adopt_styles = will_adopt_styles;
    this.observed_attributes = observed_attributes;
    this.observed_properties = observed_properties;
    this.requested_contexts = requested_contexts;
    this.provided_contexts = provided_contexts;
    this.vdom = vdom;
    this.memos = memos;
  }
}
class Reconcile extends CustomType {
  constructor(kind, patch, memos) {
    super();
    this.kind = kind;
    this.patch = patch;
    this.memos = memos;
  }
}
class Emit extends CustomType {
  constructor(kind, name, data) {
    super();
    this.kind = kind;
    this.name = name;
    this.data = data;
  }
}
class Provide extends CustomType {
  constructor(kind, key, value2) {
    super();
    this.kind = kind;
    this.key = key;
    this.value = value2;
  }
}
class Subscribe extends CustomType {
  constructor(kind, key) {
    super();
    this.kind = kind;
    this.key = key;
  }
}
class Unsubscribe extends CustomType {
  constructor(kind, key) {
    super();
    this.kind = kind;
    this.key = key;
  }
}
class Batch extends CustomType {
  constructor(kind, messages) {
    super();
    this.kind = kind;
    this.messages = messages;
  }
}
var ServerMessage$isBatch = (value2) => value2 instanceof Batch;
class AttributeChanged extends CustomType {
  constructor(kind, name, value2) {
    super();
    this.kind = kind;
    this.name = name;
    this.value = value2;
  }
}
var ServerMessage$isAttributeChanged = (value2) => value2 instanceof AttributeChanged;
class PropertyChanged extends CustomType {
  constructor(kind, name, value2) {
    super();
    this.kind = kind;
    this.name = name;
    this.value = value2;
  }
}
var ServerMessage$isPropertyChanged = (value2) => value2 instanceof PropertyChanged;
class EventFired extends CustomType {
  constructor(kind, path, name, event2) {
    super();
    this.kind = kind;
    this.path = path;
    this.name = name;
    this.event = event2;
  }
}
var ServerMessage$isEventFired = (value2) => value2 instanceof EventFired;
class ContextProvided extends CustomType {
  constructor(kind, key, value2) {
    super();
    this.kind = kind;
    this.key = key;
    this.value = value2;
  }
}
var ServerMessage$isContextProvided = (value2) => value2 instanceof ContextProvided;
var mount_kind = 0;
var reconcile_kind = 1;
var emit_kind = 2;
var provide_kind = 3;
var subscribe_kind = 4;
var unsubscribe_kind = 5;
function mount(open_shadow_root, will_adopt_styles, observed_attributes, observed_properties, requested_contexts, provided_contexts, vdom, memos) {
  return new Mount(mount_kind, open_shadow_root, will_adopt_styles, observed_attributes, observed_properties, requested_contexts, provided_contexts, vdom, memos);
}
function reconcile(patch, memos) {
  return new Reconcile(reconcile_kind, patch, memos);
}
function emit(name, data) {
  return new Emit(emit_kind, name, data);
}
function provide(key, value2) {
  return new Provide(provide_kind, key, value2);
}
function subscribe(key) {
  return new Subscribe(subscribe_kind, key);
}
function unsubscribe(key) {
  return new Unsubscribe(unsubscribe_kind, key);
}

// build/dev/javascript/lustre/lustre/vdom/path.mjs
class Root extends CustomType {
}
var Path$Root$const = new Root;

class Key extends CustomType {
  constructor(key, parent) {
    super();
    this.key = key;
    this.parent = parent;
  }
}

class Index extends CustomType {
  constructor(index4, parent) {
    super();
    this.index = index4;
    this.parent = parent;
  }
}

class Subtree extends CustomType {
  constructor(parent) {
    super();
    this.parent = parent;
  }
}
var separator_subtree = "\r";
var separator_element = "\t";
var separator_event = `
`;
var root = Path$Root$const;
function finish_to_string(acc) {
  if (acc instanceof Empty) {
    return "";
  } else {
    let segments = acc.tail;
    return concat2(segments);
  }
}
function do_to_string(loop$full, loop$path, loop$acc) {
  while (true) {
    let full = loop$full;
    let path = loop$path;
    let acc = loop$acc;
    if (path instanceof Root) {
      return finish_to_string(acc);
    } else if (path instanceof Key) {
      let key = path.key;
      let parent = path.parent;
      loop$full = full;
      loop$path = parent;
      loop$acc = prepend(separator_element, prepend(key, acc));
    } else if (path instanceof Index) {
      let index4 = path.index;
      let parent = path.parent;
      let acc$1 = prepend(separator_element, prepend(to_string(index4), acc));
      loop$full = full;
      loop$path = parent;
      loop$acc = acc$1;
    } else if (!full) {
      return finish_to_string(acc);
    } else {
      let parent = path.parent;
      if (acc instanceof Empty) {
        loop$full = full;
        loop$path = parent;
        loop$acc = acc;
      } else {
        let acc$1 = acc.tail;
        loop$full = full;
        loop$path = parent;
        loop$acc = prepend(separator_subtree, acc$1);
      }
    }
  }
}
function to_string4(path) {
  return do_to_string(true, path, empty_list);
}
function do_matches(loop$path, loop$candidates) {
  while (true) {
    let path = loop$path;
    let candidates = loop$candidates;
    if (candidates instanceof Empty) {
      return false;
    } else {
      let candidate = candidates.head;
      let rest = candidates.tail;
      let $ = starts_with(path, candidate);
      if ($) {
        return $;
      } else {
        loop$path = path;
        loop$candidates = rest;
      }
    }
  }
}
function matches(path, candidates) {
  if (candidates instanceof Empty) {
    return false;
  } else {
    return do_matches(to_string4(path), candidates);
  }
}
function split_subtree_path(path) {
  return split2(path, separator_subtree);
}
function add2(parent, index4, key) {
  if (key === "") {
    return new Index(index4, parent);
  } else {
    return new Key(key, parent);
  }
}
function subtree(path) {
  return new Subtree(path);
}
function event2(path, event3) {
  return do_to_string(false, path, prepend(separator_event, prepend(event3, empty_list)));
}
function child(path) {
  return do_to_string(false, path, empty_list);
}

// build/dev/javascript/lustre/lustre/vdom/cache.mjs
class Cache extends CustomType {
  constructor(events, vdoms, old_vdoms, dispatched_paths, next_dispatched_paths) {
    super();
    this.events = events;
    this.vdoms = vdoms;
    this.old_vdoms = old_vdoms;
    this.dispatched_paths = dispatched_paths;
    this.next_dispatched_paths = next_dispatched_paths;
  }
}

class Events extends CustomType {
  constructor(handlers, children) {
    super();
    this.handlers = handlers;
    this.children = children;
  }
}

class Child extends CustomType {
  constructor(mapper, events) {
    super();
    this.mapper = mapper;
    this.events = events;
  }
}

class AddedChildren extends CustomType {
  constructor(handlers, children, vdoms) {
    super();
    this.handlers = handlers;
    this.children = children;
    this.vdoms = vdoms;
  }
}

class DecodedEvent extends CustomType {
  constructor(path, handler) {
    super();
    this.path = path;
    this.handler = handler;
  }
}

class DispatchedEvent extends CustomType {
  constructor(path) {
    super();
    this.path = path;
  }
}
function compose_mapper(mapper, child_mapper) {
  return (message) => {
    return mapper(child_mapper(message));
  };
}
function new_events() {
  return new Events(empty2(), empty2());
}
function new$4() {
  return new Cache(new_events(), empty2(), empty2(), empty_list, empty_list);
}
function do_add_event(handlers, path, name, handler) {
  return insert2(handlers, event2(path, name), handler);
}
function add_attributes(handlers, path, attributes) {
  return fold2(attributes, handlers, (events, attribute3) => {
    if (attribute3 instanceof Event2) {
      let name = attribute3.name;
      let handler = attribute3.handler;
      return do_add_event(events, path, name, handler);
    } else {
      return events;
    }
  });
}
function do_add_children(loop$handlers, loop$children, loop$vdoms, loop$parent, loop$child_index, loop$nodes) {
  while (true) {
    let handlers = loop$handlers;
    let children = loop$children;
    let vdoms = loop$vdoms;
    let parent = loop$parent;
    let child_index = loop$child_index;
    let nodes = loop$nodes;
    let next = child_index + 1;
    if (nodes instanceof Empty) {
      return new AddedChildren(handlers, children, vdoms);
    } else {
      let $ = nodes.head;
      if ($ instanceof Fragment) {
        let rest = nodes.tail;
        let key = $.key;
        let nodes$1 = $.children;
        let path = add2(parent, child_index, key);
        let $1 = do_add_children(handlers, children, vdoms, path, 0, nodes$1);
        let handlers$1 = $1.handlers;
        let children$1 = $1.children;
        let vdoms$1 = $1.vdoms;
        loop$handlers = handlers$1;
        loop$children = children$1;
        loop$vdoms = vdoms$1;
        loop$parent = parent;
        loop$child_index = next;
        loop$nodes = rest;
      } else if ($ instanceof Element) {
        let rest = nodes.tail;
        let key = $.key;
        let attributes = $.attributes;
        let nodes$1 = $.children;
        let path = add2(parent, child_index, key);
        let handlers$1 = add_attributes(handlers, path, attributes);
        let $1 = do_add_children(handlers$1, children, vdoms, path, 0, nodes$1);
        let handlers$2 = $1.handlers;
        let children$1 = $1.children;
        let vdoms$1 = $1.vdoms;
        loop$handlers = handlers$2;
        loop$children = children$1;
        loop$vdoms = vdoms$1;
        loop$parent = parent;
        loop$child_index = next;
        loop$nodes = rest;
      } else if ($ instanceof Text) {
        let rest = nodes.tail;
        loop$handlers = handlers;
        loop$children = children;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$child_index = next;
        loop$nodes = rest;
      } else if ($ instanceof UnsafeInnerHtml) {
        let rest = nodes.tail;
        let key = $.key;
        let attributes = $.attributes;
        let path = add2(parent, child_index, key);
        let handlers$1 = add_attributes(handlers, path, attributes);
        loop$handlers = handlers$1;
        loop$children = children;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$child_index = next;
        loop$nodes = rest;
      } else if ($ instanceof Map2) {
        let rest = nodes.tail;
        let key = $.key;
        let mapper = $.mapper;
        let child2 = $.child;
        let path = add2(parent, child_index, key);
        let added = do_add_children(empty2(), empty2(), vdoms, subtree(path), 0, singleton_list(child2));
        let vdoms$1 = added.vdoms;
        let child_events = new Events(added.handlers, added.children);
        let child$1 = new Child(mapper, child_events);
        let children$1 = insert2(children, child(path), child$1);
        loop$handlers = handlers;
        loop$children = children$1;
        loop$vdoms = vdoms$1;
        loop$parent = parent;
        loop$child_index = next;
        loop$nodes = rest;
      } else {
        let rest = nodes.tail;
        let view = $.view;
        let child_node = view();
        let vdoms$1 = insert2(vdoms, view, child_node);
        let next$1 = child_index;
        let rest$1 = prepend(child_node, rest);
        loop$handlers = handlers;
        loop$children = children;
        loop$vdoms = vdoms$1;
        loop$parent = parent;
        loop$child_index = next$1;
        loop$nodes = rest$1;
      }
    }
  }
}
function add_children(cache, events, path, child_index, nodes) {
  let vdoms = cache.vdoms;
  let handlers = events.handlers;
  let children = events.children;
  let $ = do_add_children(handlers, children, vdoms, path, child_index, nodes);
  let handlers$1 = $.handlers;
  let children$1 = $.children;
  let vdoms$1 = $.vdoms;
  return [
    new Cache(cache.events, vdoms$1, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths),
    new Events(handlers$1, children$1)
  ];
}
function add_child(cache, events, parent, index4, child2) {
  let children = singleton_list(child2);
  return add_children(cache, events, parent, index4, children);
}
function from_node(root2) {
  let cache = new$4();
  let $ = add_child(cache, cache.events, root, 0, root2);
  let cache$1 = $[0];
  let events$1 = $[1];
  return new Cache(events$1, cache$1.vdoms, cache$1.old_vdoms, cache$1.dispatched_paths, cache$1.next_dispatched_paths);
}
function tick(cache) {
  return new Cache(cache.events, empty2(), cache.vdoms, cache.next_dispatched_paths, empty_list);
}
function events(cache) {
  return cache.events;
}
function update_events(cache, events2) {
  return new Cache(events2, cache.vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function memos(cache) {
  return cache.vdoms;
}
function get_old_memo(cache, old, new$5) {
  return get_or_compute(cache.old_vdoms, old, new$5);
}
function keep_memo(cache, old, new$5) {
  let node = get_or_compute(cache.old_vdoms, old, new$5);
  let vdoms = insert2(cache.vdoms, new$5, node);
  return new Cache(cache.events, vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function add_memo(cache, new$5, node) {
  let vdoms = insert2(cache.vdoms, new$5, node);
  return new Cache(cache.events, vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function get_subtree(events2, path, old_mapper) {
  let child2 = get_or_compute(events2.children, path, () => {
    return new Child(old_mapper, new_events());
  });
  return child2.events;
}
function update_subtree(parent, path, mapper, events2) {
  let new_child = new Child(mapper, events2);
  let children = insert2(parent.children, path, new_child);
  return new Events(parent.handlers, children);
}
function add_event(events2, path, name, handler) {
  let handlers = do_add_event(events2.handlers, path, name, handler);
  return new Events(handlers, events2.children);
}
function do_remove_event(handlers, path, name) {
  return remove(handlers, event2(path, name));
}
function remove_event(events2, path, name) {
  let handlers = do_remove_event(events2.handlers, path, name);
  return new Events(handlers, events2.children);
}
function remove_attributes(handlers, path, attributes) {
  return fold2(attributes, handlers, (events2, attribute3) => {
    if (attribute3 instanceof Event2) {
      let name = attribute3.name;
      return do_remove_event(events2, path, name);
    } else {
      return events2;
    }
  });
}
function do_remove_children(loop$handlers, loop$children, loop$vdoms, loop$parent, loop$index, loop$nodes) {
  while (true) {
    let handlers = loop$handlers;
    let children = loop$children;
    let vdoms = loop$vdoms;
    let parent = loop$parent;
    let index4 = loop$index;
    let nodes = loop$nodes;
    let next = index4 + 1;
    if (nodes instanceof Empty) {
      return new Events(handlers, children);
    } else {
      let $ = nodes.head;
      if ($ instanceof Fragment) {
        let rest = nodes.tail;
        let key = $.key;
        let nodes$1 = $.children;
        let path = add2(parent, index4, key);
        let $1 = do_remove_children(handlers, children, vdoms, path, 0, nodes$1);
        let handlers$1 = $1.handlers;
        let children$1 = $1.children;
        loop$handlers = handlers$1;
        loop$children = children$1;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$index = next;
        loop$nodes = rest;
      } else if ($ instanceof Element) {
        let rest = nodes.tail;
        let key = $.key;
        let attributes = $.attributes;
        let nodes$1 = $.children;
        let path = add2(parent, index4, key);
        let handlers$1 = remove_attributes(handlers, path, attributes);
        let $1 = do_remove_children(handlers$1, children, vdoms, path, 0, nodes$1);
        let handlers$2 = $1.handlers;
        let children$1 = $1.children;
        loop$handlers = handlers$2;
        loop$children = children$1;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$index = next;
        loop$nodes = rest;
      } else if ($ instanceof Text) {
        let rest = nodes.tail;
        loop$handlers = handlers;
        loop$children = children;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$index = next;
        loop$nodes = rest;
      } else if ($ instanceof UnsafeInnerHtml) {
        let rest = nodes.tail;
        let key = $.key;
        let attributes = $.attributes;
        let path = add2(parent, index4, key);
        let handlers$1 = remove_attributes(handlers, path, attributes);
        loop$handlers = handlers$1;
        loop$children = children;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$index = next;
        loop$nodes = rest;
      } else if ($ instanceof Map2) {
        let rest = nodes.tail;
        let key = $.key;
        let path = add2(parent, index4, key);
        let children$1 = remove(children, child(path));
        loop$handlers = handlers;
        loop$children = children$1;
        loop$vdoms = vdoms;
        loop$parent = parent;
        loop$index = next;
        loop$nodes = rest;
      } else {
        let rest = nodes.tail;
        let view = $.view;
        let $1 = has_key(vdoms, view);
        if ($1) {
          let child2 = get2(vdoms, view);
          let nodes$1 = prepend(child2, rest);
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = index4;
          loop$nodes = nodes$1;
        } else {
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = next;
          loop$nodes = rest;
        }
      }
    }
  }
}
function remove_child(cache, events2, parent, child_index, child2) {
  return do_remove_children(events2.handlers, events2.children, cache.old_vdoms, parent, child_index, singleton_list(child2));
}
function replace_child(cache, events2, parent, child_index, prev, next) {
  let events$1 = remove_child(cache, events2, parent, child_index, prev);
  return add_child(cache, events$1, parent, child_index, next);
}
function get_handler(loop$events, loop$path, loop$mapper) {
  while (true) {
    let events2 = loop$events;
    let path = loop$path;
    let mapper = loop$mapper;
    if (path instanceof Empty) {
      return error_nil;
    } else {
      let $ = path.tail;
      if ($ instanceof Empty) {
        let key = path.head;
        let $1 = has_key(events2.handlers, key);
        if ($1) {
          let handler = get2(events2.handlers, key);
          return new Ok(map3(handler, (handler2) => {
            return new Handler(handler2.prevent_default, handler2.stop_propagation, identity2(mapper)(handler2.message));
          }));
        } else {
          return error_nil;
        }
      } else {
        let key = path.head;
        let path$1 = $;
        let $1 = has_key(events2.children, key);
        if ($1) {
          let child2 = get2(events2.children, key);
          let mapper$1 = compose_mapper(mapper, child2.mapper);
          loop$events = child2.events;
          loop$path = path$1;
          loop$mapper = mapper$1;
        } else {
          return error_nil;
        }
      }
    }
  }
}
function decode2(cache, path, name, event3) {
  let parts = split_subtree_path(path + separator_event + name);
  let $ = get_handler(cache.events, parts, identity2);
  if ($ instanceof Ok) {
    let handler = $[0];
    let $1 = run(event3, handler);
    if ($1 instanceof Ok) {
      let handler$1 = $1[0];
      return new DecodedEvent(path, handler$1);
    } else {
      return new DispatchedEvent(path);
    }
  } else {
    return new DispatchedEvent(path);
  }
}
function dispatch(cache, event3) {
  let next_dispatched_paths = prepend(event3.path, cache.next_dispatched_paths);
  let cache$1 = new Cache(cache.events, cache.vdoms, cache.old_vdoms, cache.dispatched_paths, next_dispatched_paths);
  if (event3 instanceof DecodedEvent) {
    let handler = event3.handler;
    return [cache$1, new Ok(handler)];
  } else {
    return [cache$1, error_nil];
  }
}
function handle(cache, path, name, event3) {
  let _pipe = decode2(cache, path, name, event3);
  return ((_capture) => {
    return dispatch(cache, _capture);
  })(_pipe);
}
function has_dispatched_events(cache, path) {
  return matches(path, cache.dispatched_paths);
}

// build/dev/javascript/lustre/lustre/runtime/server/runtime.mjs
class ClientDispatchedMessage extends CustomType {
  constructor(message) {
    super();
    this.message = message;
  }
}
var Message$isClientDispatchedMessage = (value2) => value2 instanceof ClientDispatchedMessage;
class ClientRegisteredCallback extends CustomType {
  constructor(callback) {
    super();
    this.callback = callback;
  }
}
var Message$isClientRegisteredCallback = (value2) => value2 instanceof ClientRegisteredCallback;
class ClientDeregisteredCallback extends CustomType {
  constructor(callback) {
    super();
    this.callback = callback;
  }
}
var Message$isClientDeregisteredCallback = (value2) => value2 instanceof ClientDeregisteredCallback;
class EffectDispatchedMessage extends CustomType {
  constructor(message) {
    super();
    this.message = message;
  }
}
var Message$EffectDispatchedMessage = (message) => new EffectDispatchedMessage(message);
var Message$isEffectDispatchedMessage = (value2) => value2 instanceof EffectDispatchedMessage;
class EffectEmitEvent extends CustomType {
  constructor(name, data) {
    super();
    this.name = name;
    this.data = data;
  }
}
var Message$EffectEmitEvent = (name, data) => new EffectEmitEvent(name, data);
var Message$isEffectEmitEvent = (value2) => value2 instanceof EffectEmitEvent;
class EffectProvidedValue extends CustomType {
  constructor(key, value2) {
    super();
    this.key = key;
    this.value = value2;
  }
}
var Message$EffectProvidedValue = (key, value2) => new EffectProvidedValue(key, value2);
var Message$isEffectProvidedValue = (value2) => value2 instanceof EffectProvidedValue;
class EffectRequestedContextSubscription extends CustomType {
  constructor(key, decoder) {
    super();
    this.key = key;
    this.decoder = decoder;
  }
}
var Message$EffectRequestedContextSubscription = (key, decoder) => new EffectRequestedContextSubscription(key, decoder);
var Message$isEffectRequestedContextSubscription = (value2) => value2 instanceof EffectRequestedContextSubscription;
class EffectRemovedContextSubscription extends CustomType {
  constructor(key) {
    super();
    this.key = key;
  }
}
var Message$EffectRemovedContextSubscription = (key) => new EffectRemovedContextSubscription(key);
var Message$isEffectRemovedContextSubscription = (value2) => value2 instanceof EffectRemovedContextSubscription;
class SystemRequestedShutdown extends CustomType {
}
var Message$SystemRequestedShutdown$const = new SystemRequestedShutdown;
var Message$isSystemRequestedShutdown = (value2) => value2 instanceof SystemRequestedShutdown;

// build/dev/javascript/lustre/lustre/runtime/app.mjs
class App extends CustomType {
  constructor(name, init, update2, view, config) {
    super();
    this.name = name;
    this.init = init;
    this.update = update2;
    this.view = view;
    this.config = config;
  }
}
class Config2 extends CustomType {
  constructor(open_shadow_root, adopt_styles, delegates_focus, attributes, properties, contexts, is_form_associated, on_form_autofill, on_form_reset, on_form_restore, on_form_disabled, on_connect, on_adopt, on_disconnect) {
    super();
    this.open_shadow_root = open_shadow_root;
    this.adopt_styles = adopt_styles;
    this.delegates_focus = delegates_focus;
    this.attributes = attributes;
    this.properties = properties;
    this.contexts = contexts;
    this.is_form_associated = is_form_associated;
    this.on_form_autofill = on_form_autofill;
    this.on_form_reset = on_form_reset;
    this.on_form_restore = on_form_restore;
    this.on_form_disabled = on_form_disabled;
    this.on_connect = on_connect;
    this.on_adopt = on_adopt;
    this.on_disconnect = on_disconnect;
  }
}
var default_config = /* @__PURE__ */ new Config2(true, true, false, empty_list, empty_list, empty_list, false, Option$None$const, Option$None$const, Option$None$const, Option$None$const, Option$None$const, Option$None$const, Option$None$const);

// build/dev/javascript/lustre/lustre/internals/equals.ffi.mjs
var isEqual2 = (a, b) => {
  if (a === b) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  const type = typeof a;
  if (type !== typeof b) {
    return false;
  }
  if (type !== "object") {
    return false;
  }
  const ctor = a.constructor;
  if (ctor !== b.constructor) {
    return false;
  }
  if (Array.isArray(a)) {
    return areArraysEqual(a, b);
  }
  return areObjectsEqual(a, b);
};
var areArraysEqual = (a, b) => {
  let index4 = a.length;
  if (index4 !== b.length) {
    return false;
  }
  while (index4--) {
    if (!isEqual2(a[index4], b[index4])) {
      return false;
    }
  }
  return true;
};
var areObjectsEqual = (a, b) => {
  const properties = Object.keys(a);
  let index4 = properties.length;
  if (Object.keys(b).length !== index4) {
    return false;
  }
  while (index4--) {
    const property3 = properties[index4];
    if (!Object.hasOwn(b, property3)) {
      return false;
    }
    if (!isEqual2(a[property3], b[property3])) {
      return false;
    }
  }
  return true;
};

// build/dev/javascript/lustre/lustre/vdom/diff.mjs
class Diff extends CustomType {
  constructor(patch, cache) {
    super();
    this.patch = patch;
    this.cache = cache;
  }
}
class PartialDiff extends CustomType {
  constructor(patch, cache, events2) {
    super();
    this.patch = patch;
    this.cache = cache;
    this.events = events2;
  }
}

class AttributeChange extends CustomType {
  constructor(added, removed, events2) {
    super();
    this.added = added;
    this.removed = removed;
    this.events = events2;
  }
}
function diff_attributes(loop$controlled, loop$path, loop$events, loop$old, loop$new, loop$added, loop$removed) {
  while (true) {
    let controlled = loop$controlled;
    let path = loop$path;
    let events2 = loop$events;
    let old = loop$old;
    let new$5 = loop$new;
    let added = loop$added;
    let removed = loop$removed;
    if (old instanceof Empty) {
      if (new$5 instanceof Empty) {
        return new AttributeChange(added, removed, events2);
      } else {
        let $ = new$5.head;
        if ($ instanceof Event2) {
          let next = $;
          let new$1 = new$5.tail;
          let name = $.name;
          let handler = $.handler;
          let events$1 = add_event(events2, path, name, handler);
          let added$1 = prepend(next, added);
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events$1;
          loop$old = old;
          loop$new = new$1;
          loop$added = added$1;
          loop$removed = removed;
        } else {
          let next = $;
          let new$1 = new$5.tail;
          let added$1 = prepend(next, added);
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events2;
          loop$old = old;
          loop$new = new$1;
          loop$added = added$1;
          loop$removed = removed;
        }
      }
    } else if (new$5 instanceof Empty) {
      let $ = old.head;
      if ($ instanceof Event2) {
        let prev = $;
        let old$1 = old.tail;
        let name = $.name;
        let events$1 = remove_event(events2, path, name);
        let removed$1 = prepend(prev, removed);
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events$1;
        loop$old = old$1;
        loop$new = new$5;
        loop$added = added;
        loop$removed = removed$1;
      } else {
        let prev = $;
        let old$1 = old.tail;
        let removed$1 = prepend(prev, removed);
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events2;
        loop$old = old$1;
        loop$new = new$5;
        loop$added = added;
        loop$removed = removed$1;
      }
    } else {
      let prev = old.head;
      let remaining_old = old.tail;
      let next = new$5.head;
      let remaining_new = new$5.tail;
      let $ = compare2(prev, next);
      if ($ instanceof Lt) {
        if (prev instanceof Event2) {
          let name = prev.name;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = remove_event(events2, path, name);
          loop$old = remaining_old;
          loop$new = new$5;
          loop$added = added;
          loop$removed = prepend(prev, removed);
        } else {
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events2;
          loop$old = remaining_old;
          loop$new = new$5;
          loop$added = added;
          loop$removed = prepend(prev, removed);
        }
      } else if ($ instanceof Eq) {
        if (prev instanceof Attribute) {
          if (next instanceof Attribute) {
            let _block;
            let $1 = next.name;
            if ($1 === "value") {
              _block = controlled || prev.value !== next.value;
            } else if ($1 === "checked") {
              _block = controlled || prev.value !== next.value;
            } else if ($1 === "selected") {
              _block = controlled || prev.value !== next.value;
            } else {
              _block = prev.value !== next.value;
            }
            let has_changes = _block;
            let _block$1;
            if (has_changes) {
              _block$1 = prepend(next, added);
            } else {
              _block$1 = added;
            }
            let added$1 = _block$1;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = added$1;
            loop$removed = removed;
          } else if (next instanceof Event2) {
            let name = next.name;
            let handler = next.handler;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = add_event(events2, path, name, handler);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          } else {
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          }
        } else if (prev instanceof Property) {
          if (next instanceof Property) {
            let _block;
            let $1 = next.name;
            if ($1 === "scrollLeft") {
              _block = true;
            } else if ($1 === "scrollRight") {
              _block = true;
            } else if ($1 === "value") {
              _block = controlled || !isEqual2(prev.value, next.value);
            } else if ($1 === "checked") {
              _block = controlled || !isEqual2(prev.value, next.value);
            } else if ($1 === "selected") {
              _block = controlled || !isEqual2(prev.value, next.value);
            } else {
              _block = !isEqual2(prev.value, next.value);
            }
            let has_changes = _block;
            let _block$1;
            if (has_changes) {
              _block$1 = prepend(next, added);
            } else {
              _block$1 = added;
            }
            let added$1 = _block$1;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = added$1;
            loop$removed = removed;
          } else if (next instanceof Event2) {
            let name = next.name;
            let handler = next.handler;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = add_event(events2, path, name, handler);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          } else {
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events2;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          }
        } else if (next instanceof Event2) {
          let name = next.name;
          let handler = next.handler;
          let has_changes = prev.prevent_default.kind !== next.prevent_default.kind || prev.stop_propagation.kind !== next.stop_propagation.kind || prev.debounce !== next.debounce || prev.throttle !== next.throttle;
          let _block;
          if (has_changes) {
            _block = prepend(next, added);
          } else {
            _block = added;
          }
          let added$1 = _block;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = add_event(events2, path, name, handler);
          loop$old = remaining_old;
          loop$new = remaining_new;
          loop$added = added$1;
          loop$removed = removed;
        } else {
          let name = prev.name;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = remove_event(events2, path, name);
          loop$old = remaining_old;
          loop$new = remaining_new;
          loop$added = prepend(next, added);
          loop$removed = prepend(prev, removed);
        }
      } else if (next instanceof Event2) {
        let name = next.name;
        let handler = next.handler;
        loop$controlled = controlled;
        loop$path = path;
        loop$events = add_event(events2, path, name, handler);
        loop$old = old;
        loop$new = remaining_new;
        loop$added = prepend(next, added);
        loop$removed = removed;
      } else {
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events2;
        loop$old = old;
        loop$new = remaining_new;
        loop$added = prepend(next, added);
        loop$removed = removed;
      }
    }
  }
}
function is_controlled(cache, namespace, tag, path) {
  if (tag === "input" && namespace === "") {
    return has_dispatched_events(cache, path);
  } else if (tag === "select" && namespace === "") {
    return has_dispatched_events(cache, path);
  } else if (tag === "textarea" && namespace === "") {
    return has_dispatched_events(cache, path);
  } else {
    return false;
  }
}
function do_diff(loop$old, loop$old_keyed, loop$new, loop$new_keyed, loop$moved, loop$moved_offset, loop$removed, loop$node_index, loop$patch_index, loop$changes, loop$children, loop$path, loop$cache, loop$events) {
  while (true) {
    let old = loop$old;
    let old_keyed = loop$old_keyed;
    let new$5 = loop$new;
    let new_keyed = loop$new_keyed;
    let moved = loop$moved;
    let moved_offset = loop$moved_offset;
    let removed = loop$removed;
    let node_index = loop$node_index;
    let patch_index = loop$patch_index;
    let changes = loop$changes;
    let children = loop$children;
    let path = loop$path;
    let cache = loop$cache;
    let events2 = loop$events;
    if (old instanceof Empty) {
      if (new$5 instanceof Empty) {
        let _block;
        let $ = is_browser();
        if (changes instanceof Empty) {
          if (children instanceof Empty) {
            _block = new$3(patch_index, removed, changes, children);
          } else if (!$) {
            let $1 = children.tail;
            if ($1 instanceof Empty && removed === 0) {
              let child2 = children.head;
              _block = add_parent(child2, patch_index);
            } else {
              _block = new$3(patch_index, removed, changes, children);
            }
          } else {
            _block = new$3(patch_index, removed, changes, children);
          }
        } else {
          _block = new$3(patch_index, removed, changes, children);
        }
        let patch = _block;
        return new PartialDiff(patch, cache, events2);
      } else {
        let $ = add_children(cache, events2, path, node_index, new$5);
        let cache$1 = $[0];
        let events$1 = $[1];
        let insert4 = insert3(new$5, node_index - moved_offset);
        let changes$1 = prepend(insert4, changes);
        let patch = new$3(patch_index, removed, changes$1, children);
        return new PartialDiff(patch, cache$1, events$1);
      }
    } else if (new$5 instanceof Empty) {
      let prev = old.head;
      let old$1 = old.tail;
      let $ = prev.key === "" || !has_key(moved, prev.key);
      if ($) {
        let events$1 = remove_child(cache, events2, path, node_index, prev);
        loop$old = old$1;
        loop$old_keyed = old_keyed;
        loop$new = new$5;
        loop$new_keyed = new_keyed;
        loop$moved = moved;
        loop$moved_offset = moved_offset;
        loop$removed = removed + 1;
        loop$node_index = node_index;
        loop$patch_index = patch_index;
        loop$changes = changes;
        loop$children = children;
        loop$path = path;
        loop$cache = cache;
        loop$events = events$1;
      } else {
        loop$old = old$1;
        loop$old_keyed = old_keyed;
        loop$new = new$5;
        loop$new_keyed = new_keyed;
        loop$moved = moved;
        loop$moved_offset = moved_offset;
        loop$removed = removed;
        loop$node_index = node_index;
        loop$patch_index = patch_index;
        loop$changes = changes;
        loop$children = children;
        loop$path = path;
        loop$cache = cache;
        loop$events = events2;
      }
    } else {
      let prev = old.head;
      let next = new$5.head;
      if (prev.key !== next.key) {
        let old_remaining = old.tail;
        let new_remaining = new$5.tail;
        let next_did_exist = has_key(old_keyed, next.key);
        let prev_does_exist = has_key(new_keyed, prev.key);
        if (prev_does_exist) {
          if (next_did_exist) {
            let $ = has_key(moved, prev.key);
            if ($) {
              loop$old = old_remaining;
              loop$old_keyed = old_keyed;
              loop$new = new$5;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset - 1;
              loop$removed = removed;
              loop$node_index = node_index;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children;
              loop$path = path;
              loop$cache = cache;
              loop$events = events2;
            } else {
              let match = get2(old_keyed, next.key);
              let before = node_index - moved_offset;
              let changes$1 = prepend(move(next.key, before), changes);
              let moved$1 = insert2(moved, next.key, undefined);
              loop$old = prepend(match, old);
              loop$old_keyed = old_keyed;
              loop$new = new$5;
              loop$new_keyed = new_keyed;
              loop$moved = moved$1;
              loop$moved_offset = moved_offset + 1;
              loop$removed = removed;
              loop$node_index = node_index;
              loop$patch_index = patch_index;
              loop$changes = changes$1;
              loop$children = children;
              loop$path = path;
              loop$cache = cache;
              loop$events = events2;
            }
          } else {
            let before = node_index - moved_offset;
            let $ = add_child(cache, events2, path, node_index, next);
            let cache$1 = $[0];
            let events$1 = $[1];
            let insert4 = insert3(singleton_list(next), before);
            let changes$1 = prepend(insert4, changes);
            loop$old = old;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset + 1;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = changes$1;
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else if (next_did_exist) {
          let index4 = node_index - moved_offset;
          let changes$1 = prepend(remove2(index4), changes);
          let events$1 = remove_child(cache, events2, path, node_index, prev);
          loop$old = old_remaining;
          loop$old_keyed = old_keyed;
          loop$new = new$5;
          loop$new_keyed = new_keyed;
          loop$moved = moved;
          loop$moved_offset = moved_offset - 1;
          loop$removed = removed;
          loop$node_index = node_index;
          loop$patch_index = patch_index;
          loop$changes = changes$1;
          loop$children = children;
          loop$path = path;
          loop$cache = cache;
          loop$events = events$1;
        } else {
          let change = replace2(node_index - moved_offset, next);
          let $ = replace_child(cache, events2, path, node_index, prev, next);
          let cache$1 = $[0];
          let events$1 = $[1];
          loop$old = old_remaining;
          loop$old_keyed = old_keyed;
          loop$new = new_remaining;
          loop$new_keyed = new_keyed;
          loop$moved = moved;
          loop$moved_offset = moved_offset;
          loop$removed = removed;
          loop$node_index = node_index + 1;
          loop$patch_index = patch_index;
          loop$changes = prepend(change, changes);
          loop$children = children;
          loop$path = path;
          loop$cache = cache$1;
          loop$events = events$1;
        }
      } else {
        let $ = old.head;
        if ($ instanceof Fragment) {
          let $1 = new$5.head;
          if ($1 instanceof Fragment) {
            let prev2 = $;
            let old$1 = old.tail;
            let next2 = $1;
            let new$1 = new$5.tail;
            let $2 = do_diff(prev2.children, prev2.keyed_children, next2.children, next2.keyed_children, empty2(), 0, 0, 0, node_index, empty_list, empty_list, add2(path, node_index, next2.key), cache, events2);
            let patch = $2.patch;
            let cache$1 = $2.cache;
            let events$1 = $2.events;
            let _block;
            let $3 = patch.changes;
            if ($3 instanceof Empty) {
              let $4 = patch.children;
              if ($4 instanceof Empty) {
                let $5 = patch.removed;
                if ($5 === 0) {
                  _block = children;
                } else {
                  _block = prepend(patch, children);
                }
              } else {
                _block = prepend(patch, children);
              }
            } else {
              _block = prepend(patch, children);
            }
            let children$1 = _block;
            loop$old = old$1;
            loop$old_keyed = old_keyed;
            loop$new = new$1;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = changes;
            loop$children = children$1;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else if ($ instanceof Element) {
          let $1 = new$5.head;
          if ($1 instanceof Element) {
            let prev2 = $;
            let next2 = $1;
            if (prev2.namespace === next2.namespace && prev2.tag === next2.tag) {
              let old$1 = old.tail;
              let new$1 = new$5.tail;
              let child_path = add2(path, node_index, next2.key);
              let controlled = is_controlled(cache, next2.namespace, next2.tag, child_path);
              let $2 = diff_attributes(controlled, child_path, events2, prev2.attributes, next2.attributes, empty_list, empty_list);
              let added_attrs = $2.added;
              let removed_attrs = $2.removed;
              let events$1 = $2.events;
              let _block;
              if (added_attrs instanceof Empty && removed_attrs instanceof Empty) {
                _block = empty_list;
              } else {
                _block = singleton_list(update(added_attrs, removed_attrs));
              }
              let initial_child_changes = _block;
              let $3 = do_diff(prev2.children, prev2.keyed_children, next2.children, next2.keyed_children, empty2(), 0, 0, 0, node_index, initial_child_changes, empty_list, child_path, cache, events$1);
              let patch = $3.patch;
              let cache$1 = $3.cache;
              let events$2 = $3.events;
              let _block$1;
              let $4 = patch.changes;
              if ($4 instanceof Empty) {
                let $5 = patch.children;
                if ($5 instanceof Empty) {
                  let $6 = patch.removed;
                  if ($6 === 0) {
                    _block$1 = children;
                  } else {
                    _block$1 = prepend(patch, children);
                  }
                } else {
                  _block$1 = prepend(patch, children);
                }
              } else {
                _block$1 = prepend(patch, children);
              }
              let children$1 = _block$1;
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children$1;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$2;
            } else {
              let prev3 = $;
              let old_remaining = old.tail;
              let next3 = $1;
              let new_remaining = new$5.tail;
              let change = replace2(node_index - moved_offset, next3);
              let $2 = replace_child(cache, events2, path, node_index, prev3, next3);
              let cache$1 = $2[0];
              let events$1 = $2[1];
              loop$old = old_remaining;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events$1;
            }
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else if ($ instanceof Text) {
          let $1 = new$5.head;
          if ($1 instanceof Text) {
            let prev2 = $;
            let next2 = $1;
            if (prev2.content === next2.content) {
              let old$1 = old.tail;
              let new$1 = new$5.tail;
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children;
              loop$path = path;
              loop$cache = cache;
              loop$events = events2;
            } else {
              let old$1 = old.tail;
              let next3 = $1;
              let new$1 = new$5.tail;
              let child2 = new$3(node_index, 0, singleton_list(replace_text(next3.content)), empty_list);
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = prepend(child2, children);
              loop$path = path;
              loop$cache = cache;
              loop$events = events2;
            }
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else if ($ instanceof UnsafeInnerHtml) {
          let $1 = new$5.head;
          if ($1 instanceof UnsafeInnerHtml) {
            let prev2 = $;
            let old$1 = old.tail;
            let next2 = $1;
            let new$1 = new$5.tail;
            let child_path = add2(path, node_index, next2.key);
            let $2 = diff_attributes(false, child_path, events2, prev2.attributes, next2.attributes, empty_list, empty_list);
            let added_attrs = $2.added;
            let removed_attrs = $2.removed;
            let events$1 = $2.events;
            let _block;
            if (added_attrs instanceof Empty && removed_attrs instanceof Empty) {
              _block = empty_list;
            } else {
              _block = singleton_list(update(added_attrs, removed_attrs));
            }
            let child_changes = _block;
            let _block$1;
            let $3 = prev2.inner_html === next2.inner_html;
            if ($3) {
              _block$1 = child_changes;
            } else {
              _block$1 = prepend(replace_inner_html(next2.inner_html), child_changes);
            }
            let child_changes$1 = _block$1;
            let _block$2;
            if (child_changes$1 instanceof Empty) {
              _block$2 = children;
            } else {
              _block$2 = prepend(new$3(node_index, 0, child_changes$1, empty_list), children);
            }
            let children$1 = _block$2;
            loop$old = old$1;
            loop$old_keyed = old_keyed;
            loop$new = new$1;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = changes;
            loop$children = children$1;
            loop$path = path;
            loop$cache = cache;
            loop$events = events$1;
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else if ($ instanceof Map2) {
          let $1 = new$5.head;
          if ($1 instanceof Map2) {
            let prev2 = $;
            let old$1 = old.tail;
            let next2 = $1;
            let new$1 = new$5.tail;
            let child_path = add2(path, node_index, next2.key);
            let child_key = child(child_path);
            let $2 = do_diff(singleton_list(prev2.child), empty2(), singleton_list(next2.child), empty2(), empty2(), 0, 0, 0, node_index, empty_list, empty_list, subtree(child_path), cache, get_subtree(events2, child_key, prev2.mapper));
            let patch = $2.patch;
            let cache$1 = $2.cache;
            let child_events = $2.events;
            let events$1 = update_subtree(events2, child_key, next2.mapper, child_events);
            let _block;
            let $3 = patch.changes;
            if ($3 instanceof Empty) {
              let $4 = patch.children;
              if ($4 instanceof Empty) {
                let $5 = patch.removed;
                if ($5 === 0) {
                  _block = children;
                } else {
                  _block = prepend(patch, children);
                }
              } else {
                _block = prepend(patch, children);
              }
            } else {
              _block = prepend(patch, children);
            }
            let children$1 = _block;
            loop$old = old$1;
            loop$old_keyed = old_keyed;
            loop$new = new$1;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = changes;
            loop$children = children$1;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        } else {
          let $1 = new$5.head;
          if ($1 instanceof Memo) {
            let prev2 = $;
            let old$1 = old.tail;
            let next2 = $1;
            let new$1 = new$5.tail;
            let $2 = equal_lists(prev2.dependencies, next2.dependencies);
            if ($2) {
              let cache$1 = keep_memo(cache, prev2.view, next2.view);
              loop$old = old$1;
              loop$old_keyed = old_keyed;
              loop$new = new$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events2;
            } else {
              let prev_node = get_old_memo(cache, prev2.view, prev2.view);
              let next_node = next2.view();
              let cache$1 = add_memo(cache, next2.view, next_node);
              loop$old = prepend(prev_node, old$1);
              loop$old_keyed = old_keyed;
              loop$new = prepend(next_node, new$1);
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = children;
              loop$path = path;
              loop$cache = cache$1;
              loop$events = events2;
            }
          } else {
            let prev2 = $;
            let old_remaining = old.tail;
            let next2 = $1;
            let new_remaining = new$5.tail;
            let change = replace2(node_index - moved_offset, next2);
            let $2 = replace_child(cache, events2, path, node_index, prev2, next2);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining;
            loop$new_keyed = new_keyed;
            loop$moved = moved;
            loop$moved_offset = moved_offset;
            loop$removed = removed;
            loop$node_index = node_index + 1;
            loop$patch_index = patch_index;
            loop$changes = prepend(change, changes);
            loop$children = children;
            loop$path = path;
            loop$cache = cache$1;
            loop$events = events$1;
          }
        }
      }
    }
  }
}
function diff(cache, old, new$5) {
  let cache$1 = tick(cache);
  let $ = do_diff(singleton_list(old), empty2(), singleton_list(new$5), empty2(), empty2(), 0, 0, 0, 0, empty_list, empty_list, root, cache$1, events(cache$1));
  let patch = $.patch;
  let cache$2 = $.cache;
  let events2 = $.events;
  return new Diff(patch, update_events(cache$2, events2));
}

// build/dev/javascript/lustre/lustre/internals/list.ffi.mjs
var toList2 = (arr) => arr.reduceRight((xs, x) => List$NonEmpty(x, xs), empty_list);
var iterate = (list4, callback) => {
  if (Array.isArray(list4)) {
    for (let i = 0;i < list4.length; i++) {
      callback(list4[i]);
    }
  } else if (list4) {
    for (list4;List$NonEmpty$rest(list4); list4 = List$NonEmpty$rest(list4)) {
      callback(List$NonEmpty$first(list4));
    }
  }
};
var append4 = (a, b) => {
  if (!List$NonEmpty$rest(a)) {
    return b;
  } else if (!List$NonEmpty$rest(b)) {
    return a;
  } else {
    return append(a, b);
  }
};

// build/dev/javascript/lustre/lustre/internals/constants.ffi.mjs
var NAMESPACE_HTML = "http://www.w3.org/1999/xhtml";
var ELEMENT_NODE = 1;
var TEXT_NODE = 3;
var COMMENT_NODE = 8;
var SUPPORTS_MOVE_BEFORE = !!globalThis.HTMLElement?.prototype?.moveBefore;

// build/dev/javascript/lustre/lustre/vdom/reconciler.ffi.mjs
var setTimeout = globalThis.setTimeout;
var clearTimeout = globalThis.clearTimeout;
var createElementNS = (ns, name) => globalThis.document.createElementNS(ns, name);
var createTextNode = (data) => globalThis.document.createTextNode(data);
var createComment = (data) => globalThis.document.createComment(data);
var createDocumentFragment = () => globalThis.document.createDocumentFragment();
var insertBefore = (parent, node, reference) => parent.insertBefore(node, reference);
var moveBefore = SUPPORTS_MOVE_BEFORE ? (parent, node, reference) => parent.moveBefore(node, reference) : insertBefore;
var removeChild = (parent, child2) => parent.removeChild(child2);
var getAttribute = (node, name) => node.getAttribute(name);
var setAttribute = (node, name, value2) => node.setAttribute(name, value2);
var removeAttribute = (node, name) => node.removeAttribute(name);
var addEventListener = (node, name, handler, options) => node.addEventListener(name, handler, options);
var removeEventListener = (node, name, handler) => node.removeEventListener(name, handler);
var setInnerHtml = (node, innerHtml) => node.innerHTML = innerHtml;
var setData = (node, data) => node.data = data;
var meta = Symbol("lustre");

class MetadataNode {
  constructor(kind, parent, node, key) {
    this.kind = kind;
    this.key = key;
    this.parent = parent;
    this.children = [];
    this.node = node;
    this.endNode = null;
    this.handlers = new Map;
    this.throttles = new Map;
    this.debouncers = new Map;
  }
  get isVirtual() {
    return this.kind === fragment_kind || this.kind === map_kind;
  }
  get parentNode() {
    return this.isVirtual ? this.node.parentNode : this.node;
  }
}
var insertMetadataChild = (kind, parent, node, index4, key) => {
  const child2 = new MetadataNode(kind, parent, node, key);
  node[meta] = child2;
  parent?.children.splice(index4, 0, child2);
  return child2;
};
var getPath = (node) => {
  let path = "";
  for (let current = node[meta];current.parent; current = current.parent) {
    const separator = current.parent && current.parent.kind === map_kind ? separator_subtree : separator_element;
    if (current.key) {
      path = `${separator}${current.key}${path}`;
    } else {
      const index4 = current.parent.children.indexOf(current);
      path = `${separator}${index4}${path}`;
    }
  }
  return path.slice(1);
};

class Reconciler {
  #root = null;
  #decodeEvent;
  #dispatch;
  #debug = false;
  constructor(root2, decodeEvent, dispatch2, { debug = false } = {}) {
    this.#root = root2;
    this.#decodeEvent = decodeEvent;
    this.#dispatch = dispatch2;
    this.#debug = debug;
  }
  mount(vdom) {
    insertMetadataChild(element_kind, null, this.#root, 0, null);
    this.#insertChild(this.#root, null, this.#root[meta], 0, vdom);
  }
  push(patch, memos2 = null) {
    this.#memos = memos2;
    this.#stack.push({ node: this.#root[meta], patch });
    this.#reconcile();
  }
  #memos;
  #stack = [];
  #reconcile() {
    const stack = this.#stack;
    while (stack.length) {
      let { node, patch } = stack.pop();
      const { path, changes, removed, children: childPatches } = patch;
      iterate(path, (index4) => {
        node = node.children[index4];
      });
      const { children: childNodes } = node;
      iterate(changes, (change) => this.#patch(node, change));
      if (removed) {
        this.#removeChildren(node, childNodes.length - removed, removed);
      }
      iterate(childPatches, (childPatch) => {
        const child2 = childNodes[childPatch.index | 0];
        this.#stack.push({ node: child2, patch: childPatch });
      });
    }
  }
  #patch(node, change) {
    switch (change.kind) {
      case replace_text_kind:
        this.#replaceText(node, change);
        break;
      case replace_inner_html_kind:
        this.#replaceInnerHtml(node, change);
        break;
      case update_kind:
        this.#update(node, change);
        break;
      case move_kind:
        this.#move(node, change);
        break;
      case remove_kind:
        this.#remove(node, change);
        break;
      case replace_kind:
        this.#replace(node, change);
        break;
      case insert_kind:
        this.#insert(node, change);
        break;
    }
  }
  #insert(parent, { children, before }) {
    const fragment2 = createDocumentFragment();
    const beforeEl = this.#getReference(parent, before);
    this.#insertChildren(fragment2, null, parent, before | 0, children);
    insertBefore(parent.parentNode, fragment2, beforeEl);
  }
  #replace(parent, { index: index4, with: child2 }) {
    this.#removeChildren(parent, index4 | 0, 1);
    const beforeEl = this.#getReference(parent, index4);
    this.#insertChild(parent.parentNode, beforeEl, parent, index4 | 0, child2);
  }
  #getReference(node, index4) {
    index4 = index4 | 0;
    const { children } = node;
    const childCount = children.length;
    if (index4 < childCount)
      return children[index4].node;
    if (node.endNode)
      return node.endNode;
    if (!node.isVirtual)
      return null;
    while (node.isVirtual && node.children.length) {
      if (node.endNode)
        return node.endNode.nextSibling;
      node = node.children[node.children.length - 1];
    }
    return node.node.nextSibling;
  }
  #move(parent, { key, before }) {
    before = before | 0;
    const { children, parentNode } = parent;
    const beforeEl = children[before].node;
    let prev = children[before];
    for (let i = before + 1;i < children.length; ++i) {
      const next = children[i];
      children[i] = prev;
      prev = next;
      if (next.key === key) {
        children[before] = next;
        break;
      }
    }
    this.#moveChild(parentNode, prev, beforeEl);
  }
  #moveChildren(domParent, children, beforeEl) {
    for (let i = 0;i < children.length; ++i) {
      this.#moveChild(domParent, children[i], beforeEl);
    }
  }
  #moveChild(domParent, child2, beforeEl) {
    moveBefore(domParent, child2.node, beforeEl);
    if (child2.isVirtual) {
      this.#moveChildren(domParent, child2.children, beforeEl);
    }
    if (child2.endNode) {
      moveBefore(domParent, child2.endNode, beforeEl);
    }
  }
  #remove(parent, { index: index4 }) {
    this.#removeChildren(parent, index4, 1);
  }
  #removeChildren(parent, index4, count) {
    const { children, parentNode } = parent;
    const deleted = children.splice(index4, count);
    for (let i = 0;i < deleted.length; ++i) {
      const child2 = deleted[i];
      const { node, endNode, isVirtual, children: nestedChildren } = child2;
      removeChild(parentNode, node);
      if (endNode) {
        removeChild(parentNode, endNode);
      }
      this.#removeDebouncers(child2);
      if (isVirtual) {
        deleted.push(...nestedChildren);
      }
    }
  }
  #removeDebouncers(node) {
    const { debouncers, children } = node;
    for (const { timeout } of debouncers.values()) {
      if (timeout) {
        clearTimeout(timeout);
      }
    }
    debouncers.clear();
    iterate(children, (child2) => this.#removeDebouncers(child2));
  }
  #update({ node, handlers, throttles, debouncers }, { added, removed }) {
    iterate(removed, ({ name }) => {
      if (handlers.delete(name)) {
        removeEventListener(node, name, handleEvent);
        this.#updateDebounceThrottle(throttles, name, 0);
        this.#updateDebounceThrottle(debouncers, name, 0);
      } else {
        removeAttribute(node, name);
        SYNCED_ATTRIBUTES[name]?.removed?.(node, name);
      }
    });
    iterate(added, (attribute3) => this.#createAttribute(node, attribute3));
  }
  #replaceText({ node }, { content }) {
    setData(node, content ?? "");
  }
  #replaceInnerHtml({ node }, { inner_html }) {
    setInnerHtml(node, inner_html ?? "");
  }
  #insertChildren(domParent, beforeEl, metaParent, index4, children) {
    iterate(children, (child2) => this.#insertChild(domParent, beforeEl, metaParent, index4++, child2));
  }
  #insertChild(domParent, beforeEl, metaParent, index4, vnode) {
    switch (vnode.kind) {
      case element_kind: {
        const node = this.#createElement(metaParent, index4, vnode);
        this.#insertChildren(node, null, node[meta], 0, vnode.children);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case text_kind: {
        const node = this.#createTextNode(metaParent, index4, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case fragment_kind: {
        const marker = "lustre:fragment";
        const head = this.#createHead(marker, metaParent, index4, vnode);
        insertBefore(domParent, head, beforeEl);
        this.#insertChildren(domParent, beforeEl, head[meta], 0, vnode.children);
        if (this.#debug) {
          head[meta].endNode = createComment(` /${marker} `);
          insertBefore(domParent, head[meta].endNode, beforeEl);
        }
        break;
      }
      case unsafe_inner_html_kind: {
        const node = this.#createElement(metaParent, index4, vnode);
        this.#replaceInnerHtml({ node }, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case map_kind: {
        const head = this.#createHead("lustre:map", metaParent, index4, vnode);
        insertBefore(domParent, head, beforeEl);
        this.#insertChild(domParent, beforeEl, head[meta], 0, vnode.child);
        break;
      }
      case memo_kind: {
        const child2 = this.#memos?.get(vnode.view) ?? vnode.view();
        this.#insertChild(domParent, beforeEl, metaParent, index4, child2);
        break;
      }
    }
  }
  #createElement(parent, index4, { kind, key, tag, namespace, attributes }) {
    const node = createElementNS(namespace || NAMESPACE_HTML, tag);
    insertMetadataChild(kind, parent, node, index4, key);
    if (this.#debug && key) {
      setAttribute(node, "data-lustre-key", key);
    }
    iterate(attributes, (attribute3) => this.#createAttribute(node, attribute3));
    return node;
  }
  #createTextNode(parent, index4, { kind, key, content }) {
    const node = createTextNode(content ?? "");
    insertMetadataChild(kind, parent, node, index4, key);
    return node;
  }
  #createHead(marker, parent, index4, { kind, key }) {
    const node = this.#debug ? createComment(markerComment(marker, key)) : createTextNode("");
    insertMetadataChild(kind, parent, node, index4, key);
    return node;
  }
  #createAttribute(node, attribute3) {
    const { debouncers, handlers, throttles } = node[meta];
    const {
      kind,
      name,
      value: value2,
      prevent_default: prevent,
      debounce: debounceDelay,
      throttle: throttleDelay
    } = attribute3;
    switch (kind) {
      case attribute_kind: {
        const valueOrDefault = value2 ?? "";
        if (name === "virtual:defaultValue") {
          node.defaultValue = valueOrDefault;
          return;
        } else if (name === "virtual:defaultChecked") {
          node.defaultChecked = true;
          return;
        } else if (name === "virtual:defaultSelected") {
          node.defaultSelected = true;
          return;
        }
        if (valueOrDefault !== getAttribute(node, name)) {
          setAttribute(node, name, valueOrDefault);
        }
        SYNCED_ATTRIBUTES[name]?.added?.(node, valueOrDefault);
        break;
      }
      case property_kind:
        node[name] = value2;
        break;
      case event_kind: {
        if (handlers.has(name)) {
          removeEventListener(node, name, handleEvent);
        }
        const passive = prevent.kind === never_kind;
        addEventListener(node, name, handleEvent, { passive });
        this.#updateDebounceThrottle(throttles, name, throttleDelay);
        this.#updateDebounceThrottle(debouncers, name, debounceDelay);
        handlers.set(name, (event3) => this.#handleEvent(attribute3, event3));
        break;
      }
    }
  }
  #updateDebounceThrottle(map6, name, delay) {
    const debounceOrThrottle = map6.get(name);
    if (delay > 0) {
      if (debounceOrThrottle) {
        debounceOrThrottle.delay = delay;
      } else {
        map6.set(name, { delay });
      }
    } else if (debounceOrThrottle) {
      const { timeout } = debounceOrThrottle;
      if (timeout) {
        clearTimeout(timeout);
      }
      map6.delete(name);
    }
  }
  #handleEvent(attribute3, event3) {
    const { currentTarget, type } = event3;
    const { debouncers, throttles } = currentTarget[meta];
    const path = getPath(currentTarget);
    const {
      prevent_default: prevent,
      stop_propagation: stop,
      include
    } = attribute3;
    if (prevent.kind === always_kind)
      event3.preventDefault();
    if (stop.kind === always_kind)
      event3.stopPropagation();
    if (type === "submit") {
      event3.detail ??= {};
      event3.detail.formData = [
        ...new FormData(event3.target, event3.submitter).entries()
      ];
    }
    const data = this.#decodeEvent(event3, path, type, include);
    const throttle = throttles.get(type);
    if (throttle) {
      const now = Date.now();
      const last = throttle.last || 0;
      if (now > last + throttle.delay) {
        throttle.last = now;
        throttle.lastEvent = event3;
        this.#dispatch(event3, data);
      }
    }
    const debounce = debouncers.get(type);
    if (debounce) {
      clearTimeout(debounce.timeout);
      debounce.timeout = setTimeout(() => {
        if (event3 === throttles.get(type)?.lastEvent)
          return;
        this.#dispatch(event3, data);
      }, debounce.delay);
    }
    if (!throttle && !debounce) {
      this.#dispatch(event3, data);
    }
  }
}
var markerComment = (marker, key) => {
  if (key) {
    return ` ${marker} key="${escape(key)}" `;
  } else {
    return ` ${marker} `;
  }
};
var handleEvent = (event3) => {
  const { currentTarget, type } = event3;
  const handler = currentTarget[meta].handlers.get(type);
  handler(event3);
};
var syncedBooleanAttribute = (name) => {
  return {
    added(node) {
      node[name] = true;
    },
    removed(node) {
      node[name] = false;
    }
  };
};
var syncedAttribute = (name) => {
  return {
    added(node, value2) {
      node[name] = value2;
    }
  };
};
var SYNCED_ATTRIBUTES = {
  checked: syncedBooleanAttribute("checked"),
  selected: syncedBooleanAttribute("selected"),
  value: syncedAttribute("value"),
  autofocus: {
    added(node) {
      queueMicrotask(() => {
        node.focus?.();
      });
    }
  },
  autoplay: {
    added(node) {
      try {
        node.play?.();
      } catch (e) {
        console.error(e);
      }
    }
  }
};

// build/dev/javascript/lustre/lustre/element/keyed.mjs
function do_extract_keyed_children(loop$key_children_pairs, loop$keyed_children, loop$children) {
  while (true) {
    let key_children_pairs = loop$key_children_pairs;
    let keyed_children = loop$keyed_children;
    let children = loop$children;
    if (key_children_pairs instanceof Empty) {
      return [keyed_children, reverse(children)];
    } else {
      let rest = key_children_pairs.tail;
      let key = key_children_pairs.head[0];
      let element$1 = key_children_pairs.head[1];
      let keyed_element = to_keyed(key, element$1);
      let _block;
      if (key === "") {
        _block = keyed_children;
      } else {
        _block = insert2(keyed_children, key, keyed_element);
      }
      let keyed_children$1 = _block;
      let children$1 = prepend(keyed_element, children);
      loop$key_children_pairs = rest;
      loop$keyed_children = keyed_children$1;
      loop$children = children$1;
    }
  }
}
function extract_keyed_children(children) {
  return do_extract_keyed_children(children, empty2(), empty_list);
}
function element3(tag, attributes, children) {
  let $ = extract_keyed_children(children);
  let keyed_children = $[0];
  let children$1 = $[1];
  return element("", "", tag, attributes, children$1, keyed_children, false, is_void_html_element(tag, ""));
}
function namespaced2(namespace, tag, attributes, children) {
  let $ = extract_keyed_children(children);
  let keyed_children = $[0];
  let children$1 = $[1];
  return element("", namespace, tag, attributes, children$1, keyed_children, false, is_void_html_element(tag, namespace));
}
function fragment2(children) {
  let $ = extract_keyed_children(children);
  let keyed_children = $[0];
  let children$1 = $[1];
  return fragment("", children$1, keyed_children);
}

// build/dev/javascript/lustre/lustre/vdom/virtualise.ffi.mjs
var virtualise = (root2) => {
  const rootMeta = insertMetadataChild(element_kind, null, root2, 0, null);
  const { children } = virtualiseChildren(rootMeta, root2, root2.firstChild);
  if (children.length > 1) {
    const rootNodeMeta = insertMetadataChild(element_kind, null, root2, 0, null);
    rootMeta.kind = fragment_kind;
    rootMeta.node = globalThis.document.createTextNode("");
    rootMeta.parent = rootNodeMeta;
    rootNodeMeta.children.push(rootMeta);
    root2.insertBefore(rootMeta.node, root2.firstChild);
    return fragment2(toList3(children));
  }
  if (children.length === 1) {
    return children[0][1];
  }
  const placeholder2 = globalThis.document.createTextNode("");
  insertMetadataChild(text_kind, rootMeta, placeholder2, 0, null);
  root2.insertBefore(placeholder2, root2.firstChild);
  return none2();
};
var virtualiseChild = (meta2, domParent, child2, index4) => {
  if (child2.nodeType === COMMENT_NODE) {
    const data = child2.data.trim();
    if (data.startsWith("lustre:fragment")) {
      return virtualiseFragment(meta2, domParent, child2, index4);
    }
    if (data.startsWith("lustre:map")) {
      return virtualiseMap(meta2, domParent, child2, index4);
    }
    if (data.startsWith("lustre:memo")) {
      return virtualiseMemo(meta2, domParent, child2, index4);
    }
    return null;
  }
  if (child2.nodeType === ELEMENT_NODE) {
    return virtualiseElement(meta2, child2, index4);
  }
  if (child2.nodeType === TEXT_NODE) {
    return virtualiseText(meta2, child2, index4);
  }
  return null;
};
var virtualiseElement = (metaParent, node, index4) => {
  const key = node.getAttribute("data-lustre-key") ?? "";
  if (key) {
    node.removeAttribute("data-lustre-key");
  }
  const meta2 = insertMetadataChild(element_kind, metaParent, node, index4, key);
  const tag = node.localName;
  const namespace = node.namespaceURI;
  const isHtmlElement = !namespace || namespace === NAMESPACE_HTML;
  if (isHtmlElement && INPUT_ELEMENTS.includes(tag)) {
    virtualiseInputEvents(tag, node);
  }
  const attributes = virtualiseAttributes(node);
  const { children } = virtualiseChildren(meta2, node, node.firstChild);
  const vnode = isHtmlElement ? element3(tag, attributes, toList3(children)) : namespaced2(namespace, tag, attributes, toList3(children));
  return childResult(key, vnode, node.nextSibling);
};
var virtualiseChildren = (meta2, domParent, childNode) => {
  const children = [];
  while (childNode && (childNode.nodeType !== COMMENT_NODE || childNode.data.trim() !== "/lustre:fragment")) {
    const child2 = virtualiseChild(meta2, domParent, childNode, children.length);
    if (child2) {
      children.push([child2.key, child2.vnode]);
      childNode = child2.next;
    } else {
      childNode = childNode.nextSibling;
    }
  }
  return { children, end: childNode };
};
var virtualiseText = (meta2, node, index4) => {
  insertMetadataChild(text_kind, meta2, node, index4, null);
  return childResult("", text2(node.data), node.nextSibling);
};
var virtualiseFragment = (metaParent, domParent, node, index4) => {
  const key = parseKey(node.data);
  const meta2 = insertMetadataChild(fragment_kind, metaParent, node, index4, key);
  const { children, end } = virtualiseChildren(meta2, domParent, node.nextSibling);
  meta2.endNode = end;
  const vnode = fragment2(toList3(children));
  return childResult(key, vnode, end?.nextSibling);
};
var virtualiseMap = (metaParent, domParent, node, index4) => {
  const key = parseKey(node.data);
  const meta2 = insertMetadataChild(map_kind, metaParent, node, index4, key);
  const child2 = virtualiseNextChild(meta2, domParent, node, 0);
  if (!child2)
    return null;
  const vnode = map5(child2.vnode, (x) => x);
  return childResult(key, vnode, child2.next);
};
var virtualiseMemo = (meta2, domParent, node, index4) => {
  const key = parseKey(node.data);
  const child2 = virtualiseNextChild(meta2, domParent, node, index4);
  if (!child2)
    return null;
  domParent.removeChild(node);
  const vnode = memo2(toList3([ref({})]), () => child2.vnode);
  return childResult(key, vnode, child2.next);
};
var virtualiseNextChild = (meta2, domParent, node, index4) => {
  while (true) {
    node = node.nextSibling;
    if (!node)
      return null;
    const child2 = virtualiseChild(meta2, domParent, node, index4);
    if (child2)
      return child2;
  }
};
var childResult = (key, vnode, next) => {
  return { key, vnode, next };
};
var virtualiseAttributes = (node) => {
  const attributes = [];
  for (let i = 0;i < node.attributes.length; i++) {
    const attr = node.attributes[i];
    if (attr.name !== "xmlns") {
      attributes.push(attribute2(attr.localName, attr.value));
    }
  }
  return toList3(attributes);
};
var INPUT_ELEMENTS = ["input", "select", "textarea"];
var virtualiseInputEvents = (tag, node) => {
  const value2 = node.value;
  const checked = node.checked;
  if (tag === "input" && node.type === "checkbox" && !checked)
    return;
  if (tag === "input" && node.type === "radio" && !checked)
    return;
  if (node.type !== "checkbox" && node.type !== "radio" && !value2)
    return;
  queueMicrotask(() => {
    node.value = value2;
    node.checked = checked;
    node.dispatchEvent(new Event("input", { bubbles: true }));
    node.dispatchEvent(new Event("change", { bubbles: true }));
    if (globalThis.document.activeElement !== node) {
      node.dispatchEvent(new Event("blur", { bubbles: true }));
    }
  });
};
var parseKey = (data) => {
  const keyMatch = data.match(/key="([^"]*)"/);
  if (!keyMatch)
    return "";
  return unescapeKey(keyMatch[1]);
};
var unescapeKey = (key) => {
  return key.replace(/&(?:lt|gt|quot|amp|#39);/g, (entity) => {
    switch (entity) {
      case "&lt;":
        return "<";
      case "&gt;":
        return ">";
      case "&quot;":
        return '"';
      case "&amp;":
        return "&";
      case "&#39;":
        return "'";
      default:
        return entity;
    }
  });
};
var toList3 = (arr) => arr.reduceRight((xs, x) => List$NonEmpty(x, xs), empty_list);

// build/dev/javascript/lustre/lustre/runtime/client/runtime.ffi.mjs
var is_browser = () => !!globalThis.document;
class Runtime {
  constructor(root2, [model, effects], view, update2, options) {
    this.root = root2;
    this.#model = model;
    this.#view = view;
    this.#update = update2;
    this.root.addEventListener("context-request", (event3) => {
      if (!(event3.context && event3.callback))
        return;
      if (!this.#contexts.has(event3.context))
        return;
      event3.stopImmediatePropagation();
      const context = this.#contexts.get(event3.context);
      if (event3.subscribe) {
        const unsubscribe2 = () => {
          context.subscribers = context.subscribers.filter((subscriber) => subscriber !== event3.callback);
        };
        context.subscribers.push([event3.callback, unsubscribe2]);
        event3.callback(context.value, unsubscribe2);
      } else {
        event3.callback(context.value);
      }
    });
    const decodeEvent = (event3, path, name) => decode2(this.#cache, path, name, event3);
    const dispatch2 = (event3, data) => {
      const [cache, result] = dispatch(this.#cache, data);
      this.#cache = cache;
      if (Result$isOk(result)) {
        const handler = Result$Ok$0(result);
        if (handler.stop_propagation)
          event3.stopPropagation();
        if (handler.prevent_default)
          event3.preventDefault();
        this.dispatch(handler.message, false);
      }
    };
    this.#reconciler = new Reconciler(this.root, decodeEvent, dispatch2, options);
    this.#vdom = virtualise(this.root);
    this.#cache = new$4();
    this.#handleEffects(effects);
    this.#render();
  }
  root = null;
  dispatch(message, shouldFlush = false) {
    if (this.#shouldQueue) {
      this.#queue.push(message);
    } else {
      const [model, effects] = this.#update(this.#model, message);
      this.#model = model;
      this.#scheduleRender(shouldFlush);
      this.#handleEffects(effects);
    }
  }
  emit(event3, data) {
    const target = this.root.host ?? this.root;
    target.dispatchEvent(new LustreEvent(event3, data));
  }
  provide(key, value2) {
    if (!this.#contexts.has(key)) {
      this.#contexts.set(key, { value: value2, subscribers: [] });
    } else {
      const context = this.#contexts.get(key);
      if (isEqual2(context.value, value2)) {
        return;
      }
      context.value = value2;
      for (let i = context.subscribers.length - 1;i >= 0; i--) {
        const [subscriber, unsubscribe2] = context.subscribers[i];
        if (!subscriber) {
          context.subscribers.splice(i, 1);
          continue;
        }
        subscriber(value2, unsubscribe2);
      }
    }
  }
  subscribe(key, decoder) {
    if (!key)
      return;
    this.#contextSubscriptions.get(key)?.();
    const target = this.root.host ?? this.root;
    target.dispatchEvent(new ContextRequestEvent(key, (value2, unsubscribe2) => {
      const previousUnsubscribe = this.#contextSubscriptions.get(key);
      if (previousUnsubscribe !== unsubscribe2) {
        previousUnsubscribe?.();
      }
      const decoded = run(value2, decoder);
      this.#contextSubscriptions.set(key, unsubscribe2);
      if (Result$isOk(decoded)) {
        this.dispatch(Result$Ok$0(decoded), true);
      }
    }, true));
  }
  unsubscribe(key) {
    const unsubscribe2 = this.#contextSubscriptions.get(key);
    if (unsubscribe2) {
      unsubscribe2();
      this.#contextSubscriptions.delete(key);
    }
  }
  unsubscribeAll() {
    for (const [_, unsubscribe2] of this.#contextSubscriptions) {
      unsubscribe2?.();
    }
    this.#contextSubscriptions.clear();
  }
  #model;
  #view;
  #update;
  #vdom;
  #cache;
  #reconciler;
  #contexts = new Map;
  #contextSubscriptions = new Map;
  #shouldQueue = false;
  #queue = [];
  #beforePaint = empty_list;
  #afterPaint = empty_list;
  #renderTimer = null;
  #actions = {
    dispatch: (message) => this.dispatch(message),
    emit: (event3, data) => this.emit(event3, data),
    select: () => {},
    root: () => this.root,
    provide: (key, value2) => this.provide(key, value2),
    subscribe: (key, decoder) => this.subscribe(key, decoder),
    unsubscribe: (key) => this.unsubscribe(key)
  };
  #scheduleRender(shouldFlush = false) {
    if (this.#renderTimer)
      return;
    if (shouldFlush) {
      this.#renderTimer = "sync";
      queueMicrotask(() => this.#render());
    } else {
      this.#renderTimer = window.requestAnimationFrame(() => this.#render());
    }
  }
  #handleEffects(effects) {
    this.#shouldQueue = true;
    let updateCalledDuringEffects = false;
    while (true) {
      iterate(effects.synchronous, (effect) => effect(this.#actions));
      this.#beforePaint = append4(this.#beforePaint, effects.before_paint);
      this.#afterPaint = append4(this.#afterPaint, effects.after_paint);
      if (!this.#queue.length)
        break;
      const message = this.#queue.shift();
      [this.#model, effects] = this.#update(this.#model, message);
      updateCalledDuringEffects = true;
    }
    this.#shouldQueue = false;
    return updateCalledDuringEffects;
  }
  #handleAsyncEffects(effects) {
    if (this.#handleEffects(effects)) {
      this.#scheduleRender(true);
    }
  }
  #render() {
    this.#renderTimer = null;
    const next = this.#view(this.#model);
    const { patch, cache } = diff(this.#cache, this.#vdom, next);
    this.#cache = cache;
    this.#vdom = next;
    this.#reconciler.push(patch, memos(cache));
    if (List$isNonEmpty(this.#beforePaint)) {
      const effects = makeEffect(this.#beforePaint);
      this.#beforePaint = empty_list;
      queueMicrotask(() => this.#handleAsyncEffects(effects));
    }
    if (List$isNonEmpty(this.#afterPaint)) {
      const effects = makeEffect(this.#afterPaint);
      this.#afterPaint = empty_list;
      window.requestAnimationFrame(() => this.#handleAsyncEffects(effects));
    }
  }
}
function makeEffect(synchronous) {
  return {
    synchronous,
    after_paint: empty_list,
    before_paint: empty_list
  };
}
var copiedStyleSheets = new WeakMap;
class ContextRequestEvent extends Event {
  constructor(context, callback, subscribe2) {
    super("context-request", { bubbles: true, composed: true });
    this.context = context;
    this.callback = callback;
    this.subscribe = subscribe2;
  }
}

class LustreEvent extends CustomEvent {
  isLustreEvent = true;
  constructor(name, detail) {
    super(name, { detail, bubbles: true, composed: true });
  }
}

// build/dev/javascript/lustre/lustre/runtime/client/spa.ffi.mjs
class Spa {
  #runtime;
  constructor(root2, [init, effects], update2, view) {
    this.#runtime = new Runtime(root2, [init, effects], view, update2);
  }
  send(message) {
    if (Message$isEffectDispatchedMessage(message)) {
      this.dispatch(message.message, false);
    } else if (Message$isEffectEmitEvent(message)) {
      this.emit(message.name, message.data);
    } else if (Message$isSystemRequestedShutdown(message)) {}
  }
  dispatch(message) {
    this.#runtime.dispatch(message);
  }
  emit(event3, data) {
    this.#runtime.emit(event3, data);
  }
}
var start = ({ init, update: update2, view }, selector, flags) => {
  if (!is_browser())
    return Result$Error(Error$NotABrowser());
  const root2 = selector instanceof HTMLElement ? selector : globalThis.document.querySelector(selector);
  if (!root2)
    return Result$Error(Error$ElementNotFound(selector));
  return Result$Ok(new Spa(root2, init(flags), update2, view));
};

// build/dev/javascript/lustre/lustre/runtime/server/runtime.ffi.mjs
class Runtime2 {
  #model;
  #update;
  #view;
  #config;
  #vdom;
  #cache;
  #providers = make();
  #callbacks = /* @__PURE__ */ new Set;
  constructor(_, init, update2, view, config, start_arguments) {
    const [model, effects] = init(start_arguments);
    this.#model = model;
    this.#update = update2;
    this.#view = view;
    this.#config = config;
    this.#vdom = this.#view(this.#model);
    this.#cache = from_node(this.#vdom);
    this.#handle_effect(effects);
  }
  send(message) {
    if (Message$isClientDispatchedMessage(message)) {
      const { message: message2 } = message2;
      const next = this.#handle_client_message(message2);
      const diff2 = diff(this.#cache, this.#vdom, next);
      this.#vdom = next;
      this.#cache = diff2.cache;
      this.broadcast(reconcile(diff2.patch, memos(diff2.cache)));
    } else if (Message$isClientRegisteredCallback(message)) {
      const { callback } = message;
      this.#callbacks.add(callback);
      callback(mount(this.#config.open_shadow_root, this.#config.adopt_styles, keys(this.#config.attributes), keys(this.#config.properties), keys(this.#config.contexts), this.#providers, this.#vdom, memos(this.#cache)));
      if (Option$isSome(this.#config.on_connect)) {
        this.#dispatch(Option$Some$0(this.#config.on_connect));
      }
    } else if (Message$isClientDeregisteredCallback(message)) {
      const { callback } = message;
      this.#callbacks.delete(callback);
      if (Option$isSome(this.#config.on_disconnect)) {
        this.#dispatch(Option$Some$0(this.#config.on_disconnect));
      }
    } else if (Message$isEffectDispatchedMessage(message)) {
      const { message: message2 } = message2;
      const [model, effect] = this.#update(this.#model, message2);
      const next = this.#view(model);
      const diff2 = diff(this.#cache, this.#vdom, next);
      this.#handle_effect(effect);
      this.#model = model;
      this.#vdom = next;
      this.#cache = diff2.cache;
      this.broadcast(reconcile(diff2.patch, memos(diff2.cache)));
    } else if (Message$isEffectEmitEvent(message)) {
      const { name, data } = message;
      this.broadcast(emit(name, data));
    } else if (Message$isEffectProvidedValue(message)) {
      const { key, value: value2 } = message;
      const existing = get(this.#providers, key);
      if (Result$isOk(existing) && isEqual2(Result$Ok$0(existing), value2)) {
        return;
      }
      this.#providers = insert(this.#providers, key, value2);
      this.broadcast(provide(key, value2));
    } else if (Message$isEffectRequestedContextSubscription(message)) {
      const { key, decoder } = message;
      this.broadcast(subscribe(key));
      this.#config.contexts = insert(this.#config.contexts, key, decoder);
    } else if (Message$isEffectRemovedContextSubscription(message)) {
      const { key } = message;
      this.broadcast(unsubscribe(key));
      this.#config.contexts = delete$(this.#config.contexts, key);
    } else if (Message$isSystemRequestedShutdown(message)) {
      this.#model = null;
      this.#update = null;
      this.#view = null;
      this.#config = null;
      this.#vdom = null;
      this.#cache = null;
      this.#providers = null;
      this.#callbacks.clear();
    }
  }
  broadcast(message) {
    for (const callback of this.#callbacks) {
      callback(message);
    }
  }
  #handle_client_message(message) {
    if (ServerMessage$isBatch(message)) {
      const { messages } = message;
      let model = this.#model;
      let effect = none();
      for (let list4 = messages;List$NonEmpty$rest(list4); list4 = List$NonEmpty$rest(list4)) {
        const result = this.#handle_client_message(List$NonEmpty$first(list4));
        if (Result$isOk(result)) {
          model = Result$Ok$0(result)[0];
          effect = batch(toList2([effect, Result$Ok$0(result)[1]]));
          break;
        }
      }
      this.#handle_effect(effect);
      this.#model = model;
      return this.#view(model);
    } else if (ServerMessage$isAttributeChanged(message)) {
      const { name, value: value2 } = message;
      const result = this.#handle_attribute_change(name, value2);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }
      return this.#dispatch(Result$Ok$0(result));
    } else if (ServerMessage$isPropertyChanged(message)) {
      const { name, value: value2 } = message;
      const result = this.#handle_properties_change(name, value2);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }
      return this.#dispatch(Result$Ok$0(result));
    } else if (ServerMessage$isEventFired(message)) {
      const { path, name, event: event3 } = message2;
      const [cache, result] = handle(this.#cache, path, name, event3);
      this.#cache = cache;
      if (!Result$isOk(result)) {
        return this.#vdom;
      }
      const { message: message2 } = Result$Ok$0(result);
      return this.#dispatch(message2);
    } else if (ServerMessage$isContextProvided(message)) {
      const { key, value: value2 } = message;
      let result = get(this.#config.contexts, key);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }
      result = run(value2, Result$Ok$0(result));
      if (!Result$isOk(result)) {
        return this.#vdom;
      }
      return this.#dispatch(Result$Ok$0(result));
    }
  }
  #dispatch(message) {
    const [model, effects] = this.#update(this.#model, message);
    this.#handle_effect(effects);
    this.#model = model;
    return this.#view(this.#model);
  }
  #handle_attribute_change(name, value2) {
    const result = get(this.#config.attributes, name);
    if (!Result$isOk(result)) {
      return result;
    }
    return Result$Ok$0(result)(value2);
  }
  #handle_properties_change(name, value2) {
    const result = get(this.#config.properties, name);
    if (!Result$isOk(result)) {
      return result;
    }
    return Result$Ok$0(result)(value2);
  }
  #handle_effect(effect) {
    const dispatch2 = (message) => this.send(Message$EffectDispatchedMessage(message));
    const emit2 = (name, data) => this.send(Message$EffectEmitEvent(name, data));
    const select2 = () => {
      return;
    };
    const internals = () => {
      return;
    };
    const provide2 = (key, value2) => this.send(Message$EffectProvidedValue(key, value2));
    const subscribe2 = (key, decoder) => this.send(Message$EffectRequestedContextSubscription(key, decoder));
    const unsubscribe2 = (key) => this.send(Message$EffectRemovedContextSubscription(key));
    globalThis.queueMicrotask(() => {
      perform(effect, dispatch2, emit2, select2, internals, provide2, subscribe2, unsubscribe2);
    });
  }
}

// build/dev/javascript/lustre/lustre.mjs
class ElementNotFound extends CustomType {
  constructor(selector) {
    super();
    this.selector = selector;
  }
}
var Error$ElementNotFound = (selector) => new ElementNotFound(selector);
class NotABrowser extends CustomType {
}
var Error$NotABrowser$const = new NotABrowser;
var Error$NotABrowser = () => Error$NotABrowser$const;
function application(init, update2, view) {
  return new App(Option$None$const, init, update2, view, default_config);
}
function start4(app, selector, arguments$) {
  return guard(!is_browser(), new Error2(Error$NotABrowser$const), () => {
    return start(app, selector, arguments$);
  });
}
// build/dev/javascript/beamtrace_web/beamtrace_web/workspace.mjs
class Capture extends CustomType {
}
var Mode$Capture$const = new Capture;
class Live extends CustomType {
}
var Mode$Live$const = new Live;
class Compare extends CustomType {
}
var Mode$Compare$const = new Compare;
class Team extends CustomType {
}
var Mode$Team$const = new Team;
class TeamTrace extends CustomType {
  constructor(id2, status, node, module_, function_, arity, privacy, completeness, event_count, received_at_ms, legal_hold, locked) {
    super();
    this.id = id2;
    this.status = status;
    this.node = node;
    this.module_ = module_;
    this.function_ = function_;
    this.arity = arity;
    this.privacy = privacy;
    this.completeness = completeness;
    this.event_count = event_count;
    this.received_at_ms = received_at_ms;
    this.legal_hold = legal_hold;
    this.locked = locked;
  }
}
class TeamTracePage extends CustomType {
  constructor(traces, next_cursor) {
    super();
    this.traces = traces;
    this.next_cursor = next_cursor;
  }
}
class TeamEventPage extends CustomType {
  constructor(trace_id, events2, next_cursor) {
    super();
    this.trace_id = trace_id;
    this.events = events2;
    this.next_cursor = next_cursor;
  }
}
class Exact extends CustomType {
}
var Evidence$Exact$const = new Exact;
class Inferred extends CustomType {
  constructor(reason, confidence) {
    super();
    this.reason = reason;
    this.confidence = confidence;
  }
}
class Unavailable extends CustomType {
}
var CapturePhase$Unavailable$const = new Unavailable;
class Idle extends CustomType {
}
var CapturePhase$Idle$const = new Idle;
class Arming extends CustomType {
}
var CapturePhase$Arming$const = new Arming;
class Armed extends CustomType {
}
var CapturePhase$Armed$const = new Armed;
class Cancelling extends CustomType {
}
var CapturePhase$Cancelling$const = new Cancelling;
class Ready extends CustomType {
  constructor(event_count, completeness) {
    super();
    this.event_count = event_count;
    this.completeness = completeness;
  }
}
class Failed extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
}
class EventRow extends CustomType {
  constructor(id2, actor, kind, timestamp_ns, duration_ns, evidence, anomalous, internal) {
    super();
    this.id = id2;
    this.actor = actor;
    this.kind = kind;
    this.timestamp_ns = timestamp_ns;
    this.duration_ns = duration_ns;
    this.evidence = evidence;
    this.anomalous = anomalous;
    this.internal = internal;
  }
}
class EventPage extends CustomType {
  constructor(events2, total, start5, limit) {
    super();
    this.events = events2;
    this.total = total;
    this.start = start5;
    this.limit = limit;
  }
}
class LiveRow extends CustomType {
  constructor(node, pid, label2, registered_name, process_label, initial_call, mailbox_len, memory_bytes, reductions, heap_words, total_heap_words, link_count, status, current_function, links, ancestors) {
    super();
    this.node = node;
    this.pid = pid;
    this.label = label2;
    this.registered_name = registered_name;
    this.process_label = process_label;
    this.initial_call = initial_call;
    this.mailbox_len = mailbox_len;
    this.memory_bytes = memory_bytes;
    this.reductions = reductions;
    this.heap_words = heap_words;
    this.total_heap_words = total_heap_words;
    this.link_count = link_count;
    this.status = status;
    this.current_function = current_function;
    this.links = links;
    this.ancestors = ancestors;
  }
}
class LiveFinding extends CustomType {
  constructor(pid, label2, kind, summary, evidence) {
    super();
    this.pid = pid;
    this.label = label2;
    this.kind = kind;
    this.summary = summary;
    this.evidence = evidence;
  }
}
class TopologyEdge extends CustomType {
  constructor(from3, to, evidence) {
    super();
    this.from = from3;
    this.to = to;
    this.evidence = evidence;
  }
}
class LiveSnapshot extends CustomType {
  constructor(generation, sampled_at_ms, rows, findings, supervision, spawn, links) {
    super();
    this.generation = generation;
    this.sampled_at_ms = sampled_at_ms;
    this.rows = rows;
    this.findings = findings;
    this.supervision = supervision;
    this.spawn = spawn;
    this.links = links;
  }
}
class CompareItem extends CustomType {
  constructor(status, left_id, right_id, latency_delta_ns, reason) {
    super();
    this.status = status;
    this.left_id = left_id;
    this.right_id = right_id;
    this.latency_delta_ns = latency_delta_ns;
    this.reason = reason;
  }
}
class CompareRun extends CustomType {
  constructor(path, added, removed, changed, items) {
    super();
    this.path = path;
    this.added = added;
    this.removed = removed;
    this.changed = changed;
    this.items = items;
  }
}
class BranchStatistic extends CustomType {
  constructor(signature, p50_ns, p95_ns, occurrences, total_runs, occurrence_rate) {
    super();
    this.signature = signature;
    this.p50_ns = p50_ns;
    this.p95_ns = p95_ns;
    this.occurrences = occurrences;
    this.total_runs = total_runs;
    this.occurrence_rate = occurrence_rate;
  }
}
class CompareReport extends CustomType {
  constructor(baseline, run_count, reports, statistics) {
    super();
    this.baseline = baseline;
    this.run_count = run_count;
    this.reports = reports;
    this.statistics = statistics;
  }
}
class Model extends CustomType {
  constructor(remote, mode, events2, total_events, loaded_start, loaded_limit, loaded_query, loading, load_error, selected_event_id, query, show_internal, viewport_start, viewport_size, zoom, palette_open, search_focused, bookmarks, annotation, trigger_input, mfa_suggestions, capture_where, capture_preset, capture_max_roots, save_path, capture_phase, capture_notice, live_rows, live_findings, live_supervision, live_spawn, live_links, live_generation, live_sampled_at_ms, live_loading, live_error, selected_live_pid, compare_paths_input, compare_loading, compare_error, compare_report, team_traces, team_next_cursor, team_loading, team_error, selected_trace_id, team_events, team_events_next_cursor, team_events_loading, team_events_error) {
    super();
    this.remote = remote;
    this.mode = mode;
    this.events = events2;
    this.total_events = total_events;
    this.loaded_start = loaded_start;
    this.loaded_limit = loaded_limit;
    this.loaded_query = loaded_query;
    this.loading = loading;
    this.load_error = load_error;
    this.selected_event_id = selected_event_id;
    this.query = query;
    this.show_internal = show_internal;
    this.viewport_start = viewport_start;
    this.viewport_size = viewport_size;
    this.zoom = zoom;
    this.palette_open = palette_open;
    this.search_focused = search_focused;
    this.bookmarks = bookmarks;
    this.annotation = annotation;
    this.trigger_input = trigger_input;
    this.mfa_suggestions = mfa_suggestions;
    this.capture_where = capture_where;
    this.capture_preset = capture_preset;
    this.capture_max_roots = capture_max_roots;
    this.save_path = save_path;
    this.capture_phase = capture_phase;
    this.capture_notice = capture_notice;
    this.live_rows = live_rows;
    this.live_findings = live_findings;
    this.live_supervision = live_supervision;
    this.live_spawn = live_spawn;
    this.live_links = live_links;
    this.live_generation = live_generation;
    this.live_sampled_at_ms = live_sampled_at_ms;
    this.live_loading = live_loading;
    this.live_error = live_error;
    this.selected_live_pid = selected_live_pid;
    this.compare_paths_input = compare_paths_input;
    this.compare_loading = compare_loading;
    this.compare_error = compare_error;
    this.compare_report = compare_report;
    this.team_traces = team_traces;
    this.team_next_cursor = team_next_cursor;
    this.team_loading = team_loading;
    this.team_error = team_error;
    this.selected_trace_id = selected_trace_id;
    this.team_events = team_events;
    this.team_events_next_cursor = team_events_next_cursor;
    this.team_events_loading = team_events_loading;
    this.team_events_error = team_events_error;
  }
}
class UserSelectedMode extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserSelectedEvent extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedQuery extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserToggledInternalNoise extends CustomType {
}
var Msg$UserToggledInternalNoise$const = new UserToggledInternalNoise;
class UserFocusedSearch extends CustomType {
}
var Msg$UserFocusedSearch$const = new UserFocusedSearch;
class UserOpenedPalette extends CustomType {
}
var Msg$UserOpenedPalette$const = new UserOpenedPalette;
class UserClosedPalette extends CustomType {
}
var Msg$UserClosedPalette$const = new UserClosedPalette;
class UserToggledBookmark extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedAnnotation extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserPressedKey extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class ViewportChanged extends CustomType {
  constructor(start5, size3) {
    super();
    this.start = start5;
    this.size = size3;
  }
}
class UserZoomed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class PageLoaded extends CustomType {
  constructor(query, page) {
    super();
    this.query = query;
    this.page = page;
  }
}
class PageLoadFailed extends CustomType {
  constructor(query, reason) {
    super();
    this.query = query;
    this.reason = reason;
  }
}
class UserChangedTrigger extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class MfaSuggestionsLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedCaptureWhere extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedCapturePreset extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedMaxRoots extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedArm extends CustomType {
}
var Msg$UserRequestedArm$const = new UserRequestedArm;
class CaptureArmAccepted extends CustomType {
}
var Msg$CaptureArmAccepted$const = new CaptureArmAccepted;
class CaptureArmFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class PollCaptureStatus extends CustomType {
}
var Msg$PollCaptureStatus$const = new PollCaptureStatus;
class CaptureStatusLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedCancel extends CustomType {
}
var Msg$UserRequestedCancel$const = new UserRequestedCancel;
class CaptureCancelFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedSavePath extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedSave extends CustomType {
}
var Msg$UserRequestedSave$const = new UserRequestedSave;
class CaptureSaved extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class CaptureSaveFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class PollLive extends CustomType {
}
var Msg$PollLive$const = new PollLive;
class LiveLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class LiveLoadFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserSelectedLiveProcess extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserChangedComparePaths extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedCompare extends CustomType {
}
var Msg$UserRequestedCompare$const = new UserRequestedCompare;
class CompareLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class CompareFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedTeamTraces extends CustomType {
}
var Msg$UserRequestedTeamTraces$const = new UserRequestedTeamTraces;
class UserRequestedMoreTeamTraces extends CustomType {
}
var Msg$UserRequestedMoreTeamTraces$const = new UserRequestedMoreTeamTraces;
class TeamTracesLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class TeamTracesFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserSelectedTeamTrace extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedMoreTeamEvents extends CustomType {
}
var Msg$UserRequestedMoreTeamEvents$const = new UserRequestedMoreTeamEvents;
class TeamEventsLoaded extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class TeamEventsFailed extends CustomType {
  constructor(trace_id, reason) {
    super();
    this.trace_id = trace_id;
    this.reason = reason;
  }
}
class UserRequestedTraceHold extends CustomType {
  constructor(trace_id, enabled) {
    super();
    this.trace_id = trace_id;
    this.enabled = enabled;
  }
}
class TraceHoldUpdated extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class TraceHoldFailed extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
function init(events2) {
  return new Model(false, Mode$Capture$const, events2, length(events2), 0, length(events2), "", false, Option$None$const, Option$None$const, "", false, 0, 80, 1, false, false, List$Empty$const, "", "", List$Empty$const, "", "generic", "1", "capture.beamtrace", CapturePhase$Unavailable$const, "", List$Empty$const, List$Empty$const, List$Empty$const, List$Empty$const, List$Empty$const, 0, 0, false, Option$None$const, Option$None$const, `baseline.beamtrace
candidate.beamtrace`, false, Option$None$const, Option$None$const, List$Empty$const, Option$None$const, false, Option$None$const, Option$None$const, List$Empty$const, Option$None$const, false, Option$None$const);
}
function init_remote() {
  let _record = init(List$Empty$const);
  return new Model(true, _record.mode, _record.events, _record.total_events, _record.loaded_start, 200, _record.loaded_query, true, _record.load_error, _record.selected_event_id, _record.query, _record.show_internal, _record.viewport_start, 80, _record.zoom, _record.palette_open, _record.search_focused, _record.bookmarks, _record.annotation, _record.trigger_input, _record.mfa_suggestions, _record.capture_where, _record.capture_preset, _record.capture_max_roots, _record.save_path, CapturePhase$Idle$const, _record.capture_notice, _record.live_rows, _record.live_findings, _record.live_supervision, _record.live_spawn, _record.live_links, _record.live_generation, _record.live_sampled_at_ms, _record.live_loading, _record.live_error, _record.selected_live_pid, _record.compare_paths_input, _record.compare_loading, _record.compare_error, _record.compare_report, _record.team_traces, _record.team_next_cursor, _record.team_loading, _record.team_error, _record.selected_trace_id, _record.team_events, _record.team_events_next_cursor, _record.team_events_loading, _record.team_events_error);
}
function merge_team_traces(existing, incoming) {
  let _pipe = fold2(incoming, existing, (traces, incoming_trace) => {
    let $ = any(traces, (trace) => {
      return trace.id === incoming_trace.id;
    });
    if ($) {
      return traces;
    } else {
      return append(traces, toList([incoming_trace]));
    }
  });
  return take(_pipe, 100);
}
function compare_paths(model) {
  let _pipe = model.compare_paths_input;
  let _pipe$1 = split2(_pipe, `
`);
  let _pipe$2 = map2(_pipe$1, trim);
  return filter(_pipe$2, (path) => {
    return path !== "";
  });
}
function unique_strings(loop$items, loop$seen) {
  while (true) {
    let items = loop$items;
    let seen = loop$seen;
    if (items instanceof Empty) {
      return true;
    } else {
      let item = items.head;
      let rest = items.tail;
      let $ = contains(seen, item);
      if ($) {
        return false;
      } else {
        loop$items = rest;
        loop$seen = prepend(item, seen);
      }
    }
  }
}
function valid_compare_paths(paths) {
  let count = length(paths);
  return count >= 2 && count <= 20 && all(paths, (path) => {
    return ends_with(lowercase(path), ".beamtrace");
  }) && unique_strings(paths, List$Empty$const);
}
function parse_root_budget(model) {
  let $ = parse_int(trim(model.capture_max_roots));
  if ($ instanceof Ok) {
    let value2 = $[0];
    if (value2 >= 1 && value2 <= 1000) {
      return $;
    } else {
      return new Error2(undefined);
    }
  } else {
    return new Error2(undefined);
  }
}
function remote_query(model) {
  return trim(model.query);
}
function toggle_member(items, item) {
  let $ = contains(items, item);
  if ($) {
    return filter(items, (existing) => {
      return existing !== item;
    });
  } else {
    return prepend(item, items);
  }
}
function keyboard_shortcut(key) {
  let $ = lowercase(key);
  if ($ === "1") {
    return new Some(new UserSelectedMode(Mode$Capture$const));
  } else if ($ === "2") {
    return new Some(new UserSelectedMode(Mode$Live$const));
  } else if ($ === "3") {
    return new Some(new UserSelectedMode(Mode$Compare$const));
  } else if ($ === "4") {
    return new Some(new UserSelectedMode(Mode$Team$const));
  } else if ($ === "/") {
    return new Some(Msg$UserFocusedSearch$const);
  } else if ($ === "k") {
    return new Some(Msg$UserOpenedPalette$const);
  } else {
    return Option$None$const;
  }
}
function update2(loop$model, loop$message) {
  while (true) {
    let model = loop$model;
    let message = loop$message;
    if (message instanceof UserSelectedMode) {
      let mode = message[0];
      return new Model(model.remote, mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, (() => {
        if (mode instanceof Live) {
          return true;
        } else {
          return false;
        }
      })(), (() => {
        if (mode instanceof Live) {
          return Option$None$const;
        } else {
          return model.live_error;
        }
      })(), model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, (() => {
        let $ = model.team_traces;
        if ($ instanceof Empty && mode instanceof Team) {
          return true;
        } else {
          return model.team_loading;
        }
      })(), (() => {
        if (mode instanceof Team) {
          return Option$None$const;
        } else {
          return model.team_error;
        }
      })(), model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedEvent) {
      let id2 = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, new Some(id2), model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedQuery) {
      let query = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, Option$None$const, model.selected_event_id, query, model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserToggledInternalNoise) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, !model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserFocusedSearch) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, true, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserOpenedPalette) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, true, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserClosedPalette) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, false, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserToggledBookmark) {
      let id2 = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, toggle_member(model.bookmarks, id2), model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedAnnotation) {
      let annotation = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserPressedKey) {
      let key = message[0];
      let $ = keyboard_shortcut(key);
      if ($ instanceof Some) {
        let message$1 = $[0];
        loop$model = model;
        loop$message = message$1;
      } else {
        return model;
      }
    } else if (message instanceof ViewportChanged) {
      let start5 = message.start;
      let size3 = message.size;
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, Option$None$const, model.selected_event_id, model.query, model.show_internal, max2(start5, 0), min2(max2(size3, 1), 1000), model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserZoomed) {
      let zoom = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, clamp(zoom, 0.25, 4), model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PageLoaded) {
      let query = message.query;
      let page = message.page;
      let $ = !model.remote || query === remote_query(model);
      if ($) {
        return new Model(model.remote, model.mode, page.events, page.total, page.start, page.limit, query, false, Option$None$const, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof PageLoadFailed) {
      let query = message.query;
      let reason = message.reason;
      let $ = !model.remote || query === remote_query(model);
      if ($) {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, new Some(reason), model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof UserChangedTrigger) {
      let trigger = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, trigger, (() => {
        let $ = trim(trigger);
        if ($ === "") {
          return List$Empty$const;
        } else {
          return model.mfa_suggestions;
        }
      })(), model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof MfaSuggestionsLoaded) {
      let suggestions = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, take(suggestions, 200), model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedCaptureWhere) {
      let source = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, source, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedCapturePreset) {
      let preset = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedMaxRoots) {
      let max_roots = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedArm) {
      let $ = trim(model.trigger_input);
      let $1 = parse_root_budget(model);
      if ($ === "") {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed("trigger_required"), "Enter an MFA trigger", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else if ($1 instanceof Ok) {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Arming$const, "Arming " + trim(model.trigger_input), model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed("invalid_root_budget"), "Max roots must be between 1 and 1000", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof CaptureArmAccepted) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Armed$const, "Capture armed; perform one operation", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureArmFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed(reason), reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PollCaptureStatus) {
      return model;
    } else if (message instanceof CaptureStatusLoaded) {
      let phase = message[0];
      if (phase instanceof Ready) {
        let count = phase.event_count;
        return new Model(model.remote, model.mode, model.events, count, 0, 0, "", false, Option$None$const, model.selected_event_id, model.query, model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, "", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else if (phase instanceof Failed) {
        let $ = phase.reason;
        if ($ === "system_tracer_occupied") {
          return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, "Exact capture was refused; another tracer owns the node. Use Live for bounded inferred sampling.", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
        } else {
          return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
        }
      } else {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof UserRequestedCancel) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Cancelling$const, "Stopping capture and cleaning the target", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureCancelFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed(reason), reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedSavePath) {
      let path = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedSave) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, "Saving capture", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureSaved) {
      let path = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, "Saved " + path, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureSaveFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PollLive) {
      let $ = model.mode;
      if ($ instanceof Live) {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, true, Option$None$const, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return model;
      }
    } else if (message instanceof LiveLoaded) {
      let snapshot = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, snapshot.rows, snapshot.findings, snapshot.supervision, snapshot.spawn, snapshot.links, snapshot.generation, snapshot.sampled_at_ms, false, Option$None$const, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof LiveLoadFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, false, new Some(reason), model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedLiveProcess) {
      let pid = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, new Some(pid), model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedComparePaths) {
      let paths = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, paths, model.compare_loading, Option$None$const, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedCompare) {
      let $ = valid_compare_paths(compare_paths(model));
      if ($) {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, true, Option$None$const, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, new Some("Enter 2–20 distinct .beamtrace paths"), model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof CompareLoaded) {
      let report = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, Option$None$const, new Some(report), model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CompareFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, new Some(reason), model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedTeamTraces) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, List$Empty$const, Option$None$const, true, Option$None$const, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedMoreTeamTraces) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, true, Option$None$const, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof TeamTracesLoaded) {
      let page = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, merge_team_traces(model.team_traces, page.traces), page.next_cursor, false, Option$None$const, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof TeamTracesFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, false, new Some(reason), model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedTeamTrace) {
      let id2 = message[0];
      let $ = find(model.team_traces, (trace) => {
        return trace.id === id2;
      });
      if ($ instanceof Ok) {
        let trace = $[0];
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, new Some(id2), List$Empty$const, Option$None$const, !trace.locked, (() => {
          let $1 = trace.locked;
          if ($1) {
            return new Some("Raw trace content is locked for this role");
          } else {
            return Option$None$const;
          }
        })());
      } else {
        return model;
      }
    } else if (message instanceof UserRequestedMoreTeamEvents) {
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, true, Option$None$const);
    } else if (message instanceof TeamEventsLoaded) {
      let page = message[0];
      let $ = isEqual(model.selected_trace_id, new Some(page.trace_id));
      if ($) {
        let _block;
        let _pipe = append(model.team_events, page.events);
        _block = take(_pipe, 1000);
        let events2 = _block;
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, events2, (() => {
          let $1 = length(events2) >= 1000;
          if ($1) {
            return Option$None$const;
          } else {
            return page.next_cursor;
          }
        })(), false, Option$None$const);
      } else {
        return model;
      }
    } else if (message instanceof TeamEventsFailed) {
      let trace_id = message.trace_id;
      let reason = message.reason;
      let $ = isEqual(model.selected_trace_id, new Some(trace_id));
      if ($) {
        return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, false, new Some(reason));
      } else {
        return model;
      }
    } else if (message instanceof UserRequestedTraceHold) {
      return model;
    } else if (message instanceof TraceHoldUpdated) {
      let updated = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, map2(model.team_traces, (trace) => {
        let $ = trace.id === updated.id;
        if ($) {
          return updated;
        } else {
          return trace;
        }
      }), model.team_next_cursor, model.team_loading, Option$None$const, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, new Some(reason), model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    }
  }
}
function result_to_option(result) {
  if (result instanceof Ok) {
    let value2 = result[0];
    return new Some(value2);
  } else {
    return Option$None$const;
  }
}
function selected_team_trace(model) {
  let $ = model.selected_trace_id;
  if ($ instanceof Some) {
    let id2 = $[0];
    let _pipe = model.team_traces;
    let _pipe$1 = find(_pipe, (trace) => {
      return trace.id === id2;
    });
    return result_to_option(_pipe$1);
  } else {
    return $;
  }
}
function begin_loading(model) {
  return new Model(model.remote, model.mode, model.events, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, true, Option$None$const, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.search_focused, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
}
function needs_page(model) {
  let requested_end = min2(model.viewport_start + model.viewport_size, model.total_events);
  let loaded_end = model.loaded_start + model.loaded_limit;
  let outside_loaded_window = model.viewport_start < model.loaded_start || requested_end > loaded_end;
  let stale_query = model.loaded_query !== remote_query(model);
  return model.remote && model.mode instanceof Capture && !model.loading && model.load_error instanceof None && (outside_loaded_window || stale_query);
}
function filtered_live_rows(model) {
  let query = lowercase(remote_query(model));
  let _pipe = model.live_rows;
  return filter(_pipe, (row) => {
    return query === "" || contains_string(lowercase(row.pid), query) || contains_string(lowercase(row.label), query) || contains_string(lowercase(row.status), query) || contains_string(lowercase(row.current_function), query);
  });
}
function selected_live_process(model) {
  let $ = model.selected_live_pid;
  if ($ instanceof Some) {
    let pid = $[0];
    return find(model.live_rows, (row) => {
      return row.pid === pid;
    });
  } else {
    return new Error2(undefined);
  }
}
function live_findings_for(model, pid) {
  return filter(model.live_findings, (finding) => {
    return finding.pid === pid;
  });
}
function filtered_events(model) {
  let _block;
  let _pipe = model.events;
  _block = filter(_pipe, (row) => {
    return model.show_internal || !row.internal;
  });
  let visible_noise = _block;
  let $ = model.remote;
  if ($) {
    let $1 = model.loaded_query === remote_query(model);
    if ($1) {
      return visible_noise;
    } else {
      return List$Empty$const;
    }
  } else {
    let query = lowercase(remote_query(model));
    let _pipe$1 = visible_noise;
    return filter(_pipe$1, (row) => {
      return query === "" || contains_string(lowercase(row.id), query) || contains_string(lowercase(row.actor), query) || contains_string(lowercase(row.kind), query);
    });
  }
}
function visible_events(model) {
  let relative_start = max2(model.viewport_start - model.loaded_start, 0);
  let _pipe = model;
  let _pipe$1 = filtered_events(_pipe);
  let _pipe$2 = drop(_pipe$1, relative_start);
  return take(_pipe$2, model.viewport_size);
}
function selected_event(model) {
  let $ = model.selected_event_id;
  if ($ instanceof Some) {
    let id2 = $[0];
    let _pipe = model.events;
    let _pipe$1 = find(_pipe, (row) => {
      return row.id === id2;
    });
    return result_to_option(_pipe$1);
  } else {
    return $;
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/canvas_ffi.mjs
var palette = {
  background: "#111019",
  grid: "rgba(241, 188, 91, 0.12)",
  text: "#d8d1c4",
  muted: "#817b88",
  exact: "#f1bc5b",
  receive: "#9b7bff",
  anomaly: "#ff7369"
};
function draw(root2, source, zoom) {
  const canvas2 = root2?.querySelector?.("#causal-canvas") ?? document.querySelector("#causal-canvas");
  if (!(canvas2 instanceof HTMLCanvasElement))
    return;
  let rows;
  try {
    rows = JSON.parse(source);
  } catch (_) {
    return;
  }
  const bounds = canvas2.getBoundingClientRect();
  const width = Math.max(1, Math.floor(bounds.width));
  const height = Math.max(1, Math.floor(bounds.height));
  const density = Math.min(window.devicePixelRatio || 1, 2);
  canvas2.width = Math.floor(width * density);
  canvas2.height = Math.floor(height * density);
  const context = canvas2.getContext("2d");
  if (!context)
    return;
  context.setTransform(density, 0, 0, density, 0, 0);
  context.clearRect(0, 0, width, height);
  context.fillStyle = palette.background;
  context.fillRect(0, 0, width, height);
  const actors = [...new Set(rows.map((row) => row.actor))];
  const laneCount = Math.max(actors.length, 1);
  const top = 54;
  const laneHeight = Math.max(54, (height - top - 30) / laneCount);
  const left = 120;
  const right = 36;
  context.font = "12px ui-monospace, SFMono-Regular, Consolas, monospace";
  context.lineWidth = 1;
  actors.forEach((actor, index4) => {
    const y = top + index4 * laneHeight;
    context.strokeStyle = palette.grid;
    context.beginPath();
    context.moveTo(left, y);
    context.lineTo(width - right, y);
    context.stroke();
    context.fillStyle = palette.muted;
    context.fillText(actor, 14, y + 4);
  });
  if (rows.length === 0) {
    context.fillStyle = palette.muted;
    context.fillText("No events in this window", left, top + 20);
    return;
  }
  const first = Math.min(...rows.map((row) => Number(row.timestamp_ns)));
  const last = Math.max(...rows.map((row) => Number(row.timestamp_ns)));
  const range = Math.max(last - first, 1);
  const usable = Math.max(width - left - right, 1) * Math.max(0.25, Math.min(zoom, 4));
  const points = rows.map((row) => {
    const lane = Math.max(actors.indexOf(row.actor), 0);
    return {
      ...row,
      x: left + (Number(row.timestamp_ns) - first) / range * usable,
      y: top + lane * laneHeight
    };
  });
  context.strokeStyle = "rgba(216, 209, 196, 0.32)";
  context.lineWidth = 1.5;
  for (let index4 = 1;index4 < points.length; index4 += 1) {
    const from3 = points[index4 - 1];
    const to = points[index4];
    context.beginPath();
    context.moveTo(from3.x, from3.y);
    context.bezierCurveTo(from3.x + 24, from3.y, to.x - 24, to.y, to.x, to.y);
    context.stroke();
  }
  points.forEach((point) => {
    context.fillStyle = point.anomalous ? palette.anomaly : point.kind === "receive" ? palette.receive : palette.exact;
    context.beginPath();
    context.arc(point.x, point.y, point.anomalous ? 7 : 5, 0, Math.PI * 2);
    context.fill();
    if (point.evidence === "inferred") {
      context.strokeStyle = palette.muted;
      context.setLineDash([3, 3]);
      context.stroke();
      context.setLineDash([]);
    }
  });
}
function installShortcuts(handler) {
  if (window.__beamtraceShortcutsInstalled)
    return;
  window.__beamtraceShortcutsInstalled = true;
  window.addEventListener("keydown", (event3) => {
    const editable = event3.target instanceof HTMLInputElement || event3.target instanceof HTMLTextAreaElement;
    const command = (event3.ctrlKey || event3.metaKey) && event3.key.toLowerCase() === "k";
    const direct = !editable && ["1", "2", "3", "/"].includes(event3.key);
    if (!command && !direct)
      return;
    event3.preventDefault();
    handler(command ? "k" : event3.key);
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/canvas.mjs
function rows_payload(rows) {
  let _pipe = rows;
  let _pipe$1 = take(_pipe, 1000);
  let _pipe$2 = array2(_pipe$1, (row) => {
    return object2(toList([
      ["id", string3(row.id)],
      ["actor", string3(row.actor)],
      ["kind", string3(row.kind)],
      ["timestamp_ns", int3(row.timestamp_ns)],
      ["duration_ns", int3(row.duration_ns)],
      ["anomalous", bool2(row.anomalous)],
      [
        "evidence",
        string3((() => {
          let $ = row.evidence;
          if ($ instanceof Exact) {
            return "exact";
          } else {
            return "inferred";
          }
        })())
      ]
    ]));
  });
  return to_string2(_pipe$2);
}
function event_payload(model) {
  return rows_payload(visible_events(model));
}
function live_payload(model) {
  let _pipe = model;
  let _pipe$1 = filtered_live_rows(_pipe);
  let _pipe$2 = take(_pipe$1, 200);
  let _pipe$3 = array2(_pipe$2, (row) => {
    let anomalous = any(model.live_findings, (finding) => {
      return finding.pid === row.pid;
    });
    return object2(toList([
      ["id", string3(row.pid)],
      ["actor", string3(row.label)],
      ["kind", string3(row.status)],
      ["timestamp_ns", int3(row.reductions)],
      ["duration_ns", int3(row.mailbox_len)],
      ["anomalous", bool2(anomalous)],
      [
        "evidence",
        string3((() => {
          if (anomalous) {
            return "inferred";
          } else {
            return "exact";
          }
        })())
      ]
    ]));
  });
  return to_string2(_pipe$3);
}
function payload(model) {
  let $ = model.mode;
  if ($ instanceof Live) {
    return live_payload(model);
  } else if ($ instanceof Team) {
    return rows_payload(model.team_events);
  } else {
    return event_payload(model);
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/capture_control_ffi.mjs
var captureActive = false;
var mfaSearchTimer;
var mfaSearchController;
async function request(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      ...options.body ? { "content-type": "application/json" } : {}
    },
    ...options
  });
  const body = await response.text();
  if (!response.ok) {
    let detail = `request failed (${response.status})`;
    try {
      const parsed = JSON.parse(body);
      if (typeof parsed.error === "string")
        detail = parsed.error;
    } catch {}
    throw new Error(detail);
  }
  return body;
}
function complete(promise, onSuccess, onError) {
  promise.then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "capture request failed");
  });
}
function armCapture(trigger, whereAql, preset, maxRoots, onSuccess, onError) {
  complete(request("/api/v1/sessions/current/arm", {
    method: "POST",
    body: JSON.stringify({
      trigger: trigger.trim(),
      where: whereAql.trim() || null,
      capture_window_ms: 30000,
      max_events: 1e5,
      max_bytes: 64000000,
      max_agent_mailbox: 1e4,
      max_roots: Number.parseInt(maxRoots, 10),
      preset
    })
  }).then((body) => {
    captureActive = true;
    return body;
  }), onSuccess, onError);
}
function fetchCaptureStatus(onSuccess, onError) {
  complete(request("/api/v1/sessions/current", { method: "GET" }).then((body) => {
    try {
      const status = JSON.parse(body).status;
      if (status === "ready" || status === "failed" || status === "idle") {
        captureActive = false;
      }
    } catch {}
    return body;
  }), onSuccess, onError);
}
function searchMfas(query, onSuccess, onError) {
  globalThis.clearTimeout(mfaSearchTimer);
  mfaSearchController?.abort();
  const normalized = query.trim();
  if (!normalized) {
    onSuccess('{"candidates":[]}');
    return;
  }
  mfaSearchTimer = globalThis.setTimeout(() => {
    mfaSearchController = new AbortController;
    request(`/api/v1/targets/current/mfas?q=${encodeURIComponent(normalized)}&limit=20`, { method: "GET", signal: mfaSearchController.signal }).then(onSuccess).catch((error) => {
      if (error?.name !== "AbortError") {
        onError(error instanceof Error ? error.message : "MFA search failed");
      }
    });
  }, 120);
}
function cancelCapture(onSuccess, onError) {
  complete(request("/api/v1/sessions/current/cancel", { method: "POST" }), onSuccess, onError);
}
function saveCapture(path, onSuccess, onError) {
  complete(request("/api/v1/sessions/current/save", {
    method: "POST",
    body: JSON.stringify({ path })
  }), onSuccess, onError);
}
function schedule(delayMs, callback) {
  globalThis.setTimeout(callback, Math.max(0, delayMs));
}
function installPageCleanup() {
  globalThis.addEventListener("pagehide", () => {
    if (!captureActive)
      return;
    captureActive = false;
    fetch("/api/v1/sessions/current/cancel", {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { accept: "application/json" }
    }).catch(() => {});
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/capture_control.mjs
class StatusPayload extends CustomType {
  constructor(status, event_count, completeness, reason) {
    super();
    this.status = status;
    this.event_count = event_count;
    this.completeness = completeness;
    this.reason = reason;
  }
}

class MfaCandidatePayload extends CustomType {
  constructor(mfa) {
    super();
    this.mfa = mfa;
  }
}

class MfaSearchPayload extends CustomType {
  constructor(candidates) {
    super();
    this.candidates = candidates;
  }
}
function arm(trigger, where_aql, preset, max_roots) {
  return from2((dispatch2) => {
    return armCapture(trigger, where_aql, preset, max_roots, (_) => {
      return dispatch2(Msg$CaptureArmAccepted$const);
    }, (reason) => {
      return dispatch2(new CaptureArmFailed(reason));
    });
  });
}
function status_decoder() {
  return field("status", string2, (status) => {
    return optional_field("event_count", 0, int2, (event_count) => {
      return optional_field("completeness", "", string2, (completeness) => {
        return optional_field("reason", "", string2, (reason) => {
          return success(new StatusPayload(status, event_count, completeness, reason));
        });
      });
    });
  });
}
function decode_status(source) {
  let $ = parse(source, status_decoder());
  if ($ instanceof Ok) {
    let payload2 = $[0];
    let $1 = payload2.status;
    if ($1 === "idle") {
      return new Ok(CapturePhase$Idle$const);
    } else if ($1 === "armed") {
      return new Ok(CapturePhase$Armed$const);
    } else if ($1 === "cancelling") {
      return new Ok(CapturePhase$Cancelling$const);
    } else if ($1 === "ready") {
      return new Ok(new Ready(payload2.event_count, payload2.completeness));
    } else if ($1 === "failed") {
      return new Ok(new Failed(payload2.reason));
    } else {
      return new Error2("unknown capture status");
    }
  } else {
    return new Error2("invalid capture status");
  }
}
function status() {
  return from2((dispatch2) => {
    return fetchCaptureStatus((body) => {
      let $ = decode_status(body);
      if ($ instanceof Ok) {
        let phase = $[0];
        return dispatch2(new CaptureStatusLoaded(phase));
      } else {
        let reason = $[0];
        return dispatch2(new CaptureArmFailed(reason));
      }
    }, (_) => {
      return dispatch2(new CaptureStatusLoaded(CapturePhase$Unavailable$const));
    });
  });
}
function mfa_candidate_decoder() {
  return field("mfa", string2, (mfa) => {
    return success(new MfaCandidatePayload(mfa));
  });
}
function mfa_search_decoder() {
  return field("candidates", list2(mfa_candidate_decoder()), (candidates) => {
    return success(new MfaSearchPayload(candidates));
  });
}
function decode_mfas(source) {
  let $ = parse(source, mfa_search_decoder());
  if ($ instanceof Ok) {
    let payload2 = $[0];
    return new Ok((() => {
      let _pipe = payload2.candidates;
      return map2(_pipe, (candidate) => {
        return candidate.mfa;
      });
    })());
  } else {
    return new Error2("invalid MFA search response");
  }
}
function search_mfas(query) {
  return from2((dispatch2) => {
    return searchMfas(query, (body) => {
      let $ = decode_mfas(body);
      if ($ instanceof Ok) {
        let candidates = $[0];
        return dispatch2(new MfaSuggestionsLoaded(candidates));
      } else {
        return dispatch2(new MfaSuggestionsLoaded(List$Empty$const));
      }
    }, (_) => {
      return dispatch2(new MfaSuggestionsLoaded(List$Empty$const));
    });
  });
}
function poll_after(delay_ms) {
  return from2((dispatch2) => {
    return schedule(delay_ms, () => {
      return dispatch2(Msg$PollCaptureStatus$const);
    });
  });
}
function cancel() {
  return from2((dispatch2) => {
    return cancelCapture((_) => {
      return dispatch2(new CaptureStatusLoaded(CapturePhase$Cancelling$const));
    }, (reason) => {
      return dispatch2(new CaptureCancelFailed(reason));
    });
  });
}
function save(path) {
  return from2((dispatch2) => {
    return saveCapture(path, (_) => {
      return dispatch2(new CaptureSaved(path));
    }, (reason) => {
      return dispatch2(new CaptureSaveFailed(reason));
    });
  });
}
function install_cleanup() {
  return from2((_) => {
    return installPageCleanup();
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/compare_control_ffi.mjs
function requestCompare(body, onSuccess, onError) {
  fetch("/api/v1/compare", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      "content-type": "application/json"
    },
    body
  }).then(async (response) => {
    const payload2 = await response.text();
    if (!response.ok) {
      let reason = `compare request failed (${response.status})`;
      try {
        const parsed = JSON.parse(payload2);
        if (typeof parsed.error === "string")
          reason = parsed.error;
      } catch {}
      throw new Error(reason);
    }
    return payload2;
  }).then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "compare request failed");
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/compare_control.mjs
function statistic_decoder() {
  return field("signature", string2, (signature) => {
    return field("p50_ns", int2, (p50_ns) => {
      return field("p95_ns", int2, (p95_ns) => {
        return field("occurrences", int2, (occurrences) => {
          return field("total_runs", int2, (total_runs) => {
            return field("occurrence_rate", float2, (occurrence_rate) => {
              return success(new BranchStatistic(signature, p50_ns, p95_ns, occurrences, total_runs, occurrence_rate));
            });
          });
        });
      });
    });
  });
}
function item_decoder() {
  return field("status", string2, (status2) => {
    return optional_field("left_id", "", string2, (left_id) => {
      return optional_field("right_id", "", string2, (right_id) => {
        return optional_field("latency_delta_ns", 0, int2, (latency_delta_ns) => {
          return optional_field("reason", "", string2, (reason) => {
            if (status2 === "matched") {
              return success(new CompareItem(status2, left_id, right_id, latency_delta_ns, reason));
            } else if (status2 === "added") {
              return success(new CompareItem(status2, left_id, right_id, latency_delta_ns, reason));
            } else if (status2 === "removed") {
              return success(new CompareItem(status2, left_id, right_id, latency_delta_ns, reason));
            } else if (status2 === "changed") {
              return success(new CompareItem(status2, left_id, right_id, latency_delta_ns, reason));
            } else {
              return failure(new CompareItem("", "", "", 0, ""), "compare item status");
            }
          });
        });
      });
    });
  });
}
function run_decoder() {
  return field("path", string2, (path) => {
    return field("added", int2, (added) => {
      return field("removed", int2, (removed) => {
        return field("changed", int2, (changed) => {
          return field("items", list2(item_decoder()), (items) => {
            return success(new CompareRun(path, added, removed, changed, items));
          });
        });
      });
    });
  });
}
function report_decoder() {
  return field("baseline", string2, (baseline) => {
    return field("run_count", int2, (run_count) => {
      return field("reports", list2(run_decoder()), (reports) => {
        return field("statistics", list2(statistic_decoder()), (statistics) => {
          return success(new CompareReport(baseline, run_count, reports, statistics));
        });
      });
    });
  });
}
function decode_report(source) {
  let $ = parse(source, report_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let errors = $[0];
    return new Error2(inspect2(errors));
  }
}
function run2(paths) {
  return from2((dispatch2) => {
    return requestCompare((() => {
      let _pipe = object2(toList([["paths", array2(paths, string3)]]));
      return to_string2(_pipe);
    })(), (body) => {
      let $ = decode_report(body);
      if ($ instanceof Ok) {
        let report = $[0];
        return dispatch2(new CompareLoaded(report));
      } else {
        let reason = $[0];
        return dispatch2(new CompareFailed(reason));
      }
    }, (reason) => {
      return dispatch2(new CompareFailed(reason));
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/live_control_ffi.mjs
function fetchLive(onSuccess, onError) {
  fetch("/api/v1/live?limit=200", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      let reason = `live request failed (${response.status})`;
      try {
        const parsed = JSON.parse(body);
        if (typeof parsed.error === "string")
          reason = parsed.error;
      } catch {}
      throw new Error(reason);
    }
    return body;
  }).then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "live request failed");
  });
}
function schedule2(delayMs, callback) {
  globalThis.setTimeout(callback, Math.max(0, delayMs));
}

// build/dev/javascript/beamtrace_web/beamtrace_web/live_control.mjs
class TopologyPayload extends CustomType {
  constructor(supervision, spawn, links) {
    super();
    this.supervision = supervision;
    this.spawn = spawn;
    this.links = links;
  }
}
function evidence_decoder() {
  return field("status", string2, (status2) => {
    if (status2 === "exact") {
      return success(Evidence$Exact$const);
    } else if (status2 === "inferred") {
      return field("reason", string2, (reason) => {
        return field("confidence", float2, (confidence) => {
          return success(new Inferred(reason, confidence));
        });
      });
    } else {
      return failure(Evidence$Exact$const, "live evidence");
    }
  });
}
function topology_edge_decoder() {
  return field("from", string2, (from3) => {
    return field("to", string2, (to) => {
      return field("evidence", evidence_decoder(), (evidence) => {
        return success(new TopologyEdge(from3, to, evidence));
      });
    });
  });
}
function topology_decoder() {
  return field("supervision", list2(topology_edge_decoder()), (supervision) => {
    return field("spawn", list2(topology_edge_decoder()), (spawn) => {
      return field("links", list2(topology_edge_decoder()), (links) => {
        return success(new TopologyPayload(supervision, spawn, links));
      });
    });
  });
}
function finding_decoder() {
  return field("pid", string2, (pid) => {
    return field("label", string2, (label2) => {
      return field("kind", string2, (kind) => {
        return field("summary", string2, (summary) => {
          return field("evidence", evidence_decoder(), (evidence) => {
            return success(new LiveFinding(pid, label2, kind, summary, evidence));
          });
        });
      });
    });
  });
}
function row_decoder() {
  return field("node", string2, (node) => {
    return field("pid", string2, (pid) => {
      return field("label", string2, (label2) => {
        return field("registered_name", string2, (registered_name) => {
          return field("process_label", string2, (process_label) => {
            return field("initial_call", string2, (initial_call) => {
              return field("mailbox_len", int2, (mailbox_len) => {
                return field("memory_bytes", int2, (memory_bytes) => {
                  return field("reductions", int2, (reductions) => {
                    return field("heap_words", int2, (heap_words) => {
                      return field("total_heap_words", int2, (total_heap_words) => {
                        return field("link_count", int2, (link_count) => {
                          return field("status", string2, (status2) => {
                            return field("current_function", string2, (current_function) => {
                              return field("links", list2(string2), (links) => {
                                return field("ancestors", list2(string2), (ancestors) => {
                                  return success(new LiveRow(node, pid, label2, registered_name, process_label, initial_call, mailbox_len, memory_bytes, reductions, heap_words, total_heap_words, link_count, status2, current_function, links, ancestors));
                                });
                              });
                            });
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}
function snapshot_decoder() {
  return field("node", string2, (_) => {
    return field("generation", int2, (generation) => {
      return field("sampled_at_ms", int2, (sampled_at_ms) => {
        return field("next_offset", int2, (_2) => {
          return field("samples", list2(row_decoder()), (rows) => {
            return field("findings", list2(finding_decoder()), (findings) => {
              return field("topology", topology_decoder(), (topology) => {
                return success(new LiveSnapshot(generation, sampled_at_ms, rows, findings, topology.supervision, topology.spawn, topology.links));
              });
            });
          });
        });
      });
    });
  });
}
function decode_snapshot(source) {
  let $ = parse(source, snapshot_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let errors = $[0];
    return new Error2(inspect2(errors));
  }
}
function load() {
  return from2((dispatch2) => {
    return fetchLive((body) => {
      let $ = decode_snapshot(body);
      if ($ instanceof Ok) {
        let snapshot = $[0];
        return dispatch2(new LiveLoaded(snapshot));
      } else {
        let reason = $[0];
        return dispatch2(new LiveLoadFailed(reason));
      }
    }, (reason) => {
      return dispatch2(new LiveLoadFailed(reason));
    });
  });
}
function poll_after2(delay_ms) {
  return from2((dispatch2) => {
    return schedule2(delay_ms, () => {
      return dispatch2(Msg$PollLive$const);
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page.mjs
function is_internal(actor) {
  let normalized = lowercase(actor);
  return contains_string(normalized, "logger") || contains_string(normalized, "code_server") || contains_string(normalized, "beamtrace") || contains_string(normalized, "standard_io");
}
function evidence_decoder2() {
  return field("kind", string2, (kind) => {
    if (kind === "exact") {
      return success(Evidence$Exact$const);
    } else if (kind === "inferred") {
      return field("reason", string2, (reason) => {
        return field("confidence", float2, (confidence) => {
          return success(new Inferred(reason, confidence));
        });
      });
    } else {
      return failure(Evidence$Exact$const, "event evidence");
    }
  });
}
function kind_decoder() {
  return field("kind", string2, (kind) => {
    return success(kind);
  });
}
function logical_decoder() {
  return field("label", string2, (label2) => {
    return success(label2);
  });
}
function physical_decoder() {
  return field("pid", string2, (pid) => {
    return success(pid);
  });
}
function actor_decoder() {
  return field("physical", physical_decoder(), (physical) => {
    return field("logical", optional(logical_decoder()), (logical) => {
      return success((() => {
        if (logical instanceof Some) {
          let label2 = logical[0];
          return label2;
        } else {
          return physical;
        }
      })());
    });
  });
}
function event_decoder() {
  return field("id", string2, (id2) => {
    return field("process", actor_decoder(), (actor) => {
      return field("local_timestamp_ns", int2, (timestamp_ns) => {
        return field("event", kind_decoder(), (kind) => {
          return field("evidence", evidence_decoder2(), (evidence) => {
            return success(new EventRow(id2, actor, kind, timestamp_ns, 0, evidence, kind === "exit" || kind === "gap", is_internal(actor)));
          });
        });
      });
    });
  });
}
function page_decoder() {
  return field("start", int2, (start5) => {
    return field("limit", int2, (limit) => {
      return field("total", int2, (total) => {
        return field("events", list2(event_decoder()), (events2) => {
          return success(new EventPage(events2, total, start5, limit));
        });
      });
    });
  });
}
function decode3(source) {
  let $ = parse(source, page_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let errors = $[0];
    return new Error2(inspect2(errors));
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page_loader_ffi.mjs
function pageUrl(start5, limit, search) {
  const query = new URLSearchParams({
    start: String(start5),
    limit: String(limit)
  });
  if (search.trim() !== "") {
    query.set("q", search.trim());
  }
  return `/api/v1/sessions/current/events?${query}`;
}
function fetchPage(start5, limit, search, onSuccess, onError) {
  fetch(pageUrl(start5, limit, search), {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`event page request failed (${response.status})`);
    }
    return body;
  }).then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "event page request failed");
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page_loader.mjs
function load2(start5, limit, query) {
  return from2((dispatch2) => {
    return fetchPage(start5, limit, query, (body) => {
      let $ = decode3(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch2(new PageLoaded(query, page));
      } else {
        let reason = $[0];
        return dispatch2(new PageLoadFailed(query, reason));
      }
    }, (reason) => {
      return dispatch2(new PageLoadFailed(query, reason));
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/team_control_ffi.mjs
function request2(path, options = {}) {
  const { headers = {}, ...requestOptions } = options;
  return fetch(path, {
    credentials: "same-origin",
    ...requestOptions,
    headers: { accept: "application/json", ...headers }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      if (response.status === 401) {
        throw new Error("Sign in to the Team workspace to view traces");
      }
      if (response.status === 403) {
        throw new Error("This action is not permitted for your Team role");
      }
      throw new Error(`team trace request failed (${response.status})`);
    }
    return body;
  });
}
function complete2(promise, onSuccess, onError) {
  promise.then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "team trace request failed");
  });
}
function cursorQuery(cursor, limit) {
  const query = new URLSearchParams({ limit: String(limit) });
  if (cursor)
    query.set("cursor", cursor);
  return query.toString();
}
function fetchTraces(cursor, onSuccess, onError) {
  complete2(request2(`/api/v1/traces?${cursorQuery(cursor, 50)}`), onSuccess, onError);
}
function fetchEvents(traceId, cursor, onSuccess, onError) {
  complete2(request2(`/api/v1/traces/${encodeURIComponent(traceId)}/events?${cursorQuery(cursor, 200)}`), onSuccess, onError);
}
function cookie(name) {
  const prefix = `${name}=`;
  for (const part of document.cookie.split(";")) {
    const value2 = part.trim();
    if (value2.startsWith(prefix))
      return decodeURIComponent(value2.slice(prefix.length));
  }
  return "";
}
function updateHold(traceId, enabled, onSuccess, onError) {
  const csrf = cookie("beamtrace_csrf");
  complete2(request2(`/api/v1/traces/${encodeURIComponent(traceId)}/hold`, {
    method: enabled ? "POST" : "DELETE",
    headers: { "x-beamtrace-csrf": csrf }
  }), onSuccess, onError);
}

// build/dev/javascript/beamtrace_web/beamtrace_web/team_control.mjs
function mfa_decoder() {
  return field("module", string2, (module_) => {
    return field("function", string2, (function_) => {
      return field("arity", int2, (arity) => {
        return success([module_, function_, arity]);
      });
    });
  });
}
function trace_decoder() {
  return field("id", string2, (id2) => {
    return field("status", string2, (status2) => {
      return field("node", string2, (node) => {
        return field("mfa", mfa_decoder(), (mfa) => {
          return field("privacy", string2, (privacy) => {
            return field("completeness", string2, (completeness) => {
              return field("event_count", int2, (event_count) => {
                return field("received_at_ms", int2, (received_at_ms) => {
                  return field("legal_hold", bool, (legal_hold) => {
                    return field("locked", bool, (locked) => {
                      return success(new TeamTrace(id2, status2, node, mfa[0], mfa[1], mfa[2], privacy, completeness, event_count, received_at_ms, legal_hold, locked));
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}
function traces_decoder() {
  return field("traces", list2(trace_decoder()), (traces) => {
    return field("next_cursor", optional(string2), (next) => {
      return success(new TeamTracePage(traces, next));
    });
  });
}
function decode_traces(source) {
  let $ = parse(source, traces_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let error = $[0];
    return new Error2(inspect2(error));
  }
}
function load_traces(cursor) {
  return from2((dispatch2) => {
    return fetchTraces(cursor, (body) => {
      let $ = decode_traces(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch2(new TeamTracesLoaded(page));
      } else {
        let reason = $[0];
        return dispatch2(new TeamTracesFailed(reason));
      }
    }, (reason) => {
      return dispatch2(new TeamTracesFailed(reason));
    });
  });
}
function events_decoder() {
  return field("trace_id", string2, (trace_id) => {
    return field("events", list2(event_decoder()), (events2) => {
      return field("next_cursor", optional(string2), (next) => {
        return success(new TeamEventPage(trace_id, events2, next));
      });
    });
  });
}
function decode_events(source) {
  let $ = parse(source, events_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let error = $[0];
    return new Error2(inspect2(error));
  }
}
function load_events(trace_id, cursor) {
  return from2((dispatch2) => {
    return fetchEvents(trace_id, cursor, (body) => {
      let $ = decode_events(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch2(new TeamEventsLoaded(page));
      } else {
        let reason = $[0];
        return dispatch2(new TeamEventsFailed(trace_id, reason));
      }
    }, (reason) => {
      return dispatch2(new TeamEventsFailed(trace_id, reason));
    });
  });
}
function decode_trace(source) {
  let $ = parse(source, trace_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    let error = $[0];
    return new Error2(inspect2(error));
  }
}
function set_hold(trace_id, enabled) {
  return from2((dispatch2) => {
    return updateHold(trace_id, enabled, (body) => {
      let $ = decode_trace(body);
      if ($ instanceof Ok) {
        let trace = $[0];
        return dispatch2(new TraceHoldUpdated(trace));
      } else {
        let reason = $[0];
        return dispatch2(new TraceHoldFailed(reason));
      }
    }, (reason) => {
      return dispatch2(new TraceHoldFailed(reason));
    });
  });
}

// build/dev/javascript/lustre/lustre/event.mjs
function on(name, handler) {
  return event(name, map3(handler, (message) => {
    return new Handler(false, false, message);
  }), empty_list, never, never, 0, 0);
}
function on_click(message) {
  return on("click", success(message));
}
function on_input(message) {
  return on("input", subfield(toList(["target", "value"]), string2, (value2) => {
    return success(message(value2));
  }));
}

// build/dev/javascript/beamtrace_web/beamtrace_web/view.mjs
class ComparedItem extends CustomType {
  constructor(path, item) {
    super();
    this.path = path;
    this.item = item;
  }
}
function team_status(model) {
  let $ = model.team_loading;
  if ($) {
    return "Loading traces";
  } else {
    return to_string(length(model.team_traces)) + " loaded";
  }
}
function zoom_label(value2) {
  if (value2 === 0.25) {
    return "25%";
  } else if (value2 === 0.5) {
    return "50%";
  } else if (value2 === 1) {
    return "100%";
  } else if (value2 === 2) {
    return "200%";
  } else if (value2 === 4) {
    return "400%";
  } else {
    return "custom";
  }
}
function compare_summary(model) {
  let $ = model.compare_loading;
  let $1 = model.compare_error;
  let $2 = model.compare_report;
  if ($) {
    return "Loading bounded trace set…";
  } else if ($1 instanceof Some) {
    let reason = $1[0];
    return "Compare unavailable · " + reason;
  } else if ($2 instanceof Some) {
    let report = $2[0];
    let added = fold2(report.reports, 0, (total, run3) => {
      return total + run3.added;
    });
    let removed = fold2(report.reports, 0, (total, run3) => {
      return total + run3.removed;
    });
    let changed = fold2(report.reports, 0, (total, run3) => {
      return total + run3.changed;
    });
    return to_string(report.run_count) + " runs · +" + to_string(added) + " −" + to_string(removed) + " ~" + to_string(changed);
  } else {
    return "No comparison loaded";
  }
}
function definition(label2, value2) {
  return div(toList([class$("definition")]), toList([
    span(List$Empty$const, toList([text3(label2)])),
    strong(List$Empty$const, toList([text3(value2)]))
  ]));
}
function panel_heading(title, index4) {
  return div(toList([class$("panel-heading")]), toList([
    span(List$Empty$const, toList([text3(index4)])),
    strong(List$Empty$const, toList([text3(title)]))
  ]));
}
function evidence_label(evidence) {
  if (evidence instanceof Exact) {
    return "Exact";
  } else {
    let reason = evidence.reason;
    let confidence = evidence.confidence;
    return "Inferred " + zoom_label(confidence) + " · " + reason;
  }
}
function compare_inspector(model) {
  return aside(toList([
    class$("inspector panel"),
    aria_label("Compare inspector"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Compare inspector", "03"),
    (() => {
      let $ = model.compare_report;
      if ($ instanceof Some) {
        let report = $[0];
        return div(toList([class$("inspector-content")]), toList([
          definition("Baseline", report.baseline),
          definition("Runs", to_string(report.run_count)),
          definition("Aligned candidates", to_string(length(report.reports))),
          definition("Branch signatures", to_string(length(report.statistics))),
          definition("Normalization", "logical actor · term shape · root-relative time")
        ]));
      } else {
        return div(toList([class$("empty-state")]), toList([
          p(List$Empty$const, toList([
            text3("Run a comparison to inspect branch statistics.")
          ]))
        ]));
      }
    })()
  ]));
}
function list_text(items) {
  if (items instanceof Empty) {
    return "None observed";
  } else {
    return join(items, ", ");
  }
}
function mode_title(mode) {
  if (mode instanceof Capture) {
    return "Exact causal sequence";
  } else if (mode instanceof Live) {
    return "Runtime signals";
  } else if (mode instanceof Compare) {
    return "Trace alignment";
  } else {
    return "Team trace library";
  }
}
function mode_slug(mode) {
  if (mode instanceof Capture) {
    return "capture";
  } else if (mode instanceof Live) {
    return "live";
  } else if (mode instanceof Compare) {
    return "compare";
  } else {
    return "team";
  }
}
function statistics_table(rows) {
  return div(toList([class$("event-table-wrap compare-statistics")]), toList([
    table(toList([aria_label("Multi-run branch statistics")]), toList([
      thead(List$Empty$const, toList([
        tr(List$Empty$const, toList([
          th(List$Empty$const, toList([text3("Logical branch signature")])),
          th(List$Empty$const, toList([text3("Latency")])),
          th(List$Empty$const, toList([text3("Occurrence")]))
        ]))
      ])),
      tbody(List$Empty$const, map2(rows, (row) => {
        return tr(List$Empty$const, toList([
          td(List$Empty$const, toList([text3(row.signature)])),
          td(List$Empty$const, toList([
            text3("p50 " + to_string(row.p50_ns) + " ns · p95 " + to_string(row.p95_ns) + " ns")
          ])),
          td(List$Empty$const, toList([
            text3(to_string(row.occurrences) + "/" + to_string(row.total_runs) + " runs")
          ]))
        ]));
      }))
    ]))
  ]));
}
function or_dash(value2) {
  if (value2 === "") {
    return "—";
  } else {
    return value2;
  }
}
function latency_delta(item) {
  let $ = item.status;
  if ($ === "matched") {
    let $1 = item.latency_delta_ns >= 0;
    if ($1) {
      return "+" + to_string(item.latency_delta_ns) + " ns";
    } else {
      return to_string(item.latency_delta_ns) + " ns";
    }
  } else {
    return "—";
  }
}
function compare_status_class(status2) {
  if (status2 === "added") {
    return "anomalous";
  } else if (status2 === "removed") {
    return "anomalous";
  } else if (status2 === "changed") {
    return "anomalous";
  } else {
    return "";
  }
}
function alignment_row(row) {
  return tr(toList([class$(compare_status_class(row.item.status))]), toList([
    td(List$Empty$const, toList([text3(row.path)])),
    td(List$Empty$const, toList([
      span(toList([class$("kind-pill")]), toList([text3(row.item.status)]))
    ])),
    td(List$Empty$const, toList([text3(or_dash(row.item.left_id))])),
    td(List$Empty$const, toList([text3(or_dash(row.item.right_id))])),
    td(List$Empty$const, toList([text3(latency_delta(row.item))])),
    td(List$Empty$const, toList([text3(or_dash(row.item.reason))]))
  ]));
}
function alignment_table(rows) {
  return div(toList([class$("event-table-wrap compare-alignment")]), toList([
    table(toList([aria_label("Accessible trace alignment table")]), toList([
      thead(List$Empty$const, toList([
        tr(List$Empty$const, toList([
          th(List$Empty$const, toList([text3("Candidate")])),
          th(List$Empty$const, toList([text3("Status")])),
          th(List$Empty$const, toList([text3("Baseline event")])),
          th(List$Empty$const, toList([text3("Candidate event")])),
          th(List$Empty$const, toList([text3("Latency Δ")])),
          th(List$Empty$const, toList([text3("Reason")]))
        ]))
      ])),
      tbody(List$Empty$const, map2(rows, alignment_row))
    ]))
  ]));
}
function compare_workspace(model) {
  let _block;
  let $ = model.compare_report;
  if ($ instanceof Some) {
    let report = $[0];
    let _pipe = report.reports;
    _block = flat_map(_pipe, (run3) => {
      return map2(run3.items, (item) => {
        return new ComparedItem(run3.path, item);
      });
    });
  } else {
    _block = List$Empty$const;
  }
  let items = _block;
  return section(toList([
    class$("causal panel compare-panel"),
    aria_label("Trace comparison")
  ]), toList([
    div(toList([class$("panel-toolbar")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3("compare")])),
        h2(List$Empty$const, toList([text3("PID-independent causal alignment")]))
      ])),
      span(toList([
        class$("window-count"),
        aria_live("polite")
      ]), toList([text3(compare_summary(model))]))
    ])),
    (() => {
      let $1 = model.compare_report;
      if ($1 instanceof Some) {
        let report = $1[0];
        return div(toList([class$("compare-results")]), toList([alignment_table(items), statistics_table(report.statistics)]));
      } else {
        return div(toList([class$("empty-state compare-empty")]), toList([
          p(List$Empty$const, toList([
            text3("Enter two or more local .beamtrace paths. The first run is the baseline.")
          ]))
        ]));
      }
    })()
  ]));
}
function live_evidence_label(findings) {
  if (findings instanceof Empty) {
    return "Exact sample";
  } else {
    let finding = findings.head;
    return evidence_label(finding.evidence);
  }
}
function finding_names(findings) {
  if (findings instanceof Empty) {
    return "None";
  } else {
    let _pipe = findings;
    let _pipe$1 = map2(_pipe, (finding) => {
      return finding.kind;
    });
    return join(_pipe$1, ", ");
  }
}
function live_status(model, visible_count) {
  let $ = model.live_loading;
  let $1 = model.live_error;
  if ($) {
    return "Refreshing bounded sample…";
  } else if ($1 instanceof Some) {
    let reason = $1[0];
    return "Live unavailable · " + reason;
  } else {
    return to_string(visible_count) + " processes · Generation " + to_string(model.live_generation);
  }
}
function capture_phase_label(phase) {
  if (phase instanceof Unavailable) {
    return "Offline session";
  } else if (phase instanceof Idle) {
    return "Idle";
  } else if (phase instanceof Arming) {
    return "Arming";
  } else if (phase instanceof Armed) {
    return "Armed";
  } else if (phase instanceof Cancelling) {
    return "Cancelling";
  } else if (phase instanceof Ready) {
    let count = phase.event_count;
    let completeness = phase.completeness;
    return "Ready · " + to_string(count) + " events · " + completeness;
  } else {
    let reason = phase.reason;
    return "Failed · " + reason;
  }
}
function capture_navigator(model) {
  return nav(toList([
    class$("navigator panel"),
    aria_label("Session navigator"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Nodes & sessions", "01"),
    section(List$Empty$const, toList([
      h2(List$Empty$const, toList([text3("Current target")])),
      div(toList([class$("node-card selected")]), toList([
        span(toList([class$("status-dot healthy")]), List$Empty$const),
        span(List$Empty$const, toList([
          strong(List$Empty$const, toList([text3("Attached BEAM session")])),
          span(List$Empty$const, toList([
            text3(capture_phase_label(model.capture_phase))
          ]))
        ]))
      ]))
    ])),
    section(List$Empty$const, toList([
      h2(List$Empty$const, toList([text3("Capture session")])),
      p(List$Empty$const, toList([
        text3((() => {
          let $ = trim(model.trigger_input);
          if ($ === "") {
            return "No trigger armed";
          } else {
            return $;
          }
        })())
      ]))
    ]))
  ]));
}
function capture_ready(phase) {
  if (phase instanceof Ready) {
    return true;
  } else {
    return false;
  }
}
function capture_busy(phase) {
  if (phase instanceof Arming) {
    return true;
  } else if (phase instanceof Armed) {
    return true;
  } else if (phase instanceof Cancelling) {
    return true;
  } else {
    return false;
  }
}
function capture_arm_disabled(phase) {
  if (phase instanceof Unavailable) {
    return true;
  } else {
    return capture_busy(phase);
  }
}
function preset_option(value2, label2) {
  return option(toList([value(value2)]), label2);
}
function palette2(model) {
  let $ = model.palette_open;
  if ($) {
    return dialog(toList([
      class$("command-palette"),
      attribute2("open", ""),
      aria_modal(true),
      aria_label("Command palette")
    ]), toList([
      div(toList([class$("palette-heading")]), toList([
        strong(List$Empty$const, toList([text3("Command palette")])),
        button(toList([on_click(Msg$UserClosedPalette$const)]), toList([text3("Close")]))
      ])),
      button(toList([
        on_click(new UserSelectedMode(Mode$Capture$const))
      ]), toList([text3("Arm capture trigger")])),
      button(toList([
        on_click(new UserSelectedMode(Mode$Live$const))
      ]), toList([text3("Open live anomalies")])),
      button(toList([
        on_click(new UserSelectedMode(Mode$Compare$const))
      ]), toList([text3("Compare saved traces")])),
      button(toList([
        on_click(new UserSelectedMode(Mode$Team$const))
      ]), toList([text3("Open Team trace library")]))
    ]));
  } else {
    return div(List$Empty$const, List$Empty$const);
  }
}
function event_minimap(model) {
  let previous = max2(model.viewport_start - model.viewport_size, 0);
  let last_start = max2(model.total_events - model.viewport_size, 0);
  let next = min2(model.viewport_start + model.viewport_size, last_start);
  let shown_end = min2(model.viewport_start + model.viewport_size, model.total_events);
  return footer(toList([class$("minimap"), aria_label("Time minimap")]), toList([
    button(toList([
      class$("quiet-button"),
      disabled(model.viewport_start === 0 || model.loading),
      on_click(new ViewportChanged(previous, model.viewport_size))
    ]), toList([text3("Previous")])),
    div(toList([class$("minimap-track")]), toList([
      div(toList([
        class$("minimap-window"),
        attribute2("data-start", to_string(model.viewport_start))
      ]), List$Empty$const)
    ])),
    span(List$Empty$const, toList([
      text3(to_string(model.viewport_start + 1) + "–" + to_string(shown_end) + " / " + to_string(model.total_events))
    ])),
    button(toList([
      class$("quiet-button"),
      disabled(shown_end >= model.total_events || model.loading),
      on_click(new ViewportChanged(next, model.viewport_size))
    ]), toList([text3("Next")])),
    span(toList([class$("zoom-label")]), toList([text3("Zoom " + zoom_label(model.zoom))]))
  ]));
}
function minimap(model) {
  let $ = model.mode;
  if ($ instanceof Capture) {
    return event_minimap(model);
  } else if ($ instanceof Live) {
    return footer(toList([
      class$("minimap"),
      aria_label("Live sampling status")
    ]), toList([
      span(List$Empty$const, toList([
        text3("Generation " + to_string(model.live_generation) + " · sampled at " + to_string(model.live_sampled_at_ms) + " ms")
      ])),
      span(List$Empty$const, toList([
        text3(to_string(length(model.live_findings)) + " active inferred anomalies")
      ]))
    ]));
  } else if ($ instanceof Compare) {
    return footer(toList([
      class$("minimap"),
      aria_label("Compare summary")
    ]), toList([
      span(List$Empty$const, toList([text3(compare_summary(model))]))
    ]));
  } else {
    return footer(toList([
      class$("minimap"),
      aria_label("Team trace status")
    ]), toList([
      span(List$Empty$const, toList([text3(team_status(model))]))
    ]));
  }
}
function team_inspector(model) {
  return aside(toList([
    class$("inspector panel"),
    aria_label("Team trace inspector"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Trace policy", "03"),
    (() => {
      let $ = selected_team_trace(model);
      if ($ instanceof Some) {
        let trace = $[0];
        return div(List$Empty$const, toList([
          definition("Trace", trace.id),
          definition("Status", trace.status),
          definition("Completeness", trace.completeness),
          definition("Privacy", (() => {
            let $1 = trace.locked;
            if ($1) {
              return trace.privacy + " · locked";
            } else {
              return trace.privacy;
            }
          })()),
          definition("Legal hold", (() => {
            let $1 = trace.legal_hold;
            if ($1) {
              return "enabled";
            } else {
              return "disabled";
            }
          })()),
          button(toList([
            class$("quiet-button"),
            on_click(new UserRequestedTraceHold(trace.id, !trace.legal_hold))
          ]), toList([
            text3((() => {
              let $1 = trace.legal_hold;
              if ($1) {
                return "Release legal hold";
              } else {
                return "Place legal hold";
              }
            })())
          ])),
          p(List$Empty$const, toList([
            text3("Legal hold changes require an Admin role and are CSRF-protected and audited.")
          ]))
        ]));
      } else {
        return p(List$Empty$const, toList([text3("Select a trace")]));
      }
    })()
  ]));
}
function inspector_event(model, row) {
  let bookmarked = contains(model.bookmarks, row.id);
  return div(toList([class$("inspector-content")]), toList([
    div(toList([class$("inspector-title")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3(row.kind)])),
        h2(List$Empty$const, toList([text3(row.actor)]))
      ])),
      button(toList([
        class$("bookmark-button"),
        aria_pressed((() => {
          if (bookmarked) {
            return "true";
          } else {
            return "false";
          }
        })()),
        on_click(new UserToggledBookmark(row.id))
      ]), toList([
        text3((() => {
          if (bookmarked) {
            return "★";
          } else {
            return "☆";
          }
        })())
      ]))
    ])),
    definition("Event ID", row.id),
    definition("Evidence", evidence_label(row.evidence)),
    definition("Duration", to_string(row.duration_ns) + " ns"),
    definition("Boundary", "None observed"),
    definition("Source", "Unavailable in this event metadata"),
    label(toList([class$("annotation")]), toList([
      span(List$Empty$const, toList([text3("Annotation")])),
      textarea(toList([
        placeholder("Record what this event explains…"),
        value(model.annotation),
        on_input((var0) => {
          return new UserChangedAnnotation(var0);
        })
      ]), model.annotation)
    ]))
  ]));
}
function event_inspector(model) {
  return aside(toList([
    class$("inspector panel"),
    aria_label("Event inspector"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Event inspector", "03"),
    (() => {
      let $ = selected_event(model);
      if ($ instanceof Some) {
        let row = $[0];
        return inspector_event(model, row);
      } else {
        return div(toList([class$("empty-state")]), toList([
          p(List$Empty$const, toList([
            text3("Select an event to inspect exact evidence.")
          ]))
        ]));
      }
    })()
  ]));
}
function live_inspector_process(model, row) {
  let findings = live_findings_for(model, row.pid);
  return div(toList([class$("inspector-content")]), toList([
    div(toList([class$("inspector-title")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3(row.status)])),
        h2(List$Empty$const, toList([text3(row.label)]))
      ]))
    ])),
    definition("PID", row.pid + " @ " + row.node),
    definition("Initial call", row.initial_call),
    definition("Current function", row.current_function),
    definition("Mailbox", to_string(row.mailbox_len)),
    definition("Memory", to_string(row.memory_bytes) + " bytes"),
    definition("Heap", to_string(row.total_heap_words) + " words"),
    definition("Ancestors", list_text(row.ancestors)),
    definition("Links", list_text(row.links)),
    section(toList([class$("finding-list")]), toList([
      h3(List$Empty$const, toList([text3("Anomaly evidence")])),
      (() => {
        if (findings instanceof Empty) {
          return p(List$Empty$const, toList([
            text3("No anomaly crossed its hysteresis threshold.")
          ]));
        } else {
          return ul(List$Empty$const, map2(findings, (finding) => {
            return li(List$Empty$const, toList([
              strong(List$Empty$const, toList([text3(finding.kind)])),
              span(List$Empty$const, toList([text3(finding.summary)])),
              span(List$Empty$const, toList([text3(evidence_label(finding.evidence))]))
            ]));
          }));
        }
      })()
    ]))
  ]));
}
function live_inspector(model) {
  return aside(toList([
    class$("inspector panel"),
    aria_label("Process inspector"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Process inspector", "03"),
    (() => {
      let $ = selected_live_process(model);
      if ($ instanceof Ok) {
        let row = $[0];
        return live_inspector_process(model, row);
      } else {
        return div(toList([class$("empty-state")]), toList([
          p(List$Empty$const, toList([
            text3("Select a process to inspect sampled metadata and evidence.")
          ]))
        ]));
      }
    })()
  ]));
}
function inspector(model) {
  let $ = model.mode;
  if ($ instanceof Capture) {
    return event_inspector(model);
  } else if ($ instanceof Live) {
    return live_inspector(model);
  } else if ($ instanceof Compare) {
    return compare_inspector(model);
  } else {
    return team_inspector(model);
  }
}
function event_row(row) {
  return tr(toList([
    class$((() => {
      let $ = row.anomalous;
      if ($) {
        return "anomalous";
      } else {
        return "";
      }
    })()),
    on_click(new UserSelectedEvent(row.id))
  ]), toList([
    td(List$Empty$const, toList([
      button(toList([class$("event-link")]), toList([text3(row.id)]))
    ])),
    td(List$Empty$const, toList([text3(row.actor)])),
    td(List$Empty$const, toList([
      span(toList([class$("kind-pill")]), toList([text3(row.kind)]))
    ])),
    td(List$Empty$const, toList([text3(to_string(row.timestamp_ns) + " ns")])),
    td(List$Empty$const, toList([text3(evidence_label(row.evidence))]))
  ]));
}
function event_table(rows) {
  return div(toList([class$("event-table-wrap")]), toList([
    table(toList([aria_label("Accessible causal event table")]), toList([
      thead(List$Empty$const, toList([
        tr(List$Empty$const, toList([
          th(List$Empty$const, toList([text3("Event")])),
          th(List$Empty$const, toList([text3("Actor")])),
          th(List$Empty$const, toList([text3("Kind")])),
          th(List$Empty$const, toList([text3("Time")])),
          th(List$Empty$const, toList([text3("Evidence")]))
        ]))
      ])),
      tbody(List$Empty$const, map2(rows, event_row))
    ]))
  ]));
}
function team_event_section(model) {
  let $ = selected_team_trace(model);
  if ($ instanceof Some) {
    let trace = $[0];
    if (trace.locked) {
      return div(toList([class$("empty-state locked-trace")]), toList([
        h3(List$Empty$const, toList([text3("Trace contents locked")])),
        p(List$Empty$const, toList([
          text3("This page does not request or render raw payloads without ViewRawTrace permission.")
        ]))
      ]));
    } else {
      let trace2 = $[0];
      return section(toList([class$("team-events")]), toList([
        h3(List$Empty$const, toList([text3("Events · " + trace2.id)])),
        (() => {
          let $1 = model.team_events_error;
          if ($1 instanceof Some) {
            let reason = $1[0];
            return p(toList([role("alert")]), toList([text3(reason)]));
          } else {
            return event_table(model.team_events);
          }
        })(),
        (() => {
          let $1 = model.team_events_next_cursor;
          if ($1 instanceof Some) {
            return button(toList([
              class$("quiet-button"),
              disabled(model.team_events_loading),
              on_click(Msg$UserRequestedMoreTeamEvents$const)
            ]), toList([text3("Load more events")]));
          } else {
            return div(List$Empty$const, List$Empty$const);
          }
        })()
      ]));
    }
  } else {
    return div(toList([class$("empty-state")]), toList([
      p(List$Empty$const, toList([
        text3("Select a trace to inspect its bounded event page.")
      ]))
    ]));
  }
}
function team_trace_row(trace) {
  return tr(toList([
    class$((() => {
      let $ = trace.locked;
      if ($) {
        return "locked";
      } else {
        return "";
      }
    })()),
    on_click(new UserSelectedTeamTrace(trace.id))
  ]), toList([
    td(List$Empty$const, toList([
      button(toList([class$("event-link")]), toList([text3(trace.id)]))
    ])),
    td(List$Empty$const, toList([
      span(toList([class$("kind-pill")]), toList([text3(trace.status)]))
    ])),
    td(List$Empty$const, toList([
      text3(trace.node + " · " + trace.module_ + ":" + trace.function_ + "/" + to_string(trace.arity))
    ])),
    td(List$Empty$const, toList([
      text3(trace.privacy),
      (() => {
        let $ = trace.locked;
        if ($) {
          return span(toList([
            class$("locked-badge"),
            aria_label("Content locked")
          ]), toList([text3(" Locked")]));
        } else {
          return span(List$Empty$const, List$Empty$const);
        }
      })()
    ])),
    td(List$Empty$const, toList([text3(to_string(trace.event_count))])),
    td(List$Empty$const, toList([text3(to_string(trace.received_at_ms) + " ms")]))
  ]));
}
function team_trace_table(model) {
  let $ = model.team_traces;
  if ($ instanceof Empty) {
    return div(toList([class$("empty-state")]), toList([
      p(List$Empty$const, toList([text3("No team traces are available.")]))
    ]));
  } else {
    let traces = $;
    return div(toList([class$("event-table-wrap team-trace-table")]), toList([
      table(toList([aria_label("Team traces")]), toList([
        thead(List$Empty$const, toList([
          tr(List$Empty$const, toList([
            th(List$Empty$const, toList([text3("Trace")])),
            th(List$Empty$const, toList([text3("Status")])),
            th(List$Empty$const, toList([text3("Node / MFA")])),
            th(List$Empty$const, toList([text3("Privacy")])),
            th(List$Empty$const, toList([text3("Events")])),
            th(List$Empty$const, toList([text3("Received")]))
          ]))
        ])),
        tbody(List$Empty$const, map2(traces, team_trace_row))
      ]))
    ]));
  }
}
function team_workspace(model) {
  return section(toList([
    class$("causal panel team-traces-panel"),
    aria_label("Team trace library")
  ]), toList([
    div(toList([class$("panel-toolbar")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3("team")])),
        h2(List$Empty$const, toList([text3("Session-scoped traces")]))
      ])),
      span(toList([
        class$("window-count"),
        aria_live("polite")
      ]), toList([text3(team_status(model))]))
    ])),
    (() => {
      let $ = model.team_error;
      if ($ instanceof Some) {
        let reason = $[0];
        return p(toList([class$("error-state"), role("alert")]), toList([text3(reason)]));
      } else {
        return div(List$Empty$const, List$Empty$const);
      }
    })(),
    team_trace_table(model),
    (() => {
      let $ = model.team_next_cursor;
      if ($ instanceof Some) {
        return button(toList([
          class$("quiet-button"),
          disabled(model.team_loading),
          on_click(Msg$UserRequestedMoreTeamTraces$const)
        ]), toList([text3("Load more traces")]));
      } else {
        return div(List$Empty$const, List$Empty$const);
      }
    })(),
    team_event_section(model)
  ]));
}
function event_workspace(model) {
  let visible = visible_events(model);
  let shown_count = length(visible);
  let total_count = model.total_events;
  return section(toList([
    class$("causal panel"),
    aria_label("Causal timeline")
  ]), toList([
    div(toList([class$("panel-toolbar")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3(mode_slug(model.mode))])),
        h2(List$Empty$const, toList([text3(mode_title(model.mode))]))
      ])),
      div(toList([class$("toolbar-actions")]), toList([
        button(toList([
          class$("quiet-button"),
          aria_pressed((() => {
            let $ = model.show_internal;
            if ($) {
              return "true";
            } else {
              return "false";
            }
          })()),
          on_click(Msg$UserToggledInternalNoise$const)
        ]), toList([
          text3((() => {
            let $ = model.show_internal;
            if ($) {
              return "Fold OTP noise";
            } else {
              return "Expand OTP noise";
            }
          })())
        ])),
        span(toList([
          class$("window-count"),
          aria_live("polite")
        ]), toList([
          text3((() => {
            let $ = model.loading;
            let $1 = model.load_error;
            if ($) {
              return "Loading event window…";
            } else if ($1 instanceof Some) {
              let reason = $1[0];
              return "Page unavailable · " + reason;
            } else {
              return to_string(shown_count) + " visible / " + to_string(total_count) + " total";
            }
          })())
        ]))
      ]))
    ])),
    div(toList([class$("canvas-frame")]), toList([
      canvas(toList([
        id("causal-canvas"),
        attribute2("width", "1600"),
        attribute2("height", "620"),
        aria_hidden(true)
      ]))
    ])),
    event_table(visible)
  ]));
}
function live_row(model, row) {
  let findings = live_findings_for(model, row.pid);
  return tr(toList([
    class$((() => {
      if (findings instanceof Empty) {
        return "";
      } else {
        return "anomalous";
      }
    })()),
    on_click(new UserSelectedLiveProcess(row.pid))
  ]), toList([
    td(List$Empty$const, toList([
      button(toList([class$("event-link")]), toList([text3(row.label)]))
    ])),
    td(List$Empty$const, toList([text3(row.pid)])),
    td(List$Empty$const, toList([text3(to_string(row.mailbox_len))])),
    td(List$Empty$const, toList([text3(to_string(row.memory_bytes) + " B")])),
    td(List$Empty$const, toList([text3(to_string(row.reductions))])),
    td(List$Empty$const, toList([text3(row.status)])),
    td(List$Empty$const, toList([text3(finding_names(findings))])),
    td(List$Empty$const, toList([text3(live_evidence_label(findings))]))
  ]));
}
function live_table(model, rows) {
  return div(toList([class$("event-table-wrap")]), toList([
    table(toList([aria_label("Accessible live process table")]), toList([
      thead(List$Empty$const, toList([
        tr(List$Empty$const, toList([
          th(List$Empty$const, toList([text3("Process")])),
          th(List$Empty$const, toList([text3("PID")])),
          th(List$Empty$const, toList([text3("Mailbox")])),
          th(List$Empty$const, toList([text3("Memory")])),
          th(List$Empty$const, toList([text3("Reductions")])),
          th(List$Empty$const, toList([text3("Status")])),
          th(List$Empty$const, toList([text3("Anomalies")])),
          th(List$Empty$const, toList([text3("Evidence")]))
        ]))
      ])),
      tbody(List$Empty$const, map2(rows, (row) => {
        return live_row(model, row);
      }))
    ]))
  ]));
}
function live_workspace(model) {
  let rows = filtered_live_rows(model);
  return section(toList([
    class$("causal panel"),
    aria_label("Live processes")
  ]), toList([
    div(toList([class$("panel-toolbar")]), toList([
      div(List$Empty$const, toList([
        p(toList([class$("eyebrow")]), toList([text3("live")])),
        h2(List$Empty$const, toList([text3("Bounded process sampling")]))
      ])),
      div(toList([class$("toolbar-actions")]), toList([
        span(toList([class$("window-count")]), toList([
          text3("Topology · supervision " + to_string(length(model.live_supervision)) + " · spawn " + to_string(length(model.live_spawn)) + " · links " + to_string(length(model.live_links)))
        ])),
        span(toList([
          class$("window-count"),
          aria_live("polite")
        ]), toList([text3(live_status(model, length(rows)))]))
      ]))
    ])),
    div(toList([class$("canvas-frame")]), toList([
      canvas(toList([
        id("causal-canvas"),
        attribute2("width", "1600"),
        attribute2("height", "620"),
        aria_hidden(true)
      ]))
    ])),
    live_table(model, rows)
  ]));
}
function causal_workspace(model) {
  let $ = model.mode;
  if ($ instanceof Capture) {
    return event_workspace(model);
  } else if ($ instanceof Live) {
    return live_workspace(model);
  } else if ($ instanceof Compare) {
    return compare_workspace(model);
  } else {
    return team_workspace(model);
  }
}
function team_navigator(model) {
  return nav(toList([
    class$("navigator panel"),
    aria_label("Team trace navigator"),
    attribute2("tabindex", "0")
  ]), toList([
    panel_heading("Team trace library", "01"),
    section(List$Empty$const, toList([
      h2(List$Empty$const, toList([text3("Retention-safe sessions")])),
      p(List$Empty$const, toList([
        text3(to_string(length(model.team_traces)) + " traces loaded · max 100")
      ])),
      button(toList([
        class$("quiet-button"),
        disabled(model.team_loading),
        on_click(Msg$UserRequestedTeamTraces$const)
      ]), toList([text3("Refresh traces")]))
    ])),
    section(List$Empty$const, toList([
      h2(List$Empty$const, toList([text3("Privacy")])),
      p(List$Empty$const, toList([
        text3("Raw and unknown trace contents remain locked unless your combined role permits access.")
      ]))
    ]))
  ]));
}
function session_navigator(model) {
  let $ = model.mode;
  if ($ instanceof Team) {
    return team_navigator(model);
  } else {
    return capture_navigator(model);
  }
}
function compare_controls(model) {
  return section(toList([
    class$("capture-controls compare-controls"),
    aria_label("Compare controls")
  ]), toList([
    label(List$Empty$const, toList([
      span(List$Empty$const, toList([text3("Trace paths · baseline first")])),
      textarea(toList([
        aria_label("Trace paths"),
        placeholder(`baseline.beamtrace
candidate.beamtrace
optional-third.beamtrace`),
        value(model.compare_paths_input),
        on_input((var0) => {
          return new UserChangedComparePaths(var0);
        })
      ]), model.compare_paths_input)
    ])),
    button(toList([
      disabled(model.compare_loading),
      on_click(Msg$UserRequestedCompare$const)
    ]), toList([text3("Run comparison")])),
    output(toList([
      class$("capture-status"),
      aria_live("polite")
    ]), toList([
      text3((() => {
        let $ = model.compare_loading;
        if ($) {
          return "Comparing traces";
        } else {
          let $1 = model.compare_report;
          if ($1 instanceof Some) {
            let report = $1[0];
            return "Compared " + to_string(report.run_count) + " runs";
          } else {
            return "Ready";
          }
        }
      })()),
      span(List$Empty$const, toList([
        text3((() => {
          let $ = model.compare_error;
          if ($ instanceof Some) {
            let reason = $[0];
            return reason;
          } else {
            return "PID and clock origins are excluded from alignment";
          }
        })())
      ]))
    ]))
  ]));
}
function capture_controls(model) {
  let $ = model.mode;
  if ($ instanceof Capture) {
    return section(toList([
      class$("capture-controls"),
      aria_label("Capture controls")
    ]), toList([
      label(List$Empty$const, toList([
        span(List$Empty$const, toList([text3("MFA trigger")])),
        input(toList([
          type_("text"),
          aria_label("MFA trigger"),
          placeholder("module:function/arity"),
          attribute2("list", "mfa-candidates"),
          value(model.trigger_input),
          on_input((var0) => {
            return new UserChangedTrigger(var0);
          })
        ])),
        datalist(toList([id("mfa-candidates")]), map2(model.mfa_suggestions, (candidate) => {
          return option(toList([value(candidate)]), candidate);
        }))
      ])),
      label(List$Empty$const, toList([
        span(List$Empty$const, toList([text3("AQL condition")])),
        input(toList([
          type_("text"),
          aria_label("AQL condition"),
          placeholder("arg.0.tag == order"),
          value(model.capture_where),
          on_input((var0) => {
            return new UserChangedCaptureWhere(var0);
          })
        ]))
      ])),
      label(List$Empty$const, toList([
        span(List$Empty$const, toList([text3("Framework preset")])),
        select(toList([
          aria_label("Framework preset"),
          value(model.capture_preset),
          on_input((var0) => {
            return new UserChangedCapturePreset(var0);
          })
        ]), toList([
          preset_option("generic", "Generic"),
          preset_option("gleam-actor", "Gleam actor"),
          preset_option("wisp-mist", "Wisp / Mist"),
          preset_option("gen-server", "GenServer"),
          preset_option("phoenix", "Phoenix"),
          preset_option("erlang-supervisor", "Erlang supervisor")
        ]))
      ])),
      label(List$Empty$const, toList([
        span(List$Empty$const, toList([text3("Max roots")])),
        input(toList([
          type_("number"),
          aria_label("Max roots"),
          attribute2("min", "1"),
          attribute2("max", "1000"),
          value(model.capture_max_roots),
          on_input((var0) => {
            return new UserChangedMaxRoots(var0);
          })
        ]))
      ])),
      button(toList([
        disabled(capture_arm_disabled(model.capture_phase)),
        on_click(Msg$UserRequestedArm$const)
      ]), toList([text3("Arm capture")])),
      button(toList([
        disabled(!capture_busy(model.capture_phase)),
        on_click(Msg$UserRequestedCancel$const)
      ]), toList([text3("Cancel capture")])),
      label(List$Empty$const, toList([
        span(List$Empty$const, toList([text3("Save path")])),
        input(toList([
          type_("text"),
          aria_label("Save path"),
          value(model.save_path),
          on_input((var0) => {
            return new UserChangedSavePath(var0);
          })
        ]))
      ])),
      button(toList([
        disabled(!capture_ready(model.capture_phase)),
        on_click(Msg$UserRequestedSave$const)
      ]), toList([text3("Save capture")])),
      output(toList([
        class$("capture-status"),
        aria_live("polite")
      ]), toList([
        text3(capture_phase_label(model.capture_phase)),
        span(List$Empty$const, toList([text3(model.capture_notice)]))
      ]))
    ]));
  } else if ($ instanceof Compare) {
    return compare_controls(model);
  } else {
    return div(List$Empty$const, List$Empty$const);
  }
}
function mode_button(current, mode, label2, shortcut) {
  return button(toList([
    class$((() => {
      let $ = isEqual(current, mode);
      if ($) {
        return "mode-button active";
      } else {
        return "mode-button";
      }
    })()),
    aria_pressed((() => {
      let $ = isEqual(current, mode);
      if ($) {
        return "true";
      } else {
        return "false";
      }
    })()),
    aria_keyshortcuts(shortcut),
    on_click(new UserSelectedMode(mode))
  ]), toList([
    span(toList([class$("mode-dot")]), List$Empty$const),
    text3(label2)
  ]));
}
function workspace_header(model) {
  return header(toList([class$("topbar")]), toList([
    div(toList([class$("brand")]), toList([
      span(toList([
        class$("brand-mark"),
        aria_hidden(true)
      ]), toList([text3("AG")])),
      div(List$Empty$const, toList([
        h1(List$Empty$const, toList([text3("BeamTrace")])),
        p(List$Empty$const, toList([text3("BEAM causal workbench")]))
      ]))
    ])),
    nav(toList([aria_label("Workspace mode")]), toList([
      mode_button(model.mode, Mode$Capture$const, "Capture", "1"),
      mode_button(model.mode, Mode$Live$const, "Live", "2"),
      mode_button(model.mode, Mode$Compare$const, "Compare", "3"),
      mode_button(model.mode, Mode$Team$const, "Team traces", "4")
    ])),
    div(toList([class$("topbar-actions")]), toList([
      label(toList([class$("search")]), toList([
        span(toList([class$("sr-only")]), toList([text3("Search events")])),
        input(toList([
          type_("search"),
          value(model.query),
          placeholder("Search actor, message, MFA…"),
          aria_label("Search events"),
          aria_keyshortcuts("/"),
          on_input((var0) => {
            return new UserChangedQuery(var0);
          })
        ]))
      ])),
      button(toList([
        class$("quiet-button"),
        aria_keyshortcuts("Control+K"),
        on_click(Msg$UserOpenedPalette$const)
      ]), toList([text3("Commands  ⌘K")]))
    ]))
  ]));
}
function workspace(model) {
  return main(toList([
    class$("workspace"),
    attribute2("data-mode", mode_slug(model.mode))
  ]), toList([
    workspace_header(model),
    capture_controls(model),
    div(toList([class$("workspace-grid")]), toList([
      session_navigator(model),
      causal_workspace(model),
      inspector(model)
    ])),
    minimap(model),
    palette2(model)
  ]));
}

// build/dev/javascript/beamtrace_web/beamtrace_web.mjs
var FILEPATH = "src/beamtrace_web.gleam";
function page_limit(model) {
  let requested = model.viewport_size * 2;
  let $ = requested < 200;
  let $1 = requested > 1000;
  if ($) {
    return 200;
  } else if ($1) {
    return 1000;
  } else {
    return requested;
  }
}
function draw_effect(model) {
  let source = payload(model);
  let zoom = model.zoom;
  return before_paint((_, root2) => {
    return draw(root2, source, zoom);
  });
}
function finish_update(next, extra_effects) {
  let $ = needs_page(next);
  if ($) {
    let loading = begin_loading(next);
    return [
      loading,
      batch(prepend(draw_effect(loading), prepend(load2(loading.viewport_start, page_limit(loading), remote_query(loading)), extra_effects)))
    ];
  } else {
    return [next, batch(prepend(draw_effect(next), extra_effects))];
  }
}
function update3(model, message) {
  if (message instanceof UserSelectedMode) {
    let $ = message[0];
    if ($ instanceof Live) {
      return finish_update(update2(model, message), toList([load()]));
    } else if ($ instanceof Team) {
      let next = update2(model, message);
      let $1 = next.team_traces;
      if ($1 instanceof Empty) {
        return finish_update(next, toList([load_traces("")]));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else {
      return finish_update(update2(model, message), List$Empty$const);
    }
  } else if (message instanceof UserChangedTrigger) {
    let query = message[0];
    return finish_update(update2(model, message), toList([search_mfas(query)]));
  } else if (message instanceof UserRequestedArm) {
    let next = update2(model, message);
    let $ = next.capture_phase;
    if ($ instanceof Arming) {
      return finish_update(next, toList([
        arm(next.trigger_input, next.capture_where, next.capture_preset, next.capture_max_roots)
      ]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof CaptureArmAccepted) {
    return finish_update(update2(model, message), toList([poll_after(150)]));
  } else if (message instanceof PollCaptureStatus) {
    return finish_update(update2(model, message), toList([status()]));
  } else if (message instanceof CaptureStatusLoaded) {
    let phase = message[0];
    let next = update2(model, message);
    if (phase instanceof Arming) {
      return finish_update(next, toList([poll_after(150)]));
    } else if (phase instanceof Armed) {
      return finish_update(next, toList([poll_after(150)]));
    } else if (phase instanceof Cancelling) {
      return finish_update(next, toList([poll_after(150)]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserRequestedCancel) {
    return finish_update(update2(model, message), toList([cancel()]));
  } else if (message instanceof UserRequestedSave) {
    return finish_update(update2(model, message), toList([save(model.save_path)]));
  } else if (message instanceof PollLive) {
    let next = update2(model, message);
    let $ = next.mode;
    if ($ instanceof Live) {
      return finish_update(next, toList([load()]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof LiveLoaded) {
    let next = update2(model, message);
    let $ = next.mode;
    if ($ instanceof Live) {
      return finish_update(next, toList([poll_after2(1000)]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof LiveLoadFailed) {
    let next = update2(model, message);
    let $ = next.mode;
    if ($ instanceof Live) {
      return finish_update(next, toList([poll_after2(2000)]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserRequestedCompare) {
    let next = update2(model, message);
    let $ = next.compare_loading;
    if ($) {
      return finish_update(next, toList([run2(compare_paths(next))]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserRequestedTeamTraces) {
    return finish_update(update2(model, message), toList([load_traces("")]));
  } else if (message instanceof UserRequestedMoreTeamTraces) {
    let next = update2(model, message);
    let $ = model.team_next_cursor;
    if ($ instanceof Some) {
      let cursor = $[0];
      return finish_update(next, toList([load_traces(cursor)]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserSelectedTeamTrace) {
    let trace_id = message[0];
    let next = update2(model, message);
    let $ = selected_team_trace(next);
    if ($ instanceof Some) {
      let trace = $[0];
      if (!trace.locked) {
        return finish_update(next, toList([load_events(trace_id, "")]));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserRequestedMoreTeamEvents) {
    let next = update2(model, message);
    let $ = model.selected_trace_id;
    let $1 = model.team_events_next_cursor;
    if ($ instanceof Some && $1 instanceof Some) {
      let trace_id = $[0];
      let cursor = $1[0];
      return finish_update(next, toList([load_events(trace_id, cursor)]));
    } else {
      return finish_update(next, List$Empty$const);
    }
  } else if (message instanceof UserRequestedTraceHold) {
    let trace_id = message.trace_id;
    let enabled = message.enabled;
    return finish_update(update2(model, message), toList([set_hold(trace_id, enabled)]));
  } else {
    return finish_update(update2(model, message), List$Empty$const);
  }
}
function startup_effect(model) {
  return batch(toList([
    draw_effect(model),
    load2(0, 200, remote_query(model)),
    status(),
    install_cleanup(),
    from2((dispatch2) => {
      return installShortcuts((key) => {
        return dispatch2(new UserPressedKey(key));
      });
    })
  ]));
}
function init2(_) {
  let model = init_remote();
  return [model, startup_effect(model)];
}
function main2() {
  let app = application(init2, update3, workspace);
  let $ = start4(app, "#app", undefined);
  if (!($ instanceof Ok)) {
    throw makeError("let_assert", FILEPATH, "beamtrace_web", 16, "main", "Pattern match failed, no pattern matched the value.", { value: $, start: 468, end: 529, pattern_start: 479, pattern_end: 484 });
  }
  return;
}

// .lustre/build/beamtrace_web.mjs
main2();
