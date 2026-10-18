#!/usr/bin/env python3
"""Trace a fish's silhouette from a photo into an SVG path, and measure it.

  trace   <photo> <out_dir> [--faces left|right] [--tol T] [--smooth S]
          [--close R] [--svg edited.svg]
      Segments the fish from its background (colour distance from the
      border's colour, Otsu threshold unless --tol), keeps the largest blob,
      fills holes, and writes into out_dir:
        silhouette.svg   the closed outline as a smooth cubic path, in a
                         normalised frame: snout at x=0, tail tip at x=1000,
                         facing right, y down (SVG), body axis at y=0
        overlay.png      the photo with the path drawn on it (red) and the
                         mask's edge (cyan) — look at this to evaluate
        mask.png         the segmentation mask
        measure.json     proportions read off the outline (see below)
      and prints a summary. --svg evaluates a hand-edited silhouette.svg
      against the mask instead of tracing a new one.

      Evaluation rounds: read overlay.png (it carries a pixel grid, labels
      every 100 px) and fix what the colour segmentation got wrong, then
      re-run: --cut 'x,y x,y ...' removes background caught in (a lit floor,
      coral), --add 'x,y ...' adds what it missed (translucent fins, fin
      tips as pale as the water), --grow N pulls in thin dark margins, --tol
      moves the colour threshold. --rotate D levels a fish swimming nose-up
      or -down (the game's fish swim level); corrections are then read off
      the rotated overlay. Repeat until the red path hugs the fish.

  compare <photo_dir> <model_screenshot> [--faces left|right] [--bg auto]
      Traces the model's silhouette from a fish-lab screenshot (solid
      backdrop) the same way, scales both to the same length and prints IoU
      plus the height profile difference every 5% along the fish — where the
      3D model is too deep, too shallow, too short or too long.

measure.json: length 1 = snout to tail tip. "profile" lists, every 5% along
the fish, the top and bottom of the silhouette in body-length units (+y up),
so body depth, tail stock and tail height can be read directly; "summary"
picks out the deepest point, the narrowest point behind it (tail stock) and
the tail's height.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from skimage import color, filters, measure, morphology


def _segment(rgb, tol=None, close=3, keep_border=False, bridge=6):
    """Foreground mask: pixels far (in Lab) from the border's median colour.

    Regions touching the image border are background (a lit floor, a bright
    patch) unless keep_border. Every sizeable region is kept, then joined
    across gaps up to `bridge` px — dark outlines (a clownfish's black band
    edges) can be as dark as the background and split the fish in pieces.
    """
    lab = color.rgb2lab(rgb)
    h, w = lab.shape[:2]
    b = max(2, min(h, w) // 40)
    border = np.concatenate([lab[:b].reshape(-1, 3), lab[-b:].reshape(-1, 3),
                             lab[:, :b].reshape(-1, 3), lab[:, -b:].reshape(-1, 3)])
    bg = np.median(border, axis=0)
    dist = np.linalg.norm(lab - bg, axis=2)
    t = tol if tol is not None else filters.threshold_otsu(dist)
    mask = dist > t
    if close > 0:
        mask = morphology.binary_opening(mask, morphology.disk(max(1, close // 2)))
    lbl = measure.label(mask)
    if lbl.max() == 0:
        sys.exit("No foreground found — try a smaller --tol.")
    keep = np.zeros_like(mask)
    sizes = np.bincount(lbl.ravel())
    sizes[0] = 0
    edge_ids = set(np.unique(np.concatenate([lbl[0], lbl[-1], lbl[:, 0], lbl[:, -1]])))
    big = sizes.max()
    for i in range(1, len(sizes)):
        if sizes[i] < 0.03 * big:
            continue
        if i in edge_ids and not keep_border:
            continue
        keep |= lbl == i
    if not keep.any():  # everything touches the border: keep the biggest
        keep = lbl == sizes.argmax()
    mask = keep
    if bridge > 0:
        mask = morphology.binary_closing(mask, morphology.disk(bridge))
    mask = ndimage.binary_fill_holes(mask)
    lbl = measure.label(mask)
    sizes = np.bincount(lbl.ravel())
    sizes[0] = 0
    return lbl == sizes.argmax(), t


def _poly(spec):
    """'x,y x,y ...' (photo pixels) → [(x, y), ...]."""
    return [tuple(float(v) for v in pt.split(",")) for pt in spec.split()]


def _correct(mask, a):
    """Apply the evaluation rounds' fixes: grow the edge, add and cut
    polygons read off the overlay's grid; keep the largest piece."""
    if a.grow > 0:
        mask = morphology.binary_dilation(mask, morphology.disk(a.grow))
    if a.add or a.cut:
        img = Image.fromarray((mask * 255).astype(np.uint8))
        dr = ImageDraw.Draw(img)
        for spec in a.add or []:
            dr.polygon(_poly(spec), fill=255)
        for spec in a.cut or []:
            dr.polygon(_poly(spec), fill=0)
        mask = np.array(img) > 0
    mask = ndimage.binary_fill_holes(mask)
    lbl = measure.label(mask)
    sizes = np.bincount(lbl.ravel())
    sizes[0] = 0
    return lbl == sizes.argmax()


