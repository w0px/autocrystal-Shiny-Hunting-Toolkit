// gif_codec.cs - GIF reading and writing for the sprite tools (scale_sprites.ps1,
// make_egg_sprites.ps1), which load it with Add-Type. GDI+ can read animated
// GIFs but not write them.
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
        return Region(src, num, den, 0, 0, U16(src, 6), U16(src, 8));
    }

    // Trimmed to the smallest rectangle holding every pixel any frame
    // draws (transparent ones don't count), then scaled until its longer
    // side is `size`.
    public static byte[] Trimmed(byte[] src, int size) {
        if (src.Length < 13 || src[0] != 'G' || src[1] != 'I' || src[2] != 'F') throw new InvalidDataException("not a GIF");
        int[] box = DrawnBox(src);
        return Region(src, size, Math.Max(box[2], box[3]), box[0], box[1], box[2], box[3]);
    }

    // x, y, width, height of what the frames draw, on the canvas.
    static int[] DrawnBox(byte[] src) {
        int cw = U16(src, 6), ch = U16(src, 8); byte packed = src[10];
        int p = 13;
        if ((packed & 0x80) != 0) p += 3 << ((packed & 7) + 1);
        int minX = cw, minY = ch, maxX = -1, maxY = -1;
        int trans = -1; // the transparent color index of the next frame, if it has one
        while (p < src.Length) {
            byte b = src[p++];
            if (b == 0x3B) break;
            if (b == 0x21) {
                byte label = src[p++];
                if (label == 0xF9 && src[p] >= 4) trans = (src[p + 1] & 1) != 0 ? src[p + 4] : -1;
                while (src[p] != 0) p += src[p] + 1;
                p++;
            } else if (b == 0x2C) {
                int left = U16(src, p), top = U16(src, p + 2), fw = U16(src, p + 4), fh = U16(src, p + 6); byte ip = src[p + 8]; p += 9;
                if ((ip & 0x80) != 0) p += 3 << ((ip & 7) + 1);
                int minCode = src[p++];
                MemoryStream data = new MemoryStream();
                while (src[p] != 0) { data.Write(src, p + 1, src[p]); p += src[p] + 1; }
                p++;
                byte[] pixels = Decode(data.ToArray(), minCode, fw * fh);
                if ((ip & 0x40) != 0) pixels = Deinterlace(pixels, fw, fh);
                for (int y = 0; y < fh; y++) {
                    for (int x = 0; x < fw; x++) {
                        int cx = left + x, cy = top + y;
                        if (pixels[y * fw + x] == trans || cx >= cw || cy >= ch) continue;
                        if (cx < minX) minX = cx;
                        if (cx > maxX) maxX = cx;
                        if (cy < minY) minY = cy;
                        if (cy > maxY) maxY = cy;
                    }
                }
                trans = -1;
            } else {
                throw new InvalidDataException("unexpected GIF block 0x" + b.ToString("X2"));
            }
        }
        if (maxX < 0) return new int[] { 0, 0, cw, ch };
        return new int[] { minX, minY, maxX - minX + 1, maxY - minY + 1 };
    }

    // The canvas region at (cx, cy), cw x ch, scaled by num/den.
    static byte[] Region(byte[] src, int num, int den, int cx, int cy, int cw, int ch) {
        MemoryStream o = new MemoryStream();
        int p = 0;
        o.Write(src, 0, 6); p = 6;
        byte packed = src[p + 4];
        W16(o, Up(cw, num, den)); W16(o, Up(ch, num, den)); o.Write(src, p + 4, 3); p += 7;
        if ((packed & 0x80) != 0) { int n = 3 << ((packed & 7) + 1); o.Write(src, p, n); p += n; }
        int trans = -1; // the transparent color index of the next frame, if it has one
        while (p < src.Length) {
            byte b = src[p++];
            if (b == 0x3B) break;
            if (b == 0x21) {
                // Extension (frame timing/transparency, looping, comments): as-is.
                int start = p - 1;
                byte label = src[p++];
                if (label == 0xF9 && src[p] >= 4) trans = (src[p + 1] & 1) != 0 ? src[p + 4] : -1;
                while (src[p] != 0) p += src[p] + 1;
                p++;
                o.Write(src, start, p - start);
            } else if (b == 0x2C) {
                int left = U16(src, p), top = U16(src, p + 2), fw = U16(src, p + 4), fh = U16(src, p + 6); byte ip = src[p + 8]; p += 9;
                int tableStart = p, tableLength = 0;
                if ((ip & 0x80) != 0) { tableLength = 3 << ((ip & 7) + 1); p += tableLength; }
                int minCode = src[p++];
                MemoryStream data = new MemoryStream();
                while (src[p] != 0) { data.Write(src, p + 1, src[p]); p += src[p] + 1; }
                p++;
                byte[] pixels = Decode(data.ToArray(), minCode, fw * fh);
                if ((ip & 0x40) != 0) pixels = Deinterlace(pixels, fw, fh);
                // The part of this frame inside the region, in region coordinates.
                int x0 = Math.Max(left, cx) - cx, y0 = Math.Max(top, cy) - cy;
                int x1 = Math.Min(left + fw, cx + cw) - cx, y1 = Math.Min(top + fh, cy + ch) - cy;
                int nl, nt, nw, nh;
                byte[] scaled;
                if (x1 <= x0 || y1 <= y0) {
                    // Nothing of it inside the region (it only draws
                    // transparency there): a 1x1 transparent frame keeps its
                    // place and timing in the animation.
                    nl = 0; nt = 0; nw = 1; nh = 1;
                    scaled = new byte[] { (byte)(trans >= 0 ? trans : 0) };
                } else {
                    nl = Up(x0, num, den); nt = Up(y0, num, den);
                    nw = Up(x1, num, den) - nl; nh = Up(y1, num, den) - nt;
                    scaled = new byte[nw * nh];
                    for (int y = 0; y < nh; y++) {
                        int sy = cy + (nt + y) * den / num - top;
                        for (int x = 0; x < nw; x++) {
                            scaled[y * nw + x] = pixels[sy * fw + cx + (nl + x) * den / num - left];
                        }
                    }
                }
                o.WriteByte(0x2C); W16(o, nl); W16(o, nt); W16(o, nw); W16(o, nh);
                o.WriteByte((byte)(ip & ~0x40)); // written top to bottom, not interlaced
                o.Write(src, tableStart, tableLength);
                trans = -1;
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

    internal static byte[] Encode(byte[] pixels, int minCode) {
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

// A new looping animated GIF from full-size ARGB frames - for pictures drawn
// with GDI+ (smooth scaling makes colors the source palette doesn't have).
public static class GifWrite {
    const int Transparent = 255;

    // frames: w*h ARGB pixels each; delays in 1/100 s. A pixel under half
    // opacity becomes transparent; the rest share one palette of up to 255
    // colors (median cut over every frame).
    public static byte[] Animated(int w, int h, List<int[]> frames, int[] delays) {
        Dictionary<int, int> counts = new Dictionary<int, int>();
        foreach (int[] f in frames) {
            foreach (int c in f) {
                if (((c >> 24) & 0xFF) < 128) continue;
                int rgb = c & 0xFFFFFF, n;
                counts.TryGetValue(rgb, out n);
                counts[rgb] = n + 1;
            }
        }
        List<int> palette = MedianCut(counts, 255);
        Dictionary<int, byte> nearest = new Dictionary<int, byte>();

        MemoryStream o = new MemoryStream();
        o.Write(new byte[] { (byte)'G', (byte)'I', (byte)'F', (byte)'8', (byte)'9', (byte)'a' }, 0, 6);
        W16(o, w); W16(o, h);
        o.WriteByte(0xF7); o.WriteByte(Transparent); o.WriteByte(0); // 256-color global table
        for (int i = 0; i < 256; i++) {
            int c = i < palette.Count ? palette[i] : 0;
            o.WriteByte((byte)(c >> 16)); o.WriteByte((byte)(c >> 8)); o.WriteByte((byte)c);
        }
        // Loop forever.
        o.Write(new byte[] { 0x21, 0xFF, 0x0B }, 0, 3);
        o.Write(System.Text.Encoding.ASCII.GetBytes("NETSCAPE2.0"), 0, 11);
        o.Write(new byte[] { 0x03, 0x01, 0x00, 0x00, 0x00 }, 0, 5);
        for (int f = 0; f < frames.Count; f++) {
            // Restore to transparent after each frame, with that frame's delay.
            o.Write(new byte[] { 0x21, 0xF9, 0x04, 0x09 }, 0, 4);
            W16(o, delays[f]); o.WriteByte(Transparent); o.WriteByte(0);
            o.WriteByte(0x2C); W16(o, 0); W16(o, 0); W16(o, w); W16(o, h); o.WriteByte(0);
            byte[] indexed = new byte[w * h];
            for (int i = 0; i < indexed.Length; i++) {
                int c = frames[f][i];
                if (((c >> 24) & 0xFF) < 128) { indexed[i] = Transparent; continue; }
                int rgb = c & 0xFFFFFF;
                byte idx;
                if (!nearest.TryGetValue(rgb, out idx)) { idx = Nearest(palette, rgb); nearest[rgb] = idx; }
                indexed[i] = idx;
            }
            o.WriteByte(8);
            byte[] packed = GifScale.Encode(indexed, 8);
            for (int i = 0; i < packed.Length; i += 255) {
                int n = Math.Min(255, packed.Length - i);
                o.WriteByte((byte)n); o.Write(packed, i, n);
            }
            o.WriteByte(0);
        }
        o.WriteByte(0x3B);
        return o.ToArray();
    }

    // Repeatedly splits the box of colors with the widest channel at its
    // pixel-count median, until there are `max` boxes (or nothing left to
    // split); each box becomes its pixel-weighted average color.
    static List<int> MedianCut(Dictionary<int, int> counts, int max) {
        List<List<int>> boxes = new List<List<int>>();
        if (counts.Count > 0) boxes.Add(new List<int>(counts.Keys));
        while (boxes.Count < max) {
            int pick = -1, widest = 0, channel = 0;
            for (int b = 0; b < boxes.Count; b++) {
                if (boxes[b].Count < 2) continue;
                for (int ch = 0; ch < 3; ch++) {
                    int lo = 255, hi = 0;
                    foreach (int c in boxes[b]) { int v = (c >> (16 - 8 * ch)) & 0xFF; if (v < lo) lo = v; if (v > hi) hi = v; }
                    if (hi - lo > widest) { widest = hi - lo; pick = b; channel = ch; }
                }
            }
            if (pick < 0) break;
            int shift = 16 - 8 * channel;
            List<int> box = boxes[pick];
            box.Sort((a, c) => ((a >> shift) & 0xFF).CompareTo((c >> shift) & 0xFF));
            long total = 0; foreach (int c in box) total += counts[c];
            long run = 0; int cut = box.Count - 1;
            for (int i = 0; i < box.Count - 1; i++) { run += counts[box[i]]; if (run * 2 >= total) { cut = i + 1; break; } }
            boxes[pick] = box.GetRange(0, cut);
            boxes.Add(box.GetRange(cut, box.Count - cut));
        }
        List<int> palette = new List<int>();
        foreach (List<int> box in boxes) {
            long r = 0, g = 0, bl = 0, n = 0;
            foreach (int c in box) { long k = counts[c]; r += ((c >> 16) & 0xFF) * k; g += ((c >> 8) & 0xFF) * k; bl += (c & 0xFF) * k; n += k; }
            palette.Add((int)(((r / n) << 16) | ((g / n) << 8) | (bl / n)));
        }
        return palette;
    }

    static byte Nearest(List<int> palette, int rgb) {
        int best = 0; long bestD = long.MaxValue;
        for (int i = 0; i < palette.Count; i++) {
            int p = palette[i];
            long dr = ((p >> 16) & 0xFF) - ((rgb >> 16) & 0xFF), dg = ((p >> 8) & 0xFF) - ((rgb >> 8) & 0xFF), db = (p & 0xFF) - (rgb & 0xFF);
            long d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
            if (d < bestD) { bestD = d; best = i; }
        }
        return (byte)best;
    }

    static void W16(Stream s, int v) { s.WriteByte((byte)(v & 0xFF)); s.WriteByte((byte)(v >> 8)); }
}
