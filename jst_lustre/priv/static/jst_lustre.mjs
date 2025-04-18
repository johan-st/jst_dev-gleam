// build/dev/javascript/prelude.mjs
var CustomType = class {
  withFields(fields) {
    let properties = Object.keys(this).map(
      (label) => label in fields ? fields[label] : this[label]
    );
    return new this.constructor(...properties);
  }
};
var List = class {
  static fromArray(array3, tail) {
    let t = tail || new Empty();
    for (let i = array3.length - 1; i >= 0; --i) {
      t = new NonEmpty(array3[i], t);
    }
    return t;
  }
  [Symbol.iterator]() {
    return new ListIterator(this);
  }
  toArray() {
    return [...this];
  }
  // @internal
  atLeastLength(desired) {
    let current = this;
    while (desired-- > 0 && current) current = current.tail;
    return current !== void 0;
  }
  // @internal
  hasLength(desired) {
    let current = this;
    while (desired-- > 0 && current) current = current.tail;
    return desired === -1 && current instanceof Empty;
  }
  // @internal
  countLength() {
    let current = this;
    let length3 = 0;
    while (current) {
      current = current.tail;
      length3++;
    }
    return length3 - 1;
  }
};
function prepend(element2, tail) {
  return new NonEmpty(element2, tail);
}
function toList(elements2, tail) {
  return List.fromArray(elements2, tail);
}
var ListIterator = class {
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
};
var Empty = class extends List {
};
var NonEmpty = class extends List {
  constructor(head, tail) {
    super();
    this.head = head;
    this.tail = tail;
  }
};
var BitArray = class {
  /**
   * The size in bits of this bit array's data.
   *
   * @type {number}
   */
  bitSize;
  /**
   * The size in bytes of this bit array's data. If this bit array doesn't store
   * a whole number of bytes then this value is rounded up.
   *
   * @type {number}
   */
  byteSize;
  /**
   * The number of unused high bits in the first byte of this bit array's
   * buffer prior to the start of its data. The value of any unused high bits is
   * undefined.
   *
   * The bit offset will be in the range 0-7.
   *
   * @type {number}
   */
  bitOffset;
  /**
   * The raw bytes that hold this bit array's data.
   *
   * If `bitOffset` is not zero then there are unused high bits in the first
   * byte of this buffer.
   *
   * If `bitOffset + bitSize` is not a multiple of 8 then there are unused low
   * bits in the last byte of this buffer.
   *
   * @type {Uint8Array}
   */
  rawBuffer;
  /**
   * Constructs a new bit array from a `Uint8Array`, an optional size in
   * bits, and an optional bit offset.
   *
   * If no bit size is specified it is taken as `buffer.length * 8`, i.e. all
   * bytes in the buffer make up the new bit array's data.
   *
   * If no bit offset is specified it defaults to zero, i.e. there are no unused
   * high bits in the first byte of the buffer.
   *
   * @param {Uint8Array} buffer
   * @param {number} [bitSize]
   * @param {number} [bitOffset]
   */
  constructor(buffer, bitSize, bitOffset) {
    if (!(buffer instanceof Uint8Array)) {
      throw globalThis.Error(
        "BitArray can only be constructed from a Uint8Array"
      );
    }
    this.bitSize = bitSize ?? buffer.length * 8;
    this.byteSize = Math.trunc((this.bitSize + 7) / 8);
    this.bitOffset = bitOffset ?? 0;
    if (this.bitSize < 0) {
      throw globalThis.Error(`BitArray bit size is invalid: ${this.bitSize}`);
    }
    if (this.bitOffset < 0 || this.bitOffset > 7) {
      throw globalThis.Error(
        `BitArray bit offset is invalid: ${this.bitOffset}`
      );
    }
    if (buffer.length !== Math.trunc((this.bitOffset + this.bitSize + 7) / 8)) {
      throw globalThis.Error("BitArray buffer length is invalid");
    }
    this.rawBuffer = buffer;
  }
  /**
   * Returns a specific byte in this bit array. If the byte index is out of
   * range then `undefined` is returned.
   *
   * When returning the final byte of a bit array with a bit size that's not a
   * multiple of 8, the content of the unused low bits are undefined.
   *
   * @param {number} index
   * @returns {number | undefined}
   */
  byteAt(index3) {
    if (index3 < 0 || index3 >= this.byteSize) {
      return void 0;
    }
    return bitArrayByteAt(this.rawBuffer, this.bitOffset, index3);
  }
  /** @internal */
  equals(other) {
    if (this.bitSize !== other.bitSize) {
      return false;
    }
    const wholeByteCount = Math.trunc(this.bitSize / 8);
    if (this.bitOffset === 0 && other.bitOffset === 0) {
      for (let i = 0; i < wholeByteCount; i++) {
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
      for (let i = 0; i < wholeByteCount; i++) {
        const a2 = bitArrayByteAt(this.rawBuffer, this.bitOffset, i);
        const b = bitArrayByteAt(other.rawBuffer, other.bitOffset, i);
        if (a2 !== b) {
          return false;
        }
      }
      const trailingBitsCount = this.bitSize % 8;
      if (trailingBitsCount) {
        const a2 = bitArrayByteAt(
          this.rawBuffer,
          this.bitOffset,
          wholeByteCount
        );
        const b = bitArrayByteAt(
          other.rawBuffer,
          other.bitOffset,
          wholeByteCount
        );
        const unusedLowBitCount = 8 - trailingBitsCount;
        if (a2 >> unusedLowBitCount !== b >> unusedLowBitCount) {
          return false;
        }
      }
    }
    return true;
  }
  /**
   * Returns this bit array's internal buffer.
   *
   * @deprecated Use `BitArray.byteAt()` or `BitArray.rawBuffer` instead.
   *
   * @returns {Uint8Array}
   */
  get buffer() {
    bitArrayPrintDeprecationWarning(
      "buffer",
      "Use BitArray.byteAt() or BitArray.rawBuffer instead"
    );
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error(
        "BitArray.buffer does not support unaligned bit arrays"
      );
    }
    return this.rawBuffer;
  }
  /**
   * Returns the length in bytes of this bit array's internal buffer.
   *
   * @deprecated Use `BitArray.bitSize` or `BitArray.byteSize` instead.
   *
   * @returns {number}
   */
  get length() {
    bitArrayPrintDeprecationWarning(
      "length",
      "Use BitArray.bitSize or BitArray.byteSize instead"
    );
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error(
        "BitArray.length does not support unaligned bit arrays"
      );
    }
    return this.rawBuffer.length;
  }
};
function bitArrayByteAt(buffer, bitOffset, index3) {
  if (bitOffset === 0) {
    return buffer[index3] ?? 0;
  } else {
    const a2 = buffer[index3] << bitOffset & 255;
    const b = buffer[index3 + 1] >> 8 - bitOffset;
    return a2 | b;
  }
}
var isBitArrayDeprecationMessagePrinted = {};
function bitArrayPrintDeprecationWarning(name, message) {
  if (isBitArrayDeprecationMessagePrinted[name]) {
    return;
  }
  console.warn(
    `Deprecated BitArray.${name} property used in JavaScript FFI code. ${message}.`
  );
  isBitArrayDeprecationMessagePrinted[name] = true;
}
var Result = class _Result extends CustomType {
  // @internal
  static isResult(data) {
    return data instanceof _Result;
  }
};
var Ok = class extends Result {
  constructor(value) {
    super();
    this[0] = value;
  }
  // @internal
  isOk() {
    return true;
  }
};
var Error = class extends Result {
  constructor(detail) {
    super();
    this[0] = detail;
  }
  // @internal
  isOk() {
    return false;
  }
};
function isEqual(x, y) {
  let values2 = [x, y];
  while (values2.length) {
    let a2 = values2.pop();
    let b = values2.pop();
    if (a2 === b) continue;
    if (!isObject(a2) || !isObject(b)) return false;
    let unequal = !structurallyCompatibleObjects(a2, b) || unequalDates(a2, b) || unequalBuffers(a2, b) || unequalArrays(a2, b) || unequalMaps(a2, b) || unequalSets(a2, b) || unequalRegExps(a2, b);
    if (unequal) return false;
    const proto = Object.getPrototypeOf(a2);
    if (proto !== null && typeof proto.equals === "function") {
      try {
        if (a2.equals(b)) continue;
        else return false;
      } catch {
      }
    }
    let [keys2, get] = getters(a2);
    for (let k of keys2(a2)) {
      values2.push(get(a2, k), get(b, k));
    }
  }
  return true;
}
function getters(object3) {
  if (object3 instanceof Map) {
    return [(x) => x.keys(), (x, y) => x.get(y)];
  } else {
    let extra = object3 instanceof globalThis.Error ? ["message"] : [];
    return [(x) => [...extra, ...Object.keys(x)], (x, y) => x[y]];
  }
}
function unequalDates(a2, b) {
  return a2 instanceof Date && (a2 > b || a2 < b);
}
function unequalBuffers(a2, b) {
  return !(a2 instanceof BitArray) && a2.buffer instanceof ArrayBuffer && a2.BYTES_PER_ELEMENT && !(a2.byteLength === b.byteLength && a2.every((n, i) => n === b[i]));
}
function unequalArrays(a2, b) {
  return Array.isArray(a2) && a2.length !== b.length;
}
function unequalMaps(a2, b) {
  return a2 instanceof Map && a2.size !== b.size;
}
function unequalSets(a2, b) {
  return a2 instanceof Set && (a2.size != b.size || [...a2].some((e) => !b.has(e)));
}
function unequalRegExps(a2, b) {
  return a2 instanceof RegExp && (a2.source !== b.source || a2.flags !== b.flags);
}
function isObject(a2) {
  return typeof a2 === "object" && a2 !== null;
}
function structurallyCompatibleObjects(a2, b) {
  if (typeof a2 !== "object" && typeof b !== "object" && (!a2 || !b))
    return false;
  let nonstructural = [Promise, WeakSet, WeakMap, Function];
  if (nonstructural.some((c) => a2 instanceof c)) return false;
  return a2.constructor === b.constructor;
}
function makeError(variant, module, line, fn, message, extra) {
  let error = new globalThis.Error(message);
  error.gleam_error = variant;
  error.module = module;
  error.line = line;
  error.function = fn;
  error.fn = fn;
  for (let k in extra) error[k] = extra[k];
  return error;
}

