"""
Dishonored 2 PS4 - CHECKPT Save File Compressor / Decompressor
Reversed from eboot.elf (VoidEngine / Arkane Studios)

Original author: @brotherguns5624
Apollo script by Bucanero

FILE LAYOUT
===========
  Offset  Size  Description
  ------  ----  -----------
  0x00     4    MD5-XOR checksum  (XOR of the 4 LE uint32 words of MD5(body))
  0x04     *    Compressed body   (everything below)

COMPRESSION PIPELINE (compress order, reverse for decompress)
==============================================================

  Step 1 - Size header
    Prepend the uncompressed payload size as a big-endian uint32.
    This becomes the first 4 bytes of the LZ input stream.

  Step 2 - LZ Encoder  (token stream -> arithmetic input)
    - token == 0x00 : LITERAL
          Emit 0x00, then the literal byte (2 bytes total).
    - token  > 0x00 : BACK-REFERENCE
          copy_length = token + 3          (minimum copy = 4 bytes, max = 258)
          distance    = distance to match start, little-endian 16-bit
          Emit token, dist_lo, dist_hi (3 bytes total).
    Ring buffer: 128 KB (131072 bytes) circular.

  Step 3 - Arithmetic Encoder  (token stream -> bit stream)
    - 16-bit adaptive arithmetic coding
    - 256-symbol model, initially uniform (each symbol has frequency 1)
    - After each encoded symbol, that symbol's frequency is incremented
    - Bits are written LSB-first within each byte

  Step 4 - Checksum
    Prepend XOR of the 4 little-endian uint32 words of MD5(compressed_body).

PORTING NOTES
=============
  Arithmetic encoder is the exact mirror of the decoder:

    State: low=0, high=0xFFFF, pending=0  (pending counts deferred underflow bits)

    encode_symbol(sym):
      range  = high - low + 1
      high   = low + range * cum_hi[sym] / total - 1
      low    = low + range * cum_lo[sym] / total
      renormalize:
        loop:
          if MSBs of low and high agree:
            output that bit; output `pending` complement bits; pending=0
            shift low left, shift high left with LSB=1, no change to pending
          elif low bit14=1 and high bit14=0  (straddle 0.5):
            pending++; strip bit14 from both; shift left same as above
          else: break
      update model: cum_hi[sym]++, shift all later entries up by 1, total++

    flush():
      pending++
      if low bit14 is set: output 1, then (pending-1) zeros
      else:                output 0, then (pending-1) ones
      pad to byte boundary

  The LZ compressor uses a 16-bit hash table (single-entry per slot, no chains).
  For better compression ratios replace it with a hash-chain or suffix-array matcher
  while keeping the same token format.
"""

import gc
import uhashlib
import ubinascii
import ustruct as struct


# =============================================================================
# Shared: Bit I/O (LSB-first within each byte)
# =============================================================================

class BitReader:
    """
    Reads individual bits from a byte array, LSB of each byte first.

    Example: byte 0xB4 = 0b10110100 yields bits 0,0,1,0,1,1,0,1 in order.
    """

    def __init__(self, data: bytes):
        self.data     = data
        self.byte_pos = 0
        self.bit_pos  = 0

    def read_bit(self) -> int:
        """Return 0 or 1. Returns 0 indefinitely after the data is exhausted."""
        if self.byte_pos >= len(self.data):
            return 0
        bit = (self.data[self.byte_pos] >> self.bit_pos) & 1
        self.bit_pos += 1
        if self.bit_pos == 8:
            self.bit_pos  = 0
            self.byte_pos += 1
        return bit


class BitWriter:
    """
    Writes individual bits to a byte array, LSB of each byte first.
    Mirror of BitReader â€” a bit written here is read back by BitReader in the same order.
    """

    def __init__(self):
        self._buf      = bytearray()
        self._cur_byte = 0
        self._bit_pos  = 0   # next bit position within _cur_byte (0 = LSB)

    def write_bit(self, bit: int) -> None:
        self._cur_byte |= (bit & 1) << self._bit_pos
        self._bit_pos  += 1
        if self._bit_pos == 8:
            self._buf.append(self._cur_byte)
            self._cur_byte = 0
            self._bit_pos  = 0

    def flush(self) -> None:
        """Pad the current partial byte with zeros and emit it."""
        if self._bit_pos > 0:
            self._buf.append(self._cur_byte)
            self._cur_byte = 0
            self._bit_pos  = 0

    def get_bytes(self) -> bytes:
        return bytes(self._buf)


# =============================================================================
# Decompress - Pass 1b: Arithmetic decoder
# =============================================================================

