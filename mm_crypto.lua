-- mm_crypto: pure-Lua SHA-256, MD5, base64/hex decode and RSA signature
-- verification for MUSHclient (Lua 5.1 + its bit library) and MacMUSH
-- (LuaJIT). No C modules beyond the client's own bit library.

local M = {}

-- LuaJIT's bit uses lshift/rshift/bnot; MUSHclient's uses shl/shr/neg.
local bitlib = _G.bit
if not bitlib then
  local ok, lib = pcall(require, "bit")
  if ok then bitlib = lib end
end
assert(bitlib, "mm_crypto: no bit library available")
local band, bor, bxor = bitlib.band, bitlib.bor, bitlib.bxor
local bnot = bitlib.bnot or bitlib.neg
local lshift = bitlib.lshift or bitlib.shl
local rshift = bitlib.rshift or bitlib.shr

local MOD = 2 ^ 32
local function norm(x) return x % MOD end
local function rotr(x, n) return norm(bor(rshift(x, n), lshift(x, 32 - n))) end
local function rotl(x, n) return norm(bor(lshift(x, n), rshift(x, 32 - n))) end

local function to_hex(s)
  return (string.gsub(s, ".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

function M.hex_decode(s)
  if #s % 2 ~= 0 then return nil, "odd-length hex" end
  if string.find(s, "[^0-9a-fA-F]") then return nil, "bad hex character" end
  return (string.gsub(s, "..", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64V = {}
for i = 1, 64 do B64V[string.sub(B64, i, i)] = i - 1 end

function M.base64_decode(s)
  s = string.gsub(s, "%s", "")
  local pad = #string.match(s, "(=*)$")
  s = string.gsub(s, "=*$", "")
  if pad > 2 then return nil, "bad base64 padding" end
  local out, acc, bits = {}, 0, 0
  for i = 1, #s do
    local v = B64V[string.sub(s, i, i)]
    if not v then return nil, "bad base64 character" end
    acc = acc * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(acc / 2 ^ bits)
      acc = acc % 2 ^ bits
      out[#out + 1] = string.char(byte)
    end
  end
  return table.concat(out)
end

------------------------------------------------------------------
-- SHA-256
------------------------------------------------------------------

local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_pure(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  local padlen = (55 - len) % 64
  local hi = math.floor(len / 2 ^ 29) % MOD
  local lo = norm(len * 8)
  msg = msg .. "\128" .. string.rep("\0", padlen)
    .. string.char(
      math.floor(hi / 2 ^ 24) % 256, math.floor(hi / 2 ^ 16) % 256,
      math.floor(hi / 256) % 256, hi % 256,
      math.floor(lo / 2 ^ 24) % 256, math.floor(lo / 2 ^ 16) % 256,
      math.floor(lo / 256) % 256, lo % 256)

  local w = {}
  for block = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = string.byte(msg, block + i * 4, block + i * 4 + 3)
      w[i + 1] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(bxor(rotr(x, 7), rotr(x, 18)), rshift(x, 3))
      local s1 = bxor(bxor(rotr(y, 17), rotr(y, 19)), rshift(y, 10))
      w[i] = norm(w[i - 16] + norm(s0) + w[i - 7] + norm(s1))
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local s1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
      local ch = bxor(band(e, f), band(norm(bnot(e)), g))
      local t1 = norm(h + norm(s1) + norm(ch) + SHA_K[i] + w[i])
      local s0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = norm(norm(s0) + norm(maj))
      h, g, f, e = g, f, e, norm(d + t1)
      d, c, b, a = c, b, a, norm(t1 + t2)
    end
    h0, h1, h2, h3 = norm(h0 + a), norm(h1 + b), norm(h2 + c), norm(h3 + d)
    h4, h5, h6, h7 = norm(h4 + e), norm(h5 + f), norm(h6 + g), norm(h7 + h)
  end

  local out = {}
  for _, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[#out + 1] = string.char(
      math.floor(v / 2 ^ 24) % 256, math.floor(v / 2 ^ 16) % 256,
      math.floor(v / 256) % 256, v % 256)
  end
  return table.concat(out)
end

------------------------------------------------------------------
-- MD5
------------------------------------------------------------------

-- RFC 1321 defines K[i] = floor(abs(sin(i)) * 2^32); doubles give these
-- exactly, so the table is generated instead of transcribed.
local MD5_K = {}
for i = 1, 64 do MD5_K[i] = math.floor(math.abs(math.sin(i)) * MOD) end

local MD5_S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function md5_pure(msg)
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  local len = #msg
  local padlen = (55 - len) % 64
  local bits = len * 8
  local lenbytes = {}
  for _ = 1, 8 do
    lenbytes[#lenbytes + 1] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  msg = msg .. "\128" .. string.rep("\0", padlen) .. table.concat(lenbytes)

  local m = {}
  for block = 1, #msg, 64 do
    for i = 0, 15 do
      local x, y, z, w2 = string.byte(msg, block + i * 4, block + i * 4 + 3)
      m[i + 1] = ((w2 * 256 + z) * 256 + y) * 256 + x   -- little-endian
    end
    local a, b, c, d = a0, b0, c0, d0
    for i = 1, 64 do
      local f, g
      if i <= 16 then
        f = bor(band(b, c), band(norm(bnot(b)), d)); g = i
      elseif i <= 32 then
        f = bor(band(d, b), band(norm(bnot(d)), c)); g = (5 * (i - 1) + 1) % 16 + 1
      elseif i <= 48 then
        f = bxor(bxor(b, c), d); g = (3 * (i - 1) + 5) % 16 + 1
      else
        f = bxor(c, bor(b, norm(bnot(d)))); g = (7 * (i - 1)) % 16 + 1
      end
      f = norm(norm(f) + a + MD5_K[i] + m[g])
      a, d, c = d, c, b
      b = norm(b + rotl(f, MD5_S[i]))
    end
    a0, b0 = norm(a0 + a), norm(b0 + b)
    c0, d0 = norm(c0 + c), norm(d0 + d)
  end

  local out = {}
  for _, v in ipairs({ a0, b0, c0, d0 }) do
    out[#out + 1] = string.char(v % 256, math.floor(v / 256) % 256,
      math.floor(v / 2 ^ 16) % 256, math.floor(v / 2 ^ 24) % 256)
  end
  return table.concat(out)
end

------------------------------------------------------------------
-- Native hash hook (client-provided digests, self-tested)
------------------------------------------------------------------

local native = {}

-- A registered native is trusted only if it reproduces a known digest;
-- both binary and hex return conventions are accepted.
local function vet(fn, sample, want_hex)
  if type(fn) ~= "function" then return nil end
  local ok, out = pcall(fn, sample)
  if not ok or type(out) ~= "string" then return nil end
  if to_hex(out) == want_hex then
    return fn                                   -- returns binary
  end
  if string.lower(out) == want_hex then
    return function(s) return (M.hex_decode(string.lower(fn(s)))) end
  end
  return nil
end

function M.use_native(t)
  t = t or {}
  native.sha256 = vet(t.sha256, "abc",
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  native.md5 = vet(t.md5, "abc", "900150983cd24fb0d6963f7d28e17f72")
end

function M.sha256_bin(s)
  if native.sha256 then return native.sha256(s) end
  return sha256_pure(s)
end

function M.sha256_hex(s) return to_hex(M.sha256_bin(s)) end

function M.md5_hex(s)
  if native.md5 then return to_hex(native.md5(s)) end
  return to_hex(md5_pure(s))
end

------------------------------------------------------------------
-- Bignum (base-2^16 limbs, little-endian arrays) + RSA verify.
-- 16-bit limbs keep every intermediate product exact in doubles.
------------------------------------------------------------------

local BASE = 65536

local function bn_trim(a)
  while #a > 1 and a[#a] == 0 do a[#a] = nil end
  return a
end

local function bn_from_bytes(s)          -- big-endian bytes -> limbs
  local a, limb, mult = {}, 0, 1
  for i = #s, 1, -1 do
    limb = limb + string.byte(s, i) * mult
    mult = mult * 256
    if mult == BASE then
      a[#a + 1] = limb
      limb, mult = 0, 1
    end
  end
  if mult > 1 then a[#a + 1] = limb end
  if #a == 0 then a[1] = 0 end
  return bn_trim(a)
end

local function bn_to_bytes(a, len)       -- fixed-width big-endian bytes
  local out = {}
  for i = 1, #a do
    out[2 * i - 1] = string.char(a[i] % 256)
    out[2 * i] = string.char(math.floor(a[i] / 256))
  end
  local s = string.reverse(table.concat(out))
  if #s > len then
    -- only leading zero bytes may be dropped
    local extra = string.sub(s, 1, #s - len)
    if string.find(extra, "[^%z]") then return nil end
    return string.sub(s, #s - len + 1)
  end
  return string.rep("\0", len - #s) .. s
end

local function bn_cmp(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
  for i = #a, 1, -1 do
    if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
  end
  return 0
end

local function bn_mul(a, b)
  local r = {}
  for i = 1, #a + #b do r[i] = 0 end
  for i = 1, #a do
    local carry = 0
    local ai = a[i]
    for j = 1, #b do
      local acc = r[i + j - 1] + ai * b[j] + carry
      carry = math.floor(acc / BASE)
      r[i + j - 1] = acc % BASE
    end
    r[i + #b] = r[i + #b] + carry
  end
  return bn_trim(r)
end

-- Knuth TAOCP vol 2 Algorithm D, remainder only. Requires the divisor's
-- top limb >= BASE/2; RSA moduli always satisfy this (top bit set).
local function bn_mod(u, v)
  local n = #v
  assert(v[n] >= BASE / 2, "bn_mod: divisor not normalized")
  if bn_cmp(u, v) < 0 then
    local c = {}
    for i = 1, #u do c[i] = u[i] end
    return c
  end
  local r = {}
  for i = 1, #u do r[i] = u[i] end
  r[#u + 1] = 0
  for j = #u - n + 1, 1, -1 do
    local top = r[j + n] * BASE + r[j + n - 1]
    local qhat = math.floor(top / v[n])
    if qhat > BASE - 1 then qhat = BASE - 1 end
    -- multiply-subtract qhat*v from r at offset j-1
    local borrow = 0
    for i = 1, n do
      local p = qhat * v[i] + borrow
      local pl = p % BASE
      borrow = math.floor(p / BASE)
      local d = r[j + i - 1] - pl
      if d < 0 then
        d = d + BASE
        borrow = borrow + 1
      end
      r[j + i - 1] = d
    end
    local d = r[j + n] - borrow
    while d < 0 do                        -- qhat was too large: add v back
      qhat = qhat - 1
      local carry = 0
      for i = 1, n do
        local s2 = r[j + i - 1] + v[i] + carry
        r[j + i - 1] = s2 % BASE
        carry = math.floor(s2 / BASE)
      end
      d = d + carry
    end
    r[j + n] = d
  end
  for i = n + 1, #r do r[i] = nil end
  return bn_trim(r)
end

local function bn_powmod_65537(base, n)
  local r = bn_mod(base, n)
  for _ = 1, 16 do
    r = bn_mod(bn_mul(r, r), n)           -- r = base^(2^16) after the loop
  end
  return bn_mod(bn_mul(r, bn_mod(base, n)), n)
end

-- test hook: a mod n on hex strings (lowercase hex out, no leading zeros)
function M._bn_mod_hex(a_hex, n_hex)
  local a = bn_from_bytes(M.hex_decode(#a_hex % 2 == 1 and "0" .. a_hex or a_hex))
  local n = bn_from_bytes(M.hex_decode(#n_hex % 2 == 1 and "0" .. n_hex or n_hex))
  local r = bn_mod(a, n)
  local parts = {}
  for i = #r, 1, -1 do parts[#parts + 1] = string.format("%04x", r[i]) end
  local hex = string.gsub(table.concat(parts), "^0*", "")
  if hex == "" then hex = "0" end
  return hex
end

-- ASN.1 DigestInfo header for SHA-256 (RFC 8017, section 9.2 notes)
local DIGESTINFO_SHA256 = string.char(
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
  0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20)

-- PKCS#1 v1.5 verification by exact reconstruction: build the one valid
-- encoded message for this hash and compare all bytes. No padding parser,
-- so no padding-parser bugs.
function M.rsa_verify(n_hex, sig, message)
  local n_bytes = M.hex_decode(string.lower(n_hex))
  if not n_bytes then return false end
  local klen = #n_bytes
  if type(sig) ~= "string" or #sig ~= klen then return false end
  local n = bn_from_bytes(n_bytes)
  local s = bn_from_bytes(sig)
  if bn_cmp(s, n) >= 0 then return false end
  local em = bn_to_bytes(bn_powmod_65537(s, n), klen)
  if not em then return false end
  local digest = M.sha256_bin(message)
  local pslen = klen - 3 - #DIGESTINFO_SHA256 - #digest
  if pslen < 8 then return false end
  local expected = "\0\1" .. string.rep("\255", pslen) .. "\0"
    .. DIGESTINFO_SHA256 .. digest
  return em == expected
end

return M
