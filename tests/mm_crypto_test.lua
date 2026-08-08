package.path = "./?.lua;./tests/?.lua;" .. package.path

local crypto = require "mm_crypto"

local tests = {}
local function add(name, fn) table.insert(tests, { name = name, fn = fn }) end
local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

add("sha256 known vectors", function()
  eq(crypto.sha256_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  eq(crypto.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(crypto.sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

add("sha256 padding boundaries", function()
  -- 55, 56, 63, 64, 65 bytes cross the length-field padding edges
  for _, n in ipairs({ 55, 56, 63, 64, 65, 1000 }) do
    local h = crypto.sha256_hex(string.rep("a", n))
    eq(#h, 64, "hex length for n=" .. n)
    eq(h, crypto.sha256_hex(string.rep("a", n)), "deterministic n=" .. n)
  end
  -- one million 'a' -- the classic long-input vector
  eq(crypto.sha256_hex(string.rep("a", 1000000)),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
end)

add("sha256_bin matches hex", function()
  local bin = crypto.sha256_bin("abc")
  eq(#bin, 32)
  local hex = {}
  for i = 1, 32 do hex[i] = string.format("%02x", string.byte(bin, i)) end
  eq(table.concat(hex), crypto.sha256_hex("abc"))
end)

add("md5 known vectors", function()
  eq(crypto.md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e")
  eq(crypto.md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
  eq(crypto.md5_hex("The quick brown fox jumps over the lazy dog"),
    "9e107d9d372bb6826bd81d3542a419d6")
  eq(#crypto.md5_hex(string.rep("x", 200)), 32)
end)

add("base64 decode", function()
  eq(crypto.base64_decode(""), "")
  eq(crypto.base64_decode("YWJj"), "abc")
  eq(crypto.base64_decode("YWI="), "ab")
  eq(crypto.base64_decode("YQ=="), "a")
  eq(crypto.base64_decode("YW\nJj  "), "abc", "whitespace tolerated")
  local out, err = crypto.base64_decode("Y!Wj")
  eq(out, nil); assert(err, "bad char rejected")
end)

add("hex decode", function()
  eq(crypto.hex_decode("00ff10"), "\0\255\16")
  eq(crypto.hex_decode("00FF10"), "\0\255\16", "case-insensitive")
  local out, err = crypto.hex_decode("0g")
  eq(out, nil); assert(err, "bad hex rejected")
  out, err = crypto.hex_decode("abc")
  eq(out, nil); assert(err, "odd length rejected")
end)

add("use_native rejects a broken native", function()
  crypto.use_native({ sha256 = function() return "garbage" end })
  -- broken native must be dropped, pure-Lua path still correct
  eq(crypto.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  crypto.use_native(nil)
end)

add("use_native accepts a correct native (hex or binary return)", function()
  local calls = 0
  -- precomputed digest: a native calling back into crypto would recurse
  local abc_bin = crypto.sha256_bin("abc")
  crypto.use_native({ sha256 = function(s)
    calls = calls + 1
    assert(s == "abc", "only 'abc' is hashed in this test")
    return abc_bin   -- stands in for a client's binary-returning native
  end })
  eq(crypto.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert(calls >= 1, "native was actually used")
  crypto.use_native(nil)
end)

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
  end
end
if failures > 0 then os.exit(1) end