class ArithDecoder:
    """
    16-bit adaptive arithmetic decoder.

    The frequency model starts with every byte having equal probability (1/256).
    Each time a byte is decoded its frequency count is incremented, so common
    bytes gradually get shorter codes â€” this is the "adaptive" part.

    Internally:
      cum_lo[i]  = cumulative frequency BELOW symbol i
      cum_hi[i]  = cumulative frequency UP TO AND INCLUDING symbol i
                 = cum_lo[i] + freq[i]
      total      = sum of all frequencies = cum_hi[255]

    The arithmetic coder works in the range [low, high] (both 16-bit).
    'code' is the 16-bit window into the compressed bit stream.
    """

    PRECISION = 16
    MAX_VAL   = 0xFFFF
    HALF      = 0x8000
    QUARTER   = 0x4000

    def __init__(self, bits: BitReader):
        self.bits = bits

        # Frequency model â€” uniform init: symbol i covers [i, i+1) out of 256 total.
        self.cum_lo = list(range(256))
        self.cum_hi = list(range(1, 257))
        self.total  = 256

        # Coder state
        self.low  = 0
        self.high = self.MAX_VAL
        # Prime code register: first bit read -> bit 15 (MSB), 16th bit read -> bit 0.
        self.code = 0
        for _ in range(self.PRECISION):
            self.code = ((self.code << 1) | bits.read_bit()) & self.MAX_VAL

    def decode_symbol(self) -> int:
        """
        Decode and return one byte value (0â€“255).

        Steps:
          1. Compute target position in the frequency table.
          2. Binary-search for the symbol that owns that position.
          3. Narrow [low, high] to the symbol's sub-interval.
          4. Renormalize (shift matching bits out, read new bits in).
          5. Update the frequency model.
        """
        lo, hi, code = self.low, self.high, self.code
        range_ = hi - lo + 1

        # Step 1: standard arithmetic decode target
        target = ((code - lo + 1) * self.total - 1) // range_

        # Step 2: binary-search for symbol whose cumulative range contains target
        left, right = 0, 255
        while left < right:
            mid = (left + right) // 2
            if self.cum_hi[mid] <= target:
                left = mid + 1
            else:
                right = mid
        sym = left

        # Step 3: narrow the interval to this symbol's sub-range
        hi = (lo + range_ * self.cum_hi[sym] // self.total - 1) & self.MAX_VAL
        lo = (lo + range_ * self.cum_lo[sym] // self.total)      & self.MAX_VAL

        # Step 4: renormalize — shift out agreed bits and handle underflow
        while True:
            if (lo ^ hi) & self.HALF == 0:
                # MSBs of low and high agree — shift them out.
                lo   = (lo   << 1)         & self.MAX_VAL
                hi   = ((hi  << 1) | 1)    & self.MAX_VAL
                code = ((code << 1) | self.bits.read_bit()) & self.MAX_VAL

            elif (lo & ~hi & self.QUARTER) != 0:
                # Underflow: interval straddles 0.5.
                # Strip the second-most-significant bit, then shift as above.
                lo   = (lo   & ~self.QUARTER) & self.MAX_VAL
                hi   = (hi   |  self.QUARTER) & self.MAX_VAL
                code = (code ^  self.QUARTER) & self.MAX_VAL
                lo   = (lo   << 1)            & self.MAX_VAL
                hi   = ((hi  << 1) | 1)       & self.MAX_VAL
                code = ((code << 1) | self.bits.read_bit()) & self.MAX_VAL

            else:
                break

        self.low, self.high, self.code = lo, hi, code

        # Step 5: update adaptive model, increment frequency of sym
        self.cum_hi[sym] += 1
        for j in range(sym + 1, 256):
            self.cum_lo[j] += 1
            self.cum_hi[j] += 1
        self.total += 1

        return sym


# =============================================================================
# Compress - Pass 1b: Arithmetic encoder  (exact mirror of ArithDecoder)
# =============================================================================

class ArithEncoder:
    """
    16-bit adaptive arithmetic encoder â€” exact inverse of ArithDecoder.

    Uses the same adaptive model and the same renormalization logic.
    Bits are emitted LSB-first into the output byte stream via a BitWriter.

    'pending' tracks deferred underflow bits: when the interval straddles 0.5,
    we can't emit a bit yet but remember that when we eventually resolve
    the MSB we must also emit 'pending' complement bits.
    """

    MAX_VAL = 0xFFFF
    HALF    = 0x8000
    QUARTER = 0x4000

    def __init__(self, bits: BitWriter):
        self.bits = bits

        # Same initial model as the decoder
        self.cum_lo = list(range(256))
        self.cum_hi = list(range(1, 257))
        self.total  = 256

        self.low     = 0
        self.high    = self.MAX_VAL
        self.pending = 0    # deferred underflow bit count

    def _emit(self, bit: int) -> None:
        """Emit one resolved bit, then flush any pending underflow complement bits."""
        self.bits.write_bit(bit)
        comp = bit ^ 1
        for _ in range(self.pending):
            self.bits.write_bit(comp)
        self.pending = 0

    def encode_symbol(self, sym: int) -> None:
        """Encode one byte value (0â€“255) into the bit stream."""
        range_ = self.high - self.low + 1

        # Narrow the interval exactly as the decoder would narrow it for this symbol
        self.high = (self.low + range_ * self.cum_hi[sym] // self.total - 1) & self.MAX_VAL
        self.low  = (self.low + range_ * self.cum_lo[sym] // self.total)      & self.MAX_VAL

        # Renormalize â€” mirror of the decoder's loop
        while True:
            if (self.low ^ self.high) & self.HALF == 0:
                # MSBs agree â€” emit that bit (with any pending underflow complements)
                self._emit((self.low >> 15) & 1)
                self.low  = (self.low  << 1)        & self.MAX_VAL
                self.high = ((self.high << 1) | 1)  & self.MAX_VAL

            elif (self.low & ~self.high & self.QUARTER) != 0:
                # Underflow: interval straddles 0.5, defer one bit
                self.pending += 1
                self.low  = (self.low  & ~self.QUARTER) & self.MAX_VAL
                self.high = (self.high |  self.QUARTER) & self.MAX_VAL
                self.low  = (self.low  << 1)            & self.MAX_VAL
                self.high = ((self.high << 1) | 1)      & self.MAX_VAL

            else:
                break

        # Update adaptive model â€” same as decoder
        self.cum_hi[sym] += 1
        for j in range(sym + 1, 256):
            self.cum_lo[j] += 1
            self.cum_hi[j] += 1
        self.total += 1

    def flush(self) -> None:
        """
        Emit the minimum bits needed to uniquely identify the final interval,
        then pad to the next byte boundary.

        We output 1 bit (which half of [0,1) our interval falls in) followed
        by (pending) complement bits to resolve any deferred underflow.
        """
        self.pending += 1
        if self.low & self.QUARTER:
            self._emit(1)
        else:
            self._emit(0)
        self.bits.flush()


# =============================================================================
# Decompress - Pass 2: LZ decoder
# =============================================================================

RING_SIZE = 0x20000   # 131072 bytes — 128 KB circular history buffer
MIN_MATCH = 4         # minimum back-reference copy length (hard-coded in eboot)
MAX_MATCH = 258       # maximum: token=255, length = 255 + 3


def lz_decompress(arith: ArithDecoder, unc_size: int) -> bytes:
    """
    Decode the LZ layer from the arithmetic-decoded byte stream.

    Token encoding:
      0x00        : LITERAL  — next symbol is the raw byte to output
      0x01..0xFF  : BACK-REF — copy (token + 3) bytes from
                               (current_position - distance) in the ring buffer,
                               where distance = next two symbols as a LE uint16
    """
    ring   = bytearray(RING_SIZE)
    output = bytearray()
    wpos   = 0

    while len(output) < unc_size:
        token = arith.decode_symbol()

        if token == 0x00:
            byte = arith.decode_symbol()
            ring[wpos % RING_SIZE] = byte
            output.append(byte)
            wpos += 1

        else:
            copy_len = token + MIN_MATCH - 1      # token=1 → 4, token=255 → 258
            dist_lo  = arith.decode_symbol()
            dist_hi  = arith.decode_symbol()
            distance = dist_lo | (dist_hi << 8)

            for _ in range(copy_len):
                if len(output) >= unc_size:
                    break
                src  = (wpos - distance) % RING_SIZE
                byte = ring[src]
                ring[wpos % RING_SIZE] = byte
                output.append(byte)
                wpos += 1

    return bytes(output)


# =============================================================================
# Compress - Pass 2: LZ encoder
# =============================================================================

# Hash table sizing, 16-bit index, one slot per bucket (last-seen position only).
# A hash-chain or suffix-array matcher would improve compression ratio but the
# token format is identical; swap it in here if needed.
_HASH_BITS = 16
_HASH_SIZE = 1 << _HASH_BITS
_HASH_MASK = _HASH_SIZE - 1


def _hash4(data: bytes, pos: int) -> int:
    """Fast 4-byte Fibonacci hash (same mix used by many LZ implementations)."""
    v = (data[pos]
         | (data[pos + 1] << 8)
         | (data[pos + 2] << 16)
         | (data[pos + 3] << 24))
    return ((v * 0x9E3779B9) & 0xFFFFFFFF) >> (32 - _HASH_BITS)


def lz_compress(data: bytes) -> list[int]:
    """
    LZ-compress *data* and return the token byte stream as a list of ints.

    This stream is then fed symbol-by-symbol into the arithmetic encoder.

    Token format emitted:
      Literal:   [0x00, byte_value]
      Back-ref:  [token, dist & 0xFF, dist >> 8]
                 where token = copy_length - 3  (range 1..255)
    """
    size  = len(data)
    tokens = []

    # hash_table[h] = most recent position in data that hashed to h
    hash_table = [-1] * _HASH_SIZE

    pos = 0
    while pos < size:
        best_len  = 0
        best_dist = 0

        if pos + MIN_MATCH <= size:
            h        = _hash4(data, pos)
            prev_pos = hash_table[h]
            hash_table[h] = pos          # update before using, so self-matches are avoided

            if prev_pos >= 0:
                dist = pos - prev_pos
                if 1 <= dist <= 0xFFFF:
                    max_len   = min(size - pos, MAX_MATCH)
                    match_len = 0
                    while match_len < max_len and data[pos + match_len] == data[prev_pos + match_len]:
                        match_len += 1
                    if match_len >= MIN_MATCH:
                        best_len  = match_len
                        best_dist = dist

        if best_len >= MIN_MATCH:
            token = best_len - 3          # length = token + 3
            if token > 255:
                token     = 255
                best_len  = 258
            tokens.append(token)
            tokens.append(best_dist & 0xFF)
            tokens.append(best_dist >> 8)
            # Update hash for skipped positions so future matches are still findable
            for skip in range(1, best_len):
                if pos + skip + MIN_MATCH <= size:
                    h2 = _hash4(data, pos + skip)
                    hash_table[h2] = pos + skip
            pos += best_len

        else:
            tokens.append(0x00)           # literal marker
            tokens.append(data[pos])      # literal value
            pos += 1

    return tokens


# =============================================================================
# Checksum
# =============================================================================

def _md5_xor_checksum(body: bytes) -> bytes:
    """
    Compute the 4-byte header checksum: XOR of the 4 LE uint32 words of MD5(body).
    """
    digest = uhashlib.md5(body)
    w0, w1, w2, w3 = struct.unpack('<4I', digest)
    return struct.pack('<I', w0 ^ w1 ^ w2 ^ w3)


# =============================================================================
# Public API
# =============================================================================

def dishonored2_decompress(file_data):
    """Decompress a CHECKPT file to raw save data."""
    print("Input            : {} bytes".format(len(file_data)))
    body = file_data[4:]   # skip 4-byte checksum
    print("Compressed body  : {} bytes".format(len(body)))

    # Step 0: check MD5-XOR checksum
    checksum = _md5_xor_checksum(body)
    if checksum != file_data[:4]:
        print("Warning: checksum mismatch! (expected {}, got {})".format(
            ubinascii.hexlify(file_data[:4]), ubinascii.hexlify(checksum)))
    else:
        print("Checksum OK      : {}".format(ubinascii.hexlify(checksum)))

    # Pass 1: arithmetic decode
    bits  = BitReader(body)
    arith = ArithDecoder(bits)

    # First 4 decoded bytes = big-endian uncompressed size (the LZ size header)
    size_bytes = bytes(arith.decode_symbol() for _ in range(4))
    unc_size   = struct.unpack('>I', size_bytes)[0]
    print("Uncompressed size: {} bytes".format(unc_size))

    # Pass 2: LZ decode
    print("LZ decompressing...")
    result = lz_decompress(arith, unc_size)

    print("LZ Output        : {} bytes".format(len(result)))

    if len(result) != unc_size:
        print("Error: decompressed size mismatch! (expected {}, got {})".format(unc_size, len(result)))
        return False

    file_data[4:] = result

    gc.collect()
    return True


def dishonored2_compress(file_data):
    """Compress raw save data into a CHECKPT file."""

    raw = bytes(file_data[4:])   # skip 4-byte checksum
    print("Input            : {} bytes".format(len(raw)))

    # Step 1: LZ encode the raw data -> token byte stream
    # (The size header is NOT fed through LZ, it is arithmetic-encoded directly
    #  as 4 plain bytes before the token stream, matching how the decompressor
    #  reads 4 raw arithmetic symbols before calling lz_decompress.)
    print("LZ compressing...")
    token_stream = lz_compress(raw)
    print("LZ token stream  : {} bytes".format(len(token_stream)))

    # Step 2: arithmetic encode everything as one continuous stream:
    #   [big-endian uint32 size] [LZ token stream]
    print("Arithmetic encoding...")
    bw  = BitWriter()
    enc = ArithEncoder(bw)
    for b in struct.pack('>I', len(raw)):   # size header 4 bytes, then tokens
        enc.encode_symbol(b)
    for sym in token_stream:
        enc.encode_symbol(sym)
    enc.flush()
    body = bw.get_bytes()
    print("Compressed body  : {} bytes  ({:.1f}% of original)".format(len(body), len(body) * 100 / len(raw)))

    file_data[4:] = body

    gc.collect()
    return True