// build/dev/javascript/gleam_stdlib/gleam/option.mjs
var Some = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var None = class extends CustomType {
};

// build/dev/javascript/gleam_stdlib/gleam/order.mjs
var Lt = class extends CustomType {
};
var Eq = class extends CustomType {
};
var Gt = class extends CustomType {
};

// build/dev/javascript/gleam_stdlib/gleam/int.mjs
function compare(a2, b) {
  let $ = a2 === b;
  if ($) {
    return new Eq();
  } else {
    let $1 = a2 < b;
    if ($1) {
      return new Lt();
    } else {
      return new Gt();
    }
  }
}

// build/dev/javascript/gleam_stdlib/gleam/list.mjs
var Ascending = class extends CustomType {
};
var Descending = class extends CustomType {
};
function reverse_and_prepend(loop$prefix, loop$suffix) {
  while (true) {
    let prefix = loop$prefix;
    let suffix = loop$suffix;
    if (prefix.hasLength(0)) {
      return suffix;
    } else {
      let first$1 = prefix.head;
      let rest$1 = prefix.tail;
      loop$prefix = rest$1;
      loop$suffix = prepend(first$1, suffix);
    }
  }
}
function reverse(list2) {
  return reverse_and_prepend(list2, toList([]));
}
function filter_map_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list2 = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list2.hasLength(0)) {
      return reverse(acc);
    } else {
      let first$1 = list2.head;
      let rest$1 = list2.tail;
      let _block;
      let $ = fun(first$1);
      if ($.isOk()) {
        let first$2 = $[0];
        _block = prepend(first$2, acc);
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
function filter_map(list2, fun) {
  return filter_map_loop(list2, fun, toList([]));
}
function map_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list2 = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list2.hasLength(0)) {
      return reverse(acc);
    } else {
      let first$1 = list2.head;
      let rest$1 = list2.tail;
      loop$list = rest$1;
      loop$fun = fun;
      loop$acc = prepend(fun(first$1), acc);
    }
  }
}
function map(list2, fun) {
  return map_loop(list2, fun, toList([]));
}
function fold(loop$list, loop$initial, loop$fun) {
  while (true) {
    let list2 = loop$list;
    let initial = loop$initial;
    let fun = loop$fun;
    if (list2.hasLength(0)) {
      return initial;
    } else {
      let first$1 = list2.head;
      let rest$1 = list2.tail;
      loop$list = rest$1;
      loop$initial = fun(initial, first$1);
      loop$fun = fun;
    }
  }
}
function index_fold_loop(loop$over, loop$acc, loop$with, loop$index) {
  while (true) {
    let over = loop$over;
    let acc = loop$acc;
    let with$ = loop$with;
    let index3 = loop$index;
    if (over.hasLength(0)) {
      return acc;
    } else {
      let first$1 = over.head;
      let rest$1 = over.tail;
      loop$over = rest$1;
      loop$acc = with$(acc, first$1, index3);
      loop$with = with$;
      loop$index = index3 + 1;
    }
  }
}
function index_fold(list2, initial, fun) {
  return index_fold_loop(list2, initial, fun, 0);
}
function sequences(loop$list, loop$compare, loop$growing, loop$direction, loop$prev, loop$acc) {
  while (true) {
    let list2 = loop$list;
    let compare3 = loop$compare;
    let growing = loop$growing;
    let direction = loop$direction;
    let prev = loop$prev;
    let acc = loop$acc;
    let growing$1 = prepend(prev, growing);
    if (list2.hasLength(0)) {
      if (direction instanceof Ascending) {
        return prepend(reverse(growing$1), acc);
      } else {
        return prepend(growing$1, acc);
      }
    } else {
      let new$1 = list2.head;
      let rest$1 = list2.tail;
      let $ = compare3(prev, new$1);
      if ($ instanceof Gt && direction instanceof Descending) {
        loop$list = rest$1;
        loop$compare = compare3;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      } else if ($ instanceof Lt && direction instanceof Ascending) {
        loop$list = rest$1;
        loop$compare = compare3;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      } else if ($ instanceof Eq && direction instanceof Ascending) {
        loop$list = rest$1;
        loop$compare = compare3;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      } else if ($ instanceof Gt && direction instanceof Ascending) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1.hasLength(0)) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare3(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = new Ascending();
          } else if ($1 instanceof Eq) {
            _block$1 = new Ascending();
          } else {
            _block$1 = new Descending();
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare3;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else if ($ instanceof Lt && direction instanceof Descending) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1.hasLength(0)) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare3(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = new Ascending();
          } else if ($1 instanceof Eq) {
            _block$1 = new Ascending();
          } else {
            _block$1 = new Descending();
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare3;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1.hasLength(0)) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare3(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = new Ascending();
          } else if ($1 instanceof Eq) {
            _block$1 = new Ascending();
          } else {
            _block$1 = new Descending();
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare3;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      }
    }
  }
}
function merge_ascendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare3 = loop$compare;
    let acc = loop$acc;
    if (list1.hasLength(0)) {
      let list3 = list2;
      return reverse_and_prepend(list3, acc);
    } else if (list2.hasLength(0)) {
      let list3 = list1;
      return reverse_and_prepend(list3, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list2.head;
      let rest2 = list2.tail;
      let $ = compare3(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare3;
        loop$acc = prepend(first1, acc);
      } else if ($ instanceof Gt) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare3;
        loop$acc = prepend(first2, acc);
      } else {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare3;
        loop$acc = prepend(first2, acc);
      }
    }
  }
}
function merge_ascending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences2 = loop$sequences;
    let compare3 = loop$compare;
    let acc = loop$acc;
    if (sequences2.hasLength(0)) {
      return reverse(acc);
    } else if (sequences2.hasLength(1)) {
      let sequence = sequences2.head;
      return reverse(prepend(reverse(sequence), acc));
    } else {
      let ascending1 = sequences2.head;
      let ascending2 = sequences2.tail.head;
      let rest$1 = sequences2.tail.tail;
      let descending = merge_ascendings(
        ascending1,
        ascending2,
        compare3,
        toList([])
      );
      loop$sequences = rest$1;
      loop$compare = compare3;
      loop$acc = prepend(descending, acc);
    }
  }
}
function merge_descendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list2 = loop$list2;
    let compare3 = loop$compare;
    let acc = loop$acc;
    if (list1.hasLength(0)) {
      let list3 = list2;
      return reverse_and_prepend(list3, acc);
    } else if (list2.hasLength(0)) {
      let list3 = list1;
      return reverse_and_prepend(list3, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list2.head;
      let rest2 = list2.tail;
      let $ = compare3(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare3;
        loop$acc = prepend(first2, acc);
      } else if ($ instanceof Gt) {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare3;
        loop$acc = prepend(first1, acc);
      } else {
        loop$list1 = rest1;
        loop$list2 = list2;
        loop$compare = compare3;
        loop$acc = prepend(first1, acc);
      }
    }
  }
}
function merge_descending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences2 = loop$sequences;
    let compare3 = loop$compare;
    let acc = loop$acc;
    if (sequences2.hasLength(0)) {
      return reverse(acc);
    } else if (sequences2.hasLength(1)) {
      let sequence = sequences2.head;
      return reverse(prepend(reverse(sequence), acc));
    } else {
      let descending1 = sequences2.head;
      let descending2 = sequences2.tail.head;
      let rest$1 = sequences2.tail.tail;
      let ascending = merge_descendings(
        descending1,
        descending2,
        compare3,
        toList([])
      );
      loop$sequences = rest$1;
      loop$compare = compare3;
      loop$acc = prepend(ascending, acc);
    }
  }
}
function merge_all(loop$sequences, loop$direction, loop$compare) {
  while (true) {
    let sequences2 = loop$sequences;
    let direction = loop$direction;
    let compare3 = loop$compare;
    if (sequences2.hasLength(0)) {
      return toList([]);
    } else if (sequences2.hasLength(1) && direction instanceof Ascending) {
      let sequence = sequences2.head;
      return sequence;
    } else if (sequences2.hasLength(1) && direction instanceof Descending) {
      let sequence = sequences2.head;
      return reverse(sequence);
    } else if (direction instanceof Ascending) {
      let sequences$1 = merge_ascending_pairs(sequences2, compare3, toList([]));
      loop$sequences = sequences$1;
      loop$direction = new Descending();
      loop$compare = compare3;
    } else {
      let sequences$1 = merge_descending_pairs(sequences2, compare3, toList([]));
      loop$sequences = sequences$1;
      loop$direction = new Ascending();
      loop$compare = compare3;
    }
  }
}
function sort(list2, compare3) {
  if (list2.hasLength(0)) {
    return toList([]);
  } else if (list2.hasLength(1)) {
    let x = list2.head;
    return toList([x]);
  } else {
    let x = list2.head;
    let y = list2.tail.head;
    let rest$1 = list2.tail.tail;
    let _block;
    let $ = compare3(x, y);
    if ($ instanceof Lt) {
      _block = new Ascending();
    } else if ($ instanceof Eq) {
      _block = new Ascending();
    } else {
      _block = new Descending();
    }
    let direction = _block;
    let sequences$1 = sequences(
      rest$1,
      compare3,
      toList([x]),
      direction,
      y,
      toList([])
    );
    return merge_all(sequences$1, new Ascending(), compare3);
  }
}