def _grid(img, step=50):
    """Label the photo with a pixel grid, so corrections can be read off."""
    dr = ImageDraw.Draw(img)
    w, h = img.size
    for x in range(0, w, step):
        dr.line([(x, 0), (x, h)], fill=(255, 255, 0) if x % 100 == 0 else (110, 110, 0), width=1)
        if x % 100 == 0:
            dr.text((x + 2, 2), str(x), fill=(255, 255, 0))
    for y in range(0, h, step):
        dr.line([(0, y), (w, y)], fill=(255, 255, 0) if y % 100 == 0 else (110, 110, 0), width=1)
        if y % 100 == 0:
            dr.text((2, y + 2), str(y), fill=(255, 255, 0))


def _frame(mask, faces):
    """Snout→tail axis: the mask's bounding box, flipped so it faces right."""
    ys, xs = np.nonzero(mask)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    # Measured from the snout: a fish facing right has its snout at x1.
    flip = faces == 'right'
    length = x1 - x0
    # body axis: the mask's centre row over its front 60% (head + body)
    front = (xs < x0 + 0.6 * length) if flip else (xs > x1 - 0.6 * length)
    axis_y = ys[front].mean()

    def to_norm(px, py):
        u = (x1 - px) if flip else (px - x0)
        return u / length * 1000.0, (py - axis_y) / length * 1000.0

    return to_norm, (x0, x1, y0, y1), flip


def _smooth_path(pts):
    """Closed Catmull-Rom spline through pts as SVG cubic segments."""
    n = len(pts)
    d = [f"M {pts[0][0]:.1f} {pts[0][1]:.1f}"]
    for i in range(n):
        p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d.append(f"C {c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}")
    return " ".join(d) + " Z"


def _sample_path(d, steps=12):
    """Polyline of an M/C/Z path (the format _smooth_path writes)."""
    toks = d.replace(",", " ").split()
    pts, i, cur = [], 0, None
    while i < len(toks):
        t = toks[i]
        if t == "M":
            cur = (float(toks[i + 1]), float(toks[i + 2]))
            pts.append(cur)
            i += 3
        elif t == "C":
            c = [float(v) for v in toks[i + 1:i + 7]]
            p0, p1, p2, p3 = cur, (c[0], c[1]), (c[2], c[3]), (c[4], c[5])
            for k in range(1, steps + 1):
                s = k / steps
                a, b_, c_, e = (1 - s) ** 3, 3 * s * (1 - s) ** 2, 3 * s * s * (1 - s), s ** 3
                pts.append((a * p0[0] + b_ * p1[0] + c_ * p2[0] + e * p3[0],
                            a * p0[1] + b_ * p1[1] + c_ * p2[1] + e * p3[1]))
            cur = p3
            i += 7
        elif t == "L":
            cur = (float(toks[i + 1]), float(toks[i + 2]))
            pts.append(cur)
            i += 3
        else:
            i += 1
    return pts


def _profile(poly_norm):
    """Top/bottom (+y up, body lengths) every 5% along x in [0, 1000]."""
    # ±1 fish length: tall fish (angelfish, discus) reach past ±0.5.
    img = Image.new("L", (1001, 2001), 0)
    ImageDraw.Draw(img).polygon([(x, y + 1000) for x, y in poly_norm], fill=255)
    m = np.array(img) > 0
    out = []
    for k in range(0, 21):
        x = min(1000, k * 50)
        col = np.nonzero(m[:, x])[0]
        if len(col) == 0:
            out.append({"at": k * 0.05, "top": None, "bottom": None, "depth": 0.0})
            continue
        top, bot = (1000 - col.min()) / 1000, (1000 - col.max()) / 1000
        out.append({"at": round(k * 0.05, 2), "top": round(top, 4),
                    "bottom": round(bot, 4), "depth": round(top - bot, 4)})
    return out, m


