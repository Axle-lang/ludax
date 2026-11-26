# Problems glossary: `src/data` and `src/voxel`

"I want X" -> the mathematical or algorithmic means the code uses, and what it costs. Every statement below was read in
the named file; a figure that could not be confirmed in code or in an existing document is marked `UNVERIFIED`. Costs
are given in symbols (defined per entry); measured figures are quoted with their source (the test suites print
`measured:` lines when run, and nothing was run to make this document, so only figures already written in `doc/` or
in comments appear). Paths are relative to the repository root; `src/data/...` is layer 2, `src/voxel/...` layer 7.

Existing documents referred to in the `Docs` lines:
`doc/handbook/history/core-extraction.md` (API table of the extracted generic modules, lines 34-37), `doc/handbook/history/core-review.md` (review of
those modules with before/after timings, lines 285-308), `doc/handbook/render/02-visibility.md` (the ray walk of
the renderer), `doc/handbook/render/09-baked-shadows.md` (the baked shell of the blockland renderer),
`doc/handbook/render/13-dusk.md` and `doc/handbook/concepts/04-complexity-ledger.md` (memory of the flood),
`doc/spec/lighting.md` and `doc/spec/lighting-math.md` (the plan of the lighting library). No chapter of the handbook is
dedicated to `src/data` or to `src/voxel/light`; those entries say `MISSING` unless a document is named.

---------------------------------------------------------------------------------------------------------------

## 1. Bytes, checksums, text, numbers

### D-01. I want a growable run of bytes whose reads are always 0..255 and whose out-of-range access aborts
- **Means:** `ByteBuf`: a doubling `i8[]` with a `used` length; every read masks the signed byte with 255.
- **Mathematics:** none: plain arithmetic. Growth: `room' = 2 * room` (doubling until `used + n` fits in `pushRange`).
- **Instructions:** `get` tests `0 <= i < used` then `data[i] & 255`; `push` stores `v & 255` and doubles on full; `grow` copies byte by byte in a scalar loop; `pushRange` copies with one `memcpy` (`bytesCopy`); `reserve` + `raw()` + `setLen` let a decoder fill the storage directly.
- **Cost:** `push` amortised O(1); `get`/`set` O(1) with a bounds test; `grow` O(used); 1 byte per element plus `room - used` slack; minimum room 16.
- **Why this and not another:** not documented (comment: an index outside the buffer aborts like the core containers, so a decoder checks `len()` before trusting a size read from a file).
- **Where:** `src/data/bytes.axle:57` (`ByteBuf`), `:41` (`bytesCopy`), `:133` (`pushRange`), `:224` (`grow`).
- **Docs:** MISSING.

### D-02. I want to copy a run of bytes at memory speed, and to know when it is unsafe
- **Means:** `bytesCopy` = one libc `memcpy` after a range check on both arrays.
- **Mathematics:** none: plain arithmetic (range test `dstAt + count <= dst.length` and the same for src).
- **Instructions:** returns at once for `count <= 0`; aborts with `panicMsg` when either range leaves its array; the ranges must not overlap, so a LZ77 match whose distance is shorter than its length is copied by a forward byte loop instead.
- **Cost:** O(count) at memcpy speed; no allocation.
- **Why this and not another:** the comment on `bytesCopy` says overlapping matches must use a forward loop; the same rule is applied in `FastInflater` (D-13) and `Lz4` (D-16).
- **Where:** `src/data/bytes.axle:41`.
- **Docs:** MISSING.

### D-03. I want the CRC-32 of a byte range
- **Means:** table-driven reflected CRC-32, one byte per step.
- **Mathematics:** polynomial `0xEDB88320` (reflected), `table[n]` = `n` after 8 steps of `c = POLY ^ (c >>> 1)` when the low bit is set, else `c >>> 1`; `c = table[(c ^ b) & 255] ^ (c >>> 8)`, start `-1`, final `c ^ -1`.
- **Instructions:** 256-entry `i32` table built once per `Crc32` instance (256 x 8 steps); the loop reads each byte through `ByteBuf.get` (a bounds test per byte).
- **Cost:** O(n) for `n` bytes; 1 KiB per instance. No measured figure.
- **Why this and not another:** not documented (no slicing-by-4/8 variant exists in the code).
- **Where:** `src/data/bytes.axle:235` (`Crc32`), `:255` (`sum`).
- **Docs:** MISSING.

### D-04. I want the Adler-32 sum of a byte range (the trailer of a zlib stream)
- **Means:** two running sums reduced modulo 65521 after every byte.
- **Mathematics:** `s1 = 1 + sum(b_i) mod 65521`, `s2 = sum(s1 after each byte) mod 65521`, result `(s2 << 16) | s1`; 65521 is the largest prime below 65536 (comment on `ADLER_MOD`).
- **Instructions:** per byte one `get`, two additions and two `%` (no deferred reduction): the reduction is not batched.
- **Cost:** O(n); two integer divisions per byte. No measured figure. `FastInflater` skips it by default (D-11) because "the check would cost as much as the decode" (`inflate_fast.axle:13`).
- **Why this and not another:** not documented beyond that comment.
- **Where:** `src/data/bytes.axle:265`.
- **Docs:** MISSING.

### D-05. I want to read and write text that is guaranteed well-formed UTF-8
- **Means:** a byte-range validator (shortest forms only, no surrogates, nothing above U+10FFFF) and a lossy decoder that substitutes U+FFFD.
- **Mathematics:** lead byte `C2..DF` -> 2 bytes, `E0..EF` -> 3 (second byte `>= A0` after `E0`, `<= 9F` after `ED`), `F0..F4` -> 4 (second `>= 90` after `F0`, `<= 8F` after `F4`); continuation bytes `80..BF`. `C0`, `C1`, `F5..` are refused (overlong or out of range).
- **Instructions:** `sequenceLength` returns 0 (bad) or 1..4; `isValidUtf8` steps by it; `fromBytes` writes U+FFFD for each bad sequence; `pushCodePoint` writes a code point or U+FFFD if it cannot be encoded.
- **Cost:** O(n), no allocation in the validator.
- **Why this and not another:** the strict check is for JSON; "the lenient ones (names inside a model) do not" need it (`text.axle:1-8`).
- **Where:** `src/data/text.axle:92`, `:144`, `:36`, `:62`.
- **Docs:** MISSING.

### D-06. I want to decode base64 (and `data:` URIs) from text that may contain line breaks
- **Means:** 6-bit digit accumulator; the URL-safe alphabet accepted; white space skipped; strict about everything else.
- **Mathematics:** each character gives 6 bits, `acc = (acc << 6) | d`; when `bits >= 8` one byte `(acc >> (bits - 8)) & 255` is emitted. Accepted: `chars % 4 != 1`, padding `<= 2`, and with padding `(chars + pad) % 4 == 0`; a digit after padding is an error.
- **Instructions:** a per-character `digit` branch ladder (no table); `decodeFrom` starts at a byte offset so a `data:...;base64,` prefix is never copied; `dataUriStart` finds the payload.
- **Cost:** O(n); output 3/4 of the input.
- **Why this and not another:** not documented.
- **Where:** `src/data/model/base64.axle:52` (`digit`), `:86` (`decodeFrom`), `:129` (`encode`), `:162` (`dataUriStart`).
- **Docs:** MISSING.

### D-07. I want the f32 value of 32 stored bits (and back) without a reinterpreting cast
- **Means:** take the IEEE 754 fields apart and rebuild the value in `f64`, then narrow.
- **Mathematics:** `value = (-1)^s * (frac + 2^23) * 2^(e - 150)` for a normal number (`e` the 8-bit exponent), `frac * 2^-149` for a subnormal; all steps are exact in `f64`, so the narrowing to `f32` is exact. `bitsOf` finds `e` with `2^e <= |x| < 2^(e+1)` by stepping, then `frac = (|x| / 2^e - 1) * 2^23`.
- **Instructions:** `pow2` by square-and-multiply on `f64`; `isFinite` tests the exponent field `== 255`; infinities and NaNs read as 0.
- **Cost:** `toF32` O(log |e|) (about 5 squarings); `bitsOf` O(|e|) loop iterations each calling `pow2` (near 1.0 it is 0-2 iterations; a value near `2^-17` takes about 17). No measured figure.
- **Why this and not another:** the header says "Axle has no reinterpreting cast" (see Doubts: `NbtReader.readFloat` uses one).
- **Where:** `src/data/model/ieee.axle:25`, `:44`, `:49`, `:68`.
- **Docs:** MISSING.

### D-08. I want to read or write a part of a big file without loading it
- **Means:** `RandomFile`: a C stream kept open, `fseek` + `fread`/`fwrite` per call, file length cached.
- **Mathematics:** none: plain arithmetic. Limit `RANDOM_FILE_MAX_BYTES = 2^31 - 1` because the binding's `fseek`/`ftell` take a 32-bit `long` on Windows.
- **Instructions:** a failed open is a value (`isOpen` false, every call answers failure); `read` refuses `at + count > length` before touching the stream; the buffer `into` is caller-owned and reused (`reserve`, `setLen`); `write` extends the cached length when it writes past it.
- **Cost:** one seek and one read per call, O(count); the cached `bytes` is not refreshed if another process changes the file (no refresh code exists).
- **Why this and not another:** `DataFiles.read` reads whole files and "is wrong for a 38 MB archive" (`random_file.axle:3`).
- **Where:** `src/data/archive/random_file.axle:86`, `:103`; whole-file form `src/data/files.axle:19`.
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 2. Compression: deflate, zlib, gzip, LZ4

### D-09. I want to decompress a zlib stream in the simplest provable way (a save, a small picture)
- **Means:** `Inflater`, a transcription of zlib's reference `puff` (named in its header): bit-at-a-time canonical Huffman walk, no tables.
- **Mathematics:** a canonical code: with `count[l]` codes of length `l`, `first_l = (first_{l-1} + count_{l-1}) << 1`; a code `c` of length `l` is symbol `symbol[index_l + (c - first_l)]` when `c - first_l < count[l]` (`decode`). Over-subscription test `left = (left << 1) - count[l] < 0` (`construct`). Header: method `CMF & 15 == 8`, `(CMF*256 + FLG) % 31 == 0`, no preset dictionary; the trailer Adler-32 is checked.
- **Instructions:** `bits(1)` per code bit (each a `ByteBuf.get`); every match is copied one byte at a time through `out.push(out.get(...))` (correct for overlapping matches); `zlib()` allocates a private copy of the input and a fresh output buffer; `maxOutput` caps the output.
- **Cost:** O(n_out + total code bits); up to 15 `bits(1)` calls per symbol; allocation per call. No measured figure in code.
- **Why this and not another:** the header: "short enough to check against the specification line by line". `doc/handbook/history/core-review.md:285-291` says it is kept only for `src/voxel/world/region.axle`, a game importer and two test checks until they migrate to `FastInflater::zlibVerified`.
- **Where:** `src/data/image/inflate.axle:159` (`zlib`), `:267` (`construct`), `:304` (`decode`).
- **Docs:** `doc/handbook/history/core-review.md:285-291` (status only).

### D-10. I want to decompress deflate data at hundreds of MB/s with no allocation once warm
- **Means:** `FastInflater`: a 64-bit bit buffer, a 10-bit direct lookup table per code, a hot loop on locals entered only when 8 input bytes and 258 output bytes are certain.
- **Mathematics:** table entry `(symbol << 4) | length` stored at index `reverse(code, l) + k * 2^l` for all `k` (the stream is LSB-first and codes MSB-first, so the code is bit-reversed and replicated over the unused high index bits); codes longer than 10 bits (`FAST_INFLATER_FAST_BITS`) fall back to the canonical walk `decodeSlow`. Bit budget of one symbol in the fast loop: at most 48 of the 57 bits a refill gives (comment at `:644-649`).
- **Instructions:** refill loop `while bc <= 56: bb |= byte << bc`; literal: one table load, store, `outLen++`; match: length base + extra bits, distance table load, `dist > outLen` check, then `memcpy` when `len <= dist && len >= 24` else a forward byte loop; a symbol it must give up (long code, little room) is un-read and passed to the careful `step`; three 1024-entry `i32` tables (literal, distance, code-length); the fixed-Huffman tables are kept between blocks (`fixedBuilt`).
- **Cost:** O(n_out + n_in). Memory: 3 x 4 KiB tables, `input`/`output` work arrays of 64 KiB each at start (output doubles up to `maxOutput`, clamped to 2^30), plus one `memcpy` of input in and one of output out. Measured (`doc/handbook/history/core-review.md:296-297`): 515-530 MB/s on 4 MiB of text-like data (was 440 MB/s), 11 GB/s on long matches; `ZipReader` 2000 entries 312 MB/s (`:307`).
- **Why this and not another:** `inflate_fast.axle:3-9` ("right for a PNG and wrong for a game that loads thousands of 100 KB chunks"); the `i8[]` of a `ByteBuf` cannot be stored in a field (double free), hence the two copies (`:252-254`).
- **Where:** `src/data/image/inflate_fast.axle:650` (`codesFast`), `:499` (`decode`), `:389` (`construct`), `:435` (`fillTables`), `:284` (`refill`), `:312` (`room`).
- **Docs:** `doc/handbook/history/core-review.md:285-308` (figures), `doc/handbook/history/core-extraction.md:45-46`; the algorithm itself MISSING.

### D-11. I want raw deflate, zlib and gzip streams decoded by one core, with the checksum optional
- **Means:** three thin wrappers (`raw`, `zlib`, `gzip`) over `begin` / `blocks` / `finish`, plus `zlibVerified` that adds the Adler check.
- **Mathematics:** `zlibVerified` locates the trailer at `from + 2 + pos - (bitCnt >> 3)` (whole bytes still in the bit buffer are unread) and compares `be32(trailer)` with `adler32(output)`. gzip: 10 fixed bytes, flag bits `FEXTRA 4`, `FNAME 8`, `FCOMMENT 16`, `FHCRC 2`, 8-byte trailer excluded; the CRC is not verified.
- **Instructions:** header checks inline; the gzip header is parsed by `gzipBodyStart` before `begin` (a bad header never reads a negative offset).
- **Cost:** wrapper cost O(header); the verify adds one `adler32` pass (D-04).
- **Why this and not another:** checksums are skipped by default "because a container with its own length framing already bounds the data" (`inflate_fast.axle:11-14`); PNG uses `zlibVerified` (`png.axle:185`).
- **Where:** `src/data/image/inflate_fast.axle:163` (`raw`), `:170` (`zlib`), `:189` (`zlibVerified`), `:205` (`gzip`), `:218` (`gzipBodyStart`).
- **Docs:** MISSING.

