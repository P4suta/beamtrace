// SPDX-License-Identifier: Apache-2.0 OR MIT
const assert = require("node:assert/strict");
const test = require("node:test");
const fc = require("fast-check");

const unicodeScalar = fc
  .integer({ min: 0, max: 0x10ffff })
  .filter((codePoint) => codePoint < 0xd800 || codePoint > 0xdfff);

const searchText = fc
  .array(unicodeScalar, { maxLength: 128 })
  .map((codePoints) => String.fromCodePoint(...codePoints));

test("event page URL preserves arbitrary Unicode search text as one query value", async () => {
  const { pageUrl } = await import(
    "../../packages/beamtrace_web/src/beamtrace_web/page_loader_ffi.mjs"
  );
  fc.assert(
    fc.property(
      fc.integer({ min: 0, max: 10_000_000 }),
      fc.integer({ min: 1, max: 1_000 }),
      searchText,
      (start, limit, search) => {
        const parsed = new URL(pageUrl(start, limit, search), "https://beamtrace.invalid");
        const expectedSearch = search.trim();
        const expectedKeys = expectedSearch === ""
          ? ["limit", "start"]
          : ["limit", "q", "start"];

        assert.equal(parsed.origin, "https://beamtrace.invalid");
        assert.equal(parsed.pathname, "/api/v2/sessions/current/events");
        assert.deepEqual([...parsed.searchParams.keys()].sort(), expectedKeys);
        assert.equal(parsed.searchParams.getAll("start").length, 1);
        assert.equal(parsed.searchParams.get("start"), String(start));
        assert.equal(parsed.searchParams.getAll("limit").length, 1);
        assert.equal(parsed.searchParams.get("limit"), String(limit));

        if (expectedSearch === "") {
          assert.equal(parsed.searchParams.has("q"), false);
        } else {
          assert.equal(parsed.searchParams.getAll("q").length, 1);
          assert.equal(parsed.searchParams.get("q"), expectedSearch);
        }
      },
    ),
    { numRuns: 2_000 },
  );
});