def _summary(profile):
    """Landmarks of the silhouette — fins included, so a tall dorsal or
    flowing tail counts as depth; read the profile for the body alone."""
    depths = [p["depth"] for p in profile]
    deep = int(np.argmax(depths[:13]))  # front 60%: head and body
    stock = deep + 1 + int(np.argmin(depths[deep + 1:19]))  # narrowest behind it
    tail = max(depths[stock:]) if stock < len(depths) else 0
    return {
        "silhouette_max_depth": depths[deep], "silhouette_max_depth_at": profile[deep]["at"],
        "narrowest_behind_at": profile[stock]["at"], "narrowest_behind_depth": depths[stock],
        "tail_height": tail,
        "length_over_max_depth": round(1 / depths[deep], 2) if depths[deep] else None,
        "note": "silhouette incl. fins; lengths in fish lengths (snout→tail tip = 1); "
                "at = fraction from snout",
    }


def _load(a):
    """The photo, levelled by --rotate (degrees, counter-clockwise: + lowers
    a left-facing fish's raised snout), on a background-coloured canvas."""
    im = Image.open(a.photo).convert("RGB")
    if a.rotate:
        corner = im.getpixel((2, 2))
        im = im.rotate(a.rotate, resample=Image.BICUBIC, expand=True, fillcolor=corner)
    return im


def cmd_trace(a):
    photo = _load(a)
    rgb = np.array(photo).astype(float) / 255
    mask, t = _segment(rgb, a.tol, a.close, a.keep_border, a.bridge)
    mask = _correct(mask, a)
    to_norm, (x0, x1, y0, y1), flip = _frame(mask, a.faces)
    os.makedirs(a.out_dir, exist_ok=True)
    Image.fromarray((mask * 255).astype(np.uint8)).save(os.path.join(a.out_dir, "mask.png"))

    if a.svg:
        d = open(a.svg).read().split('d="')[1].split('"')[0]
        poly_norm = _sample_path(d)
    else:
        cont = max(measure.find_contours(mask.astype(float), 0.5), key=len)
        simp = measure.approximate_polygon(cont, tolerance=a.smooth)
        pts = [to_norm(c, r) for r, c in simp[:-1]]
        d = _smooth_path(pts)
        poly_norm = _sample_path(d)
        with open(os.path.join(a.out_dir, "silhouette.svg"), "w") as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="-20 -520 1040 1040">\n'
                    f'  <path d="{d}" fill="none" stroke="red" stroke-width="3"/>\n</svg>\n')

    # back to photo pixels for the overlay and the IoU
    length = x1 - x0
    ys, xs = np.nonzero(mask)
    front = (xs < x0 + 0.6 * length) if flip else (xs > x1 - 0.6 * length)
    axis_y = ys[front].mean()
    poly_px = [((x1 - u / 1000 * length) if flip else (x0 + u / 1000 * length), axis_y + v / 1000 * length)
               for u, v in poly_norm]
    fill = Image.new("L", (mask.shape[1], mask.shape[0]), 0)
    ImageDraw.Draw(fill).polygon(poly_px, fill=255)
    pm = np.array(fill) > 0
    iou = (pm & mask).sum() / max(1, (pm | mask).sum())

    over = photo.copy()
    dr = ImageDraw.Draw(over)
    edge = mask ^ morphology.binary_erosion(mask, morphology.disk(1))
    ov = np.array(over)
    ov[edge] = [0, 255, 255]
    over = Image.fromarray(ov)
    _grid(over)
    ImageDraw.Draw(over).line(poly_px + [poly_px[0]], fill=(255, 30, 30), width=2)
    over.save(os.path.join(a.out_dir, "overlay.png"))

    profile, _ = _profile(poly_norm)
    res = {"iou_path_vs_mask": round(float(iou), 4), "threshold": round(float(t), 2),
           "faces": a.faces, "summary": _summary(profile), "profile": profile}
    with open(os.path.join(a.out_dir, "measure.json"), "w") as f:
        json.dump(res, f, indent=1)
    s = res["summary"]
    print(f"IoU path↔mask {iou:.3f}  (threshold {t:.1f})")
    print(f"(silhouette incl. fins) length/depth {s['length_over_max_depth']}"
          f"  deepest {s['silhouette_max_depth']:.3f} at {s['silhouette_max_depth_at']:.2f}"
          f"  narrowest behind {s['narrowest_behind_depth']:.3f} at {s['narrowest_behind_at']:.2f}"
          f"  tail height {s['tail_height']:.3f}")
    print("wrote", ", ".join(sorted(os.listdir(a.out_dir))), "→", a.out_dir)