### D-12. I want a damaged or hostile compressed stream to fail instead of exhausting memory or aborting
- **Means:** an output limit in every decoder, bounds proved before each copy, a `damaged`/`bad` flag instead of aborts.
- **Mathematics:** `room(extra)` fails when `extra > limit - outLen` (tested before growth, so a limit below the initial buffer holds); the limit is clamped to `0..2^30`; LZ4 refuses a block with `plain > 255 * compressed` (the maximum LZ4 expansion), `plain > 32 MiB`, or beyond the caller's limit, before reserving.
- **Instructions:** a stored-block length is checked against its complement `len == inv ^ 0xFFFF`; distance checked `dist <= outLen`; dynamic header counts `<= 286` / `<= 30`; the end-of-block code must have a length.
- **Cost:** a few compares per symbol or block.
- **Why this and not another:** comments only.
- **Where:** `src/data/image/inflate_fast.axle:96`, `:312`, `:356`; `src/data/image/inflate.axle:159`; `src/data/codec/lz4.axle:97` (`blockFits`).
- **Docs:** MISSING.

### D-13. I want an LZ77 match that overlaps its own output to copy correctly and quickly
- **Means:** forward byte loop when `len > dist` (the source runs into freshly written bytes), `memcpy` when the ranges cannot overlap.
- **Mathematics:** the copy `out[p + k] = out[p - dist + k]` for `k = 0..len-1` read in increasing `k` gives the repeated pattern of period `dist`; `memcpy` is correct only when `len <= dist`.
- **Instructions:** the threshold `len >= 24` (`FAST_INFLATER_BLOCK_COPY`; `LZ4_BLOCK_COPY = 16` for LZ4) decides when the call overhead pays.
- **Cost:** O(len); the compiler already vectorises the byte loop on long runs (`doc/handbook/history/core-review.md:297`: 11 GB/s on long matches).
- **Why this and not another:** comments at `inflate_fast.axle:729`, `lz4.axle:143`, `:180`.
- **Where:** `src/data/image/inflate_fast.axle:729-737`; `src/data/codec/lz4.axle:180-188`.
- **Docs:** `doc/handbook/history/core-review.md:296-299` (figures only).

### D-14. I want to compress bytes into a valid zlib stream without a table to transmit
- **Means:** `Deflater`: greedy LZ77 over a 32 KiB window with a 3-byte hash and a bounded chain, coded with the fixed Huffman tables of RFC 1951; falls back to stored blocks.
- **Mathematics:** hash `((b0<<16 | b1<<8 | b2) * 2654435761) >>> 12 & 0xFFFF` (Knuth multiplicative, "the golden ratio times 2^32"); chain of earlier positions through `prev[pos & 32767]`, at most `DEFLATE_CHAIN = 24` tries, stopping when a link does not go back in time; match length `3..258`, distance `<= 32768`. Codes: literal `0..143` 8 bits from 48, `144..255` 9 bits from 400, `256..279` 7 bits, `280..287` 8 bits from 192, distances 5 bits (`emitMatch`). zlib header `0x78 0x9C` (fixed) or `0x78 0x01` (stored); stored size bound `size + 6 + 5 * (size/65535 + 1)`.
- **Instructions:** bits are accumulated one at a time (`bit`/`put`/`code`); each byte a match covers is inserted in the chains; end-of-block symbol 256; the output is compared with the stored size and replaced when larger; Adler-32 appended.
- **Cost:** O(n * chain * L) worst case (`matchLength` compares byte by byte with `get`); `head` 65536 `i32` + `prev` 32768 `i32` = 384 KiB per call. Deterministic: the same input gives the same bytes.
- **Why this and not another:** header: "no table to transmit, and on the flat or repeating runs of pixel data it gets most of what dynamic coding would". No lazy matching and no dynamic Huffman exist.
- **Where:** `src/data/image/deflate.axle:155` (`zlib`), `:274` (`compress`), `:93` (`longest`), `:130` (`insert`), `:257` (`emitMatch`).
- **Docs:** MISSING.

### D-15. I want the length and distance code tables of deflate without typing 59 constants
- **Means:** derive each table from the rule behind it.
- **Mathematics:** length codes 0..27: `base_0 = 3`, extra bits `0` for `i < 8` else `(i - 4) / 4`, `base_{i+1} = base_i + 2^extra_i`; code 28 is the single length 258. Distance codes 0..29: `base_0 = 1`, extra `0` for `i < 4` else `(i - 2) / 2`, `base += 2^extra`.
- **Instructions:** two loops in the constructor filling four `i32[]` (29 + 29 + 30 + 30 entries); `Deflater` searches the base downward from the last code, decoders index directly.
- **Cost:** O(60) once per codec instance.
- **Why this and not another:** header: "shorter than 59 literals and cannot be mistyped".
- **Where:** `src/data/image/deflate_tables.axle:49`.
- **Docs:** MISSING.

### D-16. I want to decompress an LZ4 block stream fast
- **Means:** `Lz4::decode`: parse the block framing, then a token loop copying literals and matches.
- **Mathematics:** block header 21 bytes: magic `LZ4Block`, token (`0x10` stored, `0x20` LZ4), compressed length, plain length (both little-endian), 4-byte checksum; a block of plain length 0 ends the stream. Token: high nibble = literal length, low nibble = match length - 4, each extended by bytes of 255 while the nibble is 15; then literals, a 2-byte little-endian offset (`offset == 0` or `> op` is damage).
- **Instructions:** literal runs `>= 16` bytes by `memcpy`, shorter by a loop; overlapping match forward loop, `len <= offset && len >= 16` by `memcpy`; checksums are not verified.
- **Cost:** O(n_out); no allocation (output `reserve`d from the declared plain length after `blockFits`). Measured (`doc/handbook/history/core-review.md:298-299`): text decode 650-720 MB/s, long-match decode 22-24 GB/s.
- **Why this and not another:** header: checksums skipped for the same reason as `FastInflater`; a stream without the end block is refused as cut.
- **Where:** `src/data/codec/lz4.axle:59` (`decode`), `:121` (`block`), `:97` (`blockFits`).
- **Docs:** `doc/handbook/history/core-extraction.md:36`, `doc/handbook/history/core-review.md:298-299` (figures); the format MISSING.

### D-17. I want to compress with LZ4 several times faster than zlib, at a larger size
- **Means:** greedy matcher over a 4096-entry hash of 4-byte prefixes, 64 KiB blocks, raw block when it does not shrink.
- **Mathematics:** hash `(word * -1640531535) >>> 20` (the signed form of 2654435761, 12 bits); a match needs `ip - ref <= 65535` and equal 4-byte words, extended while `ip + len < end - 5`; the last 12 bytes (`LZ4_MF_LIMIT`) are literals; sequence = token, literal extension, literals, 2-byte offset, match extension.
- **Instructions:** the table (16 KiB `i32[4096]`) is caller scratch, reset to -1 per block; on a miss `ip + 1` (no skip acceleration); positions inside a matched run are not inserted; a block is compressed straight into `out` behind its header and the length patched afterwards; XXH32 per block written (D-18).
- **Cost:** O(n) with one table probe per position; no allocation. Measured (`doc/handbook/history/core-review.md:298`): text encode 440-520 MB/s ("noise level: the loop is branch-bound"). Region comment: "several times faster for a file about a third larger" (`region_file.axle:551-553`).
- **Why this and not another:** the checksum is written because "readers of the format (the JVM's among them) verify" it (`lz4.axle:7-8`).
- **Where:** `src/data/codec/lz4.axle:348` (`encode`), `:302` (`compressBlock`), `:263` (`sequence`).
- **Docs:** `doc/handbook/history/core-extraction.md:36`, `doc/handbook/history/core-review.md:298`.

### D-18. I want the XXH32 hash of a byte range
- **Means:** the XXH32 algorithm (four lanes of 16 bytes, then 4-byte and 1-byte tails, avalanche).
- **Mathematics:** lane update `v = rotl(v + word * P2, 13) * P1`, merge `rotl(v1,1)+rotl(v2,7)+rotl(v3,12)+rotl(v4,18)`, `h += n`, tail rounds `rotl(h + w*P3, 17)*P4` and `rotl(h + b*P5, 11)*P1`, final `h ^= h>>>15; h*=P2; h ^= h>>>13; h*=P3; h ^= h>>>16`; `P1..P5` are the constants `XXH_P1..XXH_P5` as signed 32-bit values; LZ4 keeps the low 28 bits with the seed `XXH_SEED`.
- **Instructions:** wrapping 32-bit multiplies; words read little-endian from the raw array.
- **Cost:** O(n); 16 bytes per loop iteration.
- **Why this and not another:** it is the checksum the block format carries.
- **Where:** `src/data/codec/lz4.axle:213`.
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 3. Images and audio

### D-19. I want to load any non-interlaced PNG safely
- **Means:** `PngCodec::decode`: chunk walk with CRC checks, `FastInflater::zlibVerified` bounded by the header's size, un-filtering, expansion to RGBA.
- **Mathematics:** raw size `(rowBytes + 1) * h`; limits side `<= 16384`, pixels `<= 67 108 864`; 16-bit samples cut to the high byte; palette and `tRNS` expanded; the colour type fixes the samples per pixel.
- **Instructions:** the inflater's limit is `rawSize`, so the pixel data can never exceed what the header promises; a bad file returns an empty `Image` and a message in `error()`, never an abort.
- **Cost:** O(raw) for inflate plus O(raw) for un-filtering (each byte through `raw.get`/`raw.set`); memory raw `(rowBytes+1)*h` plus 4 bytes per pixel of the image. No measured figure.
- **Why this and not another:** header lines 1-9 only.
- **Where:** `src/data/image/png.axle:163` (`decode`), `:322` (`unfilter`), `:210` (`scanChunks`).
- **Docs:** MISSING.

### D-20. I want to undo (and choose) PNG row filters
- **Means:** per-row prediction filters 0 None, 1 Sub, 2 Up, 3 Average, 4 Paeth; the encoder picks the row's filter by the smallest sum of residual magnitudes.
- **Mathematics:** `recon = filt + pred(a, b, c)` mod 256 with `a` left, `b` above, `c` above-left (0 outside); Average `(a + b) / 2`; Paeth `p = a + b - c`, `pa = |p-a|, pb = |p-b|, pc = |p-c|`, choose `a` if `pa <= pb && pa <= pc`, else `b` if `pb <= pc`, else `c`. Encoder cost of a residual `d`: `d` if `d < 128` else `256 - d`.
- **Instructions:** `predict` is a `match` on the filter; the encoder evaluates all 5 filters over each row, then recomputes the chosen one while writing.
- **Cost:** decode O(rowBytes * h); encode O(5 * rowBytes * h) residual evaluations, each with up to 4 bounds-checked reads.
- **Why this and not another:** not documented (the heuristic "smallest sum of magnitudes" is named in the header).
- **Where:** `src/data/image/png.axle:355` (`predict`), `:366` (`paeth`), `:536` (`filteredRows`), `:570` (`residual`).
- **Docs:** MISSING.

### D-21. I want to write a PNG of an image
- **Means:** `PngCodec::encode`: RGB when no pixel is translucent else RGBA, 8 bits, adaptive row filters, `Deflater` (D-14).
- **Mathematics:** chunk = length (big-endian), tag, body, CRC-32 of tag + body (D-03); IHDR 13 bytes.
- **Instructions:** `isOpaque` scan, `plainRows`, `filteredRows`, one IDAT chunk, IEND.
- **Cost:** O(5 * W * H * channels) for filtering plus the deflate cost (D-14); a single IDAT of the whole stream.
- **Why this and not another:** fixed Huffman instead of dynamic, see D-14.
- **Where:** `src/data/image/png.axle:462`, `:591` (`chunk`).
- **Docs:** MISSING.

### D-22. I want a picture as plain RGBA pixels with safe out-of-range access
- **Means:** `Image`: one `i32` per pixel `0xAABBGGRR`, straight (not premultiplied) sRGB, row 0 on top; reads outside give transparent black, writes outside are dropped.
- **Mathematics:** `pack(r,g,b,a) = r | g<<8 | b<<16 | a<<24`; conversion to linear light is deliberately not here ("happens in `Texture`").
- **Instructions:** `get`/`set` test the rectangle; `blit`, `crop`, `flippedY`, `copy`, `same`, `bytes`.
- **Cost:** 4 bytes per pixel, O(1) access.
- **Why this and not another:** header lines 1-12.
- **Where:** `src/data/image/image.axle:21`, `:38`, `:89`, `:99`.
- **Docs:** MISSING.

### D-23. I want one decoded copy of a picture by name, with ids that do not change between runs
- **Means:** `ImageAssets`: a `StringMap` from name to a small id in order of first load; pictures made in code can be `put` under a name.
- **Mathematics:** none: plain arithmetic (id = order of first load).
- **Instructions:** a name that failed to load is not remembered, so asking again retries; the cache owns what it is given.
- **Cost:** O(1) per lookup; one decoded `Image` per name.
- **Why this and not another:** header lines 1-8.
- **Where:** `src/data/assets/image_assets.axle:47` (`put`), `:74` (`load`).
- **Docs:** MISSING.

### D-24. I want to read a WAV file (PCM 8/16/24/32, float, extensible) without trusting its sizes
- **Means:** `WavCodec::decode`: RIFF chunk walk by declared sizes with the pad byte after an odd chunk, `fmt ` parsed (plain or EXTENSIBLE), samples scaled to -1..1.
- **Mathematics:** 8-bit unsigned `(v - 128) / 128`; 16-bit `signExtend(raw) / 32768`; 24-bit `/ 8388608`; 32-bit `/ 2^31` in `f64`; float via `Ieee::toF32` (D-07); `signExtend(raw, bit) = raw - ((raw & bit) << 1)`. Frames `= dataSize / blockAlign`. Limits 64 channels, 1 000 000 Hz.
- **Instructions:** every size is compared with the bytes the buffer holds; unknown chunks (LIST, fact, cue) skipped; `data` before `fmt ` refused.
- **Cost:** O(samples) with one `sampleAt` call (a branch ladder) per sample; `f32` memory 4 bytes per sample.
- **Why this and not another:** not documented.
- **Where:** `src/data/audio/wav.axle:160` (`decode`), `:278` (`readSamples`), `:287` (`sampleAt`), `:308` (`signExtend`).
- **Docs:** MISSING.