// build/dev/javascript/gleam_stdlib/gleam/string.mjs
function join_loop(loop$strings, loop$separator, loop$accumulator) {
  while (true) {
    let strings = loop$strings;
    let separator = loop$separator;
    let accumulator = loop$accumulator;
    if (strings.hasLength(0)) {
      return accumulator;
    } else {
      let string3 = strings.head;
      let strings$1 = strings.tail;
      loop$strings = strings$1;
      loop$separator = separator;
      loop$accumulator = accumulator + separator + string3;
    }
  }
}
function join(strings, separator) {
  if (strings.hasLength(0)) {
    return "";
  } else {
    let first$1 = strings.head;
    let rest = strings.tail;
    return join_loop(rest, separator, first$1);
  }
}
function drop_start(loop$string, loop$num_graphemes) {
  while (true) {
    let string3 = loop$string;
    let num_graphemes = loop$num_graphemes;
    let $ = num_graphemes > 0;
    if (!$) {
      return string3;
    } else {
      let $1 = pop_grapheme(string3);
      if ($1.isOk()) {
        let string$1 = $1[0][1];
        loop$string = string$1;
        loop$num_graphemes = num_graphemes - 1;
      } else {
        return string3;
      }
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
    return map(_pipe$2, identity);
  }
}

// build/dev/javascript/gleam_stdlib/dict.mjs
var referenceMap = /* @__PURE__ */ new WeakMap();
var tempDataView = /* @__PURE__ */ new DataView(
  /* @__PURE__ */ new ArrayBuffer(8)
);
var referenceUID = 0;
function hashByReference(o) {
  const known = referenceMap.get(o);
  if (known !== void 0) {
    return known;
  }
  const hash = referenceUID++;
  if (referenceUID === 2147483647) {
    referenceUID = 0;
  }
  referenceMap.set(o, hash);
  return hash;
}
function hashMerge(a2, b) {
  return a2 ^ b + 2654435769 + (a2 << 6) + (a2 >> 2) | 0;
}
function hashString(s) {
  let hash = 0;
  const len = s.length;
  for (let i = 0; i < len; i++) {
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
    } catch {
    }
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
    for (let i = 0; i < o.length; i++) {
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
    const keys2 = Object.keys(o);
    for (let i = 0; i < keys2.length; i++) {
      const k = keys2[i];
      const v = o[k];
      h = h + hashMerge(getHash(v), hashString(k)) | 0;
    }
  }
  return h;
}
function getHash(u) {
  if (u === null) return 1108378658;
  if (u === void 0) return 1108378659;
  if (u === true) return 1108378657;
  if (u === false) return 1108378656;
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
var SHIFT = 5;
var BUCKET_SIZE = Math.pow(2, SHIFT);
var MASK = BUCKET_SIZE - 1;
var MAX_INDEX_NODE = BUCKET_SIZE / 2;
var MIN_ARRAY_NODE = BUCKET_SIZE / 4;
var ENTRY = 0;
var ARRAY_NODE = 1;
var INDEX_NODE = 2;
var COLLISION_NODE = 3;
var EMPTY = {
  type: INDEX_NODE,
  bitmap: 0,
  array: []
};
function mask(hash, shift) {
  return hash >>> shift & MASK;
}
function bitpos(hash, shift) {
  return 1 << mask(hash, shift);
}
function bitcount(x) {
  x -= x >> 1 & 1431655765;
  x = (x & 858993459) + (x >> 2 & 858993459);
  x = x + (x >> 4) & 252645135;
  x += x >> 8;
  x += x >> 16;
  return x & 127;
}
function index(bitmap, bit) {
  return bitcount(bitmap & bit - 1);
}
function cloneAndSet(arr, at, val) {
  const len = arr.length;
  const out = new Array(len);
  for (let i = 0; i < len; ++i) {
    out[i] = arr[i];
  }
  out[at] = val;
  return out;
}
function spliceIn(arr, at, val) {
  const len = arr.length;
  const out = new Array(len + 1);
  let i = 0;
  let g = 0;
  while (i < at) {
    out[g++] = arr[i++];
  }
  out[g++] = val;
  while (i < len) {
    out[g++] = arr[i++];
  }
  return out;
}
function spliceOut(arr, at) {
  const len = arr.length;
  const out = new Array(len - 1);
  let i = 0;
  let g = 0;
  while (i < at) {
    out[g++] = arr[i++];
  }
  ++i;
  while (i < len) {
    out[g++] = arr[i++];
  }
  return out;
}
function createNode(shift, key1, val1, key2hash, key2, val2) {
  const key1hash = getHash(key1);
  if (key1hash === key2hash) {
    return {
      type: COLLISION_NODE,
      hash: key1hash,
      array: [
        { type: ENTRY, k: key1, v: val1 },
        { type: ENTRY, k: key2, v: val2 }
      ]
    };
  }
  const addedLeaf = { val: false };
  return assoc(
    assocIndex(EMPTY, shift, key1hash, key1, val1, addedLeaf),
    shift,
    key2hash,
    key2,
    val2,
    addedLeaf
  );
}
function assoc(root, shift, hash, key, val, addedLeaf) {
  switch (root.type) {
    case ARRAY_NODE:
      return assocArray(root, shift, hash, key, val, addedLeaf);
    case INDEX_NODE:
      return assocIndex(root, shift, hash, key, val, addedLeaf);
    case COLLISION_NODE:
      return assocCollision(root, shift, hash, key, val, addedLeaf);
  }
}
function assocArray(root, shift, hash, key, val, addedLeaf) {
  const idx = mask(hash, shift);
  const node = root.array[idx];
  if (node === void 0) {
    addedLeaf.val = true;
    return {
      type: ARRAY_NODE,
      size: root.size + 1,
      array: cloneAndSet(root.array, idx, { type: ENTRY, k: key, v: val })
    };
  }
  if (node.type === ENTRY) {
    if (isEqual(key, node.k)) {
      if (val === node.v) {
        return root;
      }
      return {
        type: ARRAY_NODE,
        size: root.size,
        array: cloneAndSet(root.array, idx, {
          type: ENTRY,
          k: key,
          v: val
        })
      };
    }
    addedLeaf.val = true;
    return {
      type: ARRAY_NODE,
      size: root.size,
      array: cloneAndSet(
        root.array,
        idx,
        createNode(shift + SHIFT, node.k, node.v, hash, key, val)
      )
    };
  }
  const n = assoc(node, shift + SHIFT, hash, key, val, addedLeaf);
  if (n === node) {
    return root;
  }
  return {
    type: ARRAY_NODE,
    size: root.size,
    array: cloneAndSet(root.array, idx, n)
  };
}
function assocIndex(root, shift, hash, key, val, addedLeaf) {
  const bit = bitpos(hash, shift);
  const idx = index(root.bitmap, bit);
  if ((root.bitmap & bit) !== 0) {
    const node = root.array[idx];
    if (node.type !== ENTRY) {
      const n = assoc(node, shift + SHIFT, hash, key, val, addedLeaf);
      if (n === node) {
        return root;
      }
      return {
        type: INDEX_NODE,
        bitmap: root.bitmap,
        array: cloneAndSet(root.array, idx, n)
      };
    }
    const nodeKey = node.k;
    if (isEqual(key, nodeKey)) {
      if (val === node.v) {
        return root;
      }
      return {
        type: INDEX_NODE,
        bitmap: root.bitmap,
        array: cloneAndSet(root.array, idx, {
          type: ENTRY,
          k: key,
          v: val
        })
      };
    }
    addedLeaf.val = true;
    return {
      type: INDEX_NODE,
      bitmap: root.bitmap,
      array: cloneAndSet(
        root.array,
        idx,
        createNode(shift + SHIFT, nodeKey, node.v, hash, key, val)
      )
    };
  } else {
    const n = root.array.length;
    if (n >= MAX_INDEX_NODE) {
      const nodes = new Array(32);
      const jdx = mask(hash, shift);
      nodes[jdx] = assocIndex(EMPTY, shift + SHIFT, hash, key, val, addedLeaf);
      let j = 0;
      let bitmap = root.bitmap;
      for (let i = 0; i < 32; i++) {
        if ((bitmap & 1) !== 0) {
          const node = root.array[j++];
          nodes[i] = node;
        }
        bitmap = bitmap >>> 1;
      }
      return {
        type: ARRAY_NODE,
        size: n + 1,
        array: nodes
      };
    } else {
      const newArray = spliceIn(root.array, idx, {
        type: ENTRY,
        k: key,
        v: val
      });
      addedLeaf.val = true;
      return {
        type: INDEX_NODE,
        bitmap: root.bitmap | bit,
        array: newArray
      };
    }
  }
}
function assocCollision(root, shift, hash, key, val, addedLeaf) {
  if (hash === root.hash) {
    const idx = collisionIndexOf(root, key);
    if (idx !== -1) {
      const entry = root.array[idx];
      if (entry.v === val) {
        return root;
      }
      return {
        type: COLLISION_NODE,
        hash,
        array: cloneAndSet(root.array, idx, { type: ENTRY, k: key, v: val })
      };
    }
    const size = root.array.length;
    addedLeaf.val = true;
    return {
      type: COLLISION_NODE,
      hash,
      array: cloneAndSet(root.array, size, { type: ENTRY, k: key, v: val })
    };
  }
  return assoc(
    {
      type: INDEX_NODE,
      bitmap: bitpos(root.hash, shift),
      array: [root]
    },
    shift,
    hash,
    key,
    val,
    addedLeaf
  );
}
function collisionIndexOf(root, key) {
  const size = root.array.length;
  for (let i = 0; i < size; i++) {
    if (isEqual(key, root.array[i].k)) {
      return i;
    }
  }
  return -1;
}
function find(root, shift, hash, key) {
  switch (root.type) {
    case ARRAY_NODE:
      return findArray(root, shift, hash, key);
    case INDEX_NODE:
      return findIndex(root, shift, hash, key);
    case COLLISION_NODE:
      return findCollision(root, key);
  }
}
function findArray(root, shift, hash, key) {
  const idx = mask(hash, shift);
  const node = root.array[idx];
  if (node === void 0) {
    return void 0;
  }
  if (node.type !== ENTRY) {
    return find(node, shift + SHIFT, hash, key);
  }
  if (isEqual(key, node.k)) {
    return node;
  }
  return void 0;
}
function findIndex(root, shift, hash, key) {
  const bit = bitpos(hash, shift);
  if ((root.bitmap & bit) === 0) {
    return void 0;
  }
  const idx = index(root.bitmap, bit);
  const node = root.array[idx];
  if (node.type !== ENTRY) {
    return find(node, shift + SHIFT, hash, key);
  }
  if (isEqual(key, node.k)) {
    return node;
  }
  return void 0;
}
function findCollision(root, key) {
  const idx = collisionIndexOf(root, key);
  if (idx < 0) {
    return void 0;
  }
  return root.array[idx];
}
function without(root, shift, hash, key) {
  switch (root.type) {
    case ARRAY_NODE:
      return withoutArray(root, shift, hash, key);
    case INDEX_NODE:
      return withoutIndex(root, shift, hash, key);
    case COLLISION_NODE:
      return withoutCollision(root, key);
  }
}
function withoutArray(root, shift, hash, key) {
  const idx = mask(hash, shift);
  const node = root.array[idx];
  if (node === void 0) {
    return root;
  }
  let n = void 0;
  if (node.type === ENTRY) {
    if (!isEqual(node.k, key)) {
      return root;
    }
  } else {
    n = without(node, shift + SHIFT, hash, key);
    if (n === node) {
      return root;
    }
  }
  if (n === void 0) {
    if (root.size <= MIN_ARRAY_NODE) {
      const arr = root.array;
      const out = new Array(root.size - 1);
      let i = 0;
      let j = 0;
      let bitmap = 0;
      while (i < idx) {
        const nv = arr[i];
        if (nv !== void 0) {
          out[j] = nv;
          bitmap |= 1 << i;
          ++j;
        }
        ++i;
      }
      ++i;
      while (i < arr.length) {
        const nv = arr[i];
        if (nv !== void 0) {
          out[j] = nv;
          bitmap |= 1 << i;
          ++j;
        }
        ++i;
      }
      return {
        type: INDEX_NODE,
        bitmap,
        array: out
      };
    }
    return {
      type: ARRAY_NODE,
      size: root.size - 1,
      array: cloneAndSet(root.array, idx, n)
    };
  }
  return {
    type: ARRAY_NODE,
    size: root.size,
    array: cloneAndSet(root.array, idx, n)
  };
}
function withoutIndex(root, shift, hash, key) {
  const bit = bitpos(hash, shift);
  if ((root.bitmap & bit) === 0) {
    return root;
  }
  const idx = index(root.bitmap, bit);
  const node = root.array[idx];
  if (node.type !== ENTRY) {
    const n = without(node, shift + SHIFT, hash, key);
    if (n === node) {
      return root;
    }
    if (n !== void 0) {
      return {
        type: INDEX_NODE,
        bitmap: root.bitmap,
        array: cloneAndSet(root.array, idx, n)
      };
    }
    if (root.bitmap === bit) {
      return void 0;
    }
    return {
      type: INDEX_NODE,
      bitmap: root.bitmap ^ bit,
      array: spliceOut(root.array, idx)
    };
  }
  if (isEqual(key, node.k)) {
    if (root.bitmap === bit) {
      return void 0;
    }
    return {
      type: INDEX_NODE,
      bitmap: root.bitmap ^ bit,
      array: spliceOut(root.array, idx)
    };
  }
  return root;
}
function withoutCollision(root, key) {
  const idx = collisionIndexOf(root, key);
  if (idx < 0) {
    return root;
  }
  if (root.array.length === 1) {
    return void 0;
  }
  return {
    type: COLLISION_NODE,
    hash: root.hash,
    array: spliceOut(root.array, idx)
  };
}
function forEach(root, fn) {
  if (root === void 0) {
    return;
  }
  const items = root.array;
  const size = items.length;
  for (let i = 0; i < size; i++) {
    const item = items[i];
    if (item === void 0) {
      continue;
    }
    if (item.type === ENTRY) {
      fn(item.v, item.k);
      continue;
    }
    forEach(item, fn);
  }
}
var Dict = class _Dict {
  /**
   * @template V
   * @param {Record<string,V>} o
   * @returns {Dict<string,V>}
   */
  static fromObject(o) {
    const keys2 = Object.keys(o);
    let m = _Dict.new();
    for (let i = 0; i < keys2.length; i++) {
      const k = keys2[i];
      m = m.set(k, o[k]);
    }
    return m;
  }
  /**
   * @template K,V
   * @param {Map<K,V>} o
   * @returns {Dict<K,V>}
   */
  static fromMap(o) {
    let m = _Dict.new();
    o.forEach((v, k) => {
      m = m.set(k, v);
    });
    return m;
  }
  static new() {
    return new _Dict(void 0, 0);
  }
  /**
   * @param {undefined | Node<K,V>} root
   * @param {number} size
   */
  constructor(root, size) {
    this.root = root;
    this.size = size;
  }
  /**
   * @template NotFound
   * @param {K} key
   * @param {NotFound} notFound
   * @returns {NotFound | V}
   */
  get(key, notFound) {
    if (this.root === void 0) {
      return notFound;
    }
    const found = find(this.root, 0, getHash(key), key);
    if (found === void 0) {
      return notFound;
    }
    return found.v;
  }
  /**
   * @param {K} key
   * @param {V} val
   * @returns {Dict<K,V>}
   */
  set(key, val) {
    const addedLeaf = { val: false };
    const root = this.root === void 0 ? EMPTY : this.root;
    const newRoot = assoc(root, 0, getHash(key), key, val, addedLeaf);
    if (newRoot === this.root) {
      return this;
    }
    return new _Dict(newRoot, addedLeaf.val ? this.size + 1 : this.size);
  }
  /**
   * @param {K} key
   * @returns {Dict<K,V>}
   */
  delete(key) {
    if (this.root === void 0) {
      return this;
    }
    const newRoot = without(this.root, 0, getHash(key), key);
    if (newRoot === this.root) {
      return this;
    }
    if (newRoot === void 0) {
      return _Dict.new();
    }
    return new _Dict(newRoot, this.size - 1);
  }
  /**
   * @param {K} key
   * @returns {boolean}
   */
  has(key) {
    if (this.root === void 0) {
      return false;
    }
    return find(this.root, 0, getHash(key), key) !== void 0;
  }
  /**
   * @returns {[K,V][]}
   */
  entries() {
    if (this.root === void 0) {
      return [];
    }
    const result = [];
    this.forEach((v, k) => result.push([k, v]));
    return result;
  }
  /**
   *
   * @param {(val:V,key:K)=>void} fn
   */
  forEach(fn) {
    forEach(this.root, fn);
  }
  hashCode() {
    let h = 0;
    this.forEach((v, k) => {
      h = h + hashMerge(getHash(v), getHash(k)) | 0;
    });
    return h;
  }
  /**
   * @param {unknown} o
   * @returns {boolean}
   */
  equals(o) {
    if (!(o instanceof _Dict) || this.size !== o.size) {
      return false;
    }
    try {
      this.forEach((v, k) => {
        if (!isEqual(o.get(k, !v), v)) {
          throw unequalDictSymbol;
        }
      });
      return true;
    } catch (e) {
      if (e === unequalDictSymbol) {
        return false;
      }
      throw e;
    }
  }
};
var unequalDictSymbol = /* @__PURE__ */ Symbol();

// build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
var Nil = void 0;
var NOT_FOUND = {};
function identity(x) {
  return x;
}
function parse_int(value) {
  if (/^[-+]?(\d+)$/.test(value)) {
    return new Ok(parseInt(value));
  } else {
    return new Error(Nil);
  }
}
function to_string(term) {
  return term.toString();
}
function graphemes(string3) {
  const iterator = graphemes_iterator(string3);
  if (iterator) {
    return List.fromArray(Array.from(iterator).map((item) => item.segment));
  } else {
    return List.fromArray(string3.match(/./gsu));
  }
}
var segmenter = void 0;
function graphemes_iterator(string3) {
  if (globalThis.Intl && Intl.Segmenter) {
    segmenter ||= new Intl.Segmenter();
    return segmenter.segment(string3)[Symbol.iterator]();
  }
}
function pop_grapheme(string3) {
  let first2;
  const iterator = graphemes_iterator(string3);
  if (iterator) {
    first2 = iterator.next().value?.segment;
  } else {
    first2 = string3.match(/./su)?.[0];
  }
  if (first2) {
    return new Ok([first2, string3.slice(first2.length)]);
  } else {
    return new Error(Nil);
  }
}
function split(xs, pattern) {
  return List.fromArray(xs.split(pattern));
}
var unicode_whitespaces = [
  " ",
  // Space
  "	",
  // Horizontal tab
  "\n",
  // Line feed
  "\v",
  // Vertical tab
  "\f",
  // Form feed
  "\r",
  // Carriage return
  "\x85",
  // Next line
  "\u2028",
  // Line separator
  "\u2029"
  // Paragraph separator
].join("");
var trim_start_regex = /* @__PURE__ */ new RegExp(
  `^[${unicode_whitespaces}]*`
);
var trim_end_regex = /* @__PURE__ */ new RegExp(`[${unicode_whitespaces}]*$`);
function new_map() {
  return Dict.new();
}
function map_to_list(map4) {
  return List.fromArray(map4.entries());
}
function map_get(map4, key) {
  const value = map4.get(key, NOT_FOUND);
  if (value === NOT_FOUND) {
    return new Error(Nil);
  }
  return new Ok(value);
}
function map_insert(key, value, map4) {
  return map4.set(key, value);
}

// build/dev/javascript/gleam_stdlib/gleam/dict.mjs
function insert(dict2, key, value) {
  return map_insert(key, value, dict2);
}
function from_list_loop(loop$list, loop$initial) {
  while (true) {
    let list2 = loop$list;
    let initial = loop$initial;
    if (list2.hasLength(0)) {
      return initial;
    } else {
      let key = list2.head[0];
      let value = list2.head[1];
      let rest = list2.tail;
      loop$list = rest;
      loop$initial = insert(initial, key, value);
    }
  }
}
function from_list(list2) {
  return from_list_loop(list2, new_map());
}
function reverse_and_concat(loop$remaining, loop$accumulator) {
  while (true) {
    let remaining = loop$remaining;
    let accumulator = loop$accumulator;
    if (remaining.hasLength(0)) {
      return accumulator;
    } else {
      let first2 = remaining.head;
      let rest = remaining.tail;
      loop$remaining = rest;
      loop$accumulator = prepend(first2, accumulator);
    }
  }
}
function do_keys_loop(loop$list, loop$acc) {
  while (true) {
    let list2 = loop$list;
    let acc = loop$acc;
    if (list2.hasLength(0)) {
      return reverse_and_concat(acc, toList([]));
    } else {
      let key = list2.head[0];
      let rest = list2.tail;
      loop$list = rest;
      loop$acc = prepend(key, acc);
    }
  }
}
function keys(dict2) {
  return do_keys_loop(map_to_list(dict2), toList([]));
}
function do_values_loop(loop$list, loop$acc) {
  while (true) {
    let list2 = loop$list;
    let acc = loop$acc;
    if (list2.hasLength(0)) {
      return reverse_and_concat(acc, toList([]));
    } else {
      let value = list2.head[1];
      let rest = list2.tail;
      loop$list = rest;
      loop$acc = prepend(value, acc);
    }
  }
}
function values(dict2) {
  let list_of_pairs = map_to_list(dict2);
  return do_values_loop(list_of_pairs, toList([]));
}

// build/dev/javascript/gleam_stdlib/gleam/uri.mjs
var Uri = class extends CustomType {
  constructor(scheme, userinfo, host, port, path, query, fragment) {
    super();
    this.scheme = scheme;
    this.userinfo = userinfo;
    this.host = host;
    this.port = port;
    this.path = path;
    this.query = query;
    this.fragment = fragment;
  }
};
function remove_dot_segments_loop(loop$input, loop$accumulator) {
  while (true) {
    let input = loop$input;
    let accumulator = loop$accumulator;
    if (input.hasLength(0)) {
      return reverse(accumulator);
    } else {
      let segment = input.head;
      let rest = input.tail;
      let _block;
      if (segment === "") {
        let accumulator$12 = accumulator;
        _block = accumulator$12;
      } else if (segment === ".") {
        let accumulator$12 = accumulator;
        _block = accumulator$12;
      } else if (segment === ".." && accumulator.hasLength(0)) {
        _block = toList([]);
      } else if (segment === ".." && accumulator.atLeastLength(1)) {
        let accumulator$12 = accumulator.tail;
        _block = accumulator$12;
      } else {
        let segment$1 = segment;
        let accumulator$12 = accumulator;
        _block = prepend(segment$1, accumulator$12);
      }
      let accumulator$1 = _block;
      loop$input = rest;
      loop$accumulator = accumulator$1;
    }
  }
}
function remove_dot_segments(input) {
  return remove_dot_segments_loop(input, toList([]));
}
function path_segments(path) {
  return remove_dot_segments(split2(path, "/"));
}

// build/dev/javascript/gleam_stdlib/gleam/bool.mjs
function guard(requirement, consequence, alternative) {
  if (requirement) {
    return consequence;
  } else {
    return alternative();
  }
}

// build/dev/javascript/lustre/lustre/effect.mjs
var Effect = class extends CustomType {
  constructor(all) {
    super();
    this.all = all;
  }
};
function custom(run2) {
  return new Effect(
    toList([
      (actions) => {
        return run2(actions.dispatch, actions.emit, actions.select, actions.root);
      }
    ])
  );
}
function from(effect) {
  return custom((dispatch, _, _1, _2) => {
    return effect(dispatch);
  });
}
function none() {
  return new Effect(toList([]));
}

// build/dev/javascript/lustre/lustre/internals/vdom.mjs
var Text = class extends CustomType {
  constructor(content) {
    super();
    this.content = content;
  }
};
var Element = class extends CustomType {
  constructor(key, namespace, tag, attrs, children2, self_closing, void$) {
    super();
    this.key = key;
    this.namespace = namespace;
    this.tag = tag;
    this.attrs = attrs;
    this.children = children2;
    this.self_closing = self_closing;
    this.void = void$;
  }
};
var Map2 = class extends CustomType {
  constructor(subtree) {
    super();
    this.subtree = subtree;
  }
};
var Attribute = class extends CustomType {
  constructor(x0, x1, as_property) {
    super();
    this[0] = x0;
    this[1] = x1;
    this.as_property = as_property;
  }
};
function attribute_to_event_handler(attribute2) {
  if (attribute2 instanceof Attribute) {
    return new Error(void 0);
  } else {
    let name = attribute2[0];
    let handler = attribute2[1];
    let name$1 = drop_start(name, 2);
    return new Ok([name$1, handler]);
  }
}
function do_element_list_handlers(elements2, handlers2, key) {
  return index_fold(
    elements2,
    handlers2,
    (handlers3, element2, index3) => {
      let key$1 = key + "-" + to_string(index3);
      return do_handlers(element2, handlers3, key$1);
    }
  );
}
function do_handlers(loop$element, loop$handlers, loop$key) {
  while (true) {
    let element2 = loop$element;
    let handlers2 = loop$handlers;
    let key = loop$key;
    if (element2 instanceof Text) {
      return handlers2;
    } else if (element2 instanceof Map2) {
      let subtree = element2.subtree;
      loop$element = subtree();
      loop$handlers = handlers2;
      loop$key = key;
    } else {
      let attrs = element2.attrs;
      let children2 = element2.children;
      let handlers$1 = fold(
        attrs,
        handlers2,
        (handlers3, attr) => {
          let $ = attribute_to_event_handler(attr);
          if ($.isOk()) {
            let name = $[0][0];
            let handler = $[0][1];
            return insert(handlers3, key + "-" + name, handler);
          } else {
            return handlers3;
          }
        }
      );
      return do_element_list_handlers(children2, handlers$1, key);
    }
  }
}
function handlers(element2) {
  return do_handlers(element2, new_map(), "0");
}

// build/dev/javascript/lustre/lustre/attribute.mjs
function attribute(name, value) {
  return new Attribute(name, identity(value), false);
}
function class$(name) {
  return attribute("class", name);
}
function classes(names) {
  return attribute(
    "class",
    (() => {
      let _pipe = names;
      let _pipe$1 = filter_map(
        _pipe,
        (class$2) => {
          let $ = class$2[1];
          if ($) {
            return new Ok(class$2[0]);
          } else {
            return new Error(void 0);
          }
        }
      );
      return join(_pipe$1, " ");
    })()
  );
}
function href(uri) {
  return attribute("href", uri);
}

// build/dev/javascript/lustre/lustre/element.mjs
function element(tag, attrs, children2) {
  if (tag === "area") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "base") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "br") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "col") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "embed") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "hr") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "img") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "input") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "link") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "meta") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "param") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "source") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "track") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else if (tag === "wbr") {
    return new Element("", "", tag, attrs, toList([]), false, true);
  } else {
    return new Element("", "", tag, attrs, children2, false, false);
  }
}
function text(content) {
  return new Text(content);
}