def cmd_compare(a):
    ref = json.load(open(os.path.join(a.photo_dir, "measure.json")))
    rgb = np.array(Image.open(a.model).convert("RGB")).astype(float) / 255
    # The lab shows the model in the right half; segment only that.
    # Below the chips and labels, above the controls.
    h = rgb.shape[0]
    half = rgb[int(h * 0.11):int(h * 0.88), rgb.shape[1] // 2:]
    mask, _ = _segment(half, a.tol, 2)
    over = (half * 255).astype(np.uint8).copy()
    over[mask ^ morphology.binary_erosion(mask, morphology.disk(1))] = [255, 30, 30]
    out = os.path.join(a.photo_dir, "model_overlay.png")
    Image.fromarray(over).save(out)
    to_norm, _, _ = _frame(mask, a.faces)
    cont = max(measure.find_contours(mask.astype(float), 0.5), key=len)
    poly = _sample_path(_smooth_path([to_norm(c, r) for r, c in measure.approximate_polygon(cont, 1.5)[:-1]]))
    prof, mm = _profile(poly)
    ref_poly = _sample_path(open(os.path.join(a.photo_dir, "silhouette.svg")).read().split('d="')[1].split('"')[0])
    _, rm = _profile(ref_poly)
    iou = (mm & rm).sum() / max(1, (mm | rm).sum())
    print(f"model mask → {out}")
    print(f"silhouette IoU photo↔model {iou:.3f}   (1.0 = identical, after scaling to the same length)")
    print(" at    photo top/bot    model top/bot    depth Δ")
    for r, m in zip(ref["profile"], prof):
        if r["top"] is None or m["top"] is None:
            continue
        dd = m["depth"] - r["depth"]
        flag = "  model too deep" if dd > 0.02 else ("  model too shallow" if dd < -0.02 else "")
        print(f"{r['at']:.2f}  {r['top']:+.3f}/{r['bottom']:+.3f}   {m['top']:+.3f}/{m['bottom']:+.3f}   {dd:+.3f}{flag}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trace")
    t.add_argument("photo")
    t.add_argument("out_dir")
    t.add_argument("--faces", choices=["left", "right"], default="right")
    t.add_argument("--tol", type=float, help="colour distance threshold (default: Otsu)")
    t.add_argument("--smooth", type=float, default=2.0, help="polygon simplification, px")
    t.add_argument("--close", type=int, default=3, help="morphological closing radius, px")
    t.add_argument("--svg", help="evaluate this edited silhouette.svg instead of tracing")
    t.add_argument("--keep-border", action="store_true", help="keep regions touching the image edge")
    t.add_argument("--bridge", type=int, default=6, help="join pieces across gaps up to this many px")
    t.add_argument("--rotate", type=float, default=0,
                   help="level a pitched fish first (degrees CCW); --add/--cut use the rotated overlay's grid")
    t.add_argument("--grow", type=int, default=0, help="dilate the mask by N px (pull in thin dark margins)")
    t.add_argument("--add", action="append", help="'x,y x,y ...' polygon (photo px) to add — missed fins")
    t.add_argument("--cut", action="append", help="'x,y x,y ...' polygon (photo px) to remove — floor, rocks")
    c = sub.add_parser("compare")
    c.add_argument("photo_dir")
    c.add_argument("model")
    c.add_argument("--faces", choices=["left", "right"], default="right")
    c.add_argument("--tol", type=float, help="colour threshold for the model's backdrop (default: Otsu)")
    a = p.parse_args()
    cmd_trace(a) if a.cmd == "trace" else cmd_compare(a)


if __name__ == "__main__":
    main()