### D-25. I want to write a WAV file (16-bit PCM or 32-bit float, more than two channels)
- **Means:** `encode16` / `encodeFloat` over one `encodeWith`; EXTENSIBLE header when channels > 2.
- **Mathematics:** 16-bit sample `clamp(roundHalfAway(v * 32768), -32768, 32767)`, `roundHalfAway(x) = floor(x + 0.5)` for `x >= 0` and `-floor(-x + 0.5)` otherwise; float bits via `Ieee::bitsOf` (NaN/inf written as 0).
- **Instructions:** header laid out by `writeFmt` with the `fact` chunk for float; samples written by `writeSamples`.
- **Cost:** O(samples); 16-bit output 2 bytes per sample, float 4. The `bitsOf` loop (D-07) makes float output slower than 16-bit (UNVERIFIED: no measurement).
- **Why this and not another:** header: "what players expect there" for EXTENSIBLE.
- **Where:** `src/data/audio/wav.axle:215`, `:220`, `:312`, `:427`, `:433`, `:442`.
- **Docs:** MISSING.

### D-26. I want to change the sample rate of a clip
- **Means:** `AudioClip::resampled`: linear interpolation between neighbouring frames.
- **Mathematics:** `count = round(frames * target / rate)`, `pos = f * rate / target`, `i0 = min(floor(pos), last)`, `i1 = min(i0 + 1, last)`, `t = pos - i0`, `out = a + (b - a) * t`; first and last frame keep their values.
- **Instructions:** `f64` position; per-channel interpolation.
- **Cost:** O(count * channels); no low-pass filter, so downsampling can alias (UNVERIFIED as a limitation: no comment says so).
- **Why this and not another:** not documented.
- **Where:** `src/data/audio/clip.axle:127`.
- **Docs:** MISSING.

### D-27. I want a mono mix, a gain, a peak-normalised copy, or a slice of a clip without touching the source
- **Means:** each operation returns a new `AudioClip`.
- **Mathematics:** mono `= (1/channels) * sum_c s_c`; `normalised(target)` scales by `target / peak` (a silent clip is copied); `slice` clips the range to the clip.
- **Instructions:** direct loops over the interleaved `f32[]`.
- **Cost:** O(frames * channels) and a new array each.
- **Why this and not another:** header: loaded assets can be shared and derived from freely.
- **Where:** `src/data/audio/clip.axle:110`, `:155`, `:165`, `:174`.
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 4. Archives, region files, serialisation

### D-28. I want a few entries of a 38 MB zip without reading the archive
- **Means:** `ZipReader`: read only the central directory (found by scanning back from the end), then one positional read plus one inflate per entry.
- **Mathematics:** the end record `0x06054b50` is searched backwards in the last `22 + 65535` bytes; a central record is 46 fixed bytes + name + extra + comment; entry offsets, packed and plain sizes are `i32`; names interned (`StringInterner`), numbers in flat arrays.
- **Instructions:** every directory number is checked against the directory and file length; zip64, encryption and methods other than 0 and 8 are refused (a read of such an entry fails); a duplicated name keeps its own index and `find` answers the first; `read` reads the 30-byte local header to get its real name and extra lengths, then the data.
- **Cost:** open O(file tail <= 64 KiB + directory + entries); about 2 MB for 30 000 entries (`zip_reader.axle:15-16`); read O(packed + out). Measured (`doc/handbook/history/core-review.md:307`): 2000 deflated entries, 133 000 entries/s, 312 MB/s.
- **Why this and not another:** header lines 1-9.
- **Where:** `src/data/archive/zip_reader.axle:105` (`readDirectory`), `:167` (`readRecord`), `:199` (`read`).
- **Docs:** `doc/handbook/history/core-extraction.md:45-46` (suite names), `doc/handbook/history/core-review.md:307` (figure).

### D-29. I want to find one chunk among 1024 in a region file and read it
- **Means:** a location table (3-byte sector offset, 1-byte sector count) indexed by `(z & mask) << sideBits | (x & mask)`, then one seek.
- **Mathematics:** `slot = ((cz & 31) << 5) | (cx & 31)`; `loc = first << 8 | count`; byte offset `first << 12`; record = 4-byte big-endian length, 1-byte compression type, payload. Header = 2 tables of `1024 * 4` bytes, each rounded to sectors (`headerSectors = 2 * ceil(4096 / 4096) = 2`). External flag `0x80` in the type byte.
- **Instructions:** `readPayload` does the only disk access (one `fread` of `count << 12` bytes, clamped to the file length) and copies the payload with `pushRange`; `read` then decompresses with the caller's `RegionScratch`. The split lets a loader read on one thread and decompress on many (`:365-369`).
- **Cost:** O(record) per read, nothing allocated once `scratch` and the output are warm; per open file 2 x 1024 `i32` (8 KiB) + a body buffer of 16 KiB. Measured (`doc/handbook/history/core-review.md:306`): 100 KB chunk read 160 us (was 225-240), write 2150 us (was 2300-2500).
- **Why this and not another:** the layout is a parameter (`RegionFormat`: side bits, sector bits, max sectors, flag, type numbers, extensions); the entry layout 24-bit/8-bit is fixed (`region_file.axle:9-13`).
- **Where:** `src/data/archive/region_file.axle:331` (`slotOfAs`), `:370` (`readPayload`), `:461` (`decompressAs`).
- **Docs:** `doc/handbook/history/core-extraction.md:37`, `doc/handbook/history/core-review.md:306`.

### D-30. I want to choose how a chunk is compressed per write (zlib, gzip, stored, LZ4)
- **Means:** `RegionFile::compress` / `decompressAs` dispatch on the type number held in the `RegionFormat`.
- **Mathematics:** type numbers 1 gzip, 2 zlib, 3 stored, 4 LZ4 block stream (`REGION_COMPRESSION_*`); unzip limit 64 000 000 bytes.
- **Instructions:** `RegionScratch` holds the inflater, deflater, two buffers and the LZ4 table so each thread owns its own.
- **Cost:** see D-10, D-14, D-16, D-17; the comment ranks them: zlib smallest, LZ4 "several times faster for a file about a third larger", stored fastest and biggest (`region_file.axle:550-554`). The convenience `write` always uses zlib.
- **Why this and not another:** same comment.
- **Where:** `src/data/archive/region_file.axle:555` (`compress`), `:461` (`decompressAs`), `:105` (`RegionScratch`).
- **Docs:** `doc/handbook/history/core-extraction.md:37`.

### D-31. I want to rewrite a chunk in a region file so a crash leaves the old one intact
- **Means:** sector map + first-fit allocation; a moved record is written to its new run while the old run stays reserved, and the old run is freed only after the write.
- **Mathematics:** `count = ceil((payload + 5) / 4096)`; in place when the old count equals the new one; otherwise the first free run of `count` sectors from `headerSectors` upward, else the end of the file (a free run touching the end is reused: `start = sectorsUsed - run`).
- **Instructions:** one byte per sector (`sectors : u8[]`), marked 1 for the header and every location entry; `mark` ignores sectors past the map (a damaged table can name any sector); the record is padded with zeros to whole sectors in one pass; the table and times are rewritten only on `flush`.
- **Cost:** `allocate` O(S) sectors scanned; the sector map costs 1 byte per sector; a rewrite in place has no crash protection (`:22-25`).
- **Why this and not another:** header lines 15-25.
- **Where:** `src/data/archive/region_file.axle:581` (`writePayload`), `:524` (`allocate`), `:495` (`buildSectorMap`), `:509` (`mark`), `:617` (`storeRecord`), `:682` (`flush`).
- **Docs:** `doc/handbook/history/core-review.md:37` (the earlier finding about crash safety); the mechanism MISSING.

### D-32. I want a chunk bigger than the region file may hold to be stored beside it
- **Means:** external flag: when `count > maxSectors` (255, about 1 MiB) the record in the region is 1 sector with length 1 and `type | 0x80`, and the payload goes to `c.<cx>.<cz>.mcc`.
- **Mathematics:** external path from the slot: `cx = regionX * 32 + (slot & 31)`, `cz = regionZ * 32 + (slot >> 5)`.
- **Instructions:** `writeExternal` creates the file; `readExternal` reads the whole file into the output.
- **Cost:** one extra file open per oversize chunk; `erase` leaves the external file on disk ("the next write of the slot replaces it").
- **Why this and not another:** it is the layout rule of the format being implemented (`RegionFormat.maxSectors` comment).
- **Where:** `src/data/archive/region_file.axle:587-590`, `:424` (`externalPath`), `:434` (`readExternal`), `:653` (`writeExternal`).
- **Docs:** MISSING.

### D-33. I want to walk a binary tag tree (NBT) taking only the fields I know, without building a tree
- **Means:** `NbtReader`, a pull parser over a `ByteBuf`: `readRoot`, `while next() { if nameIs(..) read.. else skipValue() }`.
- **Mathematics:** none: plain arithmetic. All numbers big-endian; strings read as plain UTF-8 (Modified UTF-8 differs only for NUL and outside the basic plane).
- **Instructions:** `nameIs` compares bytes in place (no string); fixed-size lists and arrays are skipped in one step (`size = fixedSize(type)`, cursor `+= count * size`); compounds and lists recurse with depth `<= 512` (`NBT_NESTING_LIMIT`); a read past the end sets `failed` and answers 0.
- **Cost:** O(bytes visited); skipping a fixed array is O(1). Measured (`doc/handbook/history/core-review.md:308`): 3-4 us for a 66 KB walk at `-O 3`.
- **Why this and not another:** header: "building the tree would allocate a node per tag".
- **Where:** `src/data/serial/nbt_reader.axle:189` (`next`), `:212` (`nameIs`), `:256` (`skipOf`), `:307` (`skipList`).
- **Docs:** `doc/handbook/history/core-extraction.md:34`, `doc/handbook/history/core-review.md:308`.

### D-34. I want a hostile NBT count to fail instead of wrapping to a small number
- **Means:** sizes are checked by division against the bytes left; the product is never formed unless it fits.
- **Mathematics:** accept `count` items of `size` bytes only if `0 <= count <= (end - cursor) / size`; a single `n` bytes only if `n <= end - cursor`.
- **Instructions:** `need` and `needItems` set `damaged` and answer false; every loop of the reader ends when the buffer does.
- **Cost:** one division per array header.
- **Why this and not another:** header: "so a hostile count cannot wrap around 32 bits into a small number"; `doc/handbook/history/core-review.md:66` records the earlier overflow.
- **Where:** `src/data/serial/nbt_reader.axle:139` (`need`), `:150` (`needItems`).
- **Docs:** MISSING.

### D-35. I want the long array of a chunk section read straight into a `u64[]`
- **Means:** `readLongsInto`: eight byte loads and shifts per long from the buffer's raw array.
- **Mathematics:** `value = (hi << 32) | lo` with `hi`, `lo` the two big-endian 32-bit halves.
- **Instructions:** `beginLongArray` proves the bytes are there first, so the loop has no per-call bounds bookkeeping.
- **Cost:** O(n) longs, 8 bytes each.
- **Why this and not another:** doc comment at `:530-534`.
- **Where:** `src/data/serial/nbt_reader.axle:516` (`beginLongArray`), `:535` (`readLongsInto`).
- **Docs:** MISSING.