// build/dev/javascript/gleam_stdlib/gleam/set.mjs
var Set2 = class extends CustomType {
  constructor(dict2) {
    super();
    this.dict = dict2;
  }
};
function new$2() {
  return new Set2(new_map());
}

// build/dev/javascript/lustre/lustre/internals/patch.mjs
var Diff = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var Emit = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
var Init = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
function is_empty_element_diff(diff2) {
  return isEqual(diff2.created, new_map()) && isEqual(
    diff2.removed,
    new$2()
  ) && isEqual(diff2.updated, new_map());
}

// build/dev/javascript/lustre/lustre/internals/runtime.mjs
var Attrs = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var Batch = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
var Debug = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var Dispatch = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var Emit2 = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
var Event2 = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
var Shutdown = class extends CustomType {
};
var Subscribe = class extends CustomType {
  constructor(x0, x1) {
    super();
    this[0] = x0;
    this[1] = x1;
  }
};
var Unsubscribe = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};
var ForceModel = class extends CustomType {
  constructor(x0) {
    super();
    this[0] = x0;
  }
};

// build/dev/javascript/lustre/vdom.ffi.mjs
if (globalThis.customElements && !globalThis.customElements.get("lustre-fragment")) {
  globalThis.customElements.define(
    "lustre-fragment",
    class LustreFragment extends HTMLElement {
      constructor() {
        super();
      }
    }
  );
}
function morph(prev, next, dispatch) {
  let out;
  let stack = [{ prev, next, parent: prev.parentNode }];
  while (stack.length) {
    let { prev: prev2, next: next2, parent } = stack.pop();
    while (next2.subtree !== void 0) next2 = next2.subtree();
    if (next2.content !== void 0) {
      if (!prev2) {
        const created = document.createTextNode(next2.content);
        parent.appendChild(created);
        out ??= created;
      } else if (prev2.nodeType === Node.TEXT_NODE) {
        if (prev2.textContent !== next2.content) prev2.textContent = next2.content;
        out ??= prev2;
      } else {
        const created = document.createTextNode(next2.content);
        parent.replaceChild(created, prev2);
        out ??= created;
      }
    } else if (next2.tag !== void 0) {
      const created = createElementNode({
        prev: prev2,
        next: next2,
        dispatch,
        stack
      });
      if (!prev2) {
        parent.appendChild(created);
      } else if (prev2 !== created) {
        parent.replaceChild(created, prev2);
      }
      out ??= created;
    }
  }
  return out;
}
function createElementNode({ prev, next, dispatch, stack }) {
  const namespace = next.namespace || "http://www.w3.org/1999/xhtml";
  const canMorph = prev && prev.nodeType === Node.ELEMENT_NODE && prev.localName === next.tag && prev.namespaceURI === (next.namespace || "http://www.w3.org/1999/xhtml");
  const el = canMorph ? prev : namespace ? document.createElementNS(namespace, next.tag) : document.createElement(next.tag);
  let handlersForEl;
  if (!registeredHandlers.has(el)) {
    const emptyHandlers = /* @__PURE__ */ new Map();
    registeredHandlers.set(el, emptyHandlers);
    handlersForEl = emptyHandlers;
  } else {
    handlersForEl = registeredHandlers.get(el);
  }
  const prevHandlers = canMorph ? new Set(handlersForEl.keys()) : null;
  const prevAttributes = canMorph ? new Set(Array.from(prev.attributes, (a2) => a2.name)) : null;
  let className = null;
  let style2 = null;
  let innerHTML = null;
  if (canMorph && next.tag === "textarea") {
    const innertText = next.children[Symbol.iterator]().next().value?.content;
    if (innertText !== void 0) el.value = innertText;
  }
  const delegated = [];
  for (const attr of next.attrs) {
    const name = attr[0];
    const value = attr[1];
    if (attr.as_property) {
      if (el[name] !== value) el[name] = value;
      if (canMorph) prevAttributes.delete(name);
    } else if (name.startsWith("on")) {
      const eventName = name.slice(2);
      const callback = dispatch(value, eventName === "input");
      if (!handlersForEl.has(eventName)) {
        el.addEventListener(eventName, lustreGenericEventHandler);
      }
      handlersForEl.set(eventName, callback);
      if (canMorph) prevHandlers.delete(eventName);
    } else if (name.startsWith("data-lustre-on-")) {
      const eventName = name.slice(15);
      const callback = dispatch(lustreServerEventHandler);
      if (!handlersForEl.has(eventName)) {
        el.addEventListener(eventName, lustreGenericEventHandler);
      }
      handlersForEl.set(eventName, callback);
      el.setAttribute(name, value);
      if (canMorph) {
        prevHandlers.delete(eventName);
        prevAttributes.delete(name);
      }
    } else if (name.startsWith("delegate:data-") || name.startsWith("delegate:aria-")) {
      el.setAttribute(name, value);
      delegated.push([name.slice(10), value]);
    } else if (name === "class") {
      className = className === null ? value : className + " " + value;
    } else if (name === "style") {
      style2 = style2 === null ? value : style2 + value;
    } else if (name === "dangerous-unescaped-html") {
      innerHTML = value;
    } else {
      if (el.getAttribute(name) !== value) el.setAttribute(name, value);
      if (name === "value" || name === "selected") el[name] = value;
      if (canMorph) prevAttributes.delete(name);
    }
  }
  if (className !== null) {
    el.setAttribute("class", className);
    if (canMorph) prevAttributes.delete("class");
  }
  if (style2 !== null) {
    el.setAttribute("style", style2);
    if (canMorph) prevAttributes.delete("style");
  }
  if (canMorph) {
    for (const attr of prevAttributes) {
      el.removeAttribute(attr);
    }
    for (const eventName of prevHandlers) {
      handlersForEl.delete(eventName);
      el.removeEventListener(eventName, lustreGenericEventHandler);
    }
  }
  if (next.tag === "slot") {
    window.queueMicrotask(() => {
      for (const child of el.assignedElements()) {
        for (const [name, value] of delegated) {
          if (!child.hasAttribute(name)) {
            child.setAttribute(name, value);
          }
        }
      }
    });
  }
  if (next.key !== void 0 && next.key !== "") {
    el.setAttribute("data-lustre-key", next.key);
  } else if (innerHTML !== null) {
    el.innerHTML = innerHTML;
    return el;
  }
  let prevChild = el.firstChild;
  let seenKeys = null;
  let keyedChildren = null;
  let incomingKeyedChildren = null;
  let firstChild = children(next).next().value;
  if (canMorph && firstChild !== void 0 && // Explicit checks are more verbose but truthy checks force a bunch of comparisons
  // we don't care about: it's never gonna be a number etc.
  firstChild.key !== void 0 && firstChild.key !== "") {
    seenKeys = /* @__PURE__ */ new Set();
    keyedChildren = getKeyedChildren(prev);
    incomingKeyedChildren = getKeyedChildren(next);
    for (const child of children(next)) {
      prevChild = diffKeyedChild(
        prevChild,
        child,
        el,
        stack,
        incomingKeyedChildren,
        keyedChildren,
        seenKeys
      );
    }
  } else {
    for (const child of children(next)) {
      stack.unshift({ prev: prevChild, next: child, parent: el });
      prevChild = prevChild?.nextSibling;
    }
  }
  while (prevChild) {
    const next2 = prevChild.nextSibling;
    el.removeChild(prevChild);
    prevChild = next2;
  }
  return el;
}
var registeredHandlers = /* @__PURE__ */ new WeakMap();
function lustreGenericEventHandler(event) {
  const target = event.currentTarget;
  if (!registeredHandlers.has(target)) {
    target.removeEventListener(event.type, lustreGenericEventHandler);
    return;
  }
  const handlersForEventTarget = registeredHandlers.get(target);
  if (!handlersForEventTarget.has(event.type)) {
    target.removeEventListener(event.type, lustreGenericEventHandler);
    return;
  }
  handlersForEventTarget.get(event.type)(event);
}
function lustreServerEventHandler(event) {
  const el = event.currentTarget;
  const tag = el.getAttribute(`data-lustre-on-${event.type}`);
  const data = JSON.parse(el.getAttribute("data-lustre-data") || "{}");
  const include = JSON.parse(el.getAttribute("data-lustre-include") || "[]");
  switch (event.type) {
    case "input":
    case "change":
      include.push("target.value");
      break;
  }
  return {
    tag,
    data: include.reduce(
      (data2, property) => {
        const path = property.split(".");
        for (let i = 0, o = data2, e = event; i < path.length; i++) {
          if (i === path.length - 1) {
            o[path[i]] = e[path[i]];
          } else {
            o[path[i]] ??= {};
            e = e[path[i]];
            o = o[path[i]];
          }
        }
        return data2;
      },
      { data }
    )
  };
}
function getKeyedChildren(el) {
  const keyedChildren = /* @__PURE__ */ new Map();
  if (el) {
    for (const child of children(el)) {
      const key = child?.key || child?.getAttribute?.("data-lustre-key");
      if (key) keyedChildren.set(key, child);
    }
  }
  return keyedChildren;
}
function diffKeyedChild(prevChild, child, el, stack, incomingKeyedChildren, keyedChildren, seenKeys) {
  while (prevChild && !incomingKeyedChildren.has(prevChild.getAttribute("data-lustre-key"))) {
    const nextChild = prevChild.nextSibling;
    el.removeChild(prevChild);
    prevChild = nextChild;
  }
  if (keyedChildren.size === 0) {
    stack.unshift({ prev: prevChild, next: child, parent: el });
    prevChild = prevChild?.nextSibling;
    return prevChild;
  }
  if (seenKeys.has(child.key)) {
    console.warn(`Duplicate key found in Lustre vnode: ${child.key}`);
    stack.unshift({ prev: null, next: child, parent: el });
    return prevChild;
  }
  seenKeys.add(child.key);
  const keyedChild = keyedChildren.get(child.key);
  if (!keyedChild && !prevChild) {
    stack.unshift({ prev: null, next: child, parent: el });
    return prevChild;
  }
  if (!keyedChild && prevChild !== null) {
    const placeholder = document.createTextNode("");
    el.insertBefore(placeholder, prevChild);
    stack.unshift({ prev: placeholder, next: child, parent: el });
    return prevChild;
  }
  if (!keyedChild || keyedChild === prevChild) {
    stack.unshift({ prev: prevChild, next: child, parent: el });
    prevChild = prevChild?.nextSibling;
    return prevChild;
  }
  el.insertBefore(keyedChild, prevChild);
  stack.unshift({ prev: keyedChild, next: child, parent: el });
  return prevChild;
}
function* children(element2) {
  for (const child of element2.children) {
    yield* forceChild(child);
  }
}
function* forceChild(element2) {
  if (element2.subtree !== void 0) {
    yield* forceChild(element2.subtree());
  } else {
    yield element2;
  }
}

