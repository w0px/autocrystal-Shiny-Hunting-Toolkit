# scale_sprites.ps1
# Makes the bigger animated sprites the launcher's Last Encounter card
# shows (gui_module.lua), from the ones download_sprites.ps1 fetched:
#   data\sprites\animated\{normal,shiny}\<dex>.gif        56x56
#   -> data\sprites\animated_card\{normal,shiny}\<dex>.gif  91x91 (1.625x)
# Scaled nearest-neighbor, so the pixel art stays sharp - a picturebox can
# only scale a GIF smoothly, which blurs it. At 1.625x, five of every
# eight source pixels become 2px wide and the other three 1px. The
# animation, timing and transparency are kept as they are.
# download_sprites.ps1 runs this by itself at the end; safe to re-run, it
# only makes the ones that are missing or at a different size.

param(
    [string]$SpriteDir = (Join-Path $PSScriptRoot "..\data\sprites"),
    # The scale, as a fraction: 13/8 = 1.625x (56px -> 91px). Keep
    # gui_module.lua's SPRITE_SCALE / SPRITE_CARD_SIZE in step with it.
    [int]$Numerator = 13,
    [int]$Denominator = 8
)

# A GIF's canvas width, from its header.
function Get-GifWidth([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try { $b = New-Object byte[] 8; [void]$fs.Read($b, 0, 8); return $b[6] + 256 * $b[7] } finally { $fs.Close() }
}

$ErrorActionPreference = "Stop"

# GDI+ can read animated GIFs but not write them, so this re-encodes the
# file itself: every block is copied as-is except the frames, whose
# pixels are LZW-decoded, resampled and LZW-encoded again.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;

public static class GifScale {
    // Where source coordinate v lands: the first destination pixel whose
    // source pixel (floor(d * den / num)) is v or later. Used for the
    // canvas and every frame's edges alike, so frames stay lined up.
    static int Up(int v, int num, int den) { return (v * num + den - 1) / den; }

    public static byte[] Scale(byte[] src, int num, int den) {
        if (src.Length < 13 || src[0] != 'G' || src[1] != 'I' || src[2] != 'F') throw new InvalidDataException("not a GIF");
        MemoryStream o = new MemoryStream();
        int p = 0;
        o.Write(src, 0, 6); p = 6;
        int w = U16(src, p), h = U16(src, p + 2); byte packed = src[p + 4];
        W16(o, Up(w, num, den)); W16(o, Up(h, num, den)); o.Write(src, p + 4, 3); p += 7;
        if ((packed & 0x80) != 0) { int n = 3 << ((packed & 7) + 1); o.Write(src, p, n); p += n; }
        while (p < src.Length) {
            byte b = src[p++];
            if (b == 0x3B) break;
            if (b == 0x21) {
                // Extension (frame timing/transparency, looping, comments): as-is.
                int start = p - 1;
                p++; // label
                while (src[p] != 0) p += src[p] + 1;
                p++;
                o.Write(src, start, p - start);
            } else if (b == 0x2C) {
                int left = U16(src, p), top = U16(src, p + 2), fw = U16(src, p + 4), fh = U16(src, p + 6); byte ip = src[p + 8]; p += 9;
                int nl = Up(left, num, den), nt = Up(top, num, den);
                int nw = Up(left + fw, num, den) - nl, nh = Up(top + fh, num, den) - nt;
                o.WriteByte(0x2C); W16(o, nl); W16(o, nt); W16(o, nw); W16(o, nh);
                o.WriteByte((byte)(ip & ~0x40)); // written top to bottom, not interlaced
                if ((ip & 0x80) != 0) { int n = 3 << ((ip & 7) + 1); o.Write(src, p, n); p += n; }
                int minCode = src[p++];
                MemoryStream data = new MemoryStream();
                while (src[p] != 0) { data.Write(src, p + 1, src[p]); p += src[p] + 1; }
                p++;
                byte[] pixels = Decode(data.ToArray(), minCode, fw * fh);
                if ((ip & 0x40) != 0) pixels = Deinterlace(pixels, fw, fh);
                byte[] scaled = new byte[nw * nh];
                for (int y = 0; y < nh; y++) {
                    int sy = (nt + y) * den / num - top;
                    for (int x = 0; x < nw; x++) {
                        scaled[y * nw + x] = pixels[sy * fw + (nl + x) * den / num - left];
                    }
                }
                o.WriteByte((byte)minCode);
                byte[] packedData = Encode(scaled, minCode);
                for (int i = 0; i < packedData.Length; i += 255) {
                    int n = Math.Min(255, packedData.Length - i);
                    o.WriteByte((byte)n); o.Write(packedData, i, n);
                }
                o.WriteByte(0);
            } else {
                throw new InvalidDataException("unexpected GIF block 0x" + b.ToString("X2"));
            }
        }
        o.WriteByte(0x3B);
        return o.ToArray();
    }

    static int U16(byte[] a, int i) { return a[i] | (a[i + 1] << 8); }
    static void W16(Stream s, int v) { s.WriteByte((byte)(v & 0xFF)); s.WriteByte((byte)(v >> 8)); }

    static byte[] Decode(byte[] data, int minCode, int count) {
        int clear = 1 << minCode, eoi = clear + 1;
        int[] prefix = new int[4096]; byte[] suffix = new byte[4096]; byte[] first = new byte[4096]; int[] length = new int[4096];
        for (int i = 0; i < clear; i++) { prefix[i] = -1; suffix[i] = (byte)i; first[i] = (byte)i; length[i] = 1; }
        byte[] output = new byte[count];
        int op = 0, codeSize = minCode + 1, next = eoi + 1, prev = -1;
        long bit = 0, bits = (long)data.Length * 8;
        while (bit + codeSize <= bits && op < count) {
            int code = 0;
            for (int i = 0; i < codeSize; i++, bit++) if ((data[bit >> 3] & (1 << (int)(bit & 7))) != 0) code |= 1 << i;
            if (code == clear) { codeSize = minCode + 1; next = eoi + 1; prev = -1; continue; }
            if (code == eoi) break;
            if (prev == -1) {
                if (code >= clear) break;
                output[op++] = (byte)code; prev = code; continue;
            }
            int emit;
            if (code < next) {
                if (next < 4096) { prefix[next] = prev; suffix[next] = first[code]; first[next] = first[prev]; length[next] = length[prev] + 1; next++; }
                emit = code;
            } else if (code == next && next < 4096) {
                prefix[next] = prev; suffix[next] = first[prev]; first[next] = first[prev]; length[next] = length[prev] + 1; next++;
                emit = code;
            } else {
                break; // corrupt - keep what's decoded so far
            }
            if (next == (1 << codeSize) && codeSize < 12) codeSize++;
            int len = length[emit];
            for (int c = emit, k = len - 1; c != -1; c = prefix[c], k--) if (op + k < count) output[op + k] = suffix[c];
            op = Math.Min(count, op + len);
            prev = code;
        }
        return output;
    }

    static byte[] Encode(byte[] pixels, int minCode) {
        int clear = 1 << minCode, eoi = clear + 1;
        Bits bw = new Bits();
        int codeSize = minCode + 1, next = eoi + 1;
        Dictionary<int, int> table = new Dictionary<int, int>();
        bw.Write(clear, codeSize);
        if (pixels.Length > 0) {
            int current = pixels[0];
            for (int i = 1; i < pixels.Length; i++) {
                int key = (current << 8) | pixels[i], code;
                if (table.TryGetValue(key, out code)) { current = code; continue; }
                // A code is written as wide as the decoder will be reading
                // by then - it adds its table entries one code behind us.
                if (next > (1 << codeSize) && codeSize < 12) codeSize++;
                bw.Write(current, codeSize);
                if (next < 4096) {
                    table[key] = next++;
                } else {
                    bw.Write(clear, codeSize);
                    table.Clear(); next = eoi + 1; codeSize = minCode + 1;
                }
                current = pixels[i];
            }
            if (next > (1 << codeSize) && codeSize < 12) codeSize++;
            bw.Write(current, codeSize);
            // The decoder adds one last entry on reading that code.
            if (next >= (1 << codeSize) && codeSize < 12) codeSize++;
        }
        bw.Write(eoi, codeSize);
        return bw.ToArray();
    }

    static byte[] Deinterlace(byte[] pixels, int w, int h) {
        byte[] output = new byte[pixels.Length];
        int row = 0;
        int[][] passes = { new[] { 0, 8 }, new[] { 4, 8 }, new[] { 2, 4 }, new[] { 1, 2 } };
        foreach (int[] pass in passes) {
            for (int y = pass[0]; y < h; y += pass[1], row++) Array.Copy(pixels, row * w, output, y * w, w);
        }
        return output;
    }

    class Bits {
        MemoryStream s = new MemoryStream(); int acc, count;
        public void Write(int code, int size) {
            acc |= code << count; count += size;
            while (count >= 8) { s.WriteByte((byte)(acc & 0xFF)); acc >>= 8; count -= 8; }
        }
        public byte[] ToArray() { if (count > 0) { s.WriteByte((byte)(acc & 0xFF)); acc = 0; count = 0; } return s.ToArray(); }
    }
}
"@

$made = 0; $had = 0; $failed = New-Object System.Collections.Generic.List[string]
foreach ($set in "normal", "shiny") {
    $from = Join-Path $SpriteDir "animated\$set"
    if (-not (Test-Path -LiteralPath $from)) { continue }
    $to = Join-Path $SpriteDir "animated_card\$set"
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($gif in Get-ChildItem -LiteralPath $from -Filter "*.gif" -File) {
        $target = Join-Path $to $gif.Name
        if (Test-Path -LiteralPath $target) {
            # Kept if it's already at this scale; remade if it's from another.
            $want = [int][Math]::Ceiling((Get-GifWidth $gif.FullName) * $Numerator / $Denominator)
            if ((Get-GifWidth $target) -eq $want) { $had++; continue }
        }
        try {
            [System.IO.File]::WriteAllBytes("$target.part", [GifScale]::Scale([System.IO.File]::ReadAllBytes($gif.FullName), $Numerator, $Denominator))
            Move-Item -Force -LiteralPath "$target.part" -Destination $target
            $made++
        } catch {
            $failed.Add("$set/$($gif.Name)")
            if (Test-Path -LiteralPath "$target.part") { Remove-Item -Force -LiteralPath "$target.part" }
        }
    }
}
Write-Host ("Last Encounter card sprites: made {0}, already had {1}, failed {2}." -f $made, $had, $failed.Count)
if ($failed.Count -gt 0) { Write-Host ("Failed: " + ($failed -join ", ")) }