### D-36. I want to write NBT, and to keep the tags I do not model through a save
- **Means:** `NbtWriter` (no tree: tags emitted in order, nesting is the caller's) and `copyRaw` to splice bytes lifted from a reader unchanged.
- **Mathematics:** none: plain arithmetic (tag byte, 2-byte name length, name, big-endian value; list = element type + count).
- **Instructions:** `beginCompound`/`end`, `putInt`, `beginList` then `putIntItem` etc.; `entryStart()` of the reader gives the offset to copy from.
- **Cost:** O(bytes written).
- **Why this and not another:** header.
- **Where:** `src/data/serial/nbt_writer.axle:64`, `:143`, `:176`; `src/data/serial/nbt_reader.axle:230` (`entryStart`), `:562` (`copyRaw`).
- **Docs:** `doc/handbook/history/core-extraction.md:35`.

### D-37. I want names looked up as integers from many threads at once with no allocation
- **Means:** `NameTable`: immutable flat arrays (a name blob, an offset array, an open-addressing table of indices); lookup hashes the bytes where they sit.
- **Mathematics:** FNV-1a 32-bit (`offset 2166136261`, `prime 16777619`) `h = (h ^ byte) * prime`; slot `= h & mask`, linear probe `slot = (slot + 1) & mask`; the table doubles when `(count + 1) * 2 > table.length`, so the load factor stays `<= 1/2`; indices in insertion order.
- **Instructions:** `findBytes(buf, from, to)` takes a range of a decoded buffer; `same` compares bytes; `add` is single-threaded.
- **Cost:** lookup O(name length) with O(1) expected probes; memory `blob` + 4 bytes per name for `offsets` + at least 8 bytes per name for `table`. Measured (`doc/handbook/history/core-review.md:305`): 40 Mlookups/s on 10 000 names.
- **Why this and not another:** header lines 1-12: an interner's reference counts are not atomic ("corrupts them") in Axle 0.18.3, so several threads cannot share a `StringMap`.
- **Where:** `src/data/serial/name_table.axle:57` (`hashRaw`), `:93` (`findBytes`), `:115` (`addBytes`), `:169` (`rehash`).
- **Docs:** `doc/handbook/history/core-review.md:305`, `doc/handbook/history/core-extraction.md:45`.

### D-38. I want to parse JSON exactly as RFC 8259 defines it, with a line and column in the error
- **Means:** recursive-descent parser into a `JsonDoc` arena.
- **Mathematics:** number grammar `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE][+-]?[0-9]+)?` checked by hand, then `toF64` of the literal; `\uXXXX` with surrogate pairs joined (a lone surrogate refused); depth `<= 128`.
- **Instructions:** refuses comments, trailing commas, single quotes, control characters in strings, content after the value; skips a leading BOM; validates UTF-8 (D-05); failure returns the document with `ok()` false.
- **Cost:** O(n); one temporary string per number literal (`DataText::fromBytes` then `toF64`).
- **Why this and not another:** header lines 1-9.
- **Where:** `src/data/json/json_parse.axle:98` (`parse`), `:172` (`value`), `:481` (`number`).
- **Docs:** MISSING.

### D-39. I want to walk and query a JSON tree where no class can be stored in a container
- **Means:** `JsonDoc`: parallel arrays indexed by node (kind, number, text, key, first/last child, next sibling); a `JsonValue` is the node index.
- **Mathematics:** none: plain arithmetic. `field(obj, name)` scans all members and answers the last match; `at(v, i)` keeps a cursor `(curOf, curAt, curNode)` so an increasing walk is O(1) per step; `firstChild`/`nextSibling` walk with no search.
- **Instructions:** questions about the wrong kind answer a fallback, never abort; keys interned once.
- **Cost:** `field` O(members); `at` O(i) from the first child, amortised O(1) when increasing; bytes per node UNVERIFIED (the element types of the arrays were not summed).
- **Why this and not another:** header lines 1-11.
- **Where:** `src/data/json/json_doc.axle:265` (`at`), `:319` (`field`), `:430` (`link`).
- **Docs:** MISSING.

### D-40. I want to write JSON that reads back identically, in the order it was built
- **Means:** `JsonWriter`: compact or pretty, insertion order, a number printed as an integer when it is whole and below 2^53.
- **Mathematics:** `x` with `|x| < 9007199254740992` and `(x as i64) as f64 == x` prints as `i64`; any other uses `f64.toString()` (header: "shortest decimal that reads back as the same f64"; that property belongs to the standard library, UNVERIFIED here).
- **Instructions:** string escapes `"`, `\`, control characters (`\n`, `\t`, `\u00XX`); other bytes pass through.
- **Cost:** O(output).
- **Why this and not another:** header lines 1-7.
- **Where:** `src/data/json/json_write.axle:179` (`number`), `:93` (`emit`).
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 5. Virtual file system, assets

### D-41. I want a path to name the same file on every machine and never escape the root
- **Means:** `VfsPath::normalize`: one pass with a stack of segment starts; `.` and empty segments dropped, `..` pops, `\` read as `/`.
- **Mathematics:** none: plain arithmetic. `..` with an empty stack is an error (`escapes`), not a clamp to the root.
- **Instructions:** `walk` writes the result into a `ByteBuf` and truncates to the saved start on `..`.
- **Cost:** O(path length) plus a `Vec<i32>` stack.
- **Why this and not another:** header: silently clamping `../x` to `x` would let a hostile reference read a file it never named.
- **Where:** `src/data/vfs/vfs_path.axle:30` (`walk`), `:69` (`escapes`), `:75` (`normalize`).
- **Docs:** MISSING.

### D-42. I want files to come from a directory in development, an archive when shipped, and memory in tests, with later sources overriding earlier ones
- **Means:** `Vfs`: ordered mounts, each at a logical directory; a lookup asks mounts last to first.
- **Mathematics:** none: plain arithmetic. A write goes to the topmost writable mount that covers the path.
- **Instructions:** three mount kinds in one class branching on kind (a class cannot be stored in a trait-typed field): Memory (`VfsArchive`), Disk (read/write/exists; cannot list), Archive (read-only "LDXA" container).
- **Cost:** O(mounts) per lookup; nothing is cached, so a file changed on disk is seen by the next read (hot reload relies on it).
- **Why this and not another:** header lines 1-11 of `vfs.axle` and `vfs_mount.axle`.
- **Where:** `src/data/vfs/vfs.axle:113` (`sourceOf`), `:156` (`read`), `:193` (`write`); `src/data/vfs/vfs_mount.axle`.
- **Docs:** MISSING.

### D-43. I want a directory listing merged over several mounts, once per name, in a fixed order
- **Means:** `VfsListing`: names interned, a name that is a directory in one mount and a file in another counts as a directory, byte-order sort.
- **Mathematics:** none: plain arithmetic (order by `VfsPath::compare`, byte order).
- **Instructions:** sorting is an insertion sort performed lazily on first read.
- **Cost:** O(m^2) comparisons for `m` names in the worst case (`vfs_listing.axle:85-99`).
- **Why this and not another:** not documented (a deterministic order, "never depends on which mount was asked first or on the disk", is the stated goal).
- **Where:** `src/data/vfs/vfs_listing.axle:57` (`add`), `:85` (`sort`); `src/data/vfs/vfs.axle:175` (`list`).
- **Docs:** MISSING.

### D-44. I want a whole set of files stored in one buffer, written twice to the same bytes, and verified when opened
- **Means:** the "LDXA" v1 container: header (magic, version, count, dataStart), a table of entries (path length, path, offset, size, CRC-32), then contents with no padding, in table order.
- **Mathematics:** CRC-32 per file (D-03); table entries sized `4 + pathLength + 12`; paths 1..4096 bytes, normalised and unique.
- **Instructions:** `open` checks magic, version, table bounds, each path, each range inside the file and each CRC before trusting anything; `toBytes` emits in insertion order of the index.
- **Cost:** open O(total bytes) (every CRC); `put` copies the bytes; `remove` drops the index entry only, so the bytes stay in the `files` array until the archive is freed (see Doubts).
- **Why this and not another:** header lines 1-26.
- **Where:** `src/data/vfs/vfs_archive.axle:218` (`open`), `:182` (`toBytes`), `:144` (`put`).
- **Docs:** MISSING.

### D-45. I want a stable numeric id for an asset path
- **Means:** FNV-1a 64-bit hash of the normalised path, folded to 31 bits.
- **Mathematics:** `h = fnv1a64(normalize(path))`, `id = (h ^ (h >>> 32)) & 0x7FFFFFFF`; never negative, so `-1` is the none id; two paths that would share an id are an error at registration.
- **Instructions:** one hash; a collision check in `registerAs`.
- **Cost:** O(path length).
- **Why this and not another:** header: ids "the same in every run, on every machine, and in a saved file".
- **Where:** `src/data/assets/asset_db.axle:128`; `src/data/assets/asset_kind.axle:56` (`AssetId`).
- **Docs:** MISSING.

### D-46. I want to load an asset only after everything it depends on, and refuse a cycle before loading anything
- **Means:** depth-first post-order over the dependency edges with three states (unvisited, on path, done).
- **Mathematics:** a back edge to a node "on path" is a cycle; the post-order list is a topological order.
- **Instructions:** `mark`, `trail` (for the cycle message), `order`; edges kept as `depHead/edgeTo/edgeNext` arrays (a linked list per asset).
- **Cost:** O(V + E) for the walk, then one `fetch` per not-yet-loaded asset.
- **Why this and not another:** not documented.
- **Where:** `src/data/assets/asset_db.axle:238` (`dependsOn`), `:304` (`visit`), `:370` (`loadWithDependencies`).
- **Docs:** MISSING.

### D-47. I want to reload an asset only when its file really changed, without a clock or a file watcher
- **Means:** hash of the bytes compared with the last load; a `version` counter that rises on change.
- **Mathematics:** FNV-1a 64 over the file bytes; equal hash and version > 0 means unchanged.
- **Instructions:** `reload(path)` reads again through the `Vfs`; a failed reload keeps the old value; `reloadAll` returns how many changed.
- **Cost:** O(file bytes) per reload check (the file is read and hashed); install by kind only when changed.
- **Why this and not another:** header: "Nothing reads a clock or watches the disk; the caller decides when to look".
- **Where:** `src/data/assets/asset_db.axle:402`, `:411`, `:425` (`fetch`).
- **Docs:** MISSING.

### D-48. I want to pick how a file is read from its extension, and keep loaded class values by number
- **Means:** `AssetKind::fromExtension` (`.png` image, `.json` json, `.gltf`/`.glb`/`.bbmodel` model, else bytes) and `DataSlots<T>` (a doubling array of owned values; a slot never moves, so a reload replaces the value under the same number).
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `.bbmodel` selects the `.bbmodel` importer, any other model goes to glTF; one `DataSlots` per kind.
- **Cost:** O(1) per access; doubling growth.
- **Why this and not another:** `slots.axle` header: "A `Vec` cannot hold a class in Axle".
- **Where:** `src/data/assets/asset_kind.axle:41`; `src/data/slots.axle:29`, `:49`.
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 6. Models: glTF, `.bbmodel`, meshes, animation

### D-49. I want to open a `.gltf` or `.glb` and have every size it claims checked
- **Means:** `GltfFile::open`: JSON parse, GLB chunk split, buffers loaded (base64 `data:` URIs or files through the `Vfs`), buffer lengths checked against what was read.
- **Mathematics:** GLB: 12-byte header (`glTF`, version 2, total length), chunks of (length, type, data) padded to 4 bytes (`at = body + ceil(size / 4) * 4`); JSON type `0x4E4F534A`, BIN `0x004E4942`; the first JSON and the first BIN chunk win.
- **Instructions:** a violation is an error with a reason (`error()`), never an out-of-range read; URIs are unescaped (`%XX`) and checked against escaping the model's directory.
- **Cost:** O(file + buffers).
- **Why this and not another:** header lines 1-13.
- **Where:** `src/data/model/gltf_file.axle:240` (`open`), `:276` (`splitGlb`), `:355` (`unescape`).
- **Docs:** MISSING.

### D-50. I want the numbers of a glTF accessor decoded and validated (strides, integer widths, normalised)
- **Means:** `readAccessor` over `layoutOf`: every layer (accessor -> view -> buffer) bounds-checked in `i64` before a single read.
- **Mathematics:** element bytes `elem = componentSize * components`; stride defaults to `elem` and must be `>= elem`; the last element must end inside the view: `accOff + stride * (count - 1) + elem <= viewLen`; `count <= 2^25 / components`. Normalised integers: unsigned `v / 255` or `v / 65535`; signed `max(v / 127, -1)`, `max(v / 32767, -1)` (the most negative value maps to -1).
- **Instructions:** floats are checked finite via their bits (`Ieee::isFinite`); each component is stored both as `f32` and as `i32`; sparse accessors, accessors without a view and integer matrices are refused with a message.
- **Cost:** O(count * components) with a bounds-checked read per component; memory 8 bytes per component (one `f32[]` and one `i32[]` are allocated for every accessor).
- **Why this and not another:** header lines 7-13.
- **Where:** `src/data/model/gltf_file.axle:506` (`readAccessor`), `:558` (`layoutOf`), `:657` (`normalize`).
- **Docs:** MISSING.

### D-51. I want triangle strips and fans turned into triangles with a constant winding
- **Means:** index expansion in `addTriangles`.
- **Mathematics:** list: `(i0, i1, i2)` per 3 indices; strip: triangle `t` is `(t, t+1, t+2)` for even `t` and `(t+1, t, t+2)` for odd `t`; fan: `(0, t, t+1)` for `t = 1..n-2`. A missing `indices` accessor means `0..n-1`.
- **Instructions:** every index checked `0 <= i < vertexCount`.
- **Cost:** O(indices).
- **Why this and not another:** comment "every second triangle of a strip is flipped so that all of them keep the same winding".
- **Where:** `src/data/model/gltf_import.axle:404` (`readIndices`), `:439` (`addTriangles`).
- **Docs:** MISSING.

### D-52. I want a glTF node tree guaranteed to be a forest (no node with two parents, no loop)
- **Means:** link children after creating all nodes (so a child may precede its parent), then walk each node up to its root with a step limit.
- **Mathematics:** a parent-pointer walk of more than `n` steps proves a cycle.
- **Instructions:** `linkChildren` rejects an index out of range, equal to the node itself, or already having a parent; `hasNoLoop` walks `at = parent(at)` up to `n + 1` steps per node.
- **Cost:** O(n) to link; O(n * depth), worst case O(n^2), for the loop check.
- **Why this and not another:** header: "the tree must be a forest for everything downstream to walk it".
- **Where:** `src/data/model/gltf_scene.axle:118`, `:144`.
- **Docs:** MISSING.

### D-53. I want a node given as a matrix split into translation, rotation and scale
- **Means:** `decompose`: column lengths for scale, normalised columns for rotation, `Quat::fromMat3`.
- **Mathematics:** `s_x = |c0|`, `s_y = |c1|`, `s_z = |c2|`; if `(c0 x c1) . c2 < 0` then `s_x = -s_x` and the first rotation column is negated; translation = fourth column; shear is dropped.
- **Instructions:** `normalizedOr` per column with a unit-axis fallback.
- **Cost:** O(1).
- **Why this and not another:** comment: "a mirrored matrix gets a negative x scale".
- **Where:** `src/data/model/gltf_scene.axle:161`.
- **Docs:** MISSING.

### D-54. I want the value of an animation channel at any time (linear, step, cubic spline)
- **Means:** `ModelChannel::sampleVec3` / `sampleQuat`: binary search of the key interval, then the interpolation named by the file.
- **Mathematics:** `s = (t - t_k) / (t_{k+1} - t_k)`; linear: `a + (b - a) s` (`slerp` for rotations); step: key `k`; cubic spline (glTF's Hermite): `p(s) = (2s^3 - 3s^2 + 1) v_k + (s^3 - 2s^2 + s) dt m_k^out + (-2s^3 + 3s^2) v_{k+1} + (s^3 - s^2) dt m_{k+1}^in`, a quaternion normalised afterwards; before the first key the first value, after the last the last; a zero-length span gives `s = 0`.
- **Instructions:** `segment` returns -1 outside the key range (the caller takes `endKey`); cubic keys store (in-tangent, value, out-tangent) per key.
- **Cost:** O(log keys) per sample.
- **Why this and not another:** header lines 1-11 ("so a player does not have to repeat the interpolation rules of glTF").
- **Where:** `src/data/model/model_anim.axle:162` (`segment`), `:199` (`hermite`), `:214`, `:249`.
- **Docs:** MISSING.

### D-55. I want the animation samplers of a file checked (values per key, times that never go backwards)
- **Means:** `readSampler` / `addChannel` in `gltf_scene`; morph-weight channels skipped with a warning.
- **Mathematics:** the output count must equal `keys * width(path)` (times 3 for cubic spline); times non-decreasing (header lines 5-8; the exact test was not re-read line by line: UNVERIFIED).
- **Instructions:** an error message on a violation.
- **Cost:** O(keys).
- **Why this and not another:** header.
- **Where:** `src/data/model/gltf_scene.axle:304` (`animations`), `:397` (`readSampler`).
- **Docs:** MISSING.

### D-56. I want a model's node placement in model space
- **Means:** multiply local matrices from the node up to its root.
- **Mathematics:** `M_world = M_root * ... * M_parent * M_node` (the code does `m = local.mul(m)` while climbing); at most `MODEL_NODE_DEPTH_LIMIT = 10000` steps.
- **Instructions:** uses the stored matrix when the file gave one, else `local.toMat4()`.
- **Cost:** O(depth) per call.
- **Why this and not another:** not documented.
- **Where:** `src/data/model/model_asset.axle:297`.
- **Docs:** MISSING.

### D-57. I want a hand-built cube model (elements, groups with pivots, rotations) baked into one mesh
- **Means:** `BbModelImporter`: walk the outliner multiplying group matrices, bake element and group transforms into the vertices, one primitive per texture.
- **Mathematics:** `R = Rz * Ry * Rx` about a pivot `p`: `M = T(p) * R * T(-p)`; the matrix of a cube is `parent * M_element`; coordinates divided by 16 (a block = 1 unit); face corners in the order top-left, top-right, bottom-right, bottom-left seen from outside; a face rotation of `90 k` degrees rotates the uv corners by `k` places (`source = (k - turns) mod 4`); triangles `(0,3,2)` and `(0,2,1)`.
- **Instructions:** uv rectangles in texture pixels divided by the texture's size; embedded PNGs decoded from base64 (D-06, D-19); non-cube elements skipped with a warning.
- **Cost:** O(elements * 6 faces); 4 vertices + 2 triangles per face; no merging.
- **Why this and not another:** header lines 1-16.
- **Where:** `src/data/model/bbmodel_import.axle:331` (`rotationAbout`), `:340` (`walk`), `:377` (`cube`), `:428` (`quadOf`), `:539` (`addQuad`).
- **Docs:** MISSING.

### D-58. I want smooth vertex normals from a mesh that has none
- **Means:** `Mesh::computeNormals`: area-weighted mean of the normals of the faces that share a vertex.
- **Mathematics:** `n_v = normalize( sum over triangles t containing v of (b - a) x (c - a) )`; the cross product's length is twice the face area, which is the weight; `normalizedOr(unitY)` gives "up" for a vertex with no valid face.
- **Instructions:** one accumulator of `3 * n + 1` floats, one pass over the triangles (invalid indices skipped).
- **Cost:** O(T + V) time, `12 V` bytes of scratch.
- **Why this and not another:** not documented.
- **Where:** `src/data/model/mesh.axle:269`.
- **Docs:** MISSING.

### D-59. I want tangents (xyz plus handedness) from texture coordinates
- **Means:** `Mesh::computeTangents`: per-triangle uv frame, accumulate, orthogonalise against the normal.
- **Mathematics:** edges `e1, e2`, uv deltas `d1, d2`, `det = d1.x d2.y - d2.x d1.y` (a triangle with `|det| < 1e-10` is skipped); `T = (e1 d2.y - e2 d1.y) / det`, `B = (e2 d1.x - e1 d2.x) / det`; per vertex `u = normalize(T - n (n . T))` (any perpendicular when zero), `w = sign((n x u) . B)`.
- **Instructions:** two accumulators; requires normals and uvs (does nothing without).
- **Cost:** O(T + V); `24 V` bytes of scratch.
- **Why this and not another:** not documented.
- **Where:** `src/data/model/mesh.axle:300`, `:336` (`uvFrame`), `:363` (`orthogonalTangent`).
- **Docs:** MISSING.

### D-60. I want box, sphere and plane meshes without a file
- **Means:** parametric generation with outward normals, uvs, tangents and counter-clockwise winding.
- **Mathematics:** sphere vertex `(sin(phi) cos(theta), cos(phi), sin(phi) sin(theta))`, `phi = pi r / rings`, `theta = 2 pi s / segments`; the engine's own `sin`/`cos` so it is the same on every machine; pole triangles that would be degenerate are omitted; sizes clamped (sphere at least 3 segments, 2 rings).
- **Instructions:** `(seg + 1) * (rings + 1)` vertices (the seam duplicated for uv); `computeTangents` at the end.
- **Cost:** O(vertices).
- **Why this and not another:** header lines 1-7.
- **Where:** `src/data/model/mesh_shapes.axle:22`, `:53`, `:89`.
- **Docs:** MISSING.

### D-61. I want to know a mesh is consistent before I upload it
- **Means:** `Mesh::check`: channel lengths equal the vertex count, indices a multiple of 3 and below the vertex count.
- **Mathematics:** none: plain arithmetic. Per-vertex strides 3, 3, 2, 4 (positions, normals, uv, tangents) and 4 + 4 (joints + weights).
- **Instructions:** returns a message string, empty when fine.
- **Cost:** O(indices).
- **Why this and not another:** header lines 1-12 (flat `Vec`s so a GPU upload is a straight copy).
- **Where:** `src/data/model/mesh.axle:374`.
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 7. Voxel world: storage, generation, meshing, streaming

### D-62. I want to store a block id per cell in the fewest bits that name the blocks present
- **Means:** `VoxChunk`: a palette plus packed indices of 0, 4, 8 or 16 bits per cell.
- **Mathematics:** width `bitsFor(entries)`: 1 entry -> 0 bits (no array), `<= 16` -> 4, `<= 256` -> 8, else 16; bytes `4096 * bits / 8` = 0, 2048, 4096, 8192; cell `i` of a nibble chunk is `(data[i >> 1] >> (4 * (i & 1))) & 15`.
- **Instructions:** `set` finds the id in the palette (linear scan), appends it when missing (after widening the packing if full: `makeRoomForEntry` -> `repack(bitsFor(palLen + 1))`), writes the index; a uniform chunk gets an array only when a different block arrives.
- **Cost:** `get` O(1); `set` O(palette) for the lookup and O(4096) when it repacks; memory `96 + 4 * palRoom + dataLen` bytes (`bytesUsed`): a uniform chunk is about 112 bytes (palette room starts at 4) versus 16 KiB dense (`denseBytes`, `store.axle:184`, counts 4 bytes per cell).
- **Why this and not another:** header lines 1-13; the cell order `y*256 + z*16 + x` is "the light module's", so a chunk copies into a grid slot with no permutation.
- **Where:** `src/voxel/world/chunk.axle:274` (`set`), `:144` (`readIndex`), `:239` (`makeRoomForEntry`), `:255` (`repack`).
- **Docs:** MISSING.

### D-63. I want a chunk's palette shrunk back to what it really holds
- **Means:** `compact`: copy all cells out, rebuild with `fromCells` (palette in order of first appearance, narrowest packing).
- **Mathematics:** none: plain arithmetic. `fromCells` tries the previous cell's palette slot before searching.
- **Instructions:** the palette only grows during edits (an overwritten block stays in it); saving compacts first.
- **Cost:** O(4096 * palette) worst case, O(4096) with the previous-cell shortcut; 16 KiB temporary.
- **Why this and not another:** header lines 5-8.
- **Where:** `src/voxel/world/chunk.axle:315` (`fromCells`), `:359` (`compact`).
- **Docs:** MISSING.

### D-64. I want a chunk as bytes, validated when read back
- **Means:** `VoxChunkCodec`: `[bits:1][palette count:4][entries:4 each][packed cells]`, all little-endian.
- **Mathematics:** the byte length must equal exactly `5 + 4 * count + bytesFor(bits)`; every cell index must be `< count`; `count <= 65536`; a uniform chunk requires count 1.
- **Instructions:** `encode` compacts first; `decode` validates then `restore`s (the chunk is left as it was on failure).
- **Cost:** O(4096) to validate; a uniform chunk is 9 bytes by this formula (the header comment says five: see Doubts), a typical terrain chunk "a few hundred" before deflate (comment).
- **Why this and not another:** header: "the stored form is the chunk's own palette form".
- **Where:** `src/voxel/world/codec.axle:20`, `:36`; `src/voxel/world/chunk.axle:400` (`restore`).
- **Docs:** MISSING.

### D-65. I want the loaded chunks found by integer coordinate with deterministic iteration and bounded memory
- **Means:** `VoxChunkStore`: a `Map<i64, slot>` over a 21-bit-per-axis packed key, a slot array with a free list, iteration in insertion order.
- **Mathematics:** `key = (cx & M) | (cy & M) << 21 | (cz & M) << 42` with `M = 2^21 - 1` (about +-1M chunks per axis); the signed value is recovered by `v >= 2^20 ? v - 2^21 : v`.
- **Instructions:** `remove` puts the slot on `spare` and a fresh placeholder chunk in it; `blockAt` is one map lookup plus a palette read; an unloaded chunk reads as air.
- **Cost:** O(1) expected per lookup; memory `8 B/slot + 24 B/map entry + chunk.bytesUsed` as `bytesUsed` accounts it.
- **Why this and not another:** header: "the map iterates in insertion order, so walking the store ... is the same on every run".
- **Where:** `src/voxel/world/store.axle:41`, `:89`, `:116`, `:154`, `:173`.
- **Docs:** MISSING.

### D-66. I want an infinite world that stores only what players changed
- **Means:** `VoxWorld` = generator + sparse edit layer (edited chunks kept in their compact byte form when they leave memory).
- **Mathematics:** none: plain arithmetic. World height `VW_HEIGHT = 128` = `VW_COLUMN_CHUNKS = 8` chunks.
- **Instructions:** `loadBatch` makes a job per chunk that the edit layer lacks, runs them (parallel or serial), then inserts all in the listed order (restoring from the edit layer where it has them); `unloadChunk` encodes an edited chunk into the edit layer first; `setBlock` loads the chunk, marks it edited and dirty and appends to the journal.
- **Cost:** a save is "three chunks long" for three edited chunks (`persist.axle:3-6`); edit-layer memory is the sum of encoded chunks (`editBytes`).
- **Why this and not another:** header lines 1-11.
- **Where:** `src/voxel/world/world.axle:99` (`loadBatch`), `:196` (`unloadChunk`), `:212` (`setBlock`), `:252` (`commitEdits`).
- **Docs:** `doc/roadmap.md:40-41` (one-line status); the mechanism MISSING.

### D-67. I want the world's edits saved in one checksummed file and loaded all or nothing
- **Means:** `VoxRegion` ("VXRG" v1): header, a table of 28-byte entries, a CRC-32 of the table, then one zlib stream per chunk.
- **Mathematics:** entry = cx, cy, cz, payload offset, payload length, raw length, CRC-32 of the payload (all `i32` little-endian); file size `12 + 28 N + 4 + sum(payload)`; `load` checks magic, version, `N <= 1 000 000`, the table CRC, every payload range and CRC, no duplicate key; a payload is inflated only when read, with its length compared to the table.
- **Instructions:** `add` deflates with `Deflater` (D-14); `read` inflates with the bit-at-a-time `Inflater` (D-09); a damaged region is rejected whole.
- **Cost:** load O(file) for the CRCs; read O(chunk).
- **Why this and not another:** header lines 1-17; the choice of `Inflater` over `FastInflater` here is not explained (see Doubts and `doc/handbook/history/core-review.md:285-291`).
- **Where:** `src/voxel/world/region.axle:105` (`add`), `:132` (`read`), `:150` (`toBytes`), `:193` (`load`); `src/voxel/world/persist.axle:16-37`.
- **Docs:** MISSING.

### D-68. I want a log of edits that several consumers read at their own pace
- **Means:** `VoxJournal`: parallel `Vec`s of (x, y, z, was, now) with absolute sequence numbers and per-consumer cursors.
- **Mathematics:** entry `n` is stored at index `n - dropped`; `end() = dropped + len`; `trim(upTo)` copies the survivors into new vectors and raises `dropped`.
- **Instructions:** `record` returns the sequence number; nobody registers as a listener.
- **Cost:** `record` O(1); `trim` O(remaining); 20 bytes per edit (5 `i32`).
- **Why this and not another:** header lines 1-9.
- **Where:** `src/voxel/world/journal.axle:70` (`record`), `:115` (`trim`).
- **Docs:** MISSING.

### D-69. I want to know which chunk meshes an edit can change
- **Means:** an edit on a chunk border reaches the neighbouring chunk(s) through the face and corner visibility rules.
- **Mathematics:** local coordinate 0 reaches the chunk below on that axis, 15 the chunk above, so an edit touches `2^k` chunks for `k` border axes (up to 8 at a corner); each key listed once in first-appearance order via a `seen` map.
- **Instructions:** `collectAround` loops `dz, dy, dx` over `reachLow..reachHigh`.
- **Cost:** O(edits * up to 8).
- **Why this and not another:** comment at `journal.axle:167-171`.
- **Where:** `src/voxel/world/journal.axle:146`, `:172`.
- **Docs:** MISSING.

### D-70. I want the set of loaded chunks to follow a moving focus with bounded memory and per-frame budgets
- **Means:** `VoxStreamer`: a disc of columns around the focus loaded nearest first, unloaded only beyond `radius + hysteresis`, with load and unload budgets per update.
- **Mathematics:** wanted columns `dx^2 + dz^2 <= r^2` (about `pi r^2` columns, `discColumns`); offsets sorted by squared distance with a counting sort, stable in scan order z then x; queue entries (x, y, z) up to `columns * 8`; the focus chunk is `floor(x / 16)`. Memory is bounded by the disc of `radius + hysteresis`.
- **Instructions:** an update returns at once when the centre chunk is unchanged and the previous update settled; `unloadFar` collects victims into an array first, then unloads; `queueMissing` scans the offsets and the 8 chunks of each column.
- **Cost:** per update O(loaded chunks + wanted columns * 8); the order is a pure function of geometry (no clock, no hash order).
- **Why this and not another:** header lines 1-14.
- **Where:** `src/voxel/world/streamer.axle:110` (`buildOffsets`), `:167` (`update`), `:195` (`unloadFar`), `:228` (`queueMissing`).
- **Docs:** MISSING.

### D-71. I want to generate chunks on a pool of threads and get the same bytes with 0, 1 or 8 workers
- **Means:** `VoxGenKernel` (a `RangeKernel`): job `i` fills its own chunk from the immutable terrain; chunks are inserted afterwards in the listed order.
- **Mathematics:** none: plain arithmetic. Grain 2 chunks per job.
- **Instructions:** `JobPool.run(count, grain)` with the serial reference `runSerial` as the fallback.
- **Cost:** parallel speed-up bounded by the pool; no figure in these files.
- **Why this and not another:** header: jobs "share nothing: each writes its own chunk and reads only the immutable terrain".
- **Where:** `src/voxel/world/loader.axle:70`, `:107`; `src/voxel/world/world.axle:99-134`.
- **Docs:** `doc/handbook/engine/01-job-pool.md` (the pool in general).

### D-72. I want a lattice hash and smooth value noise that are identical on every machine
- **Means:** SplitMix64-finalised lattice hash (the header names SplitMix64), smoothstep-interpolated value noise (2D and 3D), fractal sum.
- **Mathematics:** `h = x*73856093 ^ y*19349663 ^ z*83492791 ^ seed*2654435761` (as `i64`), `hashMix(h) >>> 40` keeps 24 well-mixed bits, `unit = bits * 2^-24`; fade `t^2 (3 - 2 t)`; `fbm2 = sum(amp_o * value2(x * 2.03^o, z * 2.03^o, seed + 31 o)) / sum(amp_o)` with `amp_0 = 0.5`, halving.
- **Instructions:** only `+` and `*` on `f32` (exact IEEE), so no libm enters; `value2` 4 hashes, `value3` 8 hashes.
- **Cost:** `fbm2` with `o` octaves = `4 o` hashes.
- **Why this and not another:** header: "so no libm call enters the result".
- **Where:** `src/voxel/world/noise.axle:33` (`hash`), `:59`, `:74`, `:102`.
- **Docs:** MISSING.

### D-73. I want terrain whose height, rivers and biomes come from noise, and each chunk generated alone
- **Means:** three fractal layers (continents, hills, mountains), a river cut where a fourth passes its middle, a biome by height then climate.
- **Mathematics:** `h = 22 + 46 c + 36 (hill - 0.5) + 52 ramp(0.54, 0.74, m)`; river where `|r - 0.5| < 0.02` and `mount < 0.5`: `h -= (h - (sea - 3)) * cut`, `cut = ramp(0, 1, 1 - |r - 0.5| / 0.02)`; ground clamped to 4..119; biome: `h <= sea` Ocean, `>= 96` Mountain, `<= sea + 2` Beach, temp `< 0.42` Tundra, temp `> 0.58 && humid < 0.5` Desert, humid `> 0.52` Forest, else Plains.
- **Instructions:** `column(x, z)` is a pure function of the column; `columnsOf` computes the 256 columns of a chunk.
- **Cost:** `column` = 14 `value2` evaluations for the height (octaves 4+4+3+3) + 6 for climate = 20 `value2` = 80 hashes (derived from the octave constants `terrain.axle:51-55`); a chunk recomputes its 256 columns, so the 8 chunks of a column recompute the same columns 8 times; `biomeFor` computes the climate noise before the early returns for Ocean/Mountain/Beach.
- **Why this and not another:** header lines 1-16.
- **Where:** `src/voxel/world/terrain.axle:244` (`column`), `:253` (`groundHeight`), `:299` (`biomeFor`), `:569` (`columnsOf`).
- **Docs:** MISSING.

### D-74. I want caves and caverns carved without any dependence on neighbouring chunks
- **Means:** 3D value noise: tunnels where two noises are both near their middle value, caverns where one noise is high below a height.
- **Mathematics:** tunnel at `(x,y,z)` iff `|n_A - 0.5| <= 0.016` and `|n_B - 0.5| <= 0.016` (`n_B` sampled with an x offset of 137); cavern iff `y < 44` and `n_C > 0.74`; carved only for `3 <= y <= h - 5`; the second tunnel noise is evaluated only when the first passes.
- **Instructions:** `hollow` is called per solid cell in the carvable range.
- **Cost:** per cell 1 `value3` (8 hashes) for the tunnel test, + 8 below y = 44 for the cavern, + 8 more when the first test passes.
- **Why this and not another:** header lines 5-6.
- **Where:** `src/voxel/world/terrain.axle:344` (`hollow`), `:546` (`fillColumn`).
- **Docs:** MISSING.

### D-75. I want trees that cross chunk borders without any chunk depending on a neighbour
- **Means:** re-evaluate each tree in every chunk it touches from a hash of its 6 x 6 cell.
- **Mathematics:** the world is cut into cells of 6; each cell decides from a hash whether it holds a tree and where; a tree reaches at most 2 cells beyond its trunk (`TREE_REACH = 2`), so a chunk asks the cells `floorDiv(origin - 2, 6) .. floorDiv(origin + 17, 6)` on each axis; trees are applied in a fixed order with fixed overwrite rules (`putCell(..., strong)`).
- **Instructions:** `treesAround` filters by height reach; `plant` writes into the chunk's cell array.
- **Cost:** about 3 x 3 to 4 x 4 tree cells examined per chunk (derived from the range above).
- **Why this and not another:** header lines 7-14.
- **Where:** `src/voxel/world/terrain.axle:442` (`treeOf`), `:466` (`plant`), `:589` (`treesAround`).
- **Docs:** MISSING.

### D-76. I want a chunk's visible faces as a mesh, looking into the neighbouring chunks
- **Means:** copy the chunk and a one-cell shell into an 18 x 18 x 18 array, then every question is an array read.
- **Mathematics:** index `343 + x + 324 y + 18 z` (`343 = 1 + 18 + 324`); a face of block `A` shows towards `B` when `A != air` and (`B == air` or (`B` transparent and `A != B`)) (`faceShows`).
- **Instructions:** `gather` copies the chunk by `copyCells`, then 5832 - 4096 = 1736 shell cells by `store.blockAt` (one map lookup each); for each of 3 axes x 2 signs x 16 layers a 16 x 16 mask of shown faces is built.
- **Cost:** O(5832 + faces); scratch 5832 + 3 x 256 + 4096 `i32` per mesher (about 41 KiB, derived).
- **Why this and not another:** header lines 1-13.
- **Where:** `src/voxel/world/mesher.axle:100` (`gather`), `:217` (`build`), `:253` (`fillMask`); `src/voxel/world/blocks.axle:75` (`faceShows`).
- **Docs:** MISSING.

### D-77. I want fewer triangles without smearing the shading across a merged face
- **Means:** greedy rectangle merge of equal block id and equal packed shade, only for tiles whose four corner occlusion counts agree.
- **Mathematics:** shade `= c0 | c1<<2 | c2<<4 | c3<<6`; a tile is merge-eligible iff `c0 = c1 = c2 = c3`; the width grows along `a` while the next free cell has the same `(id, shade)`, the height grows row by row while the whole row of width `w` matches.
- **Instructions:** a `taken` mask marks consumed cells; the quad's triangle diagonal is flipped when `ao0 + ao2 > ao1 + ao3`.
- **Cost:** O(256) per layer plus rectangle growth; the result "is identical in light to the tile-by-tile mesh, with fewer triangles". Mesh memory 40 bytes per vertex (10 four-byte elements) + 24 bytes of indices per quad = 184 bytes per quad (derived from the element counts, `mesh.axle:13-20`, `:160-195`).
- **Why this and not another:** header lines 7-13.
- **Where:** `src/voxel/world/mesher.axle:284` (`mergeSlice`), `:328` (`growHeight`), `:192` (`emit`); `src/voxel/world/mesh.axle:160`, `:174`.
- **Docs:** MISSING.

### D-78. I want to point at the first block along a ray and place or break against it
- **Means:** `VoxInteract::cast`: the grid DDA (D-87) over the loaded chunks, stopping at the first block that is neither air nor water.
- **Mathematics:** the direction is normalised so `t` is a distance; the walk starts in the origin cell (a ray starting inside a block hits it at distance 0); the hit records the entry face and the previous cell (where a placed block goes).
- **Instructions:** `world.blockAt` per cell; `breakBlock` and `placeBlock` are plain `VoxWorld::setBlock` so they land in the journal.
- **Cost:** O(cells crossed) with one hash lookup per cell.
- **Why this and not another:** header.
- **Where:** `src/voxel/world/interact.axle:65`, `:108`, `:116`.
- **Docs:** MISSING.

### D-79. I want the light of a sliding window of the world, updated incrementally from the journal
- **Means:** `VoxLightBridge`: one `VoxelGrid` for the columns within `radius` chunks of a centre, whole height; `sync` feeds the journal into the flood edit by edit; a new window is built when the centre nears the edge or more of the window has loaded.
- **Mathematics:** none: plain arithmetic. `recentre` rebuilds when the offset leaves the square of half-width `radius - slack`.
- **Instructions:** `rebuild` creates a fresh light world, copies the loaded chunks cell by cell (a pure-air chunk leaves the fresh slot), floods everything, moves the cursor to the journal end.
- **Cost:** `rebuild` O(cells of the window + flood); `sync` O(edits * incremental edit, D-85); "the library has no way to drop chunks from a grid, so a slide starts a new one".
- **Why this and not another:** header lines 1-14.
- **Where:** `src/voxel/world/bridge.axle:135` (`rebuild`), `:165` (`sync`), `:195` (`recentre`).
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## 8. Voxel light: the grid, the flood, the rays

### D-80. I want a voxel grid where neighbour steps are arithmetic, not hash lookups
- **Means:** `VoxelGrid`: chunks of 16^3 bytes in one big array, a cell named by a cell id, each slot keeping its six neighbour slots.
- **Mathematics:** `cellId = slot * 4096 + local`, `local = y * 256 + z * 16 + x`; inside a chunk a step along axis `a` is `id + sign * 2^shift_a` (shifts 0 for x, 8 for y, 4 for z); across a border `other * 4096 + local - sign * 15 * 2^shift`; faces 0 `+x`, 1 `-x`, 2 `+y`, 3 `-y`, 4 `+z`, 5 `-z` (`face ^ 1` opposite, `face >> 1` axis). Chunk key: 3 x 21 bits.
- **Instructions:** `ensureChunk` doubles the arrays when full, zeroes the new slot, links the six neighbours both ways, widens the bounding box.
- **Cost:** `neighbour` O(1) without a map lookup; 4141 bytes per chunk (4096 blocks + 1 filled + 8 brick flags + 24 neighbour + 12 coordinates, derived from the array declarations); the cell id is an `i32`, so at most `2^31 / 4096 = 524 288` slots (no guard: see Doubts).
- **Why this and not another:** header lines 1-16; one byte a cell because "a word a cell would quadruple it for nothing".
- **Where:** `src/voxel/light/grid.axle:170` (`ensureChunk`), `:278` (`neighbour`), `:93` (`voxChunkKey`), `:147` (`trim`).
- **Docs:** MISSING.

### D-81. I want to know that a chunk or an 8-cell brick has never held a block, so a ray can cross it without reading cells
- **Means:** two conservative "has ever held a non-air block" flags: one per chunk, one per 8^3 brick.
- **Mathematics:** brick `= bx | bz << 1 | by << 2` with `bx = (local >> 3) & 1`, `bz = (local >> 7) & 1`, `by = (local >> 11) & 1`; the flags are raised by any non-air write and never lowered, so they err only towards "filled" and can never hide content.
- **Instructions:** `setBlockOfId` sets `filled[slot]` and `bricksFilled[slot * 8 + brick]`.
- **Cost:** O(1); 9 bytes per chunk.
- **Why this and not another:** header lines 9-12 (never lowering means "the skip then merely does not happen").
- **Where:** `src/voxel/light/grid.axle:85` (`voxBrickOf`), `:238` (`setBlockOfId`), `:211`, `:219`.
- **Docs:** `doc/handbook/render/02-visibility.md` (the renderer's own skips; this structure MISSING).

### D-82. I want a table of how every block id treats light, per colour channel, readable in one load
- **Means:** `BlockLightTable`: flat arrays of opacity, emission and albedo (3 channels each), a solid flag and obstacle classes.
- **Mathematics:** transmittance `T_c = 255 - opacity_c`; `transmitWhite = 255 - (oR + oG + oB) / 3`; `isSolid` iff all three opacities are 255; red glass is opacity `(0, 200, 200)`; id 0 is air and may not stop or emit light (abort otherwise).
- **Instructions:** values clamped to 0..255; an id outside the table is air (transmit 255, emission 0, albedo 128).
- **Cost:** O(1) per query; 9 `i32` per id plus a flag and a class.
- **Why this and not another:** header lines 1-8 ("8 bit ... leaves room for a real falloff curve" versus 4-bit levels).
- **Where:** `src/voxel/light/block.axle:113`, `:147` (`define`), `:211` (`transmit`), `:219` (`transmitWhite`).
- **Docs:** MISSING.

### D-83. I want light to fall off physically (inverse square) and to reach exactly zero at a finite range
- **Means:** a windowed inverse-square table in 16.16 fixed point for whole-cell distances 0..255.
- **Mathematics:** `raw(d) = 1 / (1 + (d/r)^2)`, `S(d) = (raw(d) - raw(R)) / (1 - raw(R))` for `d < R`, `0` from `d = R`; `S(0) = 1`, strictly decreasing, `~ r^2/d^2` for `r << d << R`; level `= (E * m * S16(d) + 2^31) >> 32` where `E` is the strength and `m` a 16.16 transmittance product (`VOX_MULT_ONE = 65536`). The standard torch is `r = 2`, `R = 32` cells.
- **Instructions:** the table is computed in `f64` with divisions only (no libm), so bit-identical everywhere; one table shared by the channels.
- **Cost:** 256 `i32` (1 KiB); `level` is one multiply-add-shift.
- **Why this and not another:** header lines 1-12 (the earlier straight line of 16 levels is replaced). `doc/spec/lighting-math.md:30` describes a different window `sat(1 - (d/R)^4)^2`, "off by default for voxel flood calibration".
- **Where:** `src/voxel/light/curve.axle:49` (constructor), `:77` (`ideal`), `:98` (`level`).
- **Docs:** `doc/spec/lighting-math.md:30`, `:69-70` (one line each); the formula itself is only in the code header.

### D-84. I want the light of every cell from every lamp, as a plain sum that an edit can undo exactly
- **Means:** block light = integer sum over lamps of each lamp's own field, each field a breadth-first flood.
- **Mathematics:** field of lamp `L` at cell `c`: `round(E * m(c) * S(d(c)))` where `d(c)` is the length in cells of the shortest transmitting path from `L` and `m(c)` the product of the transmittances along the least absorbed shortest path; "that order (shorter first, then brighter) is monotone under a step", so the field is a pure function of scene and lamp, independent of visiting order. Step product `nm = (m * t + 127) / 255` per cell; cut where `level(E, nm, d) == 0` or `d > 255`.
- **Instructions:** `spread` pops from a FIFO ring (`VoxLightQueue`, doubles when full), 6 neighbours per cell; a stamp plane with an epoch avoids clearing; the path state (length low byte, multiplier above) is packed in one plane; `floodLamp` adds (`+1`) or subtracts (`-1`) the touched cells' levels into the red/green/blue planes.
- **Cost:** per lamp per channel O(cells within path length < R) x 6 neighbour tests (in open air about `4 R^3 / 3` cells: derived, the L1 ball); 8 `i32` planes = 32 bytes per cell for the whole flood (315 MB for 9.8 M cells, `world.axle:190-191`).
- **Why this and not another:** header lines 3-34: a per-cell "brightest wins" flood (the first design) is wrong with an inverse-square curve because "which of two states is better depends on how far the light still has to go", so incremental removal could not restore what a rebuild gives; superposition and integer addition are exactly invertible.
- **Where:** `src/voxel/light/flood.axle:435` (`spread`), `:412` (`floodLamp`), `:219` (`rebuild`).
- **Docs:** MISSING (the reasoning is only in the file header; `doc/spec/lighting.md` section 5 names the idea).

### D-85. I want to place or remove a block or lamp without re-flooding the world
- **Means:** `beginEdit` / `endEdit`: subtract the fields of every lamp the cell can reach, change the scene, add them back.
- **Mathematics:** lamps with taxicab distance `< range + 1` from the edited cell are the only ones that can be affected (the path length is at least the taxicab distance); remove-then-add is the identity by integer arithmetic.
- **Instructions:** the `near` list is scanned from the lamp registry (linear), `floodLamp(l, -1)` for each, the block is changed, the cell's own lamp registration updated, `floodLamp(l, +1)` for each (and for the cell's own lamp).
- **Cost:** O(L) to find the near lamps (`L` registered lamps) + `2 k` floods of the `k` lamps in reach; `forgetLamp` is linear. Sky light of the same edit: D-93, D-94.
- **Why this and not another:** header lines 12-19.
- **Where:** `src/voxel/light/flood.axle:317` (`beginEdit`), `:341` (`endEdit`), `:271` (`setBlock`).
- **Docs:** MISSING.

### D-86. I want one lantern a different colour or strength from its block, or a lamp that ignores leaves
- **Means:** per-cell emitter override (10 bits per channel plus a presence bit) and a per-lamp pass mask over obstacle classes.
- **Mathematics:** packed `r | g << 10 | b << 20 | 1 << 30`, strength 0..1023 per channel (a lamp block is 255); a block that shares a bit with the lamp's pass mask transmits 255 for that lamp.
- **Instructions:** `emissionAt` reads the override first, else the block table; the override survives a rebuild and is dropped by `setBlock` on that cell.
- **Cost:** two extra `i32` planes (`emitters`, `passMasks`): 8 bytes per cell.
- **Why this and not another:** header lines 27-34.
- **Where:** `src/voxel/light/flood.axle:286` (`setEmitter`), `:307` (`applyEmitter`), `:381` (`emissionAt`), `:479` (`lampTransmit`).
- **Docs:** MISSING.

### D-87. I want the cells a ray crosses, in order, with the face it entered through
- **Means:** `VoxelDda`: the Amanatides and Woo traversal (named in the header), in `f64`.
- **Mathematics:** `step_a = sign(d_a)`, `tDelta_a = 1 / |d_a|`, `tMax_a = (c_a + [d_a > 0] - o_a) / d_a`; advance the axis with the smallest `tMax` (ties x, then y, then z, so the cell between two diagonal cells is visited and a thin diagonal wall does not leak); an axis the ray never moves along has `t = 10^12`; `t` is a distance because `dir` is unit length.
- **Instructions:** a compare tree and three updates per step; `entryT`, `exitT`, `entryFace` available.
- **Cost:** O(k) steps for `k` cells crossed; `f64` because "an `f32` would drift a cell off after a few hundred steps". `doc/handbook/concepts/04-complexity-ledger.md:32` lists the renderer's equivalent at 2 to 3 ns a cell.
- **Why this and not another:** header lines 1-12.
- **Where:** `src/voxel/light/dda.axle:51` (`start`), `:103` (`advance`), `:156` (`voxDdaFirst`), `:22` (`voxFloor`).
- **Docs:** `doc/handbook/render/02-visibility.md:18-40` (the same walk, derived for the renderer's own code).

### D-88. I want the first solid cell along a ray crossing empty chunks without reading each cell
- **Means:** `VoxRayTracer::trace`: walk every cell with the DDA but skip the block read in a chunk or brick that never held a block.
- **Mathematics:** a region of `2^s` cells (`s = 4` chunk, `3` brick) is skipped while the walker's coordinates `>> s` stay equal; crossing, tie rule and `crossed` count are exactly those of a plain walk, so the skip can be tested against one.
- **Instructions:** the chunk slot is looked up once and kept until the ray leaves it (a chunk that does not exist is void); a cell read is one add to a hoisted base id; the counter `walked` is a local joined to the field once; the grid and table are passed as borrowed parameters (a `Shared` copied into a field races the reference count on a worker).
- **Cost:** O(k) steps, but each skipped step costs no block load; ends at the grid's bounding box, at `reach`, or when under 0.01 % of the ray is left.
- **Why this and not another:** header lines 16-19 and 21-25.
- **Where:** `src/voxel/light/trace.axle:132` (`trace`), `:220` (`skipRegion`).
- **Docs:** MISSING (`doc/handbook/render/02-visibility.md` documents the renderer's four skips, not this).

### D-89. I want the share of light that survives a ray through glass, leaves and stone, and the colour it picked up
- **Means:** per-cell absorption with albedo-weighted colour: what a cell absorbs is the light that would have come from that cell, so it is added to the ray's colour by the cell's albedo.
- **Mathematics:** a cell lets `t = transmitWhite / 255` through: `taken = left * (1 - t)`, `taken_c += taken * albedo_c / 255`, `left *= t`; at the end `see_c = left + taken_c` (white for what got through); the fractions add to one, so the colour is an average of white and the albedos met; `left < 10^-4` ends the ray.
- **Instructions:** a block whose class shares a bit with the pass mask transmits fully; air is block 0 and costs one byte load.
- **Cost:** O(k); no allocation.
- **Why this and not another:** header lines 1-9 (the earlier design kept only the first blocker's colour).
- **Where:** `src/voxel/light/trace.axle:244` (`absorb`), `:211` (`finish`).
- **Docs:** MISSING.

### D-90. I want an even, repeatable fan of directions over a disc (the sun) or a hemisphere (the sky)
- **Means:** Vogel's golden-angle sunflower spiral (named in the header), 16 turned copies chosen by a hash of the cell.
- **Mathematics:** disc point `i` of `n`: `r = sqrt((i + 0.5) / n)`, `angle = 2.39996322972865332 i + turn`, `(r cos, r sin)` (equal area each); hemisphere direction `(r cos, sqrt(1 - u), r sin)` with `u = (i + 0.5)/n`, `r = sqrt(u)`: cosine weighted (`doc/spec/lighting-math.md:71` names this Malley's method); `turn = 2 pi k / 16`; copy `k = hashCombine(hashCombine(hashMix x, hashMix y), hashMix z) & 15`.
- **Instructions:** all `16 n` rays precomputed in an `f64[]` (3 per ray); copy 0 is the unturned fan used by analytic tests.
- **Cost:** `384 n` bytes (`n = 64` gives 24 576 bytes per fan); lookup O(1).
- **Why this and not another:** header: "a fan of n rays on a plain spiral gives n+1 visible shades of penumbra and bands"; a hash of position (never of time) means a cell's answer never flickers while neighbours do not share their bands.
- **Where:** `src/voxel/light/pattern.axle:33` (`disc`), `:50` (`hemisphere`), `:102` (`copyFor`).
- **Docs:** `doc/spec/lighting-math.md:71` (names the hemisphere method only).

### D-91. I want soft sun shadows from a fan of rays over the sun's disc
- **Means:** `VoxBakeKernel::sunAt`: the mean survival of `n` rays from the cell centre towards points of the sun's disc.
- **Mathematics:** disc points scaled by `tan(halfAngle)` span the sun's frame (`up`, `side` perpendicular to the sun direction and to each other); ray direction `normalize(sun + a * up + b * side)`; visibility `= (1/n) sum fraction_i`; penumbra width `~` occluder distance x disc angular diameter (header lines 8-10). Defaults: `sunHalfAngle = 0.02` rad (the real sun 0.0047), 64 rays, reach 96 cells.
- **Instructions:** the frame is built by components, not a cross product, so the zeros of the helper axis stay exact; the helper axis is y when the sun is within 0.9 of the x axis.
- **Cost:** `n * k` cells per baked cell (`k` cells walked per ray, up to `reach`).
- **Why this and not another:** header: "a shadow edge is as wide as the disc says"; no shadow map.
- **Where:** `src/voxel/light/bake.axle:247` (`sunAt`), `:182` (`buildSunFrame`), `:154` (`configure`).
- **Docs:** `doc/spec/lighting-math.md:25-27` (the penumbra rule, not this code).

### D-92. I want the share of the sky a cell sees and the colour the sky rays met (bounce tint)
- **Means:** `skyAt`: mean survival and mean colour of a cosine-weighted hemisphere fan from the cell centre.
- **Mathematics:** `access = (1/n) sum left_i`, `tint_c = (1/n) sum see_c,i` (D-89); both quantised by `voxByte(v) = clamp(floor(255 v + 0.5), 0, 255)`.
- **Instructions:** the hemisphere is always around +Y (not oriented to a surface normal).
- **Cost:** `n * k` per baked cell, default `n = 64`.
- **Why this and not another:** not documented.
- **Where:** `src/voxel/light/bake.axle:271` (`skyAt`), `:299` (`voxByte`).
- **Docs:** `doc/spec/lighting-math.md:71-72`.

### D-93. I want sky light that is 255 under open sky, dims through leaves and glass, and spreads sideways into overhangs
- **Means:** per-column seeds found by scanning down, then a "brightest wins" flood losing `skyStep` per cell.
- **Mathematics:** the seed of a cell `= (level * transmitWhite + 127) / 255` scanning from the top; from the seeds `cand = ((level - skyStep) * t + 127) / 255` to a neighbour, stored when `cand > level_n`; "brightest wins" is valid here because the step is monotone in the level.
- **Instructions:** seed and level packed into one plane (low byte seed, next byte level); `propagateSky` pops a FIFO queue, 6 neighbours.
- **Cost:** rebuild O(columns * height) for seeds + O(cells lit) for the spread; 4 bytes per cell.
- **Why this and not another:** header lines 21-25.
- **Where:** `src/voxel/light/flood.axle:610` (`scanColumn`), `:496` (`propagateSky`), `:487` (`skyStepped`), `:247` (`floodAllSky`).
- **Docs:** MISSING.

### D-94. I want to remove sky light correctly when a roof is placed or broken
- **Means:** the classic two-pass removal with a stated invariant.
- **Mathematics:** after the pass every cell still holding light is supported (its level is its own seed or the step of a surviving neighbour); a neighbour with level `< removed level` and not its own seed may depend on the removed cell and is cleared (back to its seed) and the pass continues from it; a neighbour with level `>= removed level` cannot depend on it, so it joins the add queue and refills the hole.
- **Instructions:** `updateColumn` rescans the column, handles seeds that fell first, then those that rose, then `propagateSky`.
- **Cost:** O(cells whose level depended on the edit).
- **Why this and not another:** comment at `flood.axle:544-554`.
- **Where:** `src/voxel/light/flood.axle:555` (`removeSky`), `:584` (`updateColumn`), `:524` (`refloodSky`).
- **Docs:** MISSING.

### D-95. I want the baked sun and sky terms only where they can be seen, with a small index
- **Means:** the surface shell: the air cells with a light-blocking block among their 26 neighbours, indexed by a rank over a bit set with `popcount`.
- **Mathematics:** `shell` has one bit per grid cell, `first[w]` the ordinal of the first shell cell of 64-cell word `w`; `ordinal(id) = first[id >> 6] + popcount(word & ((1 << (id & 63)) - 1))`; a face corner reads four cells in front of the face and each touches the face's block, so only cells beside a blocker can matter; "light-blocking" is any block that stops any channel (leaves, glass, water included); 5 bytes per entry (sun, access, tint r, g, b) and a stale flag.
- **Instructions:** `markShell` marks the 26 cells around each blocker (interior fast path by index arithmetic, border cells via `cellId`); `rebuild` keeps the baked bytes of cells that stay and starts newcomers open (255) and stale.
- **Cost:** about one cell in eighty is in the shell for a landscape (`surface.axle:9-10`); the index costs 8/64 + 4/64 = 0.19 bytes per grid cell, plus 10 bytes per shell cell accounted by `bytes()`; the header measures 1.8 MB against 39 MB for a dense `i32` per cell on a 320 x 96 x 320 world ("21 times"); rebuild O(grid cells + 26 * blockers).
- **Why this and not another:** header lines 9-13; a dense table was 21 times larger.
- **Where:** `src/voxel/light/surface.axle:109` (`ordinalOf`), `:175` (`rebuild`), `:226` (`markShell`), `:241` (`markAround`).
- **Docs:** `doc/handbook/render/09-baked-shadows.md:6-30` (the renderer's own shell of the same idea; this class MISSING).

### D-96. I want a bake to give the same bytes on 0, 1 or 8 workers
- **Means:** each shell entry is baked independently; job `i` writes only entry `order[i]`.
- **Mathematics:** none: plain arithmetic (disjoint writes, no shared accumulation).
- **Instructions:** `VoxBakeKernel` as a `RangeKernel` with a grain of 32 entries; each range makes its own `VoxRayTracer`; `runSerial` is the reference the tests compare to; `JobPool.run` falls back to serial when it cannot run.
- **Cost:** O(S * n * k) for `S` shell cells; `raysCast` counts `count * rays`. No measured figure in these files.
- **Why this and not another:** header lines 1-6.
- **Where:** `src/voxel/light/bake.axle:206` (`runRange`), `:305` (`VoxLightBaker`), `:354` (`run`).
- **Docs:** MISSING (`doc/handbook/engine/01-job-pool.md` covers the pool).

### D-97. I want to bake only the cells that joined the shell, or refresh the sun term round-robin so shadows glide
- **Means:** stale flags per entry, and a rotating slice of the sun bake.
- **Mathematics:** `bakeSunSlice(from, count)` bakes entries `(from + i) mod n` and returns `(from + take) mod n`.
- **Instructions:** `bakeStale` lists the entries whose sun flag, then whose sky flag, is set; `setSun`/`setSky` clear their flag.
- **Cost:** O(entries listed * n * k).
- **Why this and not another:** header of `world.axle`, `surface.axle:20-21`.
- **Where:** `src/voxel/light/world.axle:224` (`bakeStale`), `:251` (`bakeSunSlice`).
- **Docs:** `doc/handbook/render/09-baked-shadows.md` (the renderer's generations and glide; this API MISSING).

### D-98. I want smooth per-corner lighting that does not leak around creases
- **Means:** `cornerSample`: the mean of the four cells that meet at a face corner, solid cells excluded.
- **Mathematics:** cells: front (across the face), side A and side B (along the two tangent axes on the corner's side), diagonal; the diagonal counts only if it is not solid and not (both sides solid); mean via `VoxSampleMean` with weight 1 each, fallback the front cell; `aoCorner = voxAo(sideA, sideB, diag)` with `voxAo = 3` when both sides are solid, else the count of solid among the three.
- **Instructions:** tangent axes `(axis + 1) % 3` and `(axis + 2) % 3`; the corner number's bits pick the sign of each side.
- **Cost:** up to four `cellSample`s (each possibly a live bake: D-100) per corner.
- **Why this and not another:** comments at `world.axle:343-347`.
- **Where:** `src/voxel/light/world.axle:328` (`cornerCells`), `:348` (`cornerSample`), `:371` (`aoCorner`); `src/voxel/light/sample.axle:48` (`voxAo`).
- **Docs:** MISSING.

### D-99. I want the light at any world point, not only at a cell
- **Means:** `pointSample`: trilinear blend of the eight cell centres around the point, solid cells left out.
- **Mathematics:** `g = p - 0.5`, `i = floor(g)`, `t = g - i`, weights `w = prod_axis (t or 1 - t)`; the result is `sum w s / sum w` over non-solid cells (renormalised), so a point beside a wall is not darkened by the wall's zero; fallback the cell containing the point.
- **Instructions:** one `VoxSampleMean` accumulating in `f64`; weights `<= 0` skipped.
- **Cost:** up to 8 `cellSample`s.
- **Why this and not another:** doc comment of `pointSample`.
- **Where:** `src/voxel/light/world.axle:381`.
- **Docs:** `doc/handbook/render/09-baked-shadows.md` (trilinear sample of the renderer's bake).

### D-100. I want a read to be right even for a cell the shell does not store
- **Means:** `cellSample`: a cell outside the shell, or flagged stale, is baked on the spot with the same code and settings as the bulk bake.
- **Mathematics:** the byte returned equals the stored byte because both go through `voxByte`.
- **Instructions:** a solid cell returns zero light with the block's albedo as bounce tint; `setLiveFallback(false)` makes unstored cells read as open (full sun, full sky) for a mesher that prefers speed; a missing chunk reads as open air.
- **Cost:** a live read costs a whole fan (`n * k` cells walked).
- **Why this and not another:** header lines 10-13.
- **Where:** `src/voxel/light/world.axle:267` (`cellSample`), `:171` (`setLiveFallback`).
- **Docs:** MISSING.

### D-101. I want to give the flood's memory back once a renderer has copied the light into its own volumes
- **Means:** `releaseFlood`: replace the `VoxLightFlood` with a fresh empty one.
- **Mathematics:** eight planes of one `i32` per cell = 32 bytes per cell; "315 MB for a world of 9.8 million cells" (`world.axle:191`).
- **Instructions:** the bakes do not use the flood and work as before; block and sky light read as zero and edits are not flooded until `rebuildLight`.
- **Cost:** frees about `32 N` bytes; measured in the handbook: 741 MB -> 307 MB while rendering (`doc/handbook/concepts/04-complexity-ledger.md:100-102`, `doc/handbook/render/13-dusk.md:149`, `:306`).
- **Why this and not another:** the ledger records "keep the flood's 8 planes for the session's life: no: nothing reads them after the copy".
- **Where:** `src/voxel/light/world.axle:196`.
- **Docs:** `doc/handbook/render/13-dusk.md:149`, `doc/handbook/concepts/04-complexity-ledger.md:100-102`.

### D-102. I want a per-cell value array that grows with the grid and starts at "no light"
- **Means:** `VoxLightPlane`: one `i32` per cell addressed by cell id; `ensure(slots)` doubles and zero-fills.
- **Mathematics:** `room = max(2 * room, slots)` slots of 4096 cells.
- **Instructions:** `get` of a cell it does not cover answers 0, `set` ignores it.
- **Cost:** 4 bytes per cell; `ensure` copies the old cells.
- **Why this and not another:** header.
- **Where:** `src/voxel/light/plane.axle:22`.
- **Docs:** MISSING.

### D-103. I want a work queue for a flood that cannot know its size, without allocating in steady state
- **Means:** `VoxLightQueue`: a fixed-capacity `Ring<i64>` that moves into one twice as large when full; an entry packs a cell id (low 32 bits) and a payload (high 32 bits).
- **Mathematics:** `entry = (payload << 32) | id`; capacity starts at 65536 in the flood.
- **Instructions:** growth pops all entries into the bigger ring.
- **Cost:** push/pop O(1), growth O(len) and rare.
- **Why this and not another:** header lines 1-6 ("the engine's `Ring` has a fixed capacity on purpose").
- **Where:** `src/voxel/light/queue.axle:34`, `:42`, `:66`.
- **Docs:** MISSING.

### D-104. I want to turn a light level into 0..1 and average samples without mixing direct and ambient light
- **Means:** `VoxelLightSample` (five separate terms) and `VoxSampleMean` (a weighted running mean in `f64`).
- **Mathematics:** `voxUnit(level) = level * (1/255)` as the constant `0.00392156862745098`; terms: block light RGB (1.0 = a 255 lamp at its own cell, may exceed 1 where lamps overlap), sky light, sun visibility, sky access, bounce tint.
- **Instructions:** direct (sun, block) and ambient (sky, bounce) are never summed here "because the shading that follows needs to dim one without the other".
- **Cost:** O(1) per add; ten `f64` accumulators.
- **Why this and not another:** header lines 1-13.
- **Where:** `src/voxel/light/sample.axle:66` (`VoxSampleMean`), `:120` (`voxUnit`).
- **Docs:** MISSING.

---------------------------------------------------------------------------------------------------------------

## Missing documentation

| Mechanism | File | What is not written down anywhere in `doc/` |
|---|---|---|
| Light as a sum of per-lamp fields, the order "shorter then brighter" and why a per-cell maximum fails | `src/voxel/light/flood.axle:1-38` | Only in the file header: no handbook chapter (`doc/spec/lighting.md` section 5 names the idea without the reasoning); the cost per lamp, the lamp-reach test, the 32 bytes per cell |
| Windowed inverse-square table `S(d)`, the 16.16 level formula, the standard `r = 2`, `R = 32` | `src/voxel/light/curve.axle` | Formula only in the header; `doc/spec/lighting-math.md:30` shows a different window |
| Sky light seeds, two-pass removal and its supportedness invariant | `src/voxel/light/flood.axle:544-606` | Invariant only in a code comment |
| Brick/chunk "ever filled" flags and the region skip in `VoxRayTracer` | `src/voxel/light/grid.axle`, `trace.axle` | `doc/handbook/render/02-visibility.md` documents the renderer's skips, not these |
| Sunflower fans, the 16 turned copies, the penumbra rule as implemented | `src/voxel/light/pattern.axle`, `bake.axle` | Only comments; `doc/spec/lighting-math.md:25-27` gives the rule for the plan |
| Surface shell with a popcount rank and stale flags | `src/voxel/light/surface.axle` | Only the renderer's shell is documented (`render/09-baked-shadows.md`); the 1.8 MB versus 39 MB figure lives only in a comment |
| Light bridge: window, journal feed, rebuild-on-slide | `src/voxel/world/bridge.axle` | Header only |
| Palette-packed chunk storage (0/4/8/16 bits), widening and compaction | `src/voxel/world/chunk.axle` | Header only; no bytes-per-cell table |
| Greedy mesher with the flat-shade rule and the padded 18^3 array | `src/voxel/world/mesher.axle` | Header only |
| Streamer: counting-sorted disc, hysteresis, budgets | `src/voxel/world/streamer.axle` | Header only |
| Terrain constants (heights, thresholds, tree cell 6, reach 2) | `src/voxel/world/terrain.axle:26-130` | Nothing in `doc/` for this generator |
| Edit-layer region file "VXRG" layout | `src/voxel/world/region.axle:1-17` | Header only |
| Fast inflate: table construction, bit budget of the hot loop, copy thresholds | `src/data/image/inflate_fast.axle` | Figures in `doc/handbook/history/core-review.md:296-308`; the algorithm only in comments |
| Greedy deflate encoder (chain 24, window 32 KiB, fixed codes, stored fallback) | `src/data/image/deflate.axle` | Header only |
| LZ4 framing and encoder choices (4096-entry table, no skip acceleration, raw fallback) | `src/data/codec/lz4.axle` | Only API rows in `doc/handbook/history/core-extraction.md:36` |
| Region file sector allocation, crash-safe move, external chunks | `src/data/archive/region_file.axle` | `doc/handbook/history/core-extraction.md:37` (API); `doc/handbook/history/core-review.md:37` (a finding already acted on) |
| NBT pull parser protocol and hostile-count rules | `src/data/serial/nbt_reader.axle` | `doc/handbook/history/core-extraction.md:34`; the protocol only in a header |
| `NameTable` hash, load factor and thread-safety argument | `src/data/serial/name_table.axle` | Header only; 40 Mlookups/s in `doc/handbook/history/core-review.md:305` |
| glTF accessor validation chain and normalised-integer rule | `src/data/model/gltf_file.axle` | Header only |
| Animation sampling (Hermite, slerp, key search) | `src/data/model/model_anim.axle` | Header only |
| `.bbmodel` rotation baking and uv corner rotation | `src/data/model/bbmodel_import.axle` | Header only |
| VFS mounts, path normalisation, the "LDXA" container, asset ids, dependency order, hot reload | `src/data/vfs/*`, `src/data/assets/*` | No chapter; headers only |
| PNG reader/writer, filters, limits | `src/data/image/png.axle` | Header only |
| WAV codec scaling and the EXTENSIBLE rule | `src/data/audio/wav.axle` | Header only |
| JSON parser, arena and writer | `src/data/json/*` | Headers only |

## Doubts

1. `src/data/model/ieee.axle:3-5` says "Axle has no reinterpreting cast", but `src/data/serial/nbt_reader.axle:425-440` (`readFloat`, `readDouble`) reinterprets bits with an `unsafe` pointer cast. One of the two is stale or the second path was added later; `Ieee::bitsOf` also costs a loop of `pow2` calls per value (`ieee.axle:68-93`) where a cast would be O(1).
2. `src/voxel/light/flood.axle:431-433` describes leaving "the cells in `touched`, the lengths in `reached` and the shares in `through`"; no `reached` or `through` field exists (the path state is in the packed `path` plane).
3. `src/voxel/world/region.axle:71` and `:138` use the bit-at-a-time `Inflater` (D-09) for every chunk read, although `FastInflater` exists and `doc/handbook/history/core-review.md:285-291` already names this site as pending migration.
4. `src/voxel/light/grid.axle:170-198`: a cell id is `slot * 4096 + local` in an `i32` (so at most 524 288 slots) while the chunk key allows 21 bits per axis; `ensureChunk` does not guard the slot count, so a grid past 2^31 cells would wrap silently.
5. `src/voxel/world/world.axle:281-308` (`applyRegion`) re-reads loaded chunks from a region and marks them edited, but records no journal entry, so `VoxLightBridge::sync` (`bridge.axle:165-188`) never sees those changes in the light (the mesh is marked dirty by `restore`, `chunk.axle:439`).
6. `src/voxel/world/region.axle:132-147` (`VoxRegion::read`) appends to `out` (`pushRange`) without clearing it, unlike the other readers that "replace" the output; callers must pass an empty buffer (`world.axle:287` does).
7. `src/data/image/inflate_fast.axle:389-433`: `construct` rejects only an over-subscribed code; an incomplete code (which `Inflater` refuses unless it has a single symbol, `inflate.axle:438-449`) is accepted and fails only when an unassigned bit pattern is met. The two inflaters therefore disagree on some invalid streams.
8. `src/data/archive/zip_reader.axle:128` refuses an archive whose directory says 65 535 entries as zip64, although 65 535 is a legal non-zip64 count; conservative, but a valid archive of exactly that size is refused.
9. `src/data/vfs/vfs_archive.axle:177-179`: `remove` drops only the index entry; the bytes stay in `files` (and `put` always appends), so an archive that is written and removed repeatedly grows until it is freed.
10. `src/data/vfs/vfs_listing.axle:85-99`: an insertion sort over the names of a directory is O(m^2); only a problem for very large directories.
11. `src/voxel/world/terrain.axle:299-330` computes the temperature and humidity noises before the early returns for Ocean, Mountain and Beach, and `columnsOf` is recomputed by each of the 8 vertical chunks of a column (D-73): redundant work, not a wrong result.
12. `src/data/bytes.axle:224-231` (`grow`) copies byte by byte in a scalar loop although `bytesCopy` exists in the same file; `adler32` (`:265`) takes two `%` per byte without deferring the reduction. Both are unmeasured and could matter for large buffers (UNVERIFIED).
13. `doc/spec/lighting-math.md:30` documents a finite-range window `sat(1 - (d/R)^4)^2` "off by default for voxel flood calibration"; the voxel curve uses a different window (`curve.axle:8-9`). The document does not say which window the flood uses.
14. `src/voxel/world/codec.axle:3-4` says "a uniform chunk is five bytes"; by the layout in the same comment and by `decode` (`:46`, `5 + 4 * count + packedLen`) a uniform chunk is 9 bytes (5-byte head + one 4-byte entry).
15. The memory comment `src/voxel/light/world.axle:190-191` ("eight planes ... 315 MB for 9.8 million cells") equals `32 * 9.8e6 = 313.6 MB`, so it is consistent within rounding; the eight planes are red, green, blue, skySeed, path, stamp, emitters, passMasks (`flood.axle:150-155`), not the grid (1 further byte per cell).

## Summary

The glossary has 104 entries across eight areas: bytes and checksums (D-01 to D-08), compression (D-09 to D-18: puff-style and table-driven inflate, the greedy deflate encoder, the derived code tables, LZ4 decode/encode, XXH32), images and audio (D-19 to D-27), archives and serialisation (D-28 to D-40: zip, region files with sector allocation and external chunks, NBT reader/writer, the lock-free name table, JSON), the VFS and asset database (D-41 to D-48), models (D-49 to D-61: glTF/GLB, `.bbmodel`, normals, tangents, animation), the voxel world (D-62 to D-79: palette chunks, store, edit layer and region file, journal, streamer, noise, terrain, mesher, ray cast, light bridge) and the light engine (D-80 to D-104: grid, block table, falloff curve, per-lamp sum-of-fields flood with exact incremental edit, emitters, sky light with two-pass removal, DDA, ray tracer with region skips, sunflower fans, sun and sky bakes, the popcount-ranked surface shell, parallel bakes, corner and trilinear samples, `releaseFlood`). Formulas, constants and complexities were taken from the code; measured figures are only those already written in `doc/handbook/history/core-review.md` and `doc/handbook/` (nothing was run). Not verified: per-node memory of `JsonDoc`; whether `f64.toString` is the shortest round-trip form (D-40); the exact sampler checks of `gltf_scene` (D-55) and the material and texture paths of `gltf_import` and `bbmodel_import` (read at header and key-function level only); `vfs_mount` disk paths and the `Vfs` write rules beyond their headers; the L1-ball cell count of a lamp field (derived, not measured); worst-case timings of the encoders (no figures exist). Constants-only files, enum files and trivial accessors have no entry because they hold no mechanism a user would want something from.
