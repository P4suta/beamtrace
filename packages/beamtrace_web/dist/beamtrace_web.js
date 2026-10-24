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
function remainderInt(a, b) {
  if (b === 0) {
    return 0;
  } else {
    return a % b;
  }
}
function divideInt(a, b) {
  return Math.trunc(divideFloat(a, b));
}
function divideFloat(a, b) {
  if (b === 0) {
    return 0;
  } else {
    return a / b;
  }
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
var errorNil = /* @__PURE__ */ Result$Error(undefined);
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

// build/dev/javascript/gleam_stdlib/gleam/int.mjs
function absolute_value(x) {
  let $ = x >= 0;
  if ($) {
    return x;
  } else {
    return x * -1;
  }
}
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
var dynamic = /* @__PURE__ */ new Decoder(decode_dynamic);
var float2 = /* @__PURE__ */ new Decoder(decode_float);
var int2 = /* @__PURE__ */ new Decoder(decode_int);
var string2 = /* @__PURE__ */ new Decoder(decode_string);
var bool = /* @__PURE__ */ new Decoder(decode_bool);
function decode_dynamic(data) {
  return [data, List$Empty$const];
}
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
      prepend(new DecodeError(name, classify_dynamic(data), List$Empty$const), List$Empty$const)
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
  let decoder = one_of(string2, prepend((() => {
    let _pipe = int2;
    return map3(_pipe, to_string);
  })(), prepend((() => {
    let _pipe = float2;
    return map3(_pipe, float_to_string);
  })(), List$Empty$const)));
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
    return new DecodeError(error.expected, error.found, append2(path$1, error.path));
  });
  return [layer[0], errors];
}
function list2(inner) {
  return new Decoder((data) => {
    return list(data, inner.function, (p, k) => {
      return push_path(p, prepend(k, List$Empty$const));
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
          prepend(new DecodeError(kind, classify_dynamic(data), List$Empty$const), List$Empty$const)
        ];
        return push_path(_pipe, reverse(position));
      }
    }
  }
}
function subfield(field_path, field_decoder, next) {
  return new Decoder((data) => {
    let $ = index3(field_path, List$Empty$const, field_decoder.function, data, (data, position) => {
      let $1 = field_decoder.function(data);
      let default$ = $1[0];
      let _pipe = [
        default$,
        prepend(new DecodeError("Field", "Nothing", List$Empty$const), List$Empty$const)
      ];
      return push_path(_pipe, reverse(position));
    });
    let out = $[0];
    let errors1 = $[1];
    let $1 = next(out).function(data);
    let out$1 = $1[0];
    let errors2 = $1[1];
    return [out$1, append2(errors1, errors2)];
  });
}
function success(data) {
  return new Decoder((_) => {
    return [data, List$Empty$const];
  });
}
function decode_error(expected, found) {
  return prepend(new DecodeError(expected, classify_dynamic(found), List$Empty$const), List$Empty$const);
}
function field(field_name, field_decoder, next) {
  return subfield(prepend(field_name, List$Empty$const), field_decoder, next);
}
function optional_field(key, default$, field_decoder, next) {
  return new Decoder((data) => {
    let _block;
    let _block$1;
    let $1 = index2(data, key);
    if ($1 instanceof Ok) {
      let $2 = $1[0];
      if ($2 instanceof Some) {
        let data$1 = $2[0];
        _block$1 = field_decoder.function(data$1);
      } else {
        _block$1 = [default$, List$Empty$const];
      }
    } else {
      let kind = $1[0];
      _block$1 = [
        default$,
        prepend(new DecodeError(kind, classify_dynamic(data), List$Empty$const), List$Empty$const)
      ];
    }
    let _pipe = _block$1;
    _block = push_path(_pipe, prepend(key, List$Empty$const));
    let $ = _block;
    let out = $[0];
    let errors1 = $[1];
    let $2 = next(out).function(data);
    let out$1 = $2[0];
    let errors2 = $2[1];
    return [out$1, append2(errors1, errors2)];
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
function string_length(string) {
  if (string === "") {
    return 0;
  }
  const iterator = graphemes_iterator(string);
  if (iterator) {
    let i = 0;
    for (const _ of iterator) {
      i++;
    }
    return i;
  } else {
    return string.match(/./gsu).length;
  }
}
function graphemes(string) {
  const iterator = graphemes_iterator(string);
  if (iterator) {
    return arrayToList(Array.from(iterator).map((item) => item.segment));
  } else {
    return arrayToList(string.match(/./gsu));
  }
}
var segmenter = undefined;
function graphemes_iterator(string) {
  if (globalThis.Intl && Intl.Segmenter) {
    segmenter ||= new Intl.Segmenter;
    return segmenter.segment(string)[Symbol.iterator]();
  }
}
function lowercase(string) {
  return string.toLowerCase();
}
function split(xs, pattern) {
  return arrayToList(xs.split(pattern));
}
function string_grapheme_slice(string, idx, len) {
  if (len <= 0 || idx >= string.length) {
    return "";
  }
  const iterator = graphemes_iterator(string);
  if (iterator) {
    while (idx-- > 0) {
      iterator.next();
    }
    let result = "";
    while (len-- > 0) {
      const v = iterator.next().value;
      if (v === undefined) {
        break;
      }
      result += v.segment;
    }
    return result;
  } else {
    return string.match(/./gsu).slice(idx, idx + len).join("");
  }
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
function trim_start(string) {
  return string.replace(trim_start_regex, "");
}
function trim_end(string) {
  return string.replace(trim_end_regex, "");
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
function float_to_string(float) {
  const string = float.toString().replace("+", "");
  if (string.indexOf(".") >= 0) {
    return string;
  } else {
    const index = string.indexOf("e");
    if (index >= 0) {
      return string.slice(0, index) + ".0" + string.slice(index);
    } else {
      return string + ".0";
    }
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
function list(data, decode, pushPath, index, emptyList) {
  if (!(isList(data) || Array.isArray(data))) {
    const error = DecodeError$DecodeError("List", classify_dynamic(data), emptyList);
    return [emptyList, arrayToList([error])];
  }
  const decoded = [];
  for (const element of data) {
    const layer = decode(element);
    const [out, errors] = layer;
    if (List$isNonEmpty(errors)) {
      const [_, errors] = pushPath(layer, index.toString());
      return [emptyList, errors];
    }
    decoded.push(out);
    index++;
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
  let list = List$Empty();
  let i = array.length;
  while (i--) {
    list = List$NonEmpty(array[i], list);
  }
  return list;
}
function isList(data) {
  return List$isEmpty(data) || List$isNonEmpty(data);
}
function isResult(data) {
  return Result$isOk(data) || Result$isError(data);
}

// build/dev/javascript/gleam_stdlib/gleam/float.mjs
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
function clamp(x, min_bound, max_bound) {
  let $ = min_bound >= max_bound;
  if ($) {
    let _pipe = x;
    let _pipe$1 = min2(_pipe, min_bound);
    return max2(_pipe$1, max_bound);
  } else {
    let _pipe = x;
    let _pipe$1 = min2(_pipe, max_bound);
    return max2(_pipe$1, min_bound);
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
function append2(first, second) {
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
function find_map(loop$list, loop$fun) {
  while (true) {
    let list = loop$list;
    let fun = loop$fun;
    if (list instanceof Empty) {
      return new Error2(undefined);
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      let $ = fun(first$1);
      if ($ instanceof Ok) {
        return $;
      } else {
        loop$list = rest$1;
        loop$fun = fun;
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
function intersperse_loop(loop$list, loop$separator, loop$acc) {
  while (true) {
    let list = loop$list;
    let separator = loop$separator;
    let acc = loop$acc;
    if (list instanceof Empty) {
      return reverse(acc);
    } else {
      let first$1 = list.head;
      let rest$1 = list.tail;
      loop$list = rest$1;
      loop$separator = separator;
      loop$acc = prepend(first$1, prepend(separator, acc));
    }
  }
}
function intersperse(list, elem) {
  if (list instanceof Empty) {
    return list;
  } else {
    let $ = list.tail;
    if ($ instanceof Empty) {
      return list;
    } else {
      let first$1 = list.head;
      let rest$1 = $;
      return intersperse_loop(rest$1, elem, prepend(first$1, List$Empty$const));
    }
  }
}
function merge_descendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare = loop$compare;
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
      let $ = compare(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare;
        loop$acc = prepend(first2, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare;
        loop$acc = prepend(first1, acc);
      } else {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare;
        loop$acc = prepend(first1, acc);
      }
    }
  }
}
function merge_descending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences = loop$sequences;
    let compare = loop$compare;
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
        let ascending = merge_descendings(descending1, descending2, compare, List$Empty$const);
        loop$sequences = rest$1;
        loop$compare = compare;
        loop$acc = prepend(ascending, acc);
      }
    }
  }
}
function merge_ascendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare = loop$compare;
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
      let $ = compare(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare;
        loop$acc = prepend(first1, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare;
        loop$acc = prepend(first2, acc);
      } else {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare;
        loop$acc = prepend(first2, acc);
      }
    }
  }
}
function merge_ascending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences = loop$sequences;
    let compare = loop$compare;
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
        let descending = merge_ascendings(ascending1, ascending2, compare, List$Empty$const);
        loop$sequences = rest$1;
        loop$compare = compare;
        loop$acc = prepend(descending, acc);
      }
    }
  }
}
function merge_all(loop$sequences, loop$direction, loop$compare) {
  while (true) {
    let sequences = loop$sequences;
    let direction = loop$direction;
    let compare = loop$compare;
    if (sequences instanceof Empty) {
      return sequences;
    } else if (direction instanceof Ascending) {
      if (sequences.tail instanceof Empty) {
        let sequence = sequences.head;
        return sequence;
      } else {
        let sequences$1 = merge_ascending_pairs(sequences, compare, List$Empty$const);
        loop$sequences = sequences$1;
        loop$direction = Sorting$Descending$const;
        loop$compare = compare;
      }
    } else if (sequences.tail instanceof Empty) {
      let sequence = sequences.head;
      return reverse(sequence);
    } else {
      let sequences$1 = merge_descending_pairs(sequences, compare, List$Empty$const);
      loop$sequences = sequences$1;
      loop$direction = Sorting$Ascending$const;
      loop$compare = compare;
    }
  }
}
function sequences(loop$list, loop$compare, loop$growing, loop$direction, loop$prev, loop$acc) {
  while (true) {
    let list = loop$list;
    let compare = loop$compare;
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
      let $ = compare(prev, new$1);
      if (direction instanceof Ascending) {
        if ($ instanceof Lt) {
          loop$list = rest$1;
          loop$compare = compare;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        } else if ($ instanceof Eq) {
          loop$list = rest$1;
          loop$compare = compare;
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
            return prepend(prepend(new$1, List$Empty$const), acc$1);
          } else {
            let next = rest$1.head;
            let rest$2 = rest$1.tail;
            let _block$1;
            let $1 = compare(new$1, next);
            if ($1 instanceof Lt) {
              _block$1 = Sorting$Ascending$const;
            } else if ($1 instanceof Eq) {
              _block$1 = Sorting$Ascending$const;
            } else {
              _block$1 = Sorting$Descending$const;
            }
            let direction$1 = _block$1;
            loop$list = rest$2;
            loop$compare = compare;
            loop$growing = prepend(new$1, List$Empty$const);
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
          return prepend(prepend(new$1, List$Empty$const), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare;
          loop$growing = prepend(new$1, List$Empty$const);
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
          return prepend(prepend(new$1, List$Empty$const), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare;
          loop$growing = prepend(new$1, List$Empty$const);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else {
        loop$list = rest$1;
        loop$compare = compare;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      }
    }
  }
}
function sort(list, compare) {
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
      let $1 = compare(x, y);
      if ($1 instanceof Lt) {
        _block = Sorting$Ascending$const;
      } else if ($1 instanceof Eq) {
        _block = Sorting$Ascending$const;
      } else {
        _block = Sorting$Descending$const;
      }
      let direction = _block;
      let sequences$1 = sequences(rest$1, compare, prepend(x, List$Empty$const), direction, y, List$Empty$const);
      return merge_all(sequences$1, Sorting$Ascending$const, compare);
    }
  }
}
function last(loop$list) {
  while (true) {
    let list = loop$list;
    if (list instanceof Empty) {
      return new Error2(undefined);
    } else {
      let $ = list.tail;
      if ($ instanceof Empty) {
        let last$1 = list.head;
        return new Ok(last$1);
      } else {
        let rest$1 = $;
        loop$list = rest$1;
      }
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
function slice(string, idx, len) {
  let $ = len <= 0;
  if ($) {
    return "";
  } else {
    let $1 = idx < 0;
    if ($1) {
      let translated_idx = string_length(string) + idx;
      let $2 = translated_idx < 0;
      if ($2) {
        return "";
      } else {
        return string_grapheme_slice(string, translated_idx, len);
      }
    } else {
      return string_grapheme_slice(string, idx, len);
    }
  }
}
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
function repeat_loop(loop$times, loop$doubling_acc, loop$acc) {
  while (true) {
    let times = loop$times;
    let doubling_acc = loop$doubling_acc;
    let acc = loop$acc;
    let _block;
    let $ = times % 2;
    if ($ === 0) {
      _block = acc;
    } else {
      _block = acc + doubling_acc;
    }
    let acc$1 = _block;
    let times$1 = globalThis.Math.trunc(times / 2);
    let $1 = times$1 <= 0;
    if ($1) {
      return acc$1;
    } else {
      loop$times = times$1;
      loop$doubling_acc = doubling_acc + doubling_acc;
      loop$acc = acc$1;
    }
  }
}
function repeat(string, times) {
  let $ = times <= 0;
  if ($) {
    return "";
  } else {
    return repeat_loop(times, string, "");
  }
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
function padding(size, pad_string) {
  let pad_string_length = string_length(pad_string);
  let num_pads = divideInt(size, pad_string_length);
  let extra = remainderInt(size, pad_string_length);
  return repeat(pad_string, num_pads) + slice(pad_string, 0, extra);
}
function pad_start(string, desired_length, pad_string) {
  let current_length = string_length(string);
  let to_pad_length = desired_length - current_length;
  let $ = to_pad_length <= 0;
  if ($) {
    return string;
  } else {
    return padding(to_pad_length, pad_string) + string;
  }
}
function trim(string) {
  let _pipe = string;
  let _pipe$1 = trim_start(_pipe);
  return trim_end(_pipe$1);
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
function array(list) {
  const array = [];
  while (List$isNonEmpty(list)) {
    array.push(List$NonEmpty$first(list));
    list = List$NonEmpty$rest(list);
  }
  return array;
}
function decode(string) {
  try {
    const result = JSON.parse(string);
    return Result$Ok(result);
  } catch (err) {
    return Result$Error(getJsonDecodeError(err, string));
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
function getPositionFromMultiline(line, column, string) {
  if (line === 1)
    return column - 1;
  let currentLn = 1;
  let position = 0;
  string.split("").find((char, idx) => {
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
function preprocessed_array(from) {
  return array(from);
}
function array2(entries, inner_type) {
  let _pipe = entries;
  let _pipe$1 = map2(_pipe, inner_type);
  return preprocessed_array(_pipe$1);
}
// build/dev/javascript/houdini/houdini.ffi.mjs
function escape(string) {
  return string.replaceAll(/[><&"']/g, (replaced) => {
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
              if ($4 instanceof Attribute && $4.name === "class") {
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
              if ($4 instanceof Attribute && $4.name === "style") {
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
  } else if (attributes.tail instanceof Empty) {
    return attributes;
  } else {
    let _pipe = attributes;
    let _pipe$1 = sort(_pipe, (a, b) => {
      return compare2(b, a);
    });
    return merge(_pipe$1, empty_list);
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
function autofocus(should_autofocus) {
  return boolean_attribute("autofocus", should_autofocus);
}
function id(value) {
  return attribute2("id", value);
}
function title(text) {
  return attribute2("title", text);
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
function aria(name, value) {
  return attribute2("aria-" + name, value);
}
function role(name) {
  return attribute2("role", name);
}
function aria_hidden(value) {
  return aria("hidden", (() => {
    if (value) {
      return "true";
    } else {
      return "false";
    }
  })());
}
function aria_keyshortcuts(value) {
  return aria("keyshortcuts", value);
}
function aria_label(value) {
  return aria("label", value);
}
function aria_live(value) {
  return aria("live", value);
}
function aria_modal(value) {
  return aria("modal", (() => {
    if (value) {
      return "true";
    } else {
      return "false";
    }
  })());
}
function aria_pressed(value) {
  return aria("pressed", value);
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
var empty = /* @__PURE__ */ new Effect(empty_list, empty_list, empty_list);
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

// build/dev/javascript/lustre/lustre/internals/mutable_map.ffi.mjs
function empty2() {
  return null;
}
function get2(map, key) {
  return map?.get(key);
}
function get_or_compute(map, key, compute) {
  return map?.get(key) ?? compute();
}
function has_key(map, key) {
  return map && map.has(key);
}
function insert2(map, key, value) {
  map ??= new Map;
  map.set(key, value);
  return map;
}
function remove(map, key) {
  map?.delete(key);
  return map;
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
function map4(element, mapper) {
  if (element instanceof Map2) {
    let child_mapper = element.mapper;
    return new Map2(map_kind, element.key, (handler) => {
      return identity2(mapper)(child_mapper(handler));
    }, identity2(element.child));
  } else {
    return new Map2(map_kind, element.key, identity2(mapper), identity2(element));
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
function none() {
  return text("", "");
}
function memo2(dependencies, view) {
  return memo("", dependencies, view);
}
function ref(value) {
  return identity2(value);
}
function map5(element, f) {
  return map4(element, f);
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
function option(attrs, label) {
  return element2("option", attrs, prepend(text2(label), List$Empty$const));
}
function output(attrs, children) {
  return element2("output", attrs, children);
}
function select(attrs, children) {
  return element2("select", attrs, children);
}
function textarea(attrs, content) {
  return element2("textarea", prepend(property2("value", string3(content)), attrs), prepend(text2(content), List$Empty$const));
}
function details(attrs, children) {
  return element2("details", attrs, children);
}
function dialog(attrs, children) {
  return element2("dialog", attrs, children);
}
function summary(attrs, children) {
  return element2("summary", attrs, children);
}

// build/dev/javascript/lustre/lustre/vdom/patch.mjs
class Patch extends CustomType {
  constructor(index, path, removed, changes, children) {
    super();
    this.index = index;
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
  constructor(kind, index, with$) {
    super();
    this.kind = kind;
    this.index = index;
    this.with = with$;
  }
}
class Remove extends CustomType {
  constructor(kind, index) {
    super();
    this.kind = kind;
    this.index = index;
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
function new$3(index, removed, changes, children) {
  return new Patch(index, empty_list, removed, changes, children);
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
function remove2(index) {
  return new Remove(remove_kind, index);
}
function replace2(index, with$) {
  return new Replace(replace_kind, index, with$);
}
function insert3(children, before) {
  return new Insert(insert_kind, children, before);
}
function add_parent(child, index) {
  return new Patch(index, prepend(child.index, child.path), child.removed, child.changes, child.children);
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
  constructor(index, parent) {
    super();
    this.index = index;
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
      let index = path.index;
      let parent = path.parent;
      let acc$1 = prepend(separator_element, prepend(to_string(index), acc));
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
function add2(parent, index, key) {
  if (key === "") {
    return new Index(index, parent);
  } else {
    return new Key(key, parent);
  }
}
function subtree(path) {
  return new Subtree(path);
}
function event2(path, event) {
  return do_to_string(false, path, prepend(separator_event, prepend(event, empty_list)));
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
  return fold2(attributes, handlers, (events, attribute) => {
    if (attribute instanceof Event2) {
      let name = attribute.name;
      let handler = attribute.handler;
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
function add_child(cache, events, parent, index, child) {
  let children = singleton_list(child);
  return add_children(cache, events, parent, index, children);
}
function tick(cache) {
  return new Cache(cache.events, empty2(), cache.vdoms, cache.next_dispatched_paths, empty_list);
}
function events(cache) {
  return cache.events;
}
function update_events(cache, events) {
  return new Cache(events, cache.vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function memos(cache) {
  return cache.vdoms;
}
function get_old_memo(cache, old, new$) {
  return get_or_compute(cache.old_vdoms, old, new$);
}
function keep_memo(cache, old, new$) {
  let node = get_or_compute(cache.old_vdoms, old, new$);
  let vdoms = insert2(cache.vdoms, new$, node);
  return new Cache(cache.events, vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function add_memo(cache, new$, node) {
  let vdoms = insert2(cache.vdoms, new$, node);
  return new Cache(cache.events, vdoms, cache.old_vdoms, cache.dispatched_paths, cache.next_dispatched_paths);
}
function get_subtree(events, path, old_mapper) {
  let child = get_or_compute(events.children, path, () => {
    return new Child(old_mapper, new_events());
  });
  return child.events;
}
function update_subtree(parent, path, mapper, events) {
  let new_child = new Child(mapper, events);
  let children = insert2(parent.children, path, new_child);
  return new Events(parent.handlers, children);
}
function add_event(events, path, name, handler) {
  let handlers = do_add_event(events.handlers, path, name, handler);
  return new Events(handlers, events.children);
}
function do_remove_event(handlers, path, name) {
  return remove(handlers, event2(path, name));
}
function remove_event(events, path, name) {
  let handlers = do_remove_event(events.handlers, path, name);
  return new Events(handlers, events.children);
}
function remove_attributes(handlers, path, attributes) {
  return fold2(attributes, handlers, (events, attribute) => {
    if (attribute instanceof Event2) {
      let name = attribute.name;
      return do_remove_event(events, path, name);
    } else {
      return events;
    }
  });
}
function do_remove_children(loop$handlers, loop$children, loop$vdoms, loop$parent, loop$index, loop$nodes) {
  while (true) {
    let handlers = loop$handlers;
    let children = loop$children;
    let vdoms = loop$vdoms;
    let parent = loop$parent;
    let index = loop$index;
    let nodes = loop$nodes;
    let next = index + 1;
    if (nodes instanceof Empty) {
      return new Events(handlers, children);
    } else {
      let $ = nodes.head;
      if ($ instanceof Fragment) {
        let rest = nodes.tail;
        let key = $.key;
        let nodes$1 = $.children;
        let path = add2(parent, index, key);
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
        let path = add2(parent, index, key);
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
        let path = add2(parent, index, key);
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
        let path = add2(parent, index, key);
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
          let child = get2(vdoms, view);
          let nodes$1 = prepend(child, rest);
          loop$handlers = handlers;
          loop$children = children;
          loop$vdoms = vdoms;
          loop$parent = parent;
          loop$index = index;
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
function remove_child(cache, events, parent, child_index, child) {
  return do_remove_children(events.handlers, events.children, cache.old_vdoms, parent, child_index, singleton_list(child));
}
function replace_child(cache, events, parent, child_index, prev, next) {
  let events$1 = remove_child(cache, events, parent, child_index, prev);
  return add_child(cache, events$1, parent, child_index, next);
}
function get_handler(loop$events, loop$path, loop$mapper) {
  while (true) {
    let events = loop$events;
    let path = loop$path;
    let mapper = loop$mapper;
    if (path instanceof Empty) {
      return error_nil;
    } else {
      let $ = path.tail;
      if ($ instanceof Empty) {
        let key = path.head;
        let $1 = has_key(events.handlers, key);
        if ($1) {
          let handler = get2(events.handlers, key);
          return new Ok(map3(handler, (handler) => {
            return new Handler(handler.prevent_default, handler.stop_propagation, identity2(mapper)(handler.message));
          }));
        } else {
          return error_nil;
        }
      } else {
        let key = path.head;
        let path$1 = $;
        let $1 = has_key(events.children, key);
        if ($1) {
          let child = get2(events.children, key);
          let mapper$1 = compose_mapper(mapper, child.mapper);
          loop$events = child.events;
          loop$path = path$1;
          loop$mapper = mapper$1;
        } else {
          return error_nil;
        }
      }
    }
  }
}
function decode2(cache, path, name, event) {
  let parts = split_subtree_path(path + separator_event + name);
  let $ = get_handler(cache.events, parts, identity2);
  if ($ instanceof Ok) {
    let handler = $[0];
    let $1 = run(event, handler);
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
function dispatch(cache, event) {
  let next_dispatched_paths = prepend(event.path, cache.next_dispatched_paths);
  let cache$1 = new Cache(cache.events, cache.vdoms, cache.old_vdoms, cache.dispatched_paths, next_dispatched_paths);
  if (event instanceof DecodedEvent) {
    let handler = event.handler;
    return [cache$1, new Ok(handler)];
  } else {
    return [cache$1, error_nil];
  }
}
function has_dispatched_events(cache, path) {
  return matches(path, cache.dispatched_paths);
}

// build/dev/javascript/lustre/lustre/runtime/server/runtime.mjs
class EffectDispatchedMessage extends CustomType {
  constructor(message) {
    super();
    this.message = message;
  }
}
var Message$isEffectDispatchedMessage = (value) => value instanceof EffectDispatchedMessage;
class EffectEmitEvent extends CustomType {
  constructor(name, data) {
    super();
    this.name = name;
    this.data = data;
  }
}
var Message$isEffectEmitEvent = (value) => value instanceof EffectEmitEvent;
class SystemRequestedShutdown extends CustomType {
}
var Message$SystemRequestedShutdown$const = new SystemRequestedShutdown;
var Message$isSystemRequestedShutdown = (value) => value instanceof SystemRequestedShutdown;

// build/dev/javascript/lustre/lustre/runtime/app.mjs
class App extends CustomType {
  constructor(name, init, update, view, config) {
    super();
    this.name = name;
    this.init = init;
    this.update = update;
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
  let index = a.length;
  if (index !== b.length) {
    return false;
  }
  while (index--) {
    if (!isEqual2(a[index], b[index])) {
      return false;
    }
  }
  return true;
};
var areObjectsEqual = (a, b) => {
  const properties = Object.keys(a);
  let index = properties.length;
  if (Object.keys(b).length !== index) {
    return false;
  }
  while (index--) {
    const property = properties[index];
    if (!Object.hasOwn(b, property)) {
      return false;
    }
    if (!isEqual2(a[property], b[property])) {
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
  constructor(patch, cache, events) {
    super();
    this.patch = patch;
    this.cache = cache;
    this.events = events;
  }
}

class AttributeChange extends CustomType {
  constructor(added, removed, events) {
    super();
    this.added = added;
    this.removed = removed;
    this.events = events;
  }
}
function diff_attributes(loop$controlled, loop$path, loop$events, loop$old, loop$new, loop$added, loop$removed) {
  while (true) {
    let controlled = loop$controlled;
    let path = loop$path;
    let events = loop$events;
    let old = loop$old;
    let new$ = loop$new;
    let added = loop$added;
    let removed = loop$removed;
    if (old instanceof Empty) {
      if (new$ instanceof Empty) {
        return new AttributeChange(added, removed, events);
      } else {
        let $ = new$.head;
        if ($ instanceof Event2) {
          let next = $;
          let new$1 = new$.tail;
          let name = $.name;
          let handler = $.handler;
          let events$1 = add_event(events, path, name, handler);
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
          let new$1 = new$.tail;
          let added$1 = prepend(next, added);
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events;
          loop$old = old;
          loop$new = new$1;
          loop$added = added$1;
          loop$removed = removed;
        }
      }
    } else if (new$ instanceof Empty) {
      let $ = old.head;
      if ($ instanceof Event2) {
        let prev = $;
        let old$1 = old.tail;
        let name = $.name;
        let events$1 = remove_event(events, path, name);
        let removed$1 = prepend(prev, removed);
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events$1;
        loop$old = old$1;
        loop$new = new$;
        loop$added = added;
        loop$removed = removed$1;
      } else {
        let prev = $;
        let old$1 = old.tail;
        let removed$1 = prepend(prev, removed);
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events;
        loop$old = old$1;
        loop$new = new$;
        loop$added = added;
        loop$removed = removed$1;
      }
    } else {
      let prev = old.head;
      let remaining_old = old.tail;
      let next = new$.head;
      let remaining_new = new$.tail;
      let $ = compare2(prev, next);
      if ($ instanceof Lt) {
        if (prev instanceof Event2) {
          let name = prev.name;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = remove_event(events, path, name);
          loop$old = remaining_old;
          loop$new = new$;
          loop$added = added;
          loop$removed = prepend(prev, removed);
        } else {
          loop$controlled = controlled;
          loop$path = path;
          loop$events = events;
          loop$old = remaining_old;
          loop$new = new$;
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
            loop$events = events;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = added$1;
            loop$removed = removed;
          } else if (next instanceof Event2) {
            let name = next.name;
            let handler = next.handler;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = add_event(events, path, name, handler);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          } else {
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events;
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
            loop$events = events;
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = added$1;
            loop$removed = removed;
          } else if (next instanceof Event2) {
            let name = next.name;
            let handler = next.handler;
            loop$controlled = controlled;
            loop$path = path;
            loop$events = add_event(events, path, name, handler);
            loop$old = remaining_old;
            loop$new = remaining_new;
            loop$added = prepend(next, added);
            loop$removed = prepend(prev, removed);
          } else {
            loop$controlled = controlled;
            loop$path = path;
            loop$events = events;
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
          loop$events = add_event(events, path, name, handler);
          loop$old = remaining_old;
          loop$new = remaining_new;
          loop$added = added$1;
          loop$removed = removed;
        } else {
          let name = prev.name;
          loop$controlled = controlled;
          loop$path = path;
          loop$events = remove_event(events, path, name);
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
        loop$events = add_event(events, path, name, handler);
        loop$old = old;
        loop$new = remaining_new;
        loop$added = prepend(next, added);
        loop$removed = removed;
      } else {
        loop$controlled = controlled;
        loop$path = path;
        loop$events = events;
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
    let new$ = loop$new;
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
    let events = loop$events;
    if (old instanceof Empty) {
      if (new$ instanceof Empty) {
        let _block;
        let $ = is_browser();
        if (changes instanceof Empty) {
          if (children instanceof Empty) {
            _block = new$3(patch_index, removed, changes, children);
          } else if (!$ && children.tail instanceof Empty && removed === 0) {
            let child = children.head;
            _block = add_parent(child, patch_index);
          } else {
            _block = new$3(patch_index, removed, changes, children);
          }
        } else {
          _block = new$3(patch_index, removed, changes, children);
        }
        let patch = _block;
        return new PartialDiff(patch, cache, events);
      } else {
        let $ = add_children(cache, events, path, node_index, new$);
        let cache$1 = $[0];
        let events$1 = $[1];
        let insert = insert3(new$, node_index - moved_offset);
        let changes$1 = prepend(insert, changes);
        let patch = new$3(patch_index, removed, changes$1, children);
        return new PartialDiff(patch, cache$1, events$1);
      }
    } else if (new$ instanceof Empty) {
      let prev = old.head;
      let old$1 = old.tail;
      let $ = prev.key === "" || !has_key(moved, prev.key);
      if ($) {
        let events$1 = remove_child(cache, events, path, node_index, prev);
        loop$old = old$1;
        loop$old_keyed = old_keyed;
        loop$new = new$;
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
        loop$new = new$;
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
        loop$events = events;
      }
    } else {
      let prev = old.head;
      let next = new$.head;
      if (prev.key !== next.key) {
        let old_remaining = old.tail;
        let new_remaining = new$.tail;
        let next_did_exist = has_key(old_keyed, next.key);
        let prev_does_exist = has_key(new_keyed, prev.key);
        if (prev_does_exist) {
          if (next_did_exist) {
            let $ = has_key(moved, prev.key);
            if ($) {
              loop$old = old_remaining;
              loop$old_keyed = old_keyed;
              loop$new = new$;
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
              loop$events = events;
            } else {
              let match = get2(old_keyed, next.key);
              let before = node_index - moved_offset;
              let changes$1 = prepend(move(next.key, before), changes);
              let moved$1 = insert2(moved, next.key, undefined);
              loop$old = prepend(match, old);
              loop$old_keyed = old_keyed;
              loop$new = new$;
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
              loop$events = events;
            }
          } else {
            let before = node_index - moved_offset;
            let $ = add_child(cache, events, path, node_index, next);
            let cache$1 = $[0];
            let events$1 = $[1];
            let insert = insert3(singleton_list(next), before);
            let changes$1 = prepend(insert, changes);
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
          let index = node_index - moved_offset;
          let changes$1 = prepend(remove2(index), changes);
          let events$1 = remove_child(cache, events, path, node_index, prev);
          loop$old = old_remaining;
          loop$old_keyed = old_keyed;
          loop$new = new$;
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
          let $ = replace_child(cache, events, path, node_index, prev, next);
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
          let $1 = new$.head;
          if ($1 instanceof Fragment) {
            let prev$1 = $;
            let old$1 = old.tail;
            let next$1 = $1;
            let new$1 = new$.tail;
            let $2 = do_diff(prev$1.children, prev$1.keyed_children, next$1.children, next$1.keyed_children, empty2(), 0, 0, 0, node_index, empty_list, empty_list, add2(path, node_index, next$1.key), cache, events);
            let patch = $2.patch;
            let cache$1 = $2.cache;
            let events$1 = $2.events;
            let _block;
            if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
              _block = children;
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
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
          let $1 = new$.head;
          if ($1 instanceof Element) {
            let prev$1 = $;
            let next$1 = $1;
            if (prev$1.namespace === next$1.namespace && prev$1.tag === next$1.tag) {
              let old$1 = old.tail;
              let new$1 = new$.tail;
              let child_path = add2(path, node_index, next$1.key);
              let controlled = is_controlled(cache, next$1.namespace, next$1.tag, child_path);
              let $2 = diff_attributes(controlled, child_path, events, prev$1.attributes, next$1.attributes, empty_list, empty_list);
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
              let $3 = do_diff(prev$1.children, prev$1.keyed_children, next$1.children, next$1.keyed_children, empty2(), 0, 0, 0, node_index, initial_child_changes, empty_list, child_path, cache, events$1);
              let patch = $3.patch;
              let cache$1 = $3.cache;
              let events$2 = $3.events;
              let _block$1;
              if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
                _block$1 = children;
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
              let prev$2 = $;
              let old_remaining$1 = old.tail;
              let next$2 = $1;
              let new_remaining$1 = new$.tail;
              let change = replace2(node_index - moved_offset, next$2);
              let $4 = replace_child(cache, events, path, node_index, prev$2, next$2);
              let cache$2 = $4[0];
              let events$3 = $4[1];
              loop$old = old_remaining$1;
              loop$old_keyed = old_keyed;
              loop$new = new_remaining$1;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = prepend(change, changes);
              loop$children = children;
              loop$path = path;
              loop$cache = cache$2;
              loop$events = events$3;
            }
          } else {
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
          let $1 = new$.head;
          if ($1 instanceof Text) {
            let prev$1 = $;
            let next$1 = $1;
            if (prev$1.content === next$1.content) {
              let old$1 = old.tail;
              let new$1 = new$.tail;
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
              loop$events = events;
            } else {
              let old$2 = old.tail;
              let next$2 = $1;
              let new$2 = new$.tail;
              let child = new$3(node_index, 0, singleton_list(replace_text(next$2.content)), empty_list);
              loop$old = old$2;
              loop$old_keyed = old_keyed;
              loop$new = new$2;
              loop$new_keyed = new_keyed;
              loop$moved = moved;
              loop$moved_offset = moved_offset;
              loop$removed = removed;
              loop$node_index = node_index + 1;
              loop$patch_index = patch_index;
              loop$changes = changes;
              loop$children = prepend(child, children);
              loop$path = path;
              loop$cache = cache;
              loop$events = events;
            }
          } else {
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
          let $1 = new$.head;
          if ($1 instanceof UnsafeInnerHtml) {
            let prev$1 = $;
            let old$1 = old.tail;
            let next$1 = $1;
            let new$1 = new$.tail;
            let child_path = add2(path, node_index, next$1.key);
            let $2 = diff_attributes(false, child_path, events, prev$1.attributes, next$1.attributes, empty_list, empty_list);
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
            let $3 = prev$1.inner_html === next$1.inner_html;
            if ($3) {
              _block$1 = child_changes;
            } else {
              _block$1 = prepend(replace_inner_html(next$1.inner_html), child_changes);
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
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
          let $1 = new$.head;
          if ($1 instanceof Map2) {
            let prev$1 = $;
            let old$1 = old.tail;
            let next$1 = $1;
            let new$1 = new$.tail;
            let child_path = add2(path, node_index, next$1.key);
            let child_key = child(child_path);
            let $2 = do_diff(singleton_list(prev$1.child), empty2(), singleton_list(next$1.child), empty2(), empty2(), 0, 0, 0, node_index, empty_list, empty_list, subtree(child_path), cache, get_subtree(events, child_key, prev$1.mapper));
            let patch = $2.patch;
            let cache$1 = $2.cache;
            let child_events = $2.events;
            let events$1 = update_subtree(events, child_key, next$1.mapper, child_events);
            let _block;
            if (patch.changes instanceof Empty && patch.children instanceof Empty && patch.removed === 0) {
              _block = children;
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
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
          let $1 = new$.head;
          if ($1 instanceof Memo) {
            let prev$1 = $;
            let old$1 = old.tail;
            let next$1 = $1;
            let new$1 = new$.tail;
            let $2 = equal_lists(prev$1.dependencies, next$1.dependencies);
            if ($2) {
              let cache$1 = keep_memo(cache, prev$1.view, next$1.view);
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
              loop$events = events;
            } else {
              let prev_node = get_old_memo(cache, prev$1.view, prev$1.view);
              let next_node = next$1.view();
              let cache$1 = add_memo(cache, next$1.view, next_node);
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
              loop$events = events;
            }
          } else {
            let prev$1 = $;
            let old_remaining$1 = old.tail;
            let next$1 = $1;
            let new_remaining$1 = new$.tail;
            let change = replace2(node_index - moved_offset, next$1);
            let $2 = replace_child(cache, events, path, node_index, prev$1, next$1);
            let cache$1 = $2[0];
            let events$1 = $2[1];
            loop$old = old_remaining$1;
            loop$old_keyed = old_keyed;
            loop$new = new_remaining$1;
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
function diff(cache, old, new$) {
  let cache$1 = tick(cache);
  let $ = do_diff(singleton_list(old), empty2(), singleton_list(new$), empty2(), empty2(), 0, 0, 0, 0, empty_list, empty_list, root, cache$1, events(cache$1));
  let patch = $.patch;
  let cache$2 = $.cache;
  let events2 = $.events;
  return new Diff(patch, update_events(cache$2, events2));
}

// build/dev/javascript/lustre/lustre/internals/list.ffi.mjs
var iterate = (list, callback) => {
  if (Array.isArray(list)) {
    for (let i = 0;i < list.length; i++) {
      callback(list[i]);
    }
  } else if (list) {
    for (list;List$NonEmpty$rest(list); list = List$NonEmpty$rest(list)) {
      callback(List$NonEmpty$first(list));
    }
  }
};
var append4 = (a, b) => {
  if (!List$NonEmpty$rest(a)) {
    return b;
  } else if (!List$NonEmpty$rest(b)) {
    return a;
  } else {
    return append2(a, b);
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
var removeChild = (parent, child) => parent.removeChild(child);
var getAttribute = (node, name) => node.getAttribute(name);
var setAttribute = (node, name, value) => node.setAttribute(name, value);
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
var insertMetadataChild = (kind, parent, node, index, key) => {
  const child = new MetadataNode(kind, parent, node, key);
  node[meta] = child;
  parent?.children.splice(index, 0, child);
  return child;
};
var getPath = (node) => {
  let path = "";
  for (let current = node[meta];current.parent; current = current.parent) {
    const separator = current.parent && current.parent.kind === map_kind ? separator_subtree : separator_element;
    if (current.key) {
      path = `${separator}${current.key}${path}`;
    } else {
      const index = current.parent.children.indexOf(current);
      path = `${separator}${index}${path}`;
    }
  }
  return path.slice(1);
};

class Reconciler {
  #root = null;
  #decodeEvent;
  #dispatch;
  #debug = false;
  constructor(root, decodeEvent, dispatch, { debug = false } = {}) {
    this.#root = root;
    this.#decodeEvent = decodeEvent;
    this.#dispatch = dispatch;
    this.#debug = debug;
  }
  mount(vdom) {
    insertMetadataChild(element_kind, null, this.#root, 0, null);
    this.#insertChild(this.#root, null, this.#root[meta], 0, vdom);
  }
  push(patch, memos = null) {
    this.#memos = memos;
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
      iterate(path, (index) => {
        node = node.children[index];
      });
      const { children: childNodes } = node;
      iterate(changes, (change) => this.#patch(node, change));
      if (removed) {
        this.#removeChildren(node, childNodes.length - removed, removed);
      }
      iterate(childPatches, (childPatch) => {
        const child = childNodes[childPatch.index | 0];
        this.#stack.push({ node: child, patch: childPatch });
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
    const fragment = createDocumentFragment();
    const beforeEl = this.#getReference(parent, before);
    this.#insertChildren(fragment, null, parent, before | 0, children);
    insertBefore(parent.parentNode, fragment, beforeEl);
  }
  #replace(parent, { index, with: child }) {
    this.#removeChildren(parent, index | 0, 1);
    const beforeEl = this.#getReference(parent, index);
    this.#insertChild(parent.parentNode, beforeEl, parent, index | 0, child);
  }
  #getReference(node, index) {
    index = index | 0;
    const { children } = node;
    const childCount = children.length;
    if (index < childCount)
      return children[index].node;
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
  #moveChild(domParent, child, beforeEl) {
    moveBefore(domParent, child.node, beforeEl);
    if (child.isVirtual) {
      this.#moveChildren(domParent, child.children, beforeEl);
    }
    if (child.endNode) {
      moveBefore(domParent, child.endNode, beforeEl);
    }
  }
  #remove(parent, { index }) {
    this.#removeChildren(parent, index, 1);
  }
  #removeChildren(parent, index, count) {
    const { children, parentNode } = parent;
    const deleted = children.splice(index, count);
    for (let i = 0;i < deleted.length; ++i) {
      const child = deleted[i];
      const { node, endNode, isVirtual, children: nestedChildren } = child;
      removeChild(parentNode, node);
      if (endNode) {
        removeChild(parentNode, endNode);
      }
      this.#removeDebouncers(child);
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
    iterate(children, (child) => this.#removeDebouncers(child));
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
    iterate(added, (attribute) => this.#createAttribute(node, attribute));
  }
  #replaceText({ node }, { content }) {
    setData(node, content ?? "");
  }
  #replaceInnerHtml({ node }, { inner_html }) {
    setInnerHtml(node, inner_html ?? "");
  }
  #insertChildren(domParent, beforeEl, metaParent, index, children) {
    iterate(children, (child) => this.#insertChild(domParent, beforeEl, metaParent, index++, child));
  }
  #insertChild(domParent, beforeEl, metaParent, index, vnode) {
    switch (vnode.kind) {
      case element_kind: {
        const node = this.#createElement(metaParent, index, vnode);
        this.#insertChildren(node, null, node[meta], 0, vnode.children);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case text_kind: {
        const node = this.#createTextNode(metaParent, index, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case fragment_kind: {
        const marker = "lustre:fragment";
        const head = this.#createHead(marker, metaParent, index, vnode);
        insertBefore(domParent, head, beforeEl);
        this.#insertChildren(domParent, beforeEl, head[meta], 0, vnode.children);
        if (this.#debug) {
          head[meta].endNode = createComment(` /${marker} `);
          insertBefore(domParent, head[meta].endNode, beforeEl);
        }
        break;
      }
      case unsafe_inner_html_kind: {
        const node = this.#createElement(metaParent, index, vnode);
        this.#replaceInnerHtml({ node }, vnode);
        insertBefore(domParent, node, beforeEl);
        break;
      }
      case map_kind: {
        const head = this.#createHead("lustre:map", metaParent, index, vnode);
        insertBefore(domParent, head, beforeEl);
        this.#insertChild(domParent, beforeEl, head[meta], 0, vnode.child);
        break;
      }
      case memo_kind: {
        const child = this.#memos?.get(vnode.view) ?? vnode.view();
        this.#insertChild(domParent, beforeEl, metaParent, index, child);
        break;
      }
    }
  }
  #createElement(parent, index, { kind, key, tag, namespace, attributes }) {
    const node = createElementNS(namespace || NAMESPACE_HTML, tag);
    insertMetadataChild(kind, parent, node, index, key);
    if (this.#debug && key) {
      setAttribute(node, "data-lustre-key", key);
    }
    iterate(attributes, (attribute) => this.#createAttribute(node, attribute));
    return node;
  }
  #createTextNode(parent, index, { kind, key, content }) {
    const node = createTextNode(content ?? "");
    insertMetadataChild(kind, parent, node, index, key);
    return node;
  }
  #createHead(marker, parent, index, { kind, key }) {
    const node = this.#debug ? createComment(markerComment(marker, key)) : createTextNode("");
    insertMetadataChild(kind, parent, node, index, key);
    return node;
  }
  #createAttribute(node, attribute) {
    const { debouncers, handlers, throttles } = node[meta];
    const {
      kind,
      name,
      value,
      prevent_default: prevent,
      debounce: debounceDelay,
      throttle: throttleDelay
    } = attribute;
    switch (kind) {
      case attribute_kind: {
        const valueOrDefault = value ?? "";
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
        node[name] = value;
        break;
      case event_kind: {
        if (handlers.has(name)) {
          removeEventListener(node, name, handleEvent);
        }
        const passive = prevent.kind === never_kind;
        addEventListener(node, name, handleEvent, { passive });
        this.#updateDebounceThrottle(throttles, name, throttleDelay);
        this.#updateDebounceThrottle(debouncers, name, debounceDelay);
        handlers.set(name, (event) => this.#handleEvent(attribute, event));
        break;
      }
    }
  }
  #updateDebounceThrottle(map, name, delay) {
    const debounceOrThrottle = map.get(name);
    if (delay > 0) {
      if (debounceOrThrottle) {
        debounceOrThrottle.delay = delay;
      } else {
        map.set(name, { delay });
      }
    } else if (debounceOrThrottle) {
      const { timeout } = debounceOrThrottle;
      if (timeout) {
        clearTimeout(timeout);
      }
      map.delete(name);
    }
  }
  #handleEvent(attribute, event) {
    const { currentTarget, type } = event;
    const { debouncers, throttles } = currentTarget[meta];
    const path = getPath(currentTarget);
    const {
      prevent_default: prevent,
      stop_propagation: stop,
      include
    } = attribute;
    if (prevent.kind === always_kind)
      event.preventDefault();
    if (stop.kind === always_kind)
      event.stopPropagation();
    if (type === "submit") {
      event.detail ??= {};
      event.detail.formData = [
        ...new FormData(event.target, event.submitter).entries()
      ];
    }
    const data = this.#decodeEvent(event, path, type, include);
    const throttle = throttles.get(type);
    if (throttle) {
      const now = Date.now();
      const last = throttle.last || 0;
      if (now > last + throttle.delay) {
        throttle.last = now;
        throttle.lastEvent = event;
        this.#dispatch(event, data);
      }
    }
    const debounce = debouncers.get(type);
    if (debounce) {
      clearTimeout(debounce.timeout);
      debounce.timeout = setTimeout(() => {
        if (event === throttles.get(type)?.lastEvent)
          return;
        this.#dispatch(event, data);
      }, debounce.delay);
    }
    if (!throttle && !debounce) {
      this.#dispatch(event, data);
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
var handleEvent = (event) => {
  const { currentTarget, type } = event;
  const handler = currentTarget[meta].handlers.get(type);
  handler(event);
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
    added(node, value) {
      node[name] = value;
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
var virtualise = (root) => {
  const rootMeta = insertMetadataChild(element_kind, null, root, 0, null);
  const { children } = virtualiseChildren(rootMeta, root, root.firstChild);
  if (children.length > 1) {
    const rootNodeMeta = insertMetadataChild(element_kind, null, root, 0, null);
    rootMeta.kind = fragment_kind;
    rootMeta.node = globalThis.document.createTextNode("");
    rootMeta.parent = rootNodeMeta;
    rootNodeMeta.children.push(rootMeta);
    root.insertBefore(rootMeta.node, root.firstChild);
    return fragment2(toList2(children));
  }
  if (children.length === 1) {
    return children[0][1];
  }
  const placeholder = globalThis.document.createTextNode("");
  insertMetadataChild(text_kind, rootMeta, placeholder, 0, null);
  root.insertBefore(placeholder, root.firstChild);
  return none();
};
var virtualiseChild = (meta, domParent, child, index) => {
  if (child.nodeType === COMMENT_NODE) {
    const data = child.data.trim();
    if (data.startsWith("lustre:fragment")) {
      return virtualiseFragment(meta, domParent, child, index);
    }
    if (data.startsWith("lustre:map")) {
      return virtualiseMap(meta, domParent, child, index);
    }
    if (data.startsWith("lustre:memo")) {
      return virtualiseMemo(meta, domParent, child, index);
    }
    return null;
  }
  if (child.nodeType === ELEMENT_NODE) {
    return virtualiseElement(meta, child, index);
  }
  if (child.nodeType === TEXT_NODE) {
    return virtualiseText(meta, child, index);
  }
  return null;
};
var virtualiseElement = (metaParent, node, index) => {
  const key = node.getAttribute("data-lustre-key") ?? "";
  if (key) {
    node.removeAttribute("data-lustre-key");
  }
  const meta = insertMetadataChild(element_kind, metaParent, node, index, key);
  const tag = node.localName;
  const namespace = node.namespaceURI;
  const isHtmlElement = !namespace || namespace === NAMESPACE_HTML;
  if (isHtmlElement && INPUT_ELEMENTS.includes(tag)) {
    virtualiseInputEvents(tag, node);
  }
  const attributes = virtualiseAttributes(node);
  const { children } = virtualiseChildren(meta, node, node.firstChild);
  const vnode = isHtmlElement ? element3(tag, attributes, toList2(children)) : namespaced2(namespace, tag, attributes, toList2(children));
  return childResult(key, vnode, node.nextSibling);
};
var virtualiseChildren = (meta, domParent, childNode) => {
  const children = [];
  while (childNode && (childNode.nodeType !== COMMENT_NODE || childNode.data.trim() !== "/lustre:fragment")) {
    const child = virtualiseChild(meta, domParent, childNode, children.length);
    if (child) {
      children.push([child.key, child.vnode]);
      childNode = child.next;
    } else {
      childNode = childNode.nextSibling;
    }
  }
  return { children, end: childNode };
};
var virtualiseText = (meta, node, index) => {
  insertMetadataChild(text_kind, meta, node, index, null);
  return childResult("", text2(node.data), node.nextSibling);
};
var virtualiseFragment = (metaParent, domParent, node, index) => {
  const key = parseKey(node.data);
  const meta = insertMetadataChild(fragment_kind, metaParent, node, index, key);
  const { children, end } = virtualiseChildren(meta, domParent, node.nextSibling);
  meta.endNode = end;
  const vnode = fragment2(toList2(children));
  return childResult(key, vnode, end?.nextSibling);
};
var virtualiseMap = (metaParent, domParent, node, index) => {
  const key = parseKey(node.data);
  const meta = insertMetadataChild(map_kind, metaParent, node, index, key);
  const child = virtualiseNextChild(meta, domParent, node, 0);
  if (!child)
    return null;
  const vnode = map5(child.vnode, (x) => x);
  return childResult(key, vnode, child.next);
};
var virtualiseMemo = (meta, domParent, node, index) => {
  const key = parseKey(node.data);
  const child = virtualiseNextChild(meta, domParent, node, index);
  if (!child)
    return null;
  domParent.removeChild(node);
  const vnode = memo2(toList2([ref({})]), () => child.vnode);
  return childResult(key, vnode, child.next);
};
var virtualiseNextChild = (meta, domParent, node, index) => {
  while (true) {
    node = node.nextSibling;
    if (!node)
      return null;
    const child = virtualiseChild(meta, domParent, node, index);
    if (child)
      return child;
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
  return toList2(attributes);
};
var INPUT_ELEMENTS = ["input", "select", "textarea"];
var virtualiseInputEvents = (tag, node) => {
  const value = node.value;
  const checked = node.checked;
  if (tag === "input" && node.type === "checkbox" && !checked)
    return;
  if (tag === "input" && node.type === "radio" && !checked)
    return;
  if (node.type !== "checkbox" && node.type !== "radio" && !value)
    return;
  queueMicrotask(() => {
    node.value = value;
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
var toList2 = (arr) => arr.reduceRight((xs, x) => List$NonEmpty(x, xs), empty_list);

// build/dev/javascript/lustre/lustre/runtime/client/runtime.ffi.mjs
var is_browser = () => !!globalThis.document;
class Runtime {
  constructor(root, [model, effects], view, update, options) {
    this.root = root;
    this.#model = model;
    this.#view = view;
    this.#update = update;
    this.root.addEventListener("context-request", (event) => {
      if (!(event.context && event.callback))
        return;
      if (!this.#contexts.has(event.context))
        return;
      event.stopImmediatePropagation();
      const context = this.#contexts.get(event.context);
      if (event.subscribe) {
        const unsubscribe = () => {
          context.subscribers = context.subscribers.filter((subscriber) => subscriber !== event.callback);
        };
        context.subscribers.push([event.callback, unsubscribe]);
        event.callback(context.value, unsubscribe);
      } else {
        event.callback(context.value);
      }
    });
    const decodeEvent = (event, path, name) => decode2(this.#cache, path, name, event);
    const dispatch2 = (event, data) => {
      const [cache, result] = dispatch(this.#cache, data);
      this.#cache = cache;
      if (Result$isOk(result)) {
        const handler = Result$Ok$0(result);
        if (handler.stop_propagation)
          event.stopPropagation();
        if (handler.prevent_default)
          event.preventDefault();
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
  emit(event, data) {
    const target = this.root.host ?? this.root;
    target.dispatchEvent(new LustreEvent(event, data));
  }
  provide(key, value) {
    if (!this.#contexts.has(key)) {
      this.#contexts.set(key, { value, subscribers: [] });
    } else {
      const context = this.#contexts.get(key);
      if (isEqual2(context.value, value)) {
        return;
      }
      context.value = value;
      for (let i = context.subscribers.length - 1;i >= 0; i--) {
        const [subscriber, unsubscribe] = context.subscribers[i];
        if (!subscriber) {
          context.subscribers.splice(i, 1);
          continue;
        }
        subscriber(value, unsubscribe);
      }
    }
  }
  subscribe(key, decoder) {
    if (!key)
      return;
    this.#contextSubscriptions.get(key)?.();
    const target = this.root.host ?? this.root;
    target.dispatchEvent(new ContextRequestEvent(key, (value, unsubscribe) => {
      const previousUnsubscribe = this.#contextSubscriptions.get(key);
      if (previousUnsubscribe !== unsubscribe) {
        previousUnsubscribe?.();
      }
      const decoded = run(value, decoder);
      this.#contextSubscriptions.set(key, unsubscribe);
      if (Result$isOk(decoded)) {
        this.dispatch(Result$Ok$0(decoded), true);
      }
    }, true));
  }
  unsubscribe(key) {
    const unsubscribe = this.#contextSubscriptions.get(key);
    if (unsubscribe) {
      unsubscribe();
      this.#contextSubscriptions.delete(key);
    }
  }
  unsubscribeAll() {
    for (const [_, unsubscribe] of this.#contextSubscriptions) {
      unsubscribe?.();
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
    emit: (event, data) => this.emit(event, data),
    select: () => {},
    root: () => this.root,
    provide: (key, value) => this.provide(key, value),
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
  constructor(context, callback, subscribe) {
    super("context-request", { bubbles: true, composed: true });
    this.context = context;
    this.callback = callback;
    this.subscribe = subscribe;
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
  constructor(root, [init, effects], update, view) {
    this.#runtime = new Runtime(root, [init, effects], view, update);
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
  emit(event, data) {
    this.#runtime.emit(event, data);
  }
}
var start = ({ init, update, view }, selector, flags) => {
  if (!is_browser())
    return Result$Error(Error$NotABrowser());
  const root = selector instanceof HTMLElement ? selector : globalThis.document.querySelector(selector);
  if (!root)
    return Result$Error(Error$ElementNotFound(selector));
  return Result$Ok(new Spa(root, init(flags), update, view));
};

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
function application(init, update, view) {
  return new App(Option$None$const, init, update, view, default_config);
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
class SystemTheme extends CustomType {
}
var Theme$SystemTheme$const = new SystemTheme;
class LightTheme extends CustomType {
}
var Theme$LightTheme$const = new LightTheme;
class DarkTheme extends CustomType {
}
var Theme$DarkTheme$const = new DarkTheme;
class TeamTrace extends CustomType {
  constructor(id, node, module, function$, arity, privacy, delivery_status, event_count, received_at_ms, legal_hold, locked) {
    super();
    this.id = id;
    this.node = node;
    this.module = module;
    this.function = function$;
    this.arity = arity;
    this.privacy = privacy;
    this.delivery_status = delivery_status;
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
  constructor(trace_id, events, next_cursor) {
    super();
    this.trace_id = trace_id;
    this.events = events;
    this.next_cursor = next_cursor;
  }
}
class Exact extends CustomType {
}
var Evidence$Exact$const = new Exact;
class Inferred extends CustomType {
  constructor(method, reason) {
    super();
    this.method = method;
    this.reason = reason;
  }
}
class ExactTime extends CustomType {
  constructor(value_ns) {
    super();
    this.value_ns = value_ns;
  }
}
class EstimatedTime extends CustomType {
  constructor(value_ns, lower_ns, upper_ns) {
    super();
    this.value_ns = value_ns;
    this.lower_ns = lower_ns;
    this.upper_ns = upper_ns;
  }
}
class TimeUnavailable extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
}
class TimeSummary extends CustomType {
  constructor(estimate, valid_samples, missing_samples) {
    super();
    this.estimate = estimate;
    this.valid_samples = valid_samples;
    this.missing_samples = missing_samples;
  }
}
class GraphEdge extends CustomType {
  constructor(from, to, kind, evidence) {
    super();
    this.from = from;
    this.to = to;
    this.kind = kind;
    this.evidence = evidence;
  }
}
class GraphBoundary extends CustomType {
  constructor(event_id, kind, reason) {
    super();
    this.event_id = event_id;
    this.kind = kind;
    this.reason = reason;
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
  constructor(event_count, outcome_summary) {
    super();
    this.event_count = event_count;
    this.outcome_summary = outcome_summary;
  }
}
class Failed extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
}
class EventRow extends CustomType {
  constructor(id, actor, kind, timestamp_ns, duration_ns, time, evidence, anomalous, internal) {
    super();
    this.id = id;
    this.actor = actor;
    this.kind = kind;
    this.timestamp_ns = timestamp_ns;
    this.duration_ns = duration_ns;
    this.time = time;
    this.evidence = evidence;
    this.anomalous = anomalous;
    this.internal = internal;
  }
}
class EventPage extends CustomType {
  constructor(events, total, start, limit) {
    super();
    this.events = events;
    this.total = total;
    this.start = start;
    this.limit = limit;
  }
}
class LiveRow extends CustomType {
  constructor(node, pid, label, registered_name, process_label, initial_call, mailbox_len, memory_bytes, reductions, heap_words, total_heap_words, link_count, status, current_function, links, ancestors) {
    super();
    this.node = node;
    this.pid = pid;
    this.label = label;
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
  constructor(pid, label, kind, summary, evidence) {
    super();
    this.pid = pid;
    this.label = label;
    this.kind = kind;
    this.summary = summary;
    this.evidence = evidence;
  }
}
class TopologyEdge extends CustomType {
  constructor(from, to, evidence) {
    super();
    this.from = from;
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
  constructor(status, left_id, right_id, latency_delta, reason) {
    super();
    this.status = status;
    this.left_id = left_id;
    this.right_id = right_id;
    this.latency_delta = latency_delta;
    this.reason = reason;
  }
}
class CompareRun extends CustomType {
  constructor(path, added, removed, changed, ambiguity_count, first_divergence_path, items) {
    super();
    this.path = path;
    this.added = added;
    this.removed = removed;
    this.changed = changed;
    this.ambiguity_count = ambiguity_count;
    this.first_divergence_path = first_divergence_path;
    this.items = items;
  }
}
class BranchStatistic extends CustomType {
  constructor(signature, p50, p95, occurrences, total_runs) {
    super();
    this.signature = signature;
    this.p50 = p50;
    this.p95 = p95;
    this.occurrences = occurrences;
    this.total_runs = total_runs;
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
  constructor(remote, mode, theme, events, graph_edges, graph_boundaries, graph_loading, graph_error, total_events, loaded_start, loaded_limit, loaded_query, loading, load_error, selected_event_id, query, show_internal, viewport_start, viewport_size, zoom, palette_open, capture_form_open, bookmarks, annotation, trigger_input, mfa_suggestions, capture_where, capture_preset, capture_max_roots, save_path, capture_phase, capture_notice, live_rows, live_findings, live_supervision, live_spawn, live_links, live_generation, live_sampled_at_ms, live_loading, live_error, selected_live_pid, compare_paths_input, compare_loading, compare_error, compare_report, team_traces, team_next_cursor, team_loading, team_error, selected_trace_id, selected_team_trace_ids, team_events, team_events_next_cursor, team_events_loading, team_events_error) {
    super();
    this.remote = remote;
    this.mode = mode;
    this.theme = theme;
    this.events = events;
    this.graph_edges = graph_edges;
    this.graph_boundaries = graph_boundaries;
    this.graph_loading = graph_loading;
    this.graph_error = graph_error;
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
    this.capture_form_open = capture_form_open;
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
    this.selected_team_trace_ids = selected_team_trace_ids;
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
class UserCycledTheme extends CustomType {
}
var Msg$UserCycledTheme$const = new UserCycledTheme;
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
  constructor(start, size) {
    super();
    this.start = start;
    this.size = size;
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
class GraphLoaded extends CustomType {
  constructor(edges, boundaries) {
    super();
    this.edges = edges;
    this.boundaries = boundaries;
  }
}
class GraphLoadFailed extends CustomType {
  constructor(reason) {
    super();
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
class UserOpenedCaptureForm extends CustomType {
}
var Msg$UserOpenedCaptureForm$const = new UserOpenedCaptureForm;
class UserClosedCaptureForm extends CustomType {
}
var Msg$UserClosedCaptureForm$const = new UserClosedCaptureForm;
class UserChoseCaptureAction extends CustomType {
}
var Msg$UserChoseCaptureAction$const = new UserChoseCaptureAction;
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
class UserToggledTeamCompare extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
}
class UserRequestedTeamCompare extends CustomType {
}
var Msg$UserRequestedTeamCompare$const = new UserRequestedTeamCompare;
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
function init(events) {
  return new Model(false, Mode$Capture$const, Theme$SystemTheme$const, events, List$Empty$const, List$Empty$const, false, Option$None$const, length(events), 0, length(events), "", false, Option$None$const, Option$None$const, "", false, 0, 80, 1, false, true, List$Empty$const, "", "", List$Empty$const, "", "generic", "1", "capture.beamtrace", CapturePhase$Unavailable$const, "", List$Empty$const, List$Empty$const, List$Empty$const, List$Empty$const, List$Empty$const, 0, 0, false, Option$None$const, Option$None$const, `baseline.beamtrace
candidate.beamtrace`, false, Option$None$const, Option$None$const, List$Empty$const, Option$None$const, false, Option$None$const, Option$None$const, List$Empty$const, List$Empty$const, Option$None$const, false, Option$None$const);
}
function init_remote() {
  let _record = init(List$Empty$const);
  return new Model(true, _record.mode, _record.theme, _record.events, _record.graph_edges, _record.graph_boundaries, true, _record.graph_error, _record.total_events, _record.loaded_start, 200, _record.loaded_query, true, _record.load_error, _record.selected_event_id, _record.query, _record.show_internal, _record.viewport_start, 80, _record.zoom, _record.palette_open, _record.capture_form_open, _record.bookmarks, _record.annotation, _record.trigger_input, _record.mfa_suggestions, _record.capture_where, _record.capture_preset, _record.capture_max_roots, _record.save_path, CapturePhase$Idle$const, _record.capture_notice, _record.live_rows, _record.live_findings, _record.live_supervision, _record.live_spawn, _record.live_links, _record.live_generation, _record.live_sampled_at_ms, _record.live_loading, _record.live_error, _record.selected_live_pid, _record.compare_paths_input, _record.compare_loading, _record.compare_error, _record.compare_report, _record.team_traces, _record.team_next_cursor, _record.team_loading, _record.team_error, _record.selected_trace_id, _record.selected_team_trace_ids, _record.team_events, _record.team_events_next_cursor, _record.team_events_loading, _record.team_events_error);
}
function merge_team_traces(existing, incoming) {
  let _pipe = fold2(incoming, existing, (traces, incoming_trace) => {
    let $ = any(traces, (trace) => {
      return trace.id === incoming_trace.id;
    });
    if ($) {
      return traces;
    } else {
      return append2(traces, prepend(incoming_trace, List$Empty$const));
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
    return ends_with(lowercase(path), ".beamtrace") || starts_with(path, "team:");
  }) && unique_strings(paths, List$Empty$const);
}
function parse_root_budget(model) {
  let $ = parse_int(trim(model.capture_max_roots));
  if ($ instanceof Ok) {
    let value = $[0];
    if (value >= 1 && value <= 1000) {
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
  } else if ($ === "escape") {
    return new Some(Msg$UserClosedPalette$const);
  } else {
    return Option$None$const;
  }
}
function next_theme(theme) {
  if (theme instanceof SystemTheme) {
    return Theme$LightTheme$const;
  } else if (theme instanceof LightTheme) {
    return Theme$DarkTheme$const;
  } else {
    return Theme$SystemTheme$const;
  }
}
function update2(loop$model, loop$message) {
  while (true) {
    let model = loop$model;
    let message = loop$message;
    if (message instanceof UserSelectedMode) {
      let mode = message[0];
      return new Model(model.remote, mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, (() => {
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
      })(), model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserCycledTheme) {
      return new Model(model.remote, model.mode, next_theme(model.theme), model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedEvent) {
      let id = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, new Some(id), model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedQuery) {
      let query = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, Option$None$const, model.selected_event_id, query, model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserToggledInternalNoise) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, !model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserFocusedSearch) {
      return model;
    } else if (message instanceof UserOpenedPalette) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, true, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserClosedPalette) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, false, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserToggledBookmark) {
      let id = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, toggle_member(model.bookmarks, id), model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedAnnotation) {
      let annotation = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
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
      let start = message.start;
      let size = message.size;
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, Option$None$const, model.selected_event_id, model.query, model.show_internal, max(start, 0), min(max(size, 1), 1000), model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserZoomed) {
      let zoom = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, clamp(zoom, 0.25, 4), model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PageLoaded) {
      let query = message.query;
      let page = message.page;
      let $ = !model.remote || query === remote_query(model);
      if ($) {
        return new Model(model.remote, model.mode, model.theme, page.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, page.total, page.start, page.limit, query, false, Option$None$const, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof PageLoadFailed) {
      let query = message.query;
      let reason = message.reason;
      let $ = !model.remote || query === remote_query(model);
      if ($) {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, new Some(reason), model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, false, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof GraphLoaded) {
      let edges = message.edges;
      let boundaries = message.boundaries;
      return new Model(model.remote, model.mode, model.theme, model.events, edges, boundaries, false, Option$None$const, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof GraphLoadFailed) {
      let reason = message.reason;
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, false, new Some(reason), model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedTrigger) {
      let trigger = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, trigger, (() => {
        let $ = trim(trigger);
        if ($ === "") {
          return List$Empty$const;
        } else {
          return model.mfa_suggestions;
        }
      })(), model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof MfaSuggestionsLoaded) {
      let suggestions = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, take(suggestions, 200), model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedCaptureWhere) {
      let source = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, source, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedCapturePreset) {
      let preset = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedMaxRoots) {
      let max_roots = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedArm) {
      let $ = trim(model.trigger_input);
      let $1 = parse_root_budget(model);
      if ($ === "") {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed("trigger_required"), "Enter an MFA trigger", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else if ($1 instanceof Ok) {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Arming$const, "Arming " + trim(model.trigger_input), model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed("invalid_root_budget"), "Max roots must be between 1 and 1000", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof CaptureArmAccepted) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Armed$const, "Capture armed; perform one operation", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureArmFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed(reason), reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PollCaptureStatus) {
      return model;
    } else if (message instanceof CaptureStatusLoaded) {
      let phase = message[0];
      if (phase instanceof Ready) {
        let count = phase.event_count;
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, count, 0, 0, "", false, Option$None$const, model.selected_event_id, model.query, model.show_internal, 0, model.viewport_size, model.zoom, model.palette_open, (() => {
          let $ = model.capture_phase;
          let $1 = trim(model.trigger_input);
          if ($ instanceof Unavailable && $1 === "") {
            return false;
          } else if ($ instanceof Idle && $1 === "") {
            return false;
          } else {
            return model.capture_form_open;
          }
        })(), model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, "", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else if (phase instanceof Failed && phase.reason === "system_tracer_occupied") {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, "Exact capture was refused; another tracer owns the node. Use Live for bounded inferred sampling.", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof UserOpenedCaptureForm) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, true, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserClosedCaptureForm) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, false, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChoseCaptureAction) {
      return new Model(model.remote, Mode$Capture$const, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, false, true, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedCancel) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, CapturePhase$Cancelling$const, "Stopping capture and cleaning the target", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureCancelFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, new Failed(reason), reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedSavePath) {
      let path = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedSave) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, "Saving capture", model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureSaved) {
      let path = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, "Saved " + path, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CaptureSaveFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, reason, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof PollLive) {
      let $ = model.mode;
      if ($ instanceof Live) {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, true, Option$None$const, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return model;
      }
    } else if (message instanceof LiveLoaded) {
      let snapshot = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, snapshot.rows, snapshot.findings, snapshot.supervision, snapshot.spawn, snapshot.links, snapshot.generation, snapshot.sampled_at_ms, false, Option$None$const, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof LiveLoadFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, false, new Some(reason), model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedLiveProcess) {
      let pid = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, new Some(pid), model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserChangedComparePaths) {
      let paths = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, paths, model.compare_loading, Option$None$const, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedCompare) {
      let $ = valid_compare_paths(compare_paths(model));
      if ($) {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, true, Option$None$const, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, new Some("Enter 2–20 distinct .beamtrace paths"), model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof CompareLoaded) {
      let report = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, Option$None$const, new Some(report), model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof CompareFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, false, new Some(reason), model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedTeamTraces) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, List$Empty$const, Option$None$const, true, Option$None$const, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserRequestedMoreTeamTraces) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, true, Option$None$const, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof TeamTracesLoaded) {
      let page = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, merge_team_traces(model.team_traces, page.traces), page.next_cursor, false, Option$None$const, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof TeamTracesFailed) {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, false, new Some(reason), model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else if (message instanceof UserSelectedTeamTrace) {
      let id = message[0];
      let $ = find(model.team_traces, (trace) => {
        return trace.id === id;
      });
      if ($ instanceof Ok) {
        let trace = $[0];
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, new Some(id), model.selected_team_trace_ids, List$Empty$const, Option$None$const, !trace.locked, (() => {
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
    } else if (message instanceof UserToggledTeamCompare) {
      let id = message[0];
      let $ = contains(model.selected_team_trace_ids, id);
      if ($) {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, filter(model.selected_team_trace_ids, (selected) => {
          return selected !== id;
        }), model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        let $1 = length(model.selected_team_trace_ids) < 20;
        if ($1) {
          return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, append2(model.selected_team_trace_ids, prepend(id, List$Empty$const)), model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
        } else {
          return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, new Some("Select at most 20 traces for comparison"), model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
        }
      }
    } else if (message instanceof UserRequestedTeamCompare) {
      let $ = length(model.selected_team_trace_ids) >= 2;
      if ($) {
        return new Model(model.remote, Mode$Compare$const, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, (() => {
          let _pipe = model.selected_team_trace_ids;
          let _pipe$1 = map2(_pipe, (id) => {
            return "team:" + id;
          });
          return join(_pipe$1, `
`);
        })(), true, Option$None$const, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      } else {
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, new Some("Select between 2 and 20 traces to compare"), model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
      }
    } else if (message instanceof UserRequestedMoreTeamEvents) {
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, true, Option$None$const);
    } else if (message instanceof TeamEventsLoaded) {
      let page = message[0];
      let $ = isEqual(model.selected_trace_id, new Some(page.trace_id));
      if ($) {
        let _block;
        let _pipe = append2(model.team_events, page.events);
        _block = take(_pipe, 1000);
        let events = _block;
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, events, (() => {
          let $1 = length(events) >= 1000;
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
        return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, false, new Some(reason));
      } else {
        return model;
      }
    } else if (message instanceof UserRequestedTraceHold) {
      return model;
    } else if (message instanceof TraceHoldUpdated) {
      let updated = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, map2(model.team_traces, (trace) => {
        let $ = trace.id === updated.id;
        if ($) {
          return updated;
        } else {
          return trace;
        }
      }), model.team_next_cursor, model.team_loading, Option$None$const, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    } else {
      let reason = message[0];
      return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, model.loading, model.load_error, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, new Some(reason), model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
    }
  }
}
function result_to_option(result) {
  if (result instanceof Ok) {
    let value = result[0];
    return new Some(value);
  } else {
    return Option$None$const;
  }
}
function selected_team_trace(model) {
  let $ = model.selected_trace_id;
  if ($ instanceof Some) {
    let id = $[0];
    let _pipe = model.team_traces;
    let _pipe$1 = find(_pipe, (trace) => {
      return trace.id === id;
    });
    return result_to_option(_pipe$1);
  } else {
    return $;
  }
}
function begin_loading(model) {
  return new Model(model.remote, model.mode, model.theme, model.events, model.graph_edges, model.graph_boundaries, model.graph_loading, model.graph_error, model.total_events, model.loaded_start, model.loaded_limit, model.loaded_query, true, Option$None$const, model.selected_event_id, model.query, model.show_internal, model.viewport_start, model.viewport_size, model.zoom, model.palette_open, model.capture_form_open, model.bookmarks, model.annotation, model.trigger_input, model.mfa_suggestions, model.capture_where, model.capture_preset, model.capture_max_roots, model.save_path, model.capture_phase, model.capture_notice, model.live_rows, model.live_findings, model.live_supervision, model.live_spawn, model.live_links, model.live_generation, model.live_sampled_at_ms, model.live_loading, model.live_error, model.selected_live_pid, model.compare_paths_input, model.compare_loading, model.compare_error, model.compare_report, model.team_traces, model.team_next_cursor, model.team_loading, model.team_error, model.selected_trace_id, model.selected_team_trace_ids, model.team_events, model.team_events_next_cursor, model.team_events_loading, model.team_events_error);
}
function needs_page(model) {
  let requested_end = min(model.viewport_start + model.viewport_size, model.total_events);
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
  let relative_start = max(model.viewport_start - model.loaded_start, 0);
  let _pipe = model;
  let _pipe$1 = filtered_events(_pipe);
  let _pipe$2 = drop(_pipe$1, relative_start);
  return take(_pipe$2, model.viewport_size);
}
function selected_event(model) {
  let $ = model.selected_event_id;
  if ($ instanceof Some) {
    let id = $[0];
    let _pipe = model.events;
    let _pipe$1 = find(_pipe, (row) => {
      return row.id === id;
    });
    return result_to_option(_pipe$1);
  } else {
    return $;
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/appearance_ffi.mjs
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
}
function platformModifier() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "";
  return /Mac|iPhone|iPad|iPod/i.test(platform) ? "⌘" : "Ctrl";
}

// build/dev/javascript/beamtrace_web/beamtrace_web/appearance.mjs
function apply(theme) {
  return setTheme((() => {
    if (theme instanceof SystemTheme) {
      return "system";
    } else if (theme instanceof LightTheme) {
      return "light";
    } else {
      return "dark";
    }
  })());
}
function modifier_label() {
  return platformModifier();
}

// build/dev/javascript/beamtrace_web/beamtrace_web/canvas_ffi.mjs
var palette = {
  background: "#111019",
  grid: "rgba(241, 188, 91, 0.12)",
  text: "#d8d1c4",
  muted: "#817b88",
  exact: "#f1bc5b",
  receive: "#9b7bff",
  anomaly: "#ff7369",
  process: "#79b8ff",
  message: "#f1bc5b",
  spawn: "#72d6a0",
  boundary: "#817b88"
};
function draw(root, source, zoom) {
  const canvas = root?.querySelector?.("#causal-canvas") ?? document.querySelector("#causal-canvas");
  if (!(canvas instanceof HTMLCanvasElement))
    return;
  let payload;
  try {
    payload = JSON.parse(source);
  } catch (_) {
    return;
  }
  const rows = Array.isArray(payload) ? payload : payload.rows ?? [];
  const edges = Array.isArray(payload) ? [] : payload.edges ?? [];
  const boundaries = Array.isArray(payload) ? [] : payload.boundaries ?? [];
  const divergencePath = Array.isArray(payload) ? [] : payload.divergence_path ?? [];
  const bounds = canvas.getBoundingClientRect();
  const width = Math.max(1, Math.floor(bounds.width));
  const height = Math.max(1, Math.floor(bounds.height));
  const density = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.floor(width * density);
  canvas.height = Math.floor(height * density);
  const context = canvas.getContext("2d");
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
  actors.forEach((actor, index) => {
    const y = top + index * laneHeight;
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
  const usable = Math.max(width - left - right, 1) * Math.max(0.25, Math.min(zoom, 4));
  const points = rows.map((row, index) => {
    const lane = Math.max(actors.indexOf(row.actor), 0);
    return {
      ...row,
      x: left + index / Math.max(rows.length - 1, 1) * usable,
      y: top + lane * laneHeight
    };
  });
  const pointsById = new Map(points.map((point) => [point.id, point]));
  const divergencePairs = new Set;
  for (let index = 1;index < divergencePath.length; index += 1) {
    divergencePairs.add(`${divergencePath[index - 1]}\x00${divergencePath[index]}`);
  }
  const renderedEdges = edges.filter((edge) => pointsById.has(edge.from) || pointsById.has(edge.to));
  const renderedBoundaries = boundaries.filter((boundary) => pointsById.has(boundary.event_id));
  canvas.dataset.edgeCount = String(renderedEdges.length);
  canvas.dataset.edgeKinds = [...new Set(renderedEdges.map((edge) => edge.kind))].sort().join(",");
  canvas.dataset.inferredEdgeCount = String(renderedEdges.filter((edge) => edge.evidence === "inferred").length);
  canvas.dataset.boundaryCount = String(renderedBoundaries.length);
  canvas.dataset.estimatedTimeCount = String(points.filter((point) => point.time?.kind === "estimated").length);
  canvas.dataset.divergenceEdgeCount = String(renderedEdges.filter((edge) => divergencePairs.has(`${edge.from}\x00${edge.to}`)).length);
  const edgeColor = (kind) => kind === "sequential_message" ? palette.message : kind === "spawned" ? palette.spawn : kind === "process_order" ? palette.process : palette.muted;
  edges.forEach((edge) => {
    const from = pointsById.get(edge.from);
    const to = pointsById.get(edge.to);
    if (!from && !to)
      return;
    const highlighted = divergencePairs.has(`${edge.from}\x00${edge.to}`);
    context.strokeStyle = highlighted ? palette.anomaly : edgeColor(edge.kind);
    context.lineWidth = highlighted ? 3 : 1.5;
    context.setLineDash(edge.evidence === "inferred" ? [5, 4] : []);
    context.beginPath();
    if (from && to) {
      context.moveTo(from.x, from.y);
      context.bezierCurveTo(from.x + 24, from.y, to.x - 24, to.y, to.x, to.y);
    } else {
      const point = from ?? to;
      const direction = from ? 1 : -1;
      context.moveTo(point.x, point.y);
      context.lineTo(point.x + direction * 30, point.y);
    }
    context.stroke();
    context.setLineDash([]);
    if (!from || !to) {
      const point = from ?? to;
      const direction = from ? 1 : -1;
      context.fillStyle = palette.background;
      context.strokeStyle = palette.boundary;
      context.beginPath();
      context.arc(point.x + direction * 30, point.y, 4, 0, Math.PI * 2);
      context.fill();
      context.stroke();
    }
  });
  boundaries.forEach((boundary) => {
    const point = pointsById.get(boundary.event_id);
    if (!point)
      return;
    context.strokeStyle = palette.boundary;
    context.lineWidth = 1.5;
    context.beginPath();
    context.moveTo(point.x, point.y);
    context.lineTo(point.x - 24, point.y - 12);
    context.stroke();
    context.fillStyle = palette.background;
    context.beginPath();
    context.arc(point.x - 24, point.y - 12, 4, 0, Math.PI * 2);
    context.fill();
    context.stroke();
  });
  points.forEach((point) => {
    if (point.time?.kind === "estimated") {
      let width = 12;
      try {
        const difference = BigInt(point.time.upper_ns) - BigInt(point.time.lower_ns);
        const capped = difference > 1000000000000000n ? 1000000000000000n : difference < 0n ? -difference : difference;
        width = Math.min(34, 6 + Math.log10(Number(capped) + 1) * 3);
      } catch (_) {
        width = 12;
      }
      context.strokeStyle = palette.muted;
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(point.x - width, point.y - 11);
      context.lineTo(point.x + width, point.y - 11);
      context.moveTo(point.x - width, point.y - 15);
      context.lineTo(point.x - width, point.y - 7);
      context.moveTo(point.x + width, point.y - 15);
      context.lineTo(point.x + width, point.y - 7);
      context.stroke();
    }
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
  window.addEventListener("keydown", (event) => {
    const editable = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement;
    const palette = document.querySelector(".command-palette");
    if (event.key === "Tab" && palette) {
      trapFocus(event, palette);
      return;
    }
    if (event.key === "Escape") {
      if (editable && !palette) {
        event.target.blur();
        return;
      }
      if (palette) {
        event.preventDefault();
        handler("escape");
      }
      return;
    }
    const command = (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k";
    const direct = !editable && ["1", "2", "3", "4", "/"].includes(event.key);
    if (!command && !direct)
      return;
    event.preventDefault();
    handler(command ? "k" : event.key);
  });
}
function trapFocus(event, palette) {
  const focusable = palette.querySelectorAll("button, [href], input, [tabindex]:not([tabindex='-1'])");
  if (focusable.length === 0)
    return;
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}
var paletteOpener = null;
function focusSearch() {
  window.requestAnimationFrame(() => {
    const search = document.getElementById("event-search");
    if (search)
      search.focus();
  });
}
function focusPalette() {
  paletteOpener = document.activeElement;
  window.requestAnimationFrame(() => {
    const first = document.querySelector(".command-palette button");
    if (first)
      first.focus();
  });
}
function restoreFocus() {
  const opener = paletteOpener;
  paletteOpener = null;
  window.requestAnimationFrame(() => {
    if (opener && typeof opener.focus === "function" && document.contains(opener)) {
      opener.focus();
    }
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/canvas.mjs
function first_divergence(loop$reports) {
  while (true) {
    let reports = loop$reports;
    if (reports instanceof Empty) {
      return reports;
    } else {
      let run = reports.head;
      let rest = reports.tail;
      let $ = run.first_divergence_path;
      if ($ instanceof Empty) {
        loop$reports = rest;
      } else {
        return $;
      }
    }
  }
}
function divergence_path(model) {
  let $ = model.compare_report;
  if ($ instanceof Some) {
    let report = $[0];
    return first_divergence(report.reports);
  } else {
    return List$Empty$const;
  }
}
function boundary_json(boundary) {
  return object2(prepend(["event_id", string3(boundary.event_id)], prepend(["kind", string3(boundary.kind)], prepend(["reason", string3(boundary.reason)], List$Empty$const))));
}
function evidence_kind(evidence) {
  if (evidence instanceof Exact) {
    return "exact";
  } else {
    return "inferred";
  }
}
function edge_json(edge) {
  return object2(prepend(["from", string3(edge.from)], prepend(["to", string3(edge.to)], prepend(["kind", string3(edge.kind)], prepend(["evidence", string3(evidence_kind(edge.evidence))], List$Empty$const)))));
}
function time_json(time) {
  if (time instanceof ExactTime) {
    let value = time.value_ns;
    return object2(prepend(["kind", string3("exact")], prepend(["value_ns", string3(value)], List$Empty$const)));
  } else if (time instanceof EstimatedTime) {
    let value = time.value_ns;
    let lower = time.lower_ns;
    let upper = time.upper_ns;
    return object2(prepend(["kind", string3("estimated")], prepend(["value_ns", string3(value)], prepend(["lower_ns", string3(lower)], prepend(["upper_ns", string3(upper)], List$Empty$const)))));
  } else {
    let reason = time.reason;
    return object2(prepend(["kind", string3("unavailable")], prepend(["reason", string3(reason)], List$Empty$const)));
  }
}
function row_json(row) {
  return object2(prepend(["id", string3(row.id)], prepend(["actor", string3(row.actor)], prepend(["kind", string3(row.kind)], prepend(["local_offset_ns", int3(row.timestamp_ns)], prepend(["duration_ns", int3(row.duration_ns)], prepend(["time", time_json(row.time)], prepend(["anomalous", bool2(row.anomalous)], prepend(["evidence", string3(evidence_kind(row.evidence))], List$Empty$const)))))))));
}
function rows_payload(rows, edges, boundaries, divergence) {
  let rows$1 = take(rows, 1000);
  let ids = map2(rows$1, (row) => {
    return row.id;
  });
  let _pipe = object2(prepend(["rows", array2(rows$1, row_json)], prepend([
    "edges",
    (() => {
      let _pipe = edges;
      let _pipe$1 = filter(_pipe, (edge) => {
        return contains(ids, edge.from) || contains(ids, edge.to);
      });
      return array2(_pipe$1, edge_json);
    })()
  ], prepend([
    "boundaries",
    (() => {
      let _pipe = boundaries;
      let _pipe$1 = filter(_pipe, (boundary) => {
        return contains(ids, boundary.event_id);
      });
      return array2(_pipe$1, boundary_json);
    })()
  ], prepend(["divergence_path", array2(divergence, string3)], List$Empty$const)))));
  return to_string2(_pipe);
}
function live_payload(model) {
  let _block;
  let _pipe = model;
  let _pipe$1 = filtered_live_rows(_pipe);
  let _pipe$2 = take(_pipe$1, 200);
  _block = map2(_pipe$2, (row) => {
    let anomalous = any(model.live_findings, (finding) => {
      return finding.pid === row.pid;
    });
    return new EventRow(row.pid, row.label, row.status, row.reductions, row.mailbox_len, new TimeUnavailable("live sample has no causal clock"), (() => {
      if (anomalous) {
        return new Inferred("live_sampling", "diagnostic threshold");
      } else {
        return Evidence$Exact$const;
      }
    })(), anomalous, false);
  });
  let rows = _block;
  let supervision = map2(model.live_supervision, (edge) => {
    return new GraphEdge(edge.from, edge.to, "supervision", edge.evidence);
  });
  let spawn = map2(model.live_spawn, (edge) => {
    return new GraphEdge(edge.from, edge.to, "spawned", edge.evidence);
  });
  let links = map2(model.live_links, (edge) => {
    return new GraphEdge(edge.from, edge.to, "link_relationship", edge.evidence);
  });
  return rows_payload(rows, (() => {
    let _pipe$3 = supervision;
    let _pipe$4 = append2(_pipe$3, spawn);
    return append2(_pipe$4, links);
  })(), List$Empty$const, List$Empty$const);
}
function payload(model) {
  let $ = model.mode;
  if ($ instanceof Live) {
    return live_payload(model);
  } else if ($ instanceof Team) {
    return rows_payload(model.team_events, List$Empty$const, List$Empty$const, List$Empty$const);
  } else {
    return rows_payload(visible_events(model), model.graph_edges, model.graph_boundaries, divergence_path(model));
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/api_error_ffi.mjs
function apiError(body, status, fallback) {
  try {
    const parsed = JSON.parse(body);
    if (parsed?.error && typeof parsed.error === "object" && typeof parsed.error.code === "string" && typeof parsed.error.message === "string" && typeof parsed.error.hint === "string") {
      return `${parsed.error.message} Next: ${parsed.error.hint} [${parsed.error.code}]`;
    }
    if (typeof parsed?.error === "string")
      return parsed.error;
  } catch {}
  return `${fallback} (${status})`;
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
    throw new Error(apiError(body, response.status, "capture request failed"));
  }
  return body;
}
function complete(promise, onSuccess, onError) {
  promise.then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "capture request failed");
  });
}
function armCapture(trigger, whereAql, preset, maxRoots, onSuccess, onError) {
  complete(request("/api/v2/sessions/current/arm", {
    method: "POST",
    body: JSON.stringify({
      trigger: trigger.trim(),
      where: whereAql.trim() || null,
      capture_window_ms: 30000,
      drain_timeout_ms: 1e4,
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
  complete(request("/api/v2/sessions/current", { method: "GET" }).then((body) => {
    try {
      const status = JSON.parse(body).status;
      if (status === "ready" || status === "sealed" || status === "failed" || status === "idle") {
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
    request(`/api/v2/targets/current/mfas?q=${encodeURIComponent(normalized)}&limit=20`, { method: "GET", signal: mfaSearchController.signal }).then(onSuccess).catch((error) => {
      if (error?.name !== "AbortError") {
        onError(error instanceof Error ? error.message : "MFA search failed");
      }
    });
  }, 120);
}
function cancelCapture(onSuccess, onError) {
  complete(request("/api/v2/sessions/current/cancel", { method: "POST" }), onSuccess, onError);
}
function saveCapture(path, onSuccess, onError) {
  complete(request("/api/v2/sessions/current/save", {
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
    fetch("/api/v2/sessions/current/cancel", {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { accept: "application/json" }
    }).catch(() => {});
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/capture_control.mjs
class StatusPayload extends CustomType {
  constructor(status, event_count, outcome, delivery_verified, issue_count, issue_summary, reason) {
    super();
    this.status = status;
    this.event_count = event_count;
    this.outcome = outcome;
    this.delivery_verified = delivery_verified;
    this.issue_count = issue_count;
    this.issue_summary = issue_summary;
    this.reason = reason;
  }
}

class IssuePayload extends CustomType {
  constructor(kind, node) {
    super();
    this.kind = kind;
    this.node = node;
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
  return from2((dispatch) => {
    return armCapture(trigger, where_aql, preset, max_roots, (_) => {
      return dispatch(Msg$CaptureArmAccepted$const);
    }, (reason) => {
      return dispatch(new CaptureArmFailed(reason));
    });
  });
}
function issue_label(issue) {
  let _block;
  let $ = issue.kind;
  if ($ === "dropped_events") {
    _block = "dropped events";
  } else if ($ === "missing_node") {
    _block = "missing final node receipt";
  } else if ($ === "batch_sequence_gap") {
    _block = "batch sequence gap";
  } else if ($ === "duplicate_batch") {
    _block = "duplicate batch";
  } else if ($ === "receipt_mismatch") {
    _block = "receipt mismatch";
  } else if ($ === "drain_timeout") {
    _block = "drain timeout";
  } else if ($ === "legacy_unverified") {
    _block = "legacy archive is unverified";
  } else {
    _block = "unrecognized integrity issue";
  }
  let label = _block;
  let $1 = issue.node;
  if ($1 === "") {
    return label;
  } else {
    let node = $1;
    return label + " on " + node;
  }
}
function issue_decoder() {
  return field("kind", string2, (kind) => {
    return optional_field("node", "", string2, (node) => {
      return success(new IssuePayload(kind, node));
    });
  });
}
function outcome_issue_summary_decoder() {
  return field("issues", list2(issue_decoder()), (issues) => {
    let _pipe = issues;
    let _pipe$1 = take(_pipe, 3);
    let _pipe$2 = map2(_pipe$1, issue_label);
    let _pipe$3 = intersperse(_pipe$2, "; ");
    let _pipe$4 = fold2(_pipe$3, "", (summary, part) => {
      return summary + part;
    });
    return success(_pipe$4);
  });
}
function outcome_issue_count_decoder() {
  return field("issues", list2(dynamic), (issues) => {
    return success(length(issues));
  });
}
function outcome_end_decoder() {
  return field("kind", string2, (kind) => {
    if (kind === "quiet_period") {
      return field("quiet_ms", int2, (quiet_ms) => {
        return success("sealed after " + to_string(quiet_ms) + "ms quiet period");
      });
    } else if (kind === "time_window") {
      return field("window_ms", int2, (window_ms) => {
        return success("sealed after " + to_string(window_ms) + "ms window");
      });
    } else if (kind === "user_stopped") {
      return success("sealed after user stop");
    } else if (kind === "budget_reached") {
      return success("sealed after budget limit");
    } else if (kind === "agent_failure") {
      return success("sealed after agent failure");
    } else if (kind === "legacy_unknown") {
      return success("legacy observation end unknown");
    } else {
      return failure("", "observation end");
    }
  });
}
function outcome_decoder() {
  return field("end", outcome_end_decoder(), (end) => {
    return success(end);
  });
}
function status_decoder() {
  return field("status", string2, (status) => {
    return optional_field("event_count", 0, int2, (event_count) => {
      return optional_field("outcome", "sealed", outcome_decoder(), (outcome) => {
        return optional_field("delivery_verified", false, bool, (delivery_verified) => {
          return optional_field("outcome", 0, outcome_issue_count_decoder(), (issue_count) => {
            return optional_field("outcome", "", outcome_issue_summary_decoder(), (issue_summary) => {
              return optional_field("reason", "", string2, (reason) => {
                return success(new StatusPayload(status, event_count, outcome, delivery_verified, issue_count, issue_summary, reason));
              });
            });
          });
        });
      });
    });
  });
}
function decode_status(source) {
  let $ = parse(source, status_decoder());
  if ($ instanceof Ok) {
    let payload = $[0];
    let $1 = payload.status;
    if ($1 === "idle") {
      return new Ok(CapturePhase$Idle$const);
    } else if ($1 === "armed") {
      return new Ok(CapturePhase$Armed$const);
    } else if ($1 === "cancelling") {
      return new Ok(CapturePhase$Cancelling$const);
    } else if ($1 === "ready") {
      return new Ok(new Ready(payload.event_count, payload.outcome + (() => {
        let $2 = payload.delivery_verified;
        if ($2) {
          return " · delivery verified";
        } else {
          let $3 = payload.issue_count;
          if ($3 === 0) {
            return " · delivery unverified";
          } else {
            let count = $3;
            return " · integrity issues present (" + to_string(count) + ")" + (() => {
              let $4 = payload.issue_summary;
              if ($4 === "") {
                return $4;
              } else {
                let summary = $4;
                return ": " + summary;
              }
            })();
          }
        }
      })()));
    } else if ($1 === "sealed") {
      return new Ok(new Ready(payload.event_count, payload.outcome + (() => {
        let $2 = payload.delivery_verified;
        if ($2) {
          return " · delivery verified";
        } else {
          let $3 = payload.issue_count;
          if ($3 === 0) {
            return " · delivery unverified";
          } else {
            let count = $3;
            return " · integrity issues present (" + to_string(count) + ")" + (() => {
              let $4 = payload.issue_summary;
              if ($4 === "") {
                return $4;
              } else {
                let summary = $4;
                return ": " + summary;
              }
            })();
          }
        }
      })()));
    } else if ($1 === "failed") {
      return new Ok(new Failed(payload.reason));
    } else {
      return new Error2("unknown capture status");
    }
  } else {
    return new Error2("invalid capture status");
  }
}
function status() {
  return from2((dispatch) => {
    return fetchCaptureStatus((body) => {
      let $ = decode_status(body);
      if ($ instanceof Ok) {
        let phase = $[0];
        return dispatch(new CaptureStatusLoaded(phase));
      } else {
        let reason = $[0];
        return dispatch(new CaptureArmFailed(reason));
      }
    }, (_) => {
      return dispatch(new CaptureStatusLoaded(CapturePhase$Unavailable$const));
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
    let payload = $[0];
    return new Ok((() => {
      let _pipe = payload.candidates;
      return map2(_pipe, (candidate) => {
        return candidate.mfa;
      });
    })());
  } else {
    return new Error2("invalid MFA search response");
  }
}
function search_mfas(query) {
  return from2((dispatch) => {
    return searchMfas(query, (body) => {
      let $ = decode_mfas(body);
      if ($ instanceof Ok) {
        let candidates = $[0];
        return dispatch(new MfaSuggestionsLoaded(candidates));
      } else {
        return dispatch(new MfaSuggestionsLoaded(List$Empty$const));
      }
    }, (_) => {
      return dispatch(new MfaSuggestionsLoaded(List$Empty$const));
    });
  });
}
function poll_after(delay_ms) {
  return from2((dispatch) => {
    return schedule(delay_ms, () => {
      return dispatch(Msg$PollCaptureStatus$const);
    });
  });
}
function cancel() {
  return from2((dispatch) => {
    return cancelCapture((_) => {
      return dispatch(new CaptureStatusLoaded(CapturePhase$Cancelling$const));
    }, (reason) => {
      return dispatch(new CaptureCancelFailed(reason));
    });
  });
}
function save(path) {
  return from2((dispatch) => {
    return saveCapture(path, (_) => {
      return dispatch(new CaptureSaved(path));
    }, (reason) => {
      return dispatch(new CaptureSaveFailed(reason));
    });
  });
}
function install_cleanup() {
  return from2((_) => {
    return installPageCleanup();
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page.mjs
var otp_system_actors = /* @__PURE__ */ toList([
  "init",
  "erl_prim_loader",
  "application_controller",
  "kernel_sup",
  "kernel_safe_sup",
  "global_name_server",
  "global_group",
  "user",
  "user_drv",
  "user_drv_writer",
  "code_server",
  "rex",
  "net_kernel",
  "net_sup",
  "inet_db",
  "file_server_2",
  "erts_code_purger",
  "erl_signal_server",
  "socket_registry",
  "timer_server",
  "prim_tty"
]);
function is_internal(actor) {
  let normalized = lowercase(actor);
  let _block;
  let $ = (() => {
    let _pipe = split2(normalized, "/");
    return last(_pipe);
  })();
  if ($ instanceof Ok) {
    let last = $[0];
    _block = last;
  } else {
    _block = normalized;
  }
  let name = _block;
  return starts_with(name, "beamtrace") || starts_with(name, "logger") || starts_with(name, "standard_error") || starts_with(name, "standard_io") || contains(otp_system_actors, name);
}
function event_row(id, actor, timestamp_ns, kind, time, evidence) {
  return new EventRow(id, actor, kind, timestamp_ns, 0, time, evidence, kind === "exit" || kind === "gap", is_internal(actor));
}
function legacy_evidence_decoder() {
  return field("kind", string2, (kind) => {
    if (kind === "exact") {
      return success(Evidence$Exact$const);
    } else if (kind === "inferred") {
      return field("reason", string2, (reason) => {
        return field("confidence", float2, (_) => {
          return success(new Inferred("legacy_v1_inference", reason));
        });
      });
    } else {
      return failure(Evidence$Exact$const, "legacy event evidence");
    }
  });
}
function kind_decoder() {
  return field("kind", string2, (kind) => {
    return success(kind);
  });
}
function logical_decoder() {
  return field("label", string2, (label) => {
    return success(label);
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
          let label = logical[0];
          return label;
        } else {
          return physical;
        }
      })());
    });
  });
}
function flat_v1_event_decoder() {
  return field("id", string2, (id) => {
    return field("process", actor_decoder(), (actor) => {
      return field("local_timestamp_ns", int2, (timestamp_ns) => {
        return field("event", kind_decoder(), (kind) => {
          return field("evidence", legacy_evidence_decoder(), (evidence) => {
            return success(event_row(id, actor, timestamp_ns, kind, new TimeUnavailable("legacy trace has no clock calibration"), evidence));
          });
        });
      });
    });
  });
}
function inference_decoder() {
  return field("method", string2, (method) => {
    return field("reason", string2, (reason) => {
      return success([method, reason]);
    });
  });
}
function evidence_decoder() {
  return field("kind", string2, (kind) => {
    if (kind === "exact") {
      return success(Evidence$Exact$const);
    } else if (kind === "inferred") {
      return field("inference", inference_decoder(), (inference) => {
        return success(new Inferred(inference[0], inference[1]));
      });
    } else {
      return failure(Evidence$Exact$const, "event evidence");
    }
  });
}
function local_offset_decoder() {
  return field("offset_ns", int2, (offset) => {
    return field("order", int2, (_) => {
      return success(offset);
    });
  });
}
function flat_v2_event_decoder() {
  return field("id", string2, (id) => {
    return field("process", actor_decoder(), (actor) => {
      return field("local_instant", local_offset_decoder(), (timestamp_ns) => {
        return field("event", kind_decoder(), (kind) => {
          return field("evidence", evidence_decoder(), (evidence) => {
            return success(event_row(id, actor, timestamp_ns, kind, new TimeUnavailable("calibrated time was not supplied"), evidence));
          });
        });
      });
    });
  });
}
function time_estimate_decoder() {
  return field("kind", string2, (kind) => {
    if (kind === "exact") {
      return field("value_ns", string2, (value) => {
        return success(new ExactTime(value));
      });
    } else if (kind === "estimated") {
      return field("value_ns", string2, (value) => {
        return field("lower_ns", string2, (lower) => {
          return field("upper_ns", string2, (upper) => {
            return success(new EstimatedTime(value, lower, upper));
          });
        });
      });
    } else if (kind === "unavailable") {
      return field("reason", string2, (reason) => {
        return success(new TimeUnavailable(reason));
      });
    } else {
      return failure(new TimeUnavailable("invalid time estimate"), "time estimate");
    }
  });
}
function v2_page_event_decoder() {
  return field("observation", flat_v2_event_decoder(), (row) => {
    return field("time", time_estimate_decoder(), (time) => {
      return success(new EventRow(row.id, row.actor, row.kind, row.timestamp_ns, row.duration_ns, time, row.evidence, row.anomalous, row.internal));
    });
  });
}
function event_decoder() {
  return one_of(v2_page_event_decoder(), prepend(flat_v2_event_decoder(), prepend(flat_v1_event_decoder(), List$Empty$const)));
}
function page_decoder() {
  return field("start", int2, (start) => {
    return field("limit", int2, (limit) => {
      return field("total", int2, (total) => {
        return field("events", list2(event_decoder()), (events) => {
          return success(new EventPage(events, total, start, limit));
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
    return new Error2("Event page is not valid API v2 data. Validate the archive and reload it.");
  }
}

// build/dev/javascript/beamtrace_web/beamtrace_web/compare_control_ffi.mjs
function requestCompare(body, onSuccess, onError) {
  fetch("/api/v2/compare", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      "content-type": "application/json"
    },
    body
  }).then(async (response) => {
    const payload = await response.text();
    if (!response.ok) {
      throw new Error(apiError(payload, response.status, "compare request failed"));
    }
    return payload;
  }).then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "compare request failed");
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/compare_control.mjs
function time_summary_decoder() {
  return field("estimate", time_estimate_decoder(), (estimate) => {
    return field("valid_samples", int2, (valid) => {
      return field("missing_samples", int2, (missing) => {
        return success(new TimeSummary(estimate, valid, missing));
      });
    });
  });
}
function statistic_decoder() {
  return field("signature", string2, (signature) => {
    return field("p50", time_summary_decoder(), (p50) => {
      return field("p95", time_summary_decoder(), (p95) => {
        return field("occurrences", int2, (occurrences) => {
          return field("total_runs", int2, (total_runs) => {
            return success(new BranchStatistic(signature, p50, p95, occurrences, total_runs));
          });
        });
      });
    });
  });
}
function item_decoder() {
  return field("status", string2, (status) => {
    return optional_field("left_id", "", string2, (left_id) => {
      return optional_field("right_id", "", string2, (right_id) => {
        return optional_field("latency_delta", new TimeUnavailable("latency does not apply"), time_estimate_decoder(), (latency_delta) => {
          return optional_field("left_ids", List$Empty$const, list2(string2), (left_ids) => {
            return optional_field("right_ids", List$Empty$const, list2(string2), (right_ids) => {
              return optional_field("reason", "", string2, (reason) => {
                if (status === "matched") {
                  return success(new CompareItem(status, (() => {
                    if (left_ids instanceof Empty) {
                      return left_id;
                    } else if (left_id === "") {
                      return join(left_ids, ", ");
                    } else {
                      return left_id;
                    }
                  })(), (() => {
                    if (right_ids instanceof Empty) {
                      return right_id;
                    } else if (right_id === "") {
                      return join(right_ids, ", ");
                    } else {
                      return right_id;
                    }
                  })(), latency_delta, reason));
                } else if (status === "added") {
                  return success(new CompareItem(status, (() => {
                    if (left_ids instanceof Empty) {
                      return left_id;
                    } else if (left_id === "") {
                      return join(left_ids, ", ");
                    } else {
                      return left_id;
                    }
                  })(), (() => {
                    if (right_ids instanceof Empty) {
                      return right_id;
                    } else if (right_id === "") {
                      return join(right_ids, ", ");
                    } else {
                      return right_id;
                    }
                  })(), latency_delta, reason));
                } else if (status === "removed") {
                  return success(new CompareItem(status, (() => {
                    if (left_ids instanceof Empty) {
                      return left_id;
                    } else if (left_id === "") {
                      return join(left_ids, ", ");
                    } else {
                      return left_id;
                    }
                  })(), (() => {
                    if (right_ids instanceof Empty) {
                      return right_id;
                    } else if (right_id === "") {
                      return join(right_ids, ", ");
                    } else {
                      return right_id;
                    }
                  })(), latency_delta, reason));
                } else if (status === "changed") {
                  return success(new CompareItem(status, (() => {
                    if (left_ids instanceof Empty) {
                      return left_id;
                    } else if (left_id === "") {
                      return join(left_ids, ", ");
                    } else {
                      return left_id;
                    }
                  })(), (() => {
                    if (right_ids instanceof Empty) {
                      return right_id;
                    } else if (right_id === "") {
                      return join(right_ids, ", ");
                    } else {
                      return right_id;
                    }
                  })(), latency_delta, reason));
                } else if (status === "ambiguous") {
                  return success(new CompareItem(status, (() => {
                    if (left_ids instanceof Empty) {
                      return left_id;
                    } else if (left_id === "") {
                      return join(left_ids, ", ");
                    } else {
                      return left_id;
                    }
                  })(), (() => {
                    if (right_ids instanceof Empty) {
                      return right_id;
                    } else if (right_id === "") {
                      return join(right_ids, ", ");
                    } else {
                      return right_id;
                    }
                  })(), latency_delta, reason));
                } else {
                  return failure(new CompareItem("", "", "", new TimeUnavailable("invalid compare item"), ""), "compare item status");
                }
              });
            });
          });
        });
      });
    });
  });
}
function divergence_decoder() {
  return field("causal_path", list2(string2), (path) => {
    return success(path);
  });
}
function run_decoder() {
  return field("path", string2, (path) => {
    return field("added", int2, (added) => {
      return field("removed", int2, (removed) => {
        return field("changed", int2, (changed) => {
          return field("ambiguity_count", int2, (ambiguity_count) => {
            return field("first_divergence", optional(divergence_decoder()), (first_divergence) => {
              return field("items", list2(item_decoder()), (items) => {
                return success(new CompareRun(path, added, removed, changed, ambiguity_count, (() => {
                  if (first_divergence instanceof Some) {
                    let path$1 = first_divergence[0];
                    return path$1;
                  } else {
                    return List$Empty$const;
                  }
                })(), items));
              });
            });
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
    return new Error2("Comparison is not valid API v2 data. Validate every trace and compare again.");
  }
}
function run2(paths) {
  return from2((dispatch) => {
    return requestCompare((() => {
      let _pipe = object2(prepend(["paths", array2(paths, string3)], List$Empty$const));
      return to_string2(_pipe);
    })(), (body) => {
      let $ = decode_report(body);
      if ($ instanceof Ok) {
        let report = $[0];
        return dispatch(new CompareLoaded(report));
      } else {
        let reason = $[0];
        return dispatch(new CompareFailed(reason));
      }
    }, (reason) => {
      return dispatch(new CompareFailed(reason));
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/graph_control_ffi.mjs
function fetchGraph(onSuccess, onError) {
  fetch("/api/v2/sessions/current/graph", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      throw new Error(apiError(body, response.status, "graph request failed"));
    }
    onSuccess(body);
  }).catch((error) => onError(String(error?.message ?? error)));
}

// build/dev/javascript/beamtrace_web/beamtrace_web/graph_control.mjs
class GraphPayload extends CustomType {
  constructor(edges, boundaries) {
    super();
    this.edges = edges;
    this.boundaries = boundaries;
  }
}
function edge_kind_decoder() {
  return field("kind", string2, (kind) => {
    return success(kind);
  });
}
function boundary_decoder() {
  return field("event_id", string2, (event_id) => {
    return field("kind", edge_kind_decoder(), (kind) => {
      return field("reason", string2, (reason) => {
        return success(new GraphBoundary(event_id, kind, reason));
      });
    });
  });
}
function edge_decoder() {
  return field("from", string2, (from) => {
    return field("to", string2, (to) => {
      return field("kind", edge_kind_decoder(), (kind) => {
        return field("evidence", evidence_decoder(), (evidence) => {
          return success(new GraphEdge(from, to, kind, evidence));
        });
      });
    });
  });
}
function graph_decoder() {
  return field("schema_version", int2, (_) => {
    return field("edges", list2(edge_decoder()), (edges) => {
      return field("boundaries", list2(boundary_decoder()), (boundaries) => {
        return success(new GraphPayload(edges, boundaries));
      });
    });
  });
}
function decode_graph(source) {
  let $ = parse(source, graph_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    return new Error2("Causal graph is not valid API v2 data. Validate the archive and reload it.");
  }
}
function load() {
  return from2((dispatch) => {
    return fetchGraph((body) => {
      let $ = decode_graph(body);
      if ($ instanceof Ok) {
        let graph = $[0];
        return dispatch(new GraphLoaded(graph.edges, graph.boundaries));
      } else {
        let reason = $[0];
        return dispatch(new GraphLoadFailed(reason));
      }
    }, (reason) => {
      return dispatch(new GraphLoadFailed(reason));
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/launch_context_ffi.mjs
function consumeComparePaths() {
  const url = new URL(window.location.href);
  const value = url.searchParams.get("compare") || "";
  if (url.searchParams.has("compare")) {
    url.searchParams.delete("compare");
    const clean = `${url.pathname}${url.search}${url.hash}`;
    window.history.replaceState(null, "", clean);
  }
  return value;
}

// build/dev/javascript/beamtrace_web/beamtrace_web/launch_context.mjs
function initial_compare_paths() {
  return consumeComparePaths();
}

// build/dev/javascript/beamtrace_web/beamtrace_web/live_control_ffi.mjs
function fetchLive(onSuccess, onError) {
  fetch("/api/v2/live?limit=200", {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      throw new Error(apiError(body, response.status, "live request failed"));
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
function evidence_decoder2() {
  return evidence_decoder();
}
function topology_edge_decoder() {
  return field("from", string2, (from) => {
    return field("to", string2, (to) => {
      return field("evidence", evidence_decoder2(), (evidence) => {
        return success(new TopologyEdge(from, to, evidence));
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
    return field("label", string2, (label) => {
      return field("kind", string2, (kind) => {
        return field("summary", string2, (summary) => {
          return field("evidence", evidence_decoder2(), (evidence) => {
            return success(new LiveFinding(pid, label, kind, summary, evidence));
          });
        });
      });
    });
  });
}
function row_decoder() {
  return field("node", string2, (node) => {
    return field("pid", string2, (pid) => {
      return field("label", string2, (label) => {
        return field("registered_name", string2, (registered_name) => {
          return field("process_label", string2, (process_label) => {
            return field("initial_call", string2, (initial_call) => {
              return field("mailbox_len", int2, (mailbox_len) => {
                return field("memory_bytes", int2, (memory_bytes) => {
                  return field("reductions", int2, (reductions) => {
                    return field("heap_words", int2, (heap_words) => {
                      return field("total_heap_words", int2, (total_heap_words) => {
                        return field("link_count", int2, (link_count) => {
                          return field("status", string2, (status) => {
                            return field("current_function", string2, (current_function) => {
                              return field("links", list2(string2), (links) => {
                                return field("ancestors", list2(string2), (ancestors) => {
                                  return success(new LiveRow(node, pid, label, registered_name, process_label, initial_call, mailbox_len, memory_bytes, reductions, heap_words, total_heap_words, link_count, status, current_function, links, ancestors));
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
        return field("next_offset", int2, (_) => {
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
    return new Error2("Live sample is not valid API v2 data. Check the target and reload Live.");
  }
}
function load2() {
  return from2((dispatch) => {
    return fetchLive((body) => {
      let $ = decode_snapshot(body);
      if ($ instanceof Ok) {
        let snapshot = $[0];
        return dispatch(new LiveLoaded(snapshot));
      } else {
        let reason = $[0];
        return dispatch(new LiveLoadFailed(reason));
      }
    }, (reason) => {
      return dispatch(new LiveLoadFailed(reason));
    });
  });
}
function poll_after2(delay_ms) {
  return from2((dispatch) => {
    return schedule2(delay_ms, () => {
      return dispatch(Msg$PollLive$const);
    });
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page_loader_ffi.mjs
function pageUrl(start, limit, search) {
  const query = new URLSearchParams({
    start: String(start),
    limit: String(limit)
  });
  if (search.trim() !== "") {
    query.set("q", search.trim());
  }
  return `/api/v2/sessions/current/events?${query}`;
}
function fetchPage(start, limit, search, onSuccess, onError) {
  fetch(pageUrl(start, limit, search), {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" }
  }).then(async (response) => {
    const body = await response.text();
    if (!response.ok) {
      throw new Error(apiError(body, response.status, "event page request failed"));
    }
    return body;
  }).then(onSuccess).catch((error) => {
    onError(error instanceof Error ? error.message : "event page request failed");
  });
}

// build/dev/javascript/beamtrace_web/beamtrace_web/page_loader.mjs
function load3(start, limit, query) {
  return from2((dispatch) => {
    return fetchPage(start, limit, query, (body) => {
      let $ = decode3(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch(new PageLoaded(query, page));
      } else {
        let reason = $[0];
        return dispatch(new PageLoadFailed(query, reason));
      }
    }, (reason) => {
      return dispatch(new PageLoadFailed(query, reason));
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
      throw new Error(apiError(body, response.status, "team trace request failed"));
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
  complete2(request2(`/api/v2/traces?${cursorQuery(cursor, 50)}`), onSuccess, onError);
}
function fetchEvents(traceId, cursor, onSuccess, onError) {
  complete2(request2(`/api/v2/traces/${encodeURIComponent(traceId)}/events?${cursorQuery(cursor, 200)}`), onSuccess, onError);
}
function cookie(name) {
  const prefix = `${name}=`;
  for (const part of document.cookie.split(";")) {
    const value = part.trim();
    if (value.startsWith(prefix))
      return decodeURIComponent(value.slice(prefix.length));
  }
  return "";
}
function updateHold(traceId, enabled, onSuccess, onError) {
  const csrf = cookie("beamtrace_csrf");
  complete2(request2(`/api/v2/traces/${encodeURIComponent(traceId)}/hold`, {
    method: enabled ? "POST" : "DELETE",
    headers: { "x-beamtrace-csrf": csrf }
  }), onSuccess, onError);
}

// build/dev/javascript/beamtrace_web/beamtrace_web/team_control.mjs
function mfa_decoder() {
  return field("module", string2, (module) => {
    return field("function", string2, (function$) => {
      return field("arity", int2, (arity) => {
        return success([module, function$, arity]);
      });
    });
  });
}
function trace_decoder() {
  return field("id", string2, (id) => {
    return optional_field("status", "", string2, (_) => {
      return field("node", string2, (node) => {
        return field("mfa", mfa_decoder(), (mfa) => {
          return field("privacy", string2, (privacy) => {
            return field("delivery_status", string2, (delivery_status) => {
              return field("event_count", int2, (event_count) => {
                return field("received_at_ms", int2, (received_at_ms) => {
                  return field("legal_hold", bool, (legal_hold) => {
                    return field("locked", bool, (locked) => {
                      return success(new TeamTrace(id, node, mfa[0], mfa[1], mfa[2], privacy, delivery_status, event_count, received_at_ms, legal_hold, locked));
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
    return new Error2("Team trace list is not valid API v2 data. Refresh or check the server version.");
  }
}
function load_traces(cursor) {
  return from2((dispatch) => {
    return fetchTraces(cursor, (body) => {
      let $ = decode_traces(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch(new TeamTracesLoaded(page));
      } else {
        let reason = $[0];
        return dispatch(new TeamTracesFailed(reason));
      }
    }, (reason) => {
      return dispatch(new TeamTracesFailed(reason));
    });
  });
}
function events_decoder() {
  return field("trace_id", string2, (trace_id) => {
    return field("events", list2(event_decoder()), (events) => {
      return field("next_cursor", optional(string2), (next) => {
        return success(new TeamEventPage(trace_id, events, next));
      });
    });
  });
}
function decode_events(source) {
  let $ = parse(source, events_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    return new Error2("Team event page is not valid API v2 data. Refresh or validate the stored trace.");
  }
}
function load_events(trace_id, cursor) {
  return from2((dispatch) => {
    return fetchEvents(trace_id, cursor, (body) => {
      let $ = decode_events(body);
      if ($ instanceof Ok) {
        let page = $[0];
        return dispatch(new TeamEventsLoaded(page));
      } else {
        let reason = $[0];
        return dispatch(new TeamEventsFailed(trace_id, reason));
      }
    }, (reason) => {
      return dispatch(new TeamEventsFailed(trace_id, reason));
    });
  });
}
function decode_trace(source) {
  let $ = parse(source, trace_decoder());
  if ($ instanceof Ok) {
    return $;
  } else {
    return new Error2("Updated trace metadata is not valid API v2 data. Refresh the trace list.");
  }
}
function set_hold(trace_id, enabled) {
  return from2((dispatch) => {
    return updateHold(trace_id, enabled, (body) => {
      let $ = decode_trace(body);
      if ($ instanceof Ok) {
        let trace = $[0];
        return dispatch(new TraceHoldUpdated(trace));
      } else {
        let reason = $[0];
        return dispatch(new TraceHoldFailed(reason));
      }
    }, (reason) => {
      return dispatch(new TraceHoldFailed(reason));
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
  return on("input", subfield(prepend("target", prepend("value", List$Empty$const)), string2, (value) => {
    return success(message(value));
  }));
}

// build/dev/javascript/beamtrace_web/beamtrace_web/time_format.mjs
function pad(value, width) {
  return pad_start(to_string(value), width, "0");
}
function scaled(magnitude, unit) {
  let thousandths = divideInt(magnitude * 1000 + globalThis.Math.trunc(unit / 2), unit);
  return to_string(globalThis.Math.trunc(thousandths / 1000)) + "." + pad(thousandths % 1000, 3);
}
function duration_label(ns) {
  let magnitude = absolute_value(ns);
  let _block;
  let $ = ns < 0;
  if ($) {
    _block = "-";
  } else {
    _block = "";
  }
  let sign = _block;
  return sign + (() => {
    if (magnitude < 1000) {
      return to_string(magnitude) + " ns";
    } else if (magnitude < 1e6) {
      return scaled(magnitude, 1000) + " µs";
    } else if (magnitude < 1e9) {
      return scaled(magnitude, 1e6) + " ms";
    } else {
      return scaled(magnitude, 1e9) + " s";
    }
  })();
}
function offset_label(ns) {
  let $ = ns < 0;
  if ($) {
    return duration_label(ns);
  } else {
    return "+" + duration_label(ns);
  }
}
function raw_label(estimate) {
  if (estimate instanceof ExactTime) {
    let value = estimate.value_ns;
    return value + " ns exact";
  } else if (estimate instanceof EstimatedTime) {
    let value = estimate.value_ns;
    let lower = estimate.lower_ns;
    let upper = estimate.upper_ns;
    return value + " ns estimated [" + lower + ", " + upper + "]";
  } else {
    let reason = estimate.reason;
    return "time unavailable · " + reason;
  }
}
function parse_or_zero(text) {
  let $ = parse_int(text);
  if ($ instanceof Ok) {
    let value = $[0];
    return value;
  } else {
    return 0;
  }
}
function split_ns(value) {
  let digits = graphemes(value);
  let $ = !(digits instanceof Empty) && all(digits, (digit) => {
    return contains_string("0123456789", digit);
  });
  if ($) {
    let length2 = length(digits);
    let seconds_digits = max(length2 - 9, 0);
    let _block;
    let _pipe = digits;
    let _pipe$1 = take(_pipe, seconds_digits);
    let _pipe$2 = concat2(_pipe$1);
    _block = parse_or_zero(_pipe$2);
    let seconds = _block;
    let _block$1;
    let _pipe$3 = digits;
    let _pipe$4 = drop(_pipe$3, seconds_digits);
    let _pipe$5 = concat2(_pipe$4);
    _block$1 = parse_or_zero(_pipe$5);
    let nanos = _block$1;
    return new Ok([seconds, nanos]);
  } else {
    return new Error2(undefined);
  }
}
function half_width(lower, upper) {
  let $ = split_ns(lower);
  let $1 = split_ns(upper);
  if ($ instanceof Ok && $1 instanceof Ok) {
    let lower_s = $[0][0];
    let lower_ns = $[0][1];
    let upper_s = $1[0][0];
    let upper_ns = $1[0][1];
    let seconds = upper_s - lower_s;
    let width = seconds * 1e9 + upper_ns - lower_ns;
    let $2 = seconds > 9000000 || width < 0;
    if ($2) {
      return new Error2(undefined);
    } else {
      return new Ok(globalThis.Math.trunc(width / 2));
    }
  } else {
    return new Error2(undefined);
  }
}
function civil_from_days(days) {
  let z = days + 719468;
  let era = globalThis.Math.trunc(z / 146097);
  let doe = z - era * 146097;
  let yoe = globalThis.Math.trunc((doe - globalThis.Math.trunc(doe / 1460) + globalThis.Math.trunc(doe / 36524) - globalThis.Math.trunc(doe / 146096)) / 365);
  let y = yoe + era * 400;
  let doy = doe - (365 * yoe + globalThis.Math.trunc(yoe / 4) - globalThis.Math.trunc(yoe / 100));
  let mp = globalThis.Math.trunc((5 * doy + 2) / 153);
  let d = doy - globalThis.Math.trunc((153 * mp + 2) / 5) + 1;
  let _block;
  let $ = mp < 10;
  if ($) {
    _block = mp + 3;
  } else {
    _block = mp - 9;
  }
  let m = _block;
  let _block$1;
  let $1 = m <= 2;
  if ($1) {
    _block$1 = y + 1;
  } else {
    _block$1 = y;
  }
  let year = _block$1;
  return [year, m, d];
}
function civil(value) {
  let $ = split_ns(value);
  if ($ instanceof Ok) {
    let seconds = $[0][0];
    let nanos = $[0][1];
    let days = globalThis.Math.trunc(seconds / 86400);
    let remainder = seconds % 86400;
    let $1 = civil_from_days(days);
    let year = $1[0];
    let month = $1[1];
    let day = $1[2];
    return new Ok(pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + " " + pad(globalThis.Math.trunc(remainder / 3600), 2) + ":" + pad(globalThis.Math.trunc(remainder % 3600 / 60), 2) + ":" + pad(remainder % 60, 2) + "." + pad(globalThis.Math.trunc(nanos / 1000), 6) + " UTC");
  } else {
    return $;
  }
}
function instant_label(estimate) {
  if (estimate instanceof ExactTime) {
    let value = estimate.value_ns;
    let $ = civil(value);
    if ($ instanceof Ok) {
      let text = $[0];
      return text + " · exact";
    } else {
      return raw_label(estimate);
    }
  } else if (estimate instanceof EstimatedTime) {
    let value = estimate.value_ns;
    let lower = estimate.lower_ns;
    let upper = estimate.upper_ns;
    let $ = civil(value);
    let $1 = half_width(lower, upper);
    if ($ instanceof Ok && $1 instanceof Ok) {
      let text = $[0];
      let width = $1[0];
      return text + " ±" + duration_label(width) + " · estimated";
    } else {
      return raw_label(estimate);
    }
  } else {
    let reason = estimate.reason;
    return "time unavailable · " + reason;
  }
}
function delta_label(estimate) {
  if (estimate instanceof ExactTime) {
    let value = estimate.value_ns;
    let $ = parse_int(value);
    if ($ instanceof Ok) {
      let ns = $[0];
      return offset_label(ns) + " · exact";
    } else {
      return raw_label(estimate);
    }
  } else if (estimate instanceof EstimatedTime) {
    let value = estimate.value_ns;
    let lower = estimate.lower_ns;
    let upper = estimate.upper_ns;
    let $ = parse_int(value);
    let $1 = half_width(lower, upper);
    if ($ instanceof Ok && $1 instanceof Ok) {
      let ns = $[0];
      let width = $1[0];
      return offset_label(ns) + " ±" + duration_label(width) + " · estimated";
    } else {
      return raw_label(estimate);
    }
  } else {
    let reason = estimate.reason;
    return "time unavailable · " + reason;
  }
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
function zoom_label(value) {
  if (value === 0.25) {
    return "25%";
  } else if (value === 0.5) {
    return "50%";
  } else if (value === 1) {
    return "100%";
  } else if (value === 2) {
    return "200%";
  } else if (value === 4) {
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
    let added = fold2(report.reports, 0, (total, run) => {
      return total + run.added;
    });
    let removed = fold2(report.reports, 0, (total, run) => {
      return total + run.removed;
    });
    let changed = fold2(report.reports, 0, (total, run) => {
      return total + run.changed;
    });
    let ambiguous = fold2(report.reports, 0, (total, run) => {
      return total + run.ambiguity_count;
    });
    return to_string(report.run_count) + " runs · +" + to_string(added) + " −" + to_string(removed) + " ~" + to_string(changed) + " ambiguous " + to_string(ambiguous);
  } else {
    return "No comparison loaded";
  }
}
function definition(label, value) {
  return div(prepend(class$("definition"), List$Empty$const), prepend(span(List$Empty$const, prepend(text3(label), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(value), List$Empty$const)), List$Empty$const)));
}
function panel_heading(title, index) {
  return div(prepend(class$("panel-heading"), List$Empty$const), prepend(span(List$Empty$const, prepend(text3(index), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(title), List$Empty$const)), List$Empty$const)));
}
function event_boundary_label(model, event_id) {
  let _block;
  let _pipe = model.graph_boundaries;
  let _pipe$1 = filter(_pipe, (boundary) => {
    return boundary.event_id === event_id;
  });
  _block = map2(_pipe$1, (boundary) => {
    return boundary.kind + " · " + boundary.reason;
  });
  let boundaries = _block;
  if (boundaries instanceof Empty) {
    return "None observed";
  } else {
    return join(boundaries, "; ");
  }
}
function evidence_label(evidence) {
  if (evidence instanceof Exact) {
    return "Exact";
  } else {
    let method = evidence.method;
    let reason = evidence.reason;
    return "Inferred · " + method + " · " + reason;
  }
}
function compare_inspector(model) {
  return aside(prepend(class$("inspector panel"), prepend(aria_label("Compare inspector"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Compare inspector", "03"), prepend((() => {
    let $ = model.compare_report;
    if ($ instanceof Some) {
      let report = $[0];
      return div(prepend(class$("inspector-content"), List$Empty$const), prepend(definition("Baseline", report.baseline), prepend(definition("Runs", to_string(report.run_count)), prepend(definition("Aligned candidates", to_string(length(report.reports))), prepend(definition("Branch signatures", to_string(length(report.statistics))), prepend(definition("Normalization", "logical actor · term shape · root-relative time"), List$Empty$const))))));
    } else {
      return div(prepend(class$("empty-state"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("Run a comparison to inspect branch statistics."), List$Empty$const)), List$Empty$const));
    }
  })(), List$Empty$const)));
}
function list_text(items) {
  if (items instanceof Empty) {
    return "None observed";
  } else {
    return join(items, ", ");
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
    let outcome = phase.outcome_summary;
    return "Sealed · " + to_string(count) + " events · " + outcome;
  } else {
    let reason = phase.reason;
    return "Failed · " + reason;
  }
}
function capture_navigator(model) {
  return nav(prepend(class$("navigator panel"), prepend(aria_label("Session navigator"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Nodes & sessions", "01"), prepend(section(List$Empty$const, prepend(h2(List$Empty$const, prepend(text3("Current target"), List$Empty$const)), prepend(div(prepend(class$("node-card selected"), List$Empty$const), prepend(span(prepend(class$("status-dot healthy"), List$Empty$const), List$Empty$const), prepend(span(List$Empty$const, prepend(strong(List$Empty$const, prepend(text3("Attached BEAM session"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(capture_phase_label(model.capture_phase)), List$Empty$const)), List$Empty$const))), List$Empty$const))), List$Empty$const))), prepend(section(List$Empty$const, prepend(h2(List$Empty$const, prepend(text3("Capture session"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3((() => {
    let $ = model.capture_phase;
    let $1 = trim(model.trigger_input);
    if ($ instanceof Ready) {
      if ($1 === "") {
        let count = $.event_count;
        return "Sealed archive · " + to_string(count) + " events";
      } else {
        return $1;
      }
    } else if ($1 === "") {
      return "No trigger armed";
    } else {
      return $1;
    }
  })()), List$Empty$const)), List$Empty$const))), List$Empty$const))));
}
function mode_title(mode) {
  if (mode instanceof Capture) {
    return "Bounded causal observation";
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
function time_estimate_label(estimate) {
  return delta_label(estimate);
}
function time_summary_label(summary) {
  return time_estimate_label(summary.estimate) + " · " + to_string(summary.valid_samples) + " valid / " + to_string(summary.missing_samples) + " missing";
}
function statistics_table(rows) {
  return div(prepend(class$("event-table-wrap compare-statistics"), List$Empty$const), prepend(table(prepend(aria_label("Multi-run branch statistics"), List$Empty$const), prepend(thead(List$Empty$const, prepend(tr(List$Empty$const, prepend(th(List$Empty$const, prepend(text3("Logical branch signature"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Latency"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Occurrence"), List$Empty$const)), List$Empty$const)))), List$Empty$const)), prepend(tbody(List$Empty$const, map2(rows, (row) => {
    return tr(List$Empty$const, prepend(td(List$Empty$const, prepend(text3(row.signature), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3("p50 " + time_summary_label(row.p50) + " · p95 " + time_summary_label(row.p95)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(to_string(row.occurrences) + "/" + to_string(row.total_runs) + " runs"), List$Empty$const)), List$Empty$const))));
  })), List$Empty$const))), List$Empty$const));
}
function or_dash(value) {
  if (value === "") {
    return "—";
  } else {
    return value;
  }
}
function latency_delta(item) {
  let $ = item.status;
  if ($ === "matched") {
    return time_estimate_label(item.latency_delta);
  } else {
    return "—";
  }
}
function compare_status_class(status) {
  if (status === "added") {
    return "anomalous";
  } else if (status === "removed") {
    return "anomalous";
  } else if (status === "changed") {
    return "anomalous";
  } else {
    return "";
  }
}
function alignment_row(row) {
  return tr(prepend(class$(compare_status_class(row.item.status)), List$Empty$const), prepend(td(List$Empty$const, prepend(text3(row.path), List$Empty$const)), prepend(td(List$Empty$const, prepend(span(prepend(class$("kind-pill"), List$Empty$const), prepend(text3(row.item.status), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(or_dash(row.item.left_id)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(or_dash(row.item.right_id)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(latency_delta(row.item)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(or_dash(row.item.reason)), List$Empty$const)), List$Empty$const)))))));
}
function alignment_table(rows) {
  return div(prepend(class$("event-table-wrap compare-alignment"), List$Empty$const), prepend(table(prepend(aria_label("Accessible trace alignment table"), List$Empty$const), prepend(thead(List$Empty$const, prepend(tr(List$Empty$const, prepend(th(List$Empty$const, prepend(text3("Candidate"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Status"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Baseline event"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Candidate event"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Latency Δ"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Reason"), List$Empty$const)), List$Empty$const))))))), List$Empty$const)), prepend(tbody(List$Empty$const, map2(rows, alignment_row)), List$Empty$const))), List$Empty$const));
}
function first_divergence_path(loop$reports) {
  while (true) {
    let reports = loop$reports;
    if (reports instanceof Empty) {
      return reports;
    } else {
      let run = reports.head;
      let rest = reports.tail;
      let $ = run.first_divergence_path;
      if ($ instanceof Empty) {
        loop$reports = rest;
      } else {
        return $;
      }
    }
  }
}
function divergence_summary(reports) {
  let path = first_divergence_path(reports);
  return div(prepend(class$("divergence-summary"), prepend(aria_label("First divergence causal path"), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3("First divergence"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3((() => {
    if (path instanceof Empty) {
      return " · none established";
    } else {
      return " · " + join(path, " → ");
    }
  })()), List$Empty$const)), List$Empty$const)));
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
function capture_recovery(model) {
  let $ = model.capture_phase;
  if ($ instanceof Unavailable) {
    return "Attach a node with beamtrace attach, then search for an MFA.";
  } else if ($ instanceof Idle && model.capture_notice === "") {
    return "Search for the operation's MFA, then arm one bounded capture.";
  } else if ($ instanceof Ready && model.capture_notice === "") {
    let outcome = $.outcome_summary;
    let $1 = contains_string(outcome, "integrity issues present");
    if ($1) {
      return outcome + ". Validate the archive and retry capture after correcting the named node or delivery problem.";
    } else {
      return outcome + ". Choose a save path to retain this archive.";
    }
  } else if ($ instanceof Failed) {
    let $1 = $.reason;
    if ($1 === "system_tracer_occupied") {
      return "Another tracer owns the VM. Stop that tracer or switch to Live sampling.";
    } else if ($1 === "trigger_required") {
      return "Enter Module:function/arity or choose an MFA search result.";
    } else {
      return model.capture_notice + " Check the target connection, then arm again.";
    }
  } else {
    return model.capture_notice;
  }
}
function capture_ready(phase) {
  if (phase instanceof Ready) {
    return true;
  } else {
    return false;
  }
}
function preset_option(value2, label) {
  return option(prepend(value(value2), List$Empty$const), label);
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
function theme_label(theme) {
  if (theme instanceof SystemTheme) {
    return "System";
  } else if (theme instanceof LightTheme) {
    return "Light";
  } else {
    return "Dark";
  }
}
function palette2(model) {
  let $ = model.palette_open;
  if ($) {
    return dialog(prepend(class$("command-palette"), prepend(attribute2("open", ""), prepend(aria_modal(true), prepend(aria_label("Command palette"), List$Empty$const)))), prepend(div(prepend(class$("palette-heading"), List$Empty$const), prepend(strong(List$Empty$const, prepend(text3("Command palette"), List$Empty$const)), prepend(button(prepend(on_click(Msg$UserClosedPalette$const), List$Empty$const), prepend(text3("Close"), List$Empty$const)), List$Empty$const))), prepend(button(prepend(autofocus(true), prepend(on_click(Msg$UserChoseCaptureAction$const), List$Empty$const)), prepend(text3("Arm capture trigger"), List$Empty$const)), prepend(button(prepend(on_click(new UserSelectedMode(Mode$Live$const)), List$Empty$const), prepend(text3("Open live anomalies"), List$Empty$const)), prepend(button(prepend(on_click(new UserSelectedMode(Mode$Compare$const)), List$Empty$const), prepend(text3("Compare saved traces"), List$Empty$const)), prepend(button(prepend(on_click(new UserSelectedMode(Mode$Team$const)), List$Empty$const), prepend(text3("Open Team trace library"), List$Empty$const)), List$Empty$const))))));
  } else {
    return div(List$Empty$const, List$Empty$const);
  }
}
function event_minimap(model) {
  let previous = max(model.viewport_start - model.viewport_size, 0);
  let last_start = max(model.total_events - model.viewport_size, 0);
  let next = min(model.viewport_start + model.viewport_size, last_start);
  let shown_end = min(model.viewport_start + model.viewport_size, model.total_events);
  return footer(prepend(class$("minimap"), prepend(aria_label("Time minimap"), List$Empty$const)), prepend(button(prepend(class$("quiet-button"), prepend(disabled(model.viewport_start === 0 || model.loading), prepend(on_click(new ViewportChanged(previous, model.viewport_size)), List$Empty$const))), prepend(text3("Previous"), List$Empty$const)), prepend(div(prepend(class$("minimap-track"), List$Empty$const), prepend(div(prepend(class$("minimap-window"), prepend(attribute2("data-start", to_string(model.viewport_start)), List$Empty$const)), List$Empty$const), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(to_string(model.viewport_start + 1) + "–" + to_string(shown_end) + " / " + to_string(model.total_events)), List$Empty$const)), prepend(button(prepend(class$("quiet-button"), prepend(disabled(shown_end >= model.total_events || model.loading), prepend(on_click(new ViewportChanged(next, model.viewport_size)), List$Empty$const))), prepend(text3("Next"), List$Empty$const)), prepend(span(prepend(class$("zoom-label"), List$Empty$const), prepend(text3("Zoom " + zoom_label(model.zoom)), List$Empty$const)), List$Empty$const))))));
}
function minimap(model) {
  let $ = model.mode;
  if ($ instanceof Capture) {
    return event_minimap(model);
  } else if ($ instanceof Live) {
    return footer(prepend(class$("minimap"), prepend(aria_label("Live sampling status"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3("Generation " + to_string(model.live_generation) + " · sampled at " + to_string(model.live_sampled_at_ms) + " ms"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(to_string(length(model.live_findings)) + " active inferred anomalies"), List$Empty$const)), List$Empty$const)));
  } else if ($ instanceof Compare) {
    return footer(prepend(class$("minimap"), prepend(aria_label("Compare summary"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(compare_summary(model)), List$Empty$const)), List$Empty$const));
  } else {
    return footer(prepend(class$("minimap"), prepend(aria_label("Team trace status"), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(team_status(model)), List$Empty$const)), List$Empty$const));
  }
}
function team_inspector(model) {
  return aside(prepend(class$("inspector panel"), prepend(aria_label("Team trace inspector"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Trace policy", "03"), prepend((() => {
    let $ = selected_team_trace(model);
    if ($ instanceof Some) {
      let trace = $[0];
      return div(List$Empty$const, prepend(definition("Trace", trace.id), prepend(definition("Delivery status", trace.delivery_status), prepend(definition("Privacy", (() => {
        let $1 = trace.locked;
        if ($1) {
          return trace.privacy + " · locked";
        } else {
          return trace.privacy;
        }
      })()), prepend(definition("Legal hold", (() => {
        let $1 = trace.legal_hold;
        if ($1) {
          return "enabled";
        } else {
          return "disabled";
        }
      })()), prepend(button(prepend(class$("quiet-button"), prepend(on_click(new UserRequestedTraceHold(trace.id, !trace.legal_hold)), List$Empty$const)), prepend(text3((() => {
        let $1 = trace.legal_hold;
        if ($1) {
          return "Release legal hold";
        } else {
          return "Place legal hold";
        }
      })()), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3("Legal hold changes require an Admin role and are CSRF-protected and audited."), List$Empty$const)), List$Empty$const)))))));
    } else {
      return p(List$Empty$const, prepend(text3("Select a trace"), List$Empty$const));
    }
  })(), List$Empty$const)));
}
function inspector_event(model, row) {
  let bookmarked = contains(model.bookmarks, row.id);
  return div(prepend(class$("inspector-content"), List$Empty$const), prepend(div(prepend(class$("inspector-title"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3(row.kind), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3(row.actor), List$Empty$const)), List$Empty$const))), prepend(button(prepend(class$("bookmark-button"), prepend(aria_pressed((() => {
    if (bookmarked) {
      return "true";
    } else {
      return "false";
    }
  })()), prepend(on_click(new UserToggledBookmark(row.id)), List$Empty$const))), prepend(text3((() => {
    if (bookmarked) {
      return "★";
    } else {
      return "☆";
    }
  })()), List$Empty$const)), List$Empty$const))), prepend(definition("Event ID", row.id), prepend(definition("Evidence", evidence_label(row.evidence)), prepend(definition("Calibrated time", instant_label(row.time)), prepend(definition("Raw calibrated bounds", raw_label(row.time)), prepend(definition("Node-local offset", offset_label(row.timestamp_ns) + " (" + to_string(row.timestamp_ns) + " ns, not cross-node comparable)"), prepend(definition("Duration", duration_label(row.duration_ns) + " (" + to_string(row.duration_ns) + " ns)"), prepend(definition("Boundary", event_boundary_label(model, row.id)), prepend(definition("Source", "Unavailable in this event metadata"), prepend(label(prepend(class$("annotation"), List$Empty$const), prepend(span(List$Empty$const, prepend(text3("Annotation"), List$Empty$const)), prepend(textarea(prepend(placeholder("Record what this event explains…"), prepend(value(model.annotation), prepend(on_input((var0) => {
    return new UserChangedAnnotation(var0);
  }), List$Empty$const))), model.annotation), List$Empty$const))), List$Empty$const)))))))))));
}
function event_inspector(model) {
  return aside(prepend(class$("inspector panel"), prepend(aria_label("Event inspector"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Event inspector", "03"), prepend((() => {
    let $ = selected_event(model);
    if ($ instanceof Some) {
      let row = $[0];
      return inspector_event(model, row);
    } else {
      return div(prepend(class$("empty-state"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("Select an event to inspect exact evidence."), List$Empty$const)), List$Empty$const));
    }
  })(), List$Empty$const)));
}
function live_inspector_process(model, row) {
  let findings = live_findings_for(model, row.pid);
  return div(prepend(class$("inspector-content"), List$Empty$const), prepend(div(prepend(class$("inspector-title"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3(row.status), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3(row.label), List$Empty$const)), List$Empty$const))), List$Empty$const)), prepend(definition("PID", row.pid + " @ " + row.node), prepend(definition("Initial call", row.initial_call), prepend(definition("Current function", row.current_function), prepend(definition("Mailbox", to_string(row.mailbox_len)), prepend(definition("Memory", to_string(row.memory_bytes) + " bytes"), prepend(definition("Heap", to_string(row.total_heap_words) + " words"), prepend(definition("Ancestors", list_text(row.ancestors)), prepend(definition("Links", list_text(row.links)), prepend(section(prepend(class$("finding-list"), List$Empty$const), prepend(h3(List$Empty$const, prepend(text3("Anomaly evidence"), List$Empty$const)), prepend((() => {
    if (findings instanceof Empty) {
      return p(List$Empty$const, prepend(text3("No anomaly crossed its hysteresis threshold."), List$Empty$const));
    } else {
      return ul(List$Empty$const, map2(findings, (finding) => {
        return li(List$Empty$const, prepend(strong(List$Empty$const, prepend(text3(finding.kind), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(finding.summary), List$Empty$const)), prepend(span(List$Empty$const, prepend(text3(evidence_label(finding.evidence)), List$Empty$const)), List$Empty$const))));
      }));
    }
  })(), List$Empty$const))), List$Empty$const)))))))))));
}
function live_inspector(model) {
  return aside(prepend(class$("inspector panel"), prepend(aria_label("Process inspector"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Process inspector", "03"), prepend((() => {
    let $ = selected_live_process(model);
    if ($ instanceof Ok) {
      let row = $[0];
      return live_inspector_process(model, row);
    } else {
      return div(prepend(class$("empty-state"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("Select a process to inspect sampled metadata and evidence."), List$Empty$const)), List$Empty$const));
    }
  })(), List$Empty$const)));
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
function team_navigator(model) {
  return nav(prepend(class$("navigator panel"), prepend(aria_label("Team trace navigator"), prepend(attribute2("tabindex", "0"), List$Empty$const))), prepend(panel_heading("Team trace library", "01"), prepend(section(List$Empty$const, prepend(h2(List$Empty$const, prepend(text3("Retention-safe sessions"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3(to_string(length(model.team_traces)) + " traces loaded · max 100"), List$Empty$const)), prepend(button(prepend(class$("quiet-button"), prepend(disabled(model.team_loading), prepend(on_click(Msg$UserRequestedTeamTraces$const), List$Empty$const))), prepend(text3("Refresh traces"), List$Empty$const)), List$Empty$const)))), prepend(section(List$Empty$const, prepend(h2(List$Empty$const, prepend(text3("Privacy"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3("Raw and unknown trace contents remain locked unless your combined role permits access."), List$Empty$const)), List$Empty$const))), List$Empty$const))));
}
function session_navigator(model) {
  let $ = model.mode;
  if ($ instanceof Team) {
    return team_navigator(model);
  } else {
    return capture_navigator(model);
  }
}
function mobile_drawers(model) {
  return div(prepend(class$("mobile-drawers"), List$Empty$const), prepend(details(prepend(class$("mobile-session-drawer"), List$Empty$const), prepend(summary(List$Empty$const, prepend(text3("Session navigator"), List$Empty$const)), prepend(session_navigator(model), List$Empty$const))), prepend(details(prepend(class$("mobile-inspector-drawer"), List$Empty$const), prepend(summary(List$Empty$const, prepend(text3("Inspector"), List$Empty$const)), prepend(inspector(model), List$Empty$const))), List$Empty$const)));
}
function event_row2(row) {
  return tr(prepend(class$((() => {
    let $ = row.anomalous;
    if ($) {
      return "anomalous";
    } else {
      return "";
    }
  })()), prepend(on_click(new UserSelectedEvent(row.id)), List$Empty$const)), prepend(td(List$Empty$const, prepend(button(prepend(class$("event-link"), List$Empty$const), prepend(text3(row.id), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(row.actor), List$Empty$const)), prepend(td(List$Empty$const, prepend(span(prepend(class$("kind-pill"), List$Empty$const), prepend(text3(row.kind), List$Empty$const)), List$Empty$const)), prepend(td(prepend(title(raw_label(row.time)), List$Empty$const), prepend(text3(offset_label(row.timestamp_ns) + " · " + instant_label(row.time)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(evidence_label(row.evidence)), List$Empty$const)), List$Empty$const))))));
}
function event_table(rows, empty_reason) {
  return div(prepend(class$("event-table-wrap"), List$Empty$const), prepend(table(prepend(aria_label("Accessible causal event table"), List$Empty$const), prepend(thead(List$Empty$const, prepend(tr(List$Empty$const, prepend(th(List$Empty$const, prepend(text3("Event"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Actor"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Kind"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Time"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Evidence"), List$Empty$const)), List$Empty$const)))))), List$Empty$const)), prepend(tbody(List$Empty$const, (() => {
    if (rows instanceof Empty) {
      return prepend(tr(prepend(class$("empty-state"), List$Empty$const), prepend(td(prepend(attribute2("colspan", "5"), List$Empty$const), prepend(text3(empty_reason), List$Empty$const)), List$Empty$const)), List$Empty$const);
    } else {
      return map2(rows, event_row2);
    }
  })()), List$Empty$const))), List$Empty$const));
}
function team_event_section(model) {
  let $ = selected_team_trace(model);
  if ($ instanceof Some) {
    let trace = $[0];
    if (trace.locked) {
      return div(prepend(class$("empty-state locked-trace"), List$Empty$const), prepend(h3(List$Empty$const, prepend(text3("Trace contents locked"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3("This page does not request or render raw payloads without ViewRawTrace permission."), List$Empty$const)), List$Empty$const)));
    } else {
      let trace$1 = $[0];
      return section(prepend(class$("team-events"), List$Empty$const), prepend(h3(List$Empty$const, prepend(text3("Events · " + trace$1.id), List$Empty$const)), prepend((() => {
        let $1 = model.team_events_error;
        if ($1 instanceof Some) {
          let reason = $1[0];
          return p(prepend(role("alert"), List$Empty$const), prepend(text3(reason), List$Empty$const));
        } else {
          return event_table(model.team_events, (() => {
            let $2 = model.team_events_loading;
            if ($2) {
              return "Loading trace events…";
            } else {
              return "This trace page has no events";
            }
          })());
        }
      })(), prepend((() => {
        let $1 = model.team_events_next_cursor;
        if ($1 instanceof Some) {
          return button(prepend(class$("quiet-button"), prepend(disabled(model.team_events_loading), prepend(on_click(Msg$UserRequestedMoreTeamEvents$const), List$Empty$const))), prepend(text3("Load more events"), List$Empty$const));
        } else {
          return div(List$Empty$const, List$Empty$const);
        }
      })(), List$Empty$const))));
    }
  } else {
    return div(prepend(class$("empty-state"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("Select a trace to inspect its bounded event page."), List$Empty$const)), List$Empty$const));
  }
}
function team_trace_row(model, trace) {
  return tr(prepend(class$((() => {
    let $ = trace.locked;
    if ($) {
      return "locked";
    } else {
      return "";
    }
  })()), List$Empty$const), prepend(td(List$Empty$const, prepend(button(prepend(class$("compare-selector"), prepend(aria_pressed((() => {
    let $ = contains(model.selected_team_trace_ids, trace.id);
    if ($) {
      return "true";
    } else {
      return "false";
    }
  })()), prepend(aria_label("Select " + trace.id + " for comparison"), prepend(on_click(new UserToggledTeamCompare(trace.id)), List$Empty$const)))), prepend(text3((() => {
    let $ = contains(model.selected_team_trace_ids, trace.id);
    if ($) {
      return "Selected";
    } else {
      return "Select";
    }
  })()), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(button(prepend(class$("event-link"), prepend(on_click(new UserSelectedTeamTrace(trace.id)), List$Empty$const)), prepend(text3(trace.id), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(span(prepend(class$("kind-pill"), List$Empty$const), prepend(text3(trace.delivery_status), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(trace.node + " · " + trace.module + ":" + trace.function + "/" + to_string(trace.arity)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(trace.privacy), prepend((() => {
    let $ = trace.locked;
    if ($) {
      return span(prepend(class$("locked-badge"), prepend(aria_label("Content locked"), List$Empty$const)), prepend(text3(" Locked"), List$Empty$const));
    } else {
      return span(List$Empty$const, List$Empty$const);
    }
  })(), List$Empty$const))), prepend(td(List$Empty$const, prepend(text3(to_string(trace.event_count)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(to_string(trace.received_at_ms) + " ms"), List$Empty$const)), List$Empty$const))))))));
}
function team_trace_table(model) {
  let $ = model.team_traces;
  if ($ instanceof Empty) {
    return div(prepend(class$("empty-state"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("No team traces are available."), List$Empty$const)), List$Empty$const));
  } else {
    let traces = $;
    return div(prepend(class$("event-table-wrap team-trace-table"), List$Empty$const), prepend(table(prepend(aria_label("Team traces"), List$Empty$const), prepend(thead(List$Empty$const, prepend(tr(List$Empty$const, prepend(th(List$Empty$const, prepend(text3("Compare"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Trace"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Status"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Node / MFA"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Privacy"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Events"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Received"), List$Empty$const)), List$Empty$const)))))))), List$Empty$const)), prepend(tbody(List$Empty$const, map2(traces, (trace) => {
      return team_trace_row(model, trace);
    })), List$Empty$const))), List$Empty$const));
  }
}
function team_compare_bar(model) {
  let count = length(model.selected_team_trace_ids);
  return div(prepend(class$("team-compare-bar"), List$Empty$const), prepend(span(prepend(aria_live("polite"), List$Empty$const), prepend(text3(to_string(count) + " of 20 selected for comparison"), List$Empty$const)), prepend(button(prepend(class$("quiet-button"), prepend(disabled(count < 2 || count > 20), prepend(on_click(Msg$UserRequestedTeamCompare$const), List$Empty$const))), prepend(text3("Compare selected traces"), List$Empty$const)), List$Empty$const)));
}
function team_workspace(model) {
  return section(prepend(class$("causal panel team-traces-panel"), prepend(aria_label("Team trace library"), List$Empty$const)), prepend(div(prepend(class$("panel-toolbar"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3("team"), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3("Session-scoped traces"), List$Empty$const)), List$Empty$const))), prepend(span(prepend(class$("window-count"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3(team_status(model)), List$Empty$const)), List$Empty$const))), prepend((() => {
    let $ = model.team_error;
    if ($ instanceof Some) {
      let reason = $[0];
      return p(prepend(class$("error-state"), prepend(role("alert"), List$Empty$const)), prepend(text3(reason), List$Empty$const));
    } else {
      return div(List$Empty$const, List$Empty$const);
    }
  })(), prepend(team_compare_bar(model), prepend(team_trace_table(model), prepend((() => {
    let $ = model.team_next_cursor;
    if ($ instanceof Some) {
      return button(prepend(class$("quiet-button"), prepend(disabled(model.team_loading), prepend(on_click(Msg$UserRequestedMoreTeamTraces$const), List$Empty$const))), prepend(text3("Load more traces"), List$Empty$const));
    } else {
      return div(List$Empty$const, List$Empty$const);
    }
  })(), prepend(team_event_section(model), List$Empty$const)))))));
}
function event_table_empty_reason(model) {
  let $ = model.loading;
  let $1 = remote_query(model);
  if ($) {
    return "Loading event window…";
  } else if ($1 === "") {
    let $2 = !model.show_internal && any(model.events, (row) => {
      return row.internal;
    });
    if ($2) {
      return "No events in this window · Expand OTP noise to show system processes";
    } else {
      return "No events in this window · widen the window or record again";
    }
  } else {
    return "No events match · clear the search";
  }
}
function evidence_overview(model) {
  let $ = fold2(visible_events(model), [0, 0], (counts, row) => {
    let $1 = row.evidence;
    if ($1 instanceof Exact) {
      return [counts[0] + 1, counts[1]];
    } else {
      return [counts[0], counts[1] + 1];
    }
  });
  let exact = $[0];
  let inferred = $[1];
  let _block;
  let $1 = model.capture_phase;
  if ($1 instanceof Arming) {
    _block = "Observation has not ended";
  } else if ($1 instanceof Armed) {
    _block = "Observation has not ended";
  } else if ($1 instanceof Cancelling) {
    _block = "Observation has not ended";
  } else if ($1 instanceof Ready) {
    let summary = $1.outcome_summary;
    _block = summary;
  } else if ($1 instanceof Failed) {
    let reason = $1.reason;
    _block = "Capture failed · " + reason;
  } else {
    _block = "No sealed observation outcome is available";
  }
  let outcome = _block;
  let _block$1;
  let $2 = contains_string(outcome, "delivery verified");
  if ($2) {
    _block$1 = "Verified by final node receipts";
  } else {
    _block$1 = "Not verified; inspect integrity issues before drawing conclusions";
  }
  let delivery = _block$1;
  let _block$2;
  let _pipe = model.events;
  _block$2 = find_map(_pipe, (row) => {
    let $3 = row.evidence;
    if ($3 instanceof Exact) {
      return new Error2(undefined);
    } else {
      let method = $3.method;
      let reason = $3.reason;
      return new Ok(method + " · " + reason);
    }
  });
  let inference_basis = _block$2;
  return section(prepend(class$("evidence-overview"), prepend(aria_label("What this trace establishes and does not establish"), List$Empty$const)), prepend(div(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Observation end"), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(outcome), List$Empty$const)), List$Empty$const))), prepend(div(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Delivery verification"), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(delivery), List$Empty$const)), List$Empty$const))), prepend(div(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Integrity / boundaries"), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(to_string(length(model.graph_boundaries)) + " causal boundaries · " + (() => {
    let $3 = model.graph_error;
    if ($3 instanceof Some) {
      return "graph issue; reload or validate the archive";
    } else {
      return "no graph loader issue";
    }
  })()), List$Empty$const)), List$Empty$const))), prepend(div(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Evidence basis"), List$Empty$const)), prepend(strong(List$Empty$const, prepend(text3(to_string(exact) + " visible Exact · " + to_string(inferred) + " visible Inferred" + (() => {
    if (inference_basis instanceof Ok) {
      let value = inference_basis[0];
      return " · first basis: " + value;
    } else {
      return "";
    }
  })()), List$Empty$const)), List$Empty$const))), prepend(p(List$Empty$const, prepend(text3("Known: recorded ordering and stated inference inputs. Unknown: work outside the observation end, missing delivery, and every marked boundary."), List$Empty$const)), List$Empty$const))))));
}
function event_workspace(model) {
  let visible = visible_events(model);
  let shown_count = length(visible);
  let total_count = model.total_events;
  return section(prepend(class$("causal panel"), prepend(aria_label("Causal timeline"), List$Empty$const)), prepend(div(prepend(class$("panel-toolbar"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3(mode_slug(model.mode)), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3((() => {
    let $ = model.mode;
    let $1 = model.capture_phase;
    if ($ instanceof Capture && $1 instanceof Ready) {
      return "Sealed causal observation";
    } else {
      return mode_title(model.mode);
    }
  })()), List$Empty$const)), List$Empty$const))), prepend(div(prepend(class$("toolbar-actions"), List$Empty$const), prepend(button(prepend(class$("quiet-button"), prepend(aria_pressed((() => {
    let $ = model.show_internal;
    if ($) {
      return "true";
    } else {
      return "false";
    }
  })()), prepend(on_click(Msg$UserToggledInternalNoise$const), List$Empty$const))), prepend(text3((() => {
    let $ = model.show_internal;
    if ($) {
      return "Fold OTP noise";
    } else {
      return "Expand OTP noise";
    }
  })()), List$Empty$const)), prepend(span(prepend(class$("window-count"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3((() => {
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
  })()), List$Empty$const)), List$Empty$const))), List$Empty$const))), prepend(evidence_overview(model), prepend(div(prepend(class$("canvas-frame"), List$Empty$const), prepend(canvas(prepend(id("causal-canvas"), prepend(attribute2("width", "1600"), prepend(attribute2("height", "620"), prepend(aria_hidden(true), List$Empty$const))))), List$Empty$const)), prepend(event_table(visible, event_table_empty_reason(model)), List$Empty$const)))));
}
function compare_workspace(model) {
  let _block;
  let $ = model.compare_report;
  if ($ instanceof Some) {
    let report = $[0];
    let _pipe = report.reports;
    _block = flat_map(_pipe, (run) => {
      return map2(run.items, (item) => {
        return new ComparedItem(run.path, item);
      });
    });
  } else {
    _block = List$Empty$const;
  }
  let items = _block;
  return section(prepend(class$("causal panel compare-panel"), prepend(aria_label("Trace comparison"), List$Empty$const)), prepend(div(prepend(class$("panel-toolbar"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3("compare"), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3("PID-independent causal alignment"), List$Empty$const)), List$Empty$const))), prepend(span(prepend(class$("window-count"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3(compare_summary(model)), List$Empty$const)), List$Empty$const))), prepend((() => {
    let $1 = model.compare_report;
    if ($1 instanceof Some) {
      let report = $1[0];
      return div(prepend(class$("compare-results"), List$Empty$const), prepend(divergence_summary(report.reports), prepend(div(prepend(class$("canvas-frame"), List$Empty$const), prepend(canvas(prepend(id("causal-canvas"), prepend(attribute2("width", "1600"), prepend(attribute2("height", "620"), prepend(aria_hidden(true), List$Empty$const))))), List$Empty$const)), prepend(event_table(visible_events(model), event_table_empty_reason(model)), prepend(alignment_table(items), prepend(statistics_table(report.statistics), List$Empty$const))))));
    } else {
      return div(prepend(class$("empty-state compare-empty"), List$Empty$const), prepend(p(List$Empty$const, prepend(text3("Enter two or more local .beamtrace paths. The first run is the baseline."), List$Empty$const)), List$Empty$const));
    }
  })(), List$Empty$const)));
}
function live_row(model, row) {
  let findings = live_findings_for(model, row.pid);
  return tr(prepend(class$((() => {
    if (findings instanceof Empty) {
      return "";
    } else {
      return "anomalous";
    }
  })()), prepend(on_click(new UserSelectedLiveProcess(row.pid)), List$Empty$const)), prepend(td(List$Empty$const, prepend(button(prepend(class$("event-link"), List$Empty$const), prepend(text3(row.label), List$Empty$const)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(row.pid), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(to_string(row.mailbox_len)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(to_string(row.memory_bytes) + " B"), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(to_string(row.reductions)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(row.status), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(finding_names(findings)), List$Empty$const)), prepend(td(List$Empty$const, prepend(text3(live_evidence_label(findings)), List$Empty$const)), List$Empty$const)))))))));
}
function live_table(model, rows) {
  return div(prepend(class$("event-table-wrap"), List$Empty$const), prepend(table(prepend(aria_label("Accessible live process table"), List$Empty$const), prepend(thead(List$Empty$const, prepend(tr(List$Empty$const, prepend(th(List$Empty$const, prepend(text3("Process"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("PID"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Mailbox"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Memory"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Reductions"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Status"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Anomalies"), List$Empty$const)), prepend(th(List$Empty$const, prepend(text3("Evidence"), List$Empty$const)), List$Empty$const))))))))), List$Empty$const)), prepend(tbody(List$Empty$const, map2(rows, (row) => {
    return live_row(model, row);
  })), List$Empty$const))), List$Empty$const));
}
function live_workspace(model) {
  let rows = filtered_live_rows(model);
  return section(prepend(class$("causal panel"), prepend(aria_label("Live processes"), List$Empty$const)), prepend(div(prepend(class$("panel-toolbar"), List$Empty$const), prepend(div(List$Empty$const, prepend(p(prepend(class$("eyebrow"), List$Empty$const), prepend(text3("live"), List$Empty$const)), prepend(h2(List$Empty$const, prepend(text3("Bounded process sampling"), List$Empty$const)), List$Empty$const))), prepend(div(prepend(class$("toolbar-actions"), List$Empty$const), prepend(span(prepend(class$("window-count"), List$Empty$const), prepend(text3("Topology · supervision " + to_string(length(model.live_supervision)) + " · spawn " + to_string(length(model.live_spawn)) + " · links " + to_string(length(model.live_links))), List$Empty$const)), prepend(span(prepend(class$("window-count"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3(live_status(model, length(rows))), List$Empty$const)), List$Empty$const))), List$Empty$const))), prepend(div(prepend(class$("canvas-frame"), List$Empty$const), prepend(canvas(prepend(id("causal-canvas"), prepend(attribute2("width", "1600"), prepend(attribute2("height", "620"), prepend(aria_hidden(true), List$Empty$const))))), List$Empty$const)), prepend(live_table(model, rows), List$Empty$const))));
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
function mode_button(current, mode, label, shortcut) {
  return button(prepend(class$((() => {
    let $ = isEqual(current, mode);
    if ($) {
      return "mode-button active";
    } else {
      return "mode-button";
    }
  })()), prepend(aria_pressed((() => {
    let $ = isEqual(current, mode);
    if ($) {
      return "true";
    } else {
      return "false";
    }
  })()), prepend(aria_keyshortcuts(shortcut), prepend(on_click(new UserSelectedMode(mode)), List$Empty$const)))), prepend(span(prepend(class$("mode-dot"), List$Empty$const), List$Empty$const), prepend(text3(label), List$Empty$const)));
}
function mobile_mode_navigation(model) {
  return nav(prepend(class$("mobile-mode-navigation"), prepend(aria_label("Mobile workspace mode"), List$Empty$const)), prepend(mode_button(model.mode, Mode$Capture$const, "Capture", "1"), prepend(mode_button(model.mode, Mode$Live$const, "Live", "2"), prepend(mode_button(model.mode, Mode$Compare$const, "Compare", "3"), prepend(mode_button(model.mode, Mode$Team$const, "Team", "4"), List$Empty$const)))));
}
function compare_controls(model) {
  return section(prepend(class$("capture-controls compare-controls"), prepend(aria_label("Compare controls"), List$Empty$const)), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Trace paths · baseline first"), List$Empty$const)), prepend(textarea(prepend(aria_label("Trace paths"), prepend(placeholder(`baseline.beamtrace
candidate.beamtrace
optional-third.beamtrace`), prepend(value(model.compare_paths_input), prepend(on_input((var0) => {
    return new UserChangedComparePaths(var0);
  }), List$Empty$const)))), model.compare_paths_input), List$Empty$const))), prepend(button(prepend(disabled(model.compare_loading), prepend(on_click(Msg$UserRequestedCompare$const), List$Empty$const)), prepend(text3("Run comparison"), List$Empty$const)), prepend(output(prepend(class$("capture-status"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3((() => {
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
  })()), prepend(span(List$Empty$const, prepend(text3((() => {
    let $ = model.compare_error;
    if ($ instanceof Some) {
      let reason = $[0];
      return reason;
    } else {
      return "PID and clock origins are excluded from alignment";
    }
  })()), List$Empty$const)), List$Empty$const))), List$Empty$const))));
}
function capture_save_controls(model) {
  let $ = capture_ready(model.capture_phase);
  if ($) {
    return div(prepend(class$("capture-save"), List$Empty$const), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Save path"), List$Empty$const)), prepend(input(prepend(type_("text"), prepend(aria_label("Save path"), prepend(value(model.save_path), prepend(on_input((var0) => {
      return new UserChangedSavePath(var0);
    }), List$Empty$const))))), List$Empty$const))), prepend(button(prepend(on_click(Msg$UserRequestedSave$const), List$Empty$const), prepend(text3("Save capture"), List$Empty$const)), List$Empty$const)));
  } else {
    return div(prepend(class$("capture-save pending"), List$Empty$const), List$Empty$const);
  }
}
function capture_advanced(model) {
  return details(prepend(class$("capture-advanced"), List$Empty$const), prepend(summary(List$Empty$const, prepend(text3("Advanced"), List$Empty$const)), prepend(div(prepend(class$("capture-advanced-grid"), List$Empty$const), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("AQL condition"), List$Empty$const)), prepend(input(prepend(type_("text"), prepend(aria_label("AQL condition"), prepend(placeholder("arg.0.tag == order"), prepend(value(model.capture_where), prepend(on_input((var0) => {
    return new UserChangedCaptureWhere(var0);
  }), List$Empty$const)))))), List$Empty$const))), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Framework preset"), List$Empty$const)), prepend(select(prepend(aria_label("Framework preset"), prepend(value(model.capture_preset), prepend(on_input((var0) => {
    return new UserChangedCapturePreset(var0);
  }), List$Empty$const))), prepend(preset_option("generic", "Generic"), prepend(preset_option("gleam-actor", "Gleam actor"), prepend(preset_option("wisp-mist", "Wisp / Mist"), prepend(preset_option("gen-server", "GenServer"), prepend(preset_option("phoenix", "Phoenix"), prepend(preset_option("erlang-supervisor", "Erlang supervisor"), List$Empty$const))))))), List$Empty$const))), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("Max roots"), List$Empty$const)), prepend(input(prepend(type_("number"), prepend(aria_label("Max roots"), prepend(attribute2("min", "1"), prepend(attribute2("max", "1000"), prepend(value(model.capture_max_roots), prepend(on_input((var0) => {
    return new UserChangedMaxRoots(var0);
  }), List$Empty$const))))))), List$Empty$const))), List$Empty$const)))), List$Empty$const)));
}
function archive_overview(model) {
  let _block;
  let $1 = model.capture_phase;
  if ($1 instanceof Ready) {
    let count = $1.event_count;
    let outcome = $1.outcome_summary;
    _block = [count, outcome];
  } else {
    _block = [model.total_events, ""];
  }
  let $ = _block;
  let count = $[0];
  let outcome = $[1];
  return section(prepend(class$("capture-controls archive-overview"), prepend(aria_label("Sealed archive"), List$Empty$const)), prepend(div(List$Empty$const, prepend(h2(List$Empty$const, prepend(text3("Sealed archive"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3(to_string(count) + " events · " + outcome + ". Choose a save path to retain this archive."), List$Empty$const)), List$Empty$const))), prepend(capture_save_controls(model), prepend(button(prepend(class$("quiet-button"), prepend(on_click(Msg$UserOpenedCaptureForm$const), List$Empty$const)), prepend(text3("New capture"), List$Empty$const)), List$Empty$const))));
}
function capture_controls(model) {
  let sealed_landing = capture_ready(model.capture_phase) && !model.capture_form_open;
  let $ = model.mode;
  if ($ instanceof Capture) {
    if (sealed_landing) {
      return archive_overview(model);
    } else {
      return section(prepend(class$("capture-controls"), prepend(aria_label("Capture controls"), List$Empty$const)), prepend(label(List$Empty$const, prepend(span(List$Empty$const, prepend(text3("MFA trigger"), List$Empty$const)), prepend(input(prepend(type_("text"), prepend(aria_label("MFA trigger"), prepend(placeholder("module:function/arity"), prepend(attribute2("list", "mfa-candidates"), prepend(value(model.trigger_input), prepend(on_input((var0) => {
        return new UserChangedTrigger(var0);
      }), List$Empty$const))))))), prepend(datalist(prepend(id("mfa-candidates"), List$Empty$const), map2(model.mfa_suggestions, (candidate) => {
        return option(prepend(value(candidate), List$Empty$const), candidate);
      })), List$Empty$const)))), prepend(button(prepend(disabled(capture_arm_disabled(model.capture_phase)), prepend(on_click(Msg$UserRequestedArm$const), List$Empty$const)), prepend(text3("Arm capture"), List$Empty$const)), prepend(button(prepend(disabled(!capture_busy(model.capture_phase)), prepend(on_click(Msg$UserRequestedCancel$const), List$Empty$const)), prepend(text3("Cancel capture"), List$Empty$const)), prepend(capture_advanced(model), prepend(capture_save_controls(model), prepend((() => {
        let $1 = capture_ready(model.capture_phase);
        if ($1) {
          return button(prepend(class$("quiet-button"), prepend(on_click(Msg$UserClosedCaptureForm$const), List$Empty$const)), prepend(text3("Back to result"), List$Empty$const));
        } else {
          return div(List$Empty$const, List$Empty$const);
        }
      })(), prepend(output(prepend(class$("capture-status"), prepend(aria_live("polite"), List$Empty$const)), prepend(text3(capture_phase_label(model.capture_phase)), prepend(span(List$Empty$const, prepend(text3(capture_recovery(model)), List$Empty$const)), List$Empty$const))), List$Empty$const))))))));
    }
  } else if ($ instanceof Compare) {
    return compare_controls(model);
  } else {
    return div(List$Empty$const, List$Empty$const);
  }
}
function workspace_header(model) {
  return header(prepend(class$("topbar"), List$Empty$const), prepend(div(prepend(class$("brand"), List$Empty$const), prepend(span(prepend(class$("brand-mark"), prepend(aria_hidden(true), List$Empty$const)), prepend(text3("BT"), List$Empty$const)), prepend(div(List$Empty$const, prepend(h1(List$Empty$const, prepend(text3("BeamTrace"), List$Empty$const)), prepend(p(List$Empty$const, prepend(text3("BEAM causal workbench"), List$Empty$const)), List$Empty$const))), List$Empty$const))), prepend(nav(prepend(aria_label("Workspace mode"), List$Empty$const), prepend(mode_button(model.mode, Mode$Capture$const, "Capture", "1"), prepend(mode_button(model.mode, Mode$Live$const, "Live", "2"), prepend(mode_button(model.mode, Mode$Compare$const, "Compare", "3"), prepend(mode_button(model.mode, Mode$Team$const, "Team traces", "4"), List$Empty$const))))), prepend(div(prepend(class$("topbar-actions"), List$Empty$const), prepend(label(prepend(class$("search"), List$Empty$const), prepend(span(prepend(class$("sr-only"), List$Empty$const), prepend(text3("Search events"), List$Empty$const)), prepend(input(prepend(id("event-search"), prepend(type_("search"), prepend(value(model.query), prepend(placeholder("Search actor, message, MFA…"), prepend(aria_label("Search events"), prepend(aria_keyshortcuts("/"), prepend(on_input((var0) => {
    return new UserChangedQuery(var0);
  }), List$Empty$const)))))))), List$Empty$const))), prepend(button(prepend(class$("quiet-button"), prepend(aria_keyshortcuts("Control+K Meta+K"), prepend(on_click(Msg$UserOpenedPalette$const), List$Empty$const))), prepend(text3("Commands  " + modifier_label() + "K"), List$Empty$const)), prepend(button(prepend(class$("quiet-button theme-button"), prepend(aria_label("Change color theme: Theme · " + theme_label(model.theme)), prepend(on_click(Msg$UserCycledTheme$const), List$Empty$const))), prepend(text3("Theme · " + theme_label(model.theme)), List$Empty$const)), List$Empty$const)))), List$Empty$const))));
}
function workspace(model) {
  return main(prepend(class$("workspace"), prepend(attribute2("data-mode", mode_slug(model.mode)), List$Empty$const)), prepend(workspace_header(model), prepend(capture_controls(model), prepend(mobile_mode_navigation(model), prepend(div(prepend(class$("workspace-grid"), List$Empty$const), prepend(session_navigator(model), prepend(causal_workspace(model), prepend(inspector(model), List$Empty$const)))), prepend(mobile_drawers(model), prepend(minimap(model), prepend(palette2(model), List$Empty$const))))))));
}

// build/dev/javascript/beamtrace_web/beamtrace_web.mjs
var FILEPATH = "src\\beamtrace_web.gleam";
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
  return before_paint((_, root) => {
    return draw(root, source, zoom);
  });
}
function finish_update(next, extra_effects) {
  let $ = needs_page(next);
  if ($) {
    let loading = begin_loading(next);
    return [
      loading,
      batch(prepend(draw_effect(loading), prepend(load3(loading.viewport_start, page_limit(loading), remote_query(loading)), extra_effects)))
    ];
  } else {
    return [next, batch(prepend(draw_effect(next), extra_effects))];
  }
}
function update3(loop$model, loop$message) {
  while (true) {
    let model = loop$model;
    let message = loop$message;
    if (message instanceof UserSelectedMode) {
      let $ = message[0];
      if ($ instanceof Live) {
        return finish_update(update2(model, message), prepend(load2(), List$Empty$const));
      } else if ($ instanceof Team) {
        let next = update2(model, message);
        let $1 = next.team_traces;
        if ($1 instanceof Empty) {
          return finish_update(next, prepend(load_traces(""), List$Empty$const));
        } else {
          return finish_update(next, List$Empty$const);
        }
      } else {
        return finish_update(update2(model, message), List$Empty$const);
      }
    } else if (message instanceof UserCycledTheme) {
      let next = update2(model, message);
      apply(next.theme);
      return finish_update(next, List$Empty$const);
    } else if (message instanceof UserFocusedSearch) {
      focusSearch();
      return finish_update(update2(model, message), List$Empty$const);
    } else if (message instanceof UserOpenedPalette) {
      focusPalette();
      return finish_update(update2(model, message), List$Empty$const);
    } else if (message instanceof UserClosedPalette) {
      restoreFocus();
      return finish_update(update2(model, message), List$Empty$const);
    } else if (message instanceof UserPressedKey) {
      let key = message[0];
      let $ = keyboard_shortcut(key);
      if ($ instanceof Some) {
        let shortcut = $[0];
        loop$model = model;
        loop$message = shortcut;
      } else {
        return finish_update(model, List$Empty$const);
      }
    } else if (message instanceof UserChangedTrigger) {
      let query = message[0];
      return finish_update(update2(model, message), prepend(search_mfas(query), List$Empty$const));
    } else if (message instanceof UserRequestedArm) {
      let next = update2(model, message);
      let $ = next.capture_phase;
      if ($ instanceof Arming) {
        return finish_update(next, prepend(arm(next.trigger_input, next.capture_where, next.capture_preset, next.capture_max_roots), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof CaptureArmAccepted) {
      return finish_update(update2(model, message), prepend(poll_after(150), List$Empty$const));
    } else if (message instanceof PollCaptureStatus) {
      return finish_update(update2(model, message), prepend(status(), List$Empty$const));
    } else if (message instanceof CaptureStatusLoaded) {
      let phase = message[0];
      let next = update2(model, message);
      if (phase instanceof Arming) {
        return finish_update(next, prepend(poll_after(150), List$Empty$const));
      } else if (phase instanceof Armed) {
        return finish_update(next, prepend(poll_after(150), List$Empty$const));
      } else if (phase instanceof Cancelling) {
        return finish_update(next, prepend(poll_after(150), List$Empty$const));
      } else if (phase instanceof Ready) {
        return finish_update(next, prepend(load(), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof UserRequestedCancel) {
      return finish_update(update2(model, message), prepend(cancel(), List$Empty$const));
    } else if (message instanceof UserRequestedSave) {
      return finish_update(update2(model, message), prepend(save(model.save_path), List$Empty$const));
    } else if (message instanceof PollLive) {
      let next = update2(model, message);
      let $ = next.mode;
      if ($ instanceof Live) {
        return finish_update(next, prepend(load2(), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof LiveLoaded) {
      let next = update2(model, message);
      let $ = next.mode;
      if ($ instanceof Live) {
        return finish_update(next, prepend(poll_after2(1000), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof LiveLoadFailed) {
      let next = update2(model, message);
      let $ = next.mode;
      if ($ instanceof Live) {
        return finish_update(next, prepend(poll_after2(2000), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof UserRequestedCompare) {
      let next = update2(model, message);
      let $ = next.compare_loading;
      if ($) {
        return finish_update(next, prepend(run2(compare_paths(next)), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof UserRequestedTeamTraces) {
      return finish_update(update2(model, message), prepend(load_traces(""), List$Empty$const));
    } else if (message instanceof UserRequestedMoreTeamTraces) {
      let next = update2(model, message);
      let $ = model.team_next_cursor;
      if ($ instanceof Some) {
        let cursor = $[0];
        return finish_update(next, prepend(load_traces(cursor), List$Empty$const));
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
          return finish_update(next, prepend(load_events(trace_id, ""), List$Empty$const));
        } else {
          return finish_update(next, List$Empty$const);
        }
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof UserRequestedTeamCompare) {
      let next = update2(model, message);
      let $ = next.compare_loading;
      if ($) {
        return finish_update(next, prepend(run2(compare_paths(next)), List$Empty$const));
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
        return finish_update(next, prepend(load_events(trace_id, cursor), List$Empty$const));
      } else {
        return finish_update(next, List$Empty$const);
      }
    } else if (message instanceof UserRequestedTraceHold) {
      let trace_id = message.trace_id;
      let enabled = message.enabled;
      return finish_update(update2(model, message), prepend(set_hold(trace_id, enabled), List$Empty$const));
    } else {
      return finish_update(update2(model, message), List$Empty$const);
    }
  }
}
function startup_effect(model) {
  return batch(prepend(draw_effect(model), prepend(load3(0, 200, remote_query(model)), prepend(load(), prepend(status(), prepend(install_cleanup(), prepend(from2((dispatch) => {
    return installShortcuts((key) => {
      return dispatch(new UserPressedKey(key));
    });
  }), List$Empty$const)))))));
}
function init2(_) {
  let model = init_remote();
  let compare_paths2 = initial_compare_paths();
  let $ = trim(compare_paths2);
  if ($ === "") {
    return [model, startup_effect(model)];
  } else {
    let paths = $;
    let _block;
    let _pipe = model;
    let _pipe$1 = update2(_pipe, new UserSelectedMode(Mode$Compare$const));
    let _pipe$2 = update2(_pipe$1, new UserChangedComparePaths(paths));
    _block = update2(_pipe$2, Msg$UserRequestedCompare$const);
    let next = _block;
    let $1 = next.compare_loading;
    if ($1) {
      return [
        next,
        batch(prepend(startup_effect(next), prepend(run2(compare_paths(next)), List$Empty$const)))
      ];
    } else {
      return [next, startup_effect(next)];
    }
  }
}
function main2() {
  let app = application(init2, update3, workspace);
  let $ = start4(app, "#app", undefined);
  if (!($ instanceof Ok)) {
    throw makeError("let_assert", FILEPATH, "beamtrace_web", 20, "main", "Pattern match failed, no pattern matched the value.", { value: $, start: 591, end: 652, pattern_start: 602, pattern_end: 607 });
  }
  return;
}

// .lustre/build/beamtrace_web.mjs
main2();