// build/dev/javascript/lustre/lustre.ffi.mjs
var LustreClientApplication = class _LustreClientApplication {
  /**
   * @template Flags
   *
   * @param {object} app
   * @param {(flags: Flags) => [Model, Lustre.Effect<Msg>]} app.init
   * @param {(msg: Msg, model: Model) => [Model, Lustre.Effect<Msg>]} app.update
   * @param {(model: Model) => Lustre.Element<Msg>} app.view
   * @param {string | HTMLElement} selector
   * @param {Flags} flags
   *
   * @returns {Gleam.Ok<(action: Lustre.Action<Lustre.Client, Msg>>) => void>}
   */
  static start({ init: init4, update: update2, view: view2 }, selector, flags) {
    if (!is_browser()) return new Error(new NotABrowser());
    const root = selector instanceof HTMLElement ? selector : document.querySelector(selector);
    if (!root) return new Error(new ElementNotFound(selector));
    const app = new _LustreClientApplication(root, init4(flags), update2, view2);
    return new Ok((action) => app.send(action));
  }
  /**
   * @param {Element} root
   * @param {[Model, Lustre.Effect<Msg>]} init
   * @param {(model: Model, msg: Msg) => [Model, Lustre.Effect<Msg>]} update
   * @param {(model: Model) => Lustre.Element<Msg>} view
   *
   * @returns {LustreClientApplication}
   */
  constructor(root, [init4, effects], update2, view2) {
    this.root = root;
    this.#model = init4;
    this.#update = update2;
    this.#view = view2;
    this.#tickScheduled = window.setTimeout(
      () => this.#tick(effects.all.toArray(), true),
      0
    );
  }
  /** @type {Element} */
  root;
  /**
   * @param {Lustre.Action<Lustre.Client, Msg>} action
   *
   * @returns {void}
   */
  send(action) {
    if (action instanceof Debug) {
      if (action[0] instanceof ForceModel) {
        this.#tickScheduled = window.clearTimeout(this.#tickScheduled);
        this.#queue = [];
        this.#model = action[0][0];
        const vdom = this.#view(this.#model);
        const dispatch = (handler, immediate = false) => (event) => {
          const result = handler(event);
          if (result instanceof Ok) {
            this.send(new Dispatch(result[0], immediate));
          }
        };
        const prev = this.root.firstChild ?? this.root.appendChild(document.createTextNode(""));
        morph(prev, vdom, dispatch);
      }
    } else if (action instanceof Dispatch) {
      const msg = action[0];
      const immediate = action[1] ?? false;
      this.#queue.push(msg);
      if (immediate) {
        this.#tickScheduled = window.clearTimeout(this.#tickScheduled);
        this.#tick();
      } else if (!this.#tickScheduled) {
        this.#tickScheduled = window.setTimeout(() => this.#tick());
      }
    } else if (action instanceof Emit2) {
      const event = action[0];
      const data = action[1];
      this.root.dispatchEvent(
        new CustomEvent(event, {
          detail: data,
          bubbles: true,
          composed: true
        })
      );
    } else if (action instanceof Shutdown) {
      this.#tickScheduled = window.clearTimeout(this.#tickScheduled);
      this.#model = null;
      this.#update = null;
      this.#view = null;
      this.#queue = null;
      while (this.root.firstChild) {
        this.root.firstChild.remove();
      }
    }
  }
  /** @type {Model} */
  #model;
  /** @type {(model: Model, msg: Msg) => [Model, Lustre.Effect<Msg>]} */
  #update;
  /** @type {(model: Model) => Lustre.Element<Msg>} */
  #view;
  /** @type {Array<Msg>} */
  #queue = [];
  /** @type {number | undefined} */
  #tickScheduled;
  /**
   * @param {Lustre.Effect<Msg>[]} effects
   */
  #tick(effects = []) {
    this.#tickScheduled = void 0;
    this.#flush(effects);
    const vdom = this.#view(this.#model);
    const dispatch = (handler, immediate = false) => (event) => {
      const result = handler(event);
      if (result instanceof Ok) {
        this.send(new Dispatch(result[0], immediate));
      }
    };
    const prev = this.root.firstChild ?? this.root.appendChild(document.createTextNode(""));
    morph(prev, vdom, dispatch);
  }
  #flush(effects = []) {
    while (this.#queue.length > 0) {
      const msg = this.#queue.shift();
      const [next, effect] = this.#update(this.#model, msg);
      effects = effects.concat(effect.all.toArray());
      this.#model = next;
    }
    while (effects.length > 0) {
      const effect = effects.shift();
      const dispatch = (msg) => this.send(new Dispatch(msg));
      const emit2 = (event, data) => this.root.dispatchEvent(
        new CustomEvent(event, {
          detail: data,
          bubbles: true,
          composed: true
        })
      );
      const select = () => {
      };
      const root = this.root;
      effect({ dispatch, emit: emit2, select, root });
    }
    if (this.#queue.length > 0) {
      this.#flush(effects);
    }
  }
};
var start = LustreClientApplication.start;
var LustreServerApplication = class _LustreServerApplication {
  static start({ init: init4, update: update2, view: view2, on_attribute_change }, flags) {
    const app = new _LustreServerApplication(
      init4(flags),
      update2,
      view2,
      on_attribute_change
    );
    return new Ok((action) => app.send(action));
  }
  constructor([model, effects], update2, view2, on_attribute_change) {
    this.#model = model;
    this.#update = update2;
    this.#view = view2;
    this.#html = view2(model);
    this.#onAttributeChange = on_attribute_change;
    this.#renderers = /* @__PURE__ */ new Map();
    this.#handlers = handlers(this.#html);
    this.#tick(effects.all.toArray());
  }
  send(action) {
    if (action instanceof Attrs) {
      for (const attr of action[0]) {
        const decoder = this.#onAttributeChange.get(attr[0]);
        if (!decoder) continue;
        const msg = decoder(attr[1]);
        if (msg instanceof Error) continue;
        this.#queue.push(msg);
      }
      this.#tick();
    } else if (action instanceof Batch) {
      this.#queue = this.#queue.concat(action[0].toArray());
      this.#tick(action[1].all.toArray());
    } else if (action instanceof Debug) {
    } else if (action instanceof Dispatch) {
      this.#queue.push(action[0]);
      this.#tick();
    } else if (action instanceof Emit2) {
      const event = new Emit(action[0], action[1]);
      for (const [_, renderer] of this.#renderers) {
        renderer(event);
      }
    } else if (action instanceof Event2) {
      const handler = this.#handlers.get(action[0]);
      if (!handler) return;
      const msg = handler(action[1]);
      if (msg instanceof Error) return;
      this.#queue.push(msg[0]);
      this.#tick();
    } else if (action instanceof Subscribe) {
      const attrs = keys(this.#onAttributeChange);
      const patch = new Init(attrs, this.#html);
      this.#renderers = this.#renderers.set(action[0], action[1]);
      action[1](patch);
    } else if (action instanceof Unsubscribe) {
      this.#renderers = this.#renderers.delete(action[0]);
    }
  }
  #model;
  #update;
  #queue;
  #view;
  #html;
  #renderers;
  #handlers;
  #onAttributeChange;
  #tick(effects = []) {
    this.#flush(effects);
    const vdom = this.#view(this.#model);
    const diff2 = elements(this.#html, vdom);
    if (!is_empty_element_diff(diff2)) {
      const patch = new Diff(diff2);
      for (const [_, renderer] of this.#renderers) {
        renderer(patch);
      }
    }
    this.#html = vdom;
    this.#handlers = diff2.handlers;
  }
  #flush(effects = []) {
    while (this.#queue.length > 0) {
      const msg = this.#queue.shift();
      const [next, effect] = this.#update(this.#model, msg);
      effects = effects.concat(effect.all.toArray());
      this.#model = next;
    }
    while (effects.length > 0) {
      const effect = effects.shift();
      const dispatch = (msg) => this.send(new Dispatch(msg));
      const emit2 = (event, data) => this.root.dispatchEvent(
        new CustomEvent(event, {
          detail: data,
          bubbles: true,
          composed: true
        })
      );
      const select = () => {
      };
      const root = null;
      effect({ dispatch, emit: emit2, select, root });
    }
    if (this.#queue.length > 0) {
      this.#flush(effects);
    }
  }
};
var start_server_application = LustreServerApplication.start;
var is_browser = () => globalThis.window && window.document;

// build/dev/javascript/lustre/lustre.mjs
var App = class extends CustomType {
  constructor(init4, update2, view2, on_attribute_change) {
    super();
    this.init = init4;
    this.update = update2;
    this.view = view2;
    this.on_attribute_change = on_attribute_change;
  }
};
var ElementNotFound = class extends CustomType {
  constructor(selector) {
    super();
    this.selector = selector;
  }
};
var NotABrowser = class extends CustomType {
};
function application(init4, update2, view2) {
  return new App(init4, update2, view2, new None());
}
function start2(app, selector, flags) {
  return guard(
    !is_browser(),
    new Error(new NotABrowser()),
    () => {
      return start(app, selector, flags);
    }
  );
}

// build/dev/javascript/lustre/lustre/element/html.mjs
function text2(content) {
  return text(content);
}
function article(attrs, children2) {
  return element("article", attrs, children2);
}
function h1(attrs, children2) {
  return element("h1", attrs, children2);
}
function h2(attrs, children2) {
  return element("h2", attrs, children2);
}
function h3(attrs, children2) {
  return element("h3", attrs, children2);
}
function main(attrs, children2) {
  return element("main", attrs, children2);
}
function nav(attrs, children2) {
  return element("nav", attrs, children2);
}
function div(attrs, children2) {
  return element("div", attrs, children2);
}
function li(attrs, children2) {
  return element("li", attrs, children2);
}
function p(attrs, children2) {
  return element("p", attrs, children2);
}
function ul(attrs, children2) {
  return element("ul", attrs, children2);
}
function a(attrs, children2) {
  return element("a", attrs, children2);
}

// build/dev/javascript/modem/modem.ffi.mjs
var defaults = {
  handle_external_links: false,
  handle_internal_links: true
};
var initial_location = window?.location?.href;
var do_initial_uri = () => {
  if (!initial_location) {
    return new Error(void 0);
  } else {
    return new Ok(uri_from_url(new URL(initial_location)));
  }
};
var do_init = (dispatch, options = defaults) => {
  document.addEventListener("click", (event) => {
    const a2 = find_anchor(event.target);
    if (!a2) return;
    try {
      const url = new URL(a2.href);
      const uri = uri_from_url(url);
      const is_external = url.host !== window.location.host;
      if (!options.handle_external_links && is_external) return;
      if (!options.handle_internal_links && !is_external) return;
      event.preventDefault();
      if (!is_external) {
        window.history.pushState({}, "", a2.href);
        window.requestAnimationFrame(() => {
          if (url.hash) {
            document.getElementById(url.hash.slice(1))?.scrollIntoView();
          }
        });
      }
      return dispatch(uri);
    } catch {
      return;
    }
  });
  window.addEventListener("popstate", (e) => {
    e.preventDefault();
    const url = new URL(window.location.href);
    const uri = uri_from_url(url);
    window.requestAnimationFrame(() => {
      if (url.hash) {
        document.getElementById(url.hash.slice(1))?.scrollIntoView();
      }
    });
    dispatch(uri);
  });
  window.addEventListener("modem-push", ({ detail }) => {
    dispatch(detail);
  });
  window.addEventListener("modem-replace", ({ detail }) => {
    dispatch(detail);
  });
};
var find_anchor = (el) => {
  if (!el || el.tagName === "BODY") {
    return null;
  } else if (el.tagName === "A") {
    return el;
  } else {
    return find_anchor(el.parentElement);
  }
};
var uri_from_url = (url) => {
  return new Uri(
    /* scheme   */
    url.protocol ? new Some(url.protocol.slice(0, -1)) : new None(),
    /* userinfo */
    new None(),
    /* host     */
    url.hostname ? new Some(url.hostname) : new None(),
    /* port     */
    url.port ? new Some(Number(url.port)) : new None(),
    /* path     */
    url.pathname,
    /* query    */
    url.search ? new Some(url.search.slice(1)) : new None(),
    /* fragment */
    url.hash ? new Some(url.hash.slice(1)) : new None()
  );
};

// build/dev/javascript/modem/modem.mjs
function init2(handler) {
  return from(
    (dispatch) => {
      return guard(
        !is_browser(),
        void 0,
        () => {
          return do_init(
            (uri) => {
              let _pipe = uri;
              let _pipe$1 = handler(_pipe);
              return dispatch(_pipe$1);
            }
          );
        }
      );
    }
  );
}

// build/dev/javascript/jst_lustre/jst_lustre.mjs
var Model2 = class extends CustomType {
  constructor(posts2, route) {
    super();
    this.posts = posts2;
    this.route = route;
  }
};
var Post = class extends CustomType {
  constructor(id, title2, subtitle2, summary, text3) {
    super();
    this.id = id;
    this.title = title2;
    this.subtitle = subtitle2;
    this.summary = summary;
    this.text = text3;
  }
};
var Index = class extends CustomType {
};
var Posts = class extends CustomType {
};
var PostById = class extends CustomType {
  constructor(id) {
    super();
    this.id = id;
  }
};
var About = class extends CustomType {
};
var NotFound = class extends CustomType {
  constructor(uri) {
    super();
    this.uri = uri;
  }
};
var UserNavigatedTo = class extends CustomType {
  constructor(route) {
    super();
    this.route = route;
  }
};
function parse_route(uri) {
  let $ = path_segments(uri.path);
  if ($.hasLength(0)) {
    return new Index();
  } else if ($.hasLength(1) && $.head === "") {
    return new Index();
  } else if ($.hasLength(1) && $.head === "posts") {
    return new Posts();
  } else if ($.hasLength(2) && $.head === "post") {
    let post_id = $.tail.head;
    let $1 = parse_int(post_id);
    if ($1.isOk()) {
      let post_id$1 = $1[0];
      return new PostById(post_id$1);
    } else {
      return new NotFound(uri);
    }
  } else if ($.hasLength(1) && $.head === "about") {
    return new About();
  } else {
    return new NotFound(uri);
  }
}
function href2(route) {
  let _block;
  if (route instanceof Index) {
    _block = "/";
  } else if (route instanceof About) {
    _block = "/about";
  } else if (route instanceof Posts) {
    _block = "/posts";
  } else if (route instanceof PostById) {
    let post_id = route.id;
    _block = "/post/" + to_string(post_id);
  } else {
    _block = "/404";
  }
  let url = _block;
  return href(url);
}
function update(model, msg) {
  {
    let route = msg.route;
    return [
      (() => {
        let _record = model;
        return new Model2(_record.posts, route);
      })(),
      none()
    ];
  }
}
function view_header_link(target, current, text3) {
  let _block;
  if (current instanceof PostById && target instanceof Posts) {
    _block = true;
  } else {
    _block = isEqual(current, target);
  }
  let is_active = _block;
  return li(
    toList([
      classes(
        toList([
          ["border-transparent border-b-2 hover:border-pink-700", true],
          ["text-pink-700", is_active]
        ])
      )
    ]),
    toList([a(toList([href2(target)]), toList([text2(text3)]))])
  );
}
function view_header(model) {
  return nav(
    toList([
      class$("py-2 border-b bg-zinc-800 border-pink-700 font-mono ")
    ]),
    toList([
      div(
        toList([
          class$(
            "flex justify-between px-10 items-center max-w-screen-md mx-auto"
          )
        ]),
        toList([
          div(
            toList([]),
            toList([
              a(
                toList([class$("font-light"), href2(new Index())]),
                toList([text2("jst.dev")])
              )
            ])
          ),
          ul(
            toList([class$("flex space-x-8 pr-2")]),
            toList([
              view_header_link(new Posts(), model.route, "Posts"),
              view_header_link(new About(), model.route, "About")
            ])
          )
        ])
      )
    ])
  );
}
function title(title2) {
  return h1(
    toList([class$("text-3xl pt-8 text-pink-700 font-light")]),
    toList([text2(title2)])
  );
}
function view_posts(model) {
  let _block;
  let _pipe = model.posts;
  let _pipe$1 = values(_pipe);
  let _pipe$2 = sort(
    _pipe$1,
    (a2, b) => {
      return compare(a2.id, b.id);
    }
  );
  _block = map(
    _pipe$2,
    (post) => {
      return article(
        toList([class$("mt-14")]),
        toList([
          h3(
            toList([class$("text-xl text-pink-700 font-light")]),
            toList([
              a(
                toList([
                  class$("hover:underline"),
                  href2(new PostById(post.id))
                ]),
                toList([text2(post.title)])
              )
            ])
          ),
          p(
            toList([class$("mt-1")]),
            toList([text2(post.summary)])
          )
        ])
      );
    }
  );
  let posts$1 = _block;
  return prepend(title("Posts"), posts$1);
}
function subtitle(title2) {
  return h2(
    toList([class$("text-md text-zinc-600 font-light")]),
    toList([text2(title2)])
  );
}
function leading(text3) {
  return p(
    toList([class$("font-bold pt-12")]),
    toList([text2(text3)])
  );
}
function paragraph(text3) {
  return p(
    toList([class$("pt-8")]),
    toList([text2(text3)])
  );
}
function view_about() {
  return toList([
    title("About"),
    paragraph(
      "I'm a software developer and a writer. I'm also a father and a husband. \n      I'm also a software developer and a writer. I'm also a father and a \n      husband. I'm also a software developer and a writer. I'm also a father \n      and a husband. I'm also a software developer and a writer. I'm also a \n      father and a husband."
    ),
    paragraph(
      "If you enjoy these glimpses into my mind, feel free to come back\n       semi-regularly. But not too regularly, you creep."
    )
  ]);
}
function view_not_found() {
  return toList([
    title("Not found"),
    paragraph(
      "You glimpse into the void and see -- nothing?\n       Well that was somewhat expected."
    )
  ]);
}
function link(target, title2) {
  return a(
    toList([
      href2(target),
      class$("text-pink-700 hover:underline cursor-pointer")
    ]),
    toList([text2(title2)])
  );
}
function view_index() {
  return toList([
    title("Welcome to jst.dev!"),
    subtitle(
      "...or, A lession on overengineering for fun and.. \n      well just for fun."
    ),
    leading(
      "This site and it's underlying IT-infrastructure is the primary \n      place for me to experiment with technologies and topologies. I \n      also share some of my thoughts and learnings here."
    ),
    p(
      toList([class$("mt-14")]),
      toList([
        text2(
          "This site and it's underlying IT-infrastructure is the primary \n        place for me to experiment with technologies and topologies. I \n        also share some of my thoughts and learnings here. Feel free to \n        check out my overview, "
        ),
        link(new Posts(), "NATS all the way down ->")
      ])
    ),
    paragraph(
      "It to is a work in progress and I mostly keep it here for my own reference."
    ),
    paragraph(
      "I'm also a software developer and a writer. I'm also a father and a \n      husband. I'm also a software developer and a writer. I'm also a father \n      and a husband. I'm also a software developer and a writer. I'm also a \n      father and a husband. I'm also a software developer and a writer."
    )
  ]);
}
function view_post(model, post_id) {
  let $ = map_get(model.posts, post_id);
  if (!$.isOk()) {
    return view_not_found();
  } else {
    let post = $[0];
    return toList([
      article(
        toList([]),
        toList([title(post.title), leading(post.summary), paragraph(post.text)])
      ),
      p(
        toList([class$("mt-14")]),
        toList([link(new Posts(), "<- Go back?")])
      )
    ]);
  }
}
function view(model) {
  return div(
    toList([
      class$("text-zinc-400 h-full w-full text-lg font-thin mx-auto")
    ]),
    toList([
      view_header(model),
      main(
        toList([class$("px-10 py-4 max-w-screen-md mx-auto")]),
        (() => {
          let $ = model.route;
          if ($ instanceof Index) {
            return view_index();
          } else if ($ instanceof Posts) {
            return view_posts(model);
          } else if ($ instanceof PostById) {
            let id = $.id;
            return view_post(model, id);
          } else if ($ instanceof About) {
            return view_about();
          } else {
            return view_not_found();
          }
        })()
      )
    ])
  );
}
var posts = /* @__PURE__ */ toList([
  /* @__PURE__ */ new Post(
    1,
    "The Empty Chair",
    "A guide to uninvited furniture and its temporal implications",
    "A guide to uninvited furniture and its temporal implications",
    "\n      There's an empty chair in my home that wasn't there yesterday. When I sit\n      in it, I start to remember things that haven't happened yet. The chair is\n      getting closer to my bedroom each night, though I never caught it move.\n      Last night, I dreamt it was watching me sleep. This morning, it offered\n      me coffee.\n    "
  ),
  /* @__PURE__ */ new Post(
    2,
    "The Library of Unwritten Books",
    "Warning: Reading this may shorten your narrative arc",
    "Warning: Reading this may shorten your narrative arc",
    "\n      Between the shelves in the public library exists a thin space where\n      books that were never written somehow exist. Their pages change when you\n      blink. Forms shifting to match the souls blueprint. Librarians warn\n      against reading the final chapter of any unwritten book \u2013 those who do\n      find their own stories mysteriously concluding. Yourself is just another\n      draft to be rewritten.\n    "
  ),
  /* @__PURE__ */ new Post(
    3,
    "The Hum",
    "",
    "A frequency analysis of the collective forgetting",
    "\n      The citywide hum started Tuesday. Not everyone can hear it, but those who\n      can't are slowly being replaced by perfect copies who smile too widely.\n      The hum isn't sound \u2013 it's the universe forgetting our coordinates.\n      Reports suggest humming back in harmony might postpone whatever comes\n      next. Or perhaps accelerate it.\n    "
  )
]);
function init3(_) {
  let _block;
  let $ = do_initial_uri();
  if ($.isOk()) {
    let uri = $[0];
    _block = parse_route(uri);
  } else {
    _block = new Index();
  }
  let route = _block;
  let _block$1;
  let _pipe = posts;
  let _pipe$1 = map(_pipe, (post) => {
    return [post.id, post];
  });
  _block$1 = from_list(_pipe$1);
  let posts$1 = _block$1;
  let model = new Model2(posts$1, route);
  let effect = init2(
    (uri) => {
      let _pipe$2 = uri;
      let _pipe$3 = parse_route(_pipe$2);
      return new UserNavigatedTo(_pipe$3);
    }
  );
  return [model, effect];
}
function main2() {
  let app = application(init3, update, view);
  let $ = start2(app, "#app", void 0);
  if (!$.isOk()) {
    throw makeError(
      "let_assert",
      "jst_lustre",
      23,
      "main",
      "Pattern match failed, no pattern matched the value.",
      { value: $ }
    );
  }
  return void 0;
}

// build/.lustre/entry.mjs
main2();
