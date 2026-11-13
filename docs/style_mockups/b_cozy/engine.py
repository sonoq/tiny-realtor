"""Cozy pastel diorama - tiny isometric pixel renderer (Pillow + numpy + shapely).

Everything is drawn into ONE low-res pixel grid and upscaled with NEAREST only.
Pipeline:  faces (planar 3D polygons) are rasterised with a z-buffer into a G-buffer
(lit colour, in-shadow colour, world xyz).  Shadows are ray-marched over a heightmap
toward a low afternoon sun; two sun samples give a dithered penumbra.
"""
import math, hashlib
import numpy as np
from PIL import Image, ImageDraw

# ------------------------------------------------------------------ palette ---------
HEX = {
    # outlines / ink
    "ink": "#4a3b52", "ink2": "#6d5a73",
    # sky + background
    "sky0": "#c9e4ee", "sky1": "#dcecef", "sky2": "#f5e9dc", "sky3": "#f8d9cb",
    "cloud": "#fffaf1", "cloud2": "#efdfe6", "floatsh": "#e7c3bf",
    # facades  (L lit, M mid/chamfer, D shade, X deep shade)
    "creL": "#f8ecd2", "creM": "#ecdcc0", "creD": "#d6c3b6", "creX": "#b7a5ad",
    "peaL": "#f9d0b0", "peaM": "#efbea2", "peaD": "#d6a297", "peaX": "#b4878f",
    "minL": "#d3ebd0", "minM": "#c0dcc2", "minD": "#a4c1b8", "minX": "#88a2a5",
    "skyL": "#d4e5f2", "skyM": "#c0d3e9", "skyD": "#a6b6d4", "skyX": "#8c9abb",
    "rosL": "#f7d5d3", "rosM": "#ebc2c4", "rosD": "#d0a7b3", "rosX": "#ad8a9e",
    "butL": "#f9e6a8", "butM": "#eed596", "butD": "#d3b78f", "butX": "#ae9585",
    # terracotta
    "terH": "#efa17b", "terL": "#df8763", "terM": "#cb7259", "terD": "#a95c55", "terX": "#874a50",
    # glass / windows
    "glaL": "#6f84a6", "glaD": "#58668c", "glaX": "#4b5478", "glaH": "#b4d4e6",
    "rail": "#6e5a6e", "shut": "#7db69b", "shutD": "#5f9583",
    # modern glass (tower / skyscraper)
    "gtH": "#c8e9f0", "gtL": "#a9d6e6", "gtM": "#8fc1dc", "gtD": "#7aa2c8", "gtX": "#6683ad",
    "frmL": "#fbf6ec", "frmD": "#d9d3dc",
    # ground
    "pavL": "#efe3cc", "pavP": "#e2d3ba", "pavX": "#c4b5bf", "pavXP": "#b6a8b6",
    "curb": "#d6c6ae", "curbD": "#b9a99f",
    "asp": "#9ca3bb", "asp2": "#929ab3", "aspX": "#7d819f", "mark": "#f7f0de", "markX": "#c9c2cf",
    "grsH": "#c8e39b", "grsL": "#b0d68c", "grsM": "#9ac87e", "grsX": "#7fa785", "grsXX": "#6b9079",
    "sand": "#ecd6ae", "sandX": "#c3afae",
    "dirL": "#ddb68b", "dirM": "#c99e78", "dirX": "#a88a87",
    "watL": "#9fe0dc", "watM": "#74c6cf", "watX": "#5e9fb5",
    # vegetation
    "leH": "#bfe28f", "leL": "#93c975", "leM": "#6fae6a", "leD": "#548d61", "leX": "#46705a",
    "trunk": "#9b6b55", "trunkD": "#7a5452",
    "flwP": "#f49aaa", "flwY": "#fbd36b", "flwO": "#f6a25c",
    # diorama base
    "e0": "#e0a77c", "e1": "#cb8c68", "e2": "#ad7059", "e3": "#8c5a53", "e4": "#6f4850",
    "e0D": "#c08a74", "e1D": "#a87262", "e2D": "#8d5b55", "e3D": "#734a4f", "e4D": "#5b3c4a",
    "stone": "#e9d9c6", "stoneD": "#bfa9a4",
    # brand / ui
    "teaH": "#9fe3cf", "teaL": "#46b8a0", "teaD": "#2f8e80", "teaX": "#276f6c",
    "corH": "#ffb19d", "corL": "#f07f6b", "corD": "#cc5f5c",
    "golH": "#ffe9a0", "golL": "#f8cd5d", "golD": "#d99b44",
    "uiL": "#fff7e8", "uiM": "#f6e6cc", "uiD": "#e5cfb1",
    "red": "#e8615f", "white": "#fffdf7",
    "skin": "#f2c7a5", "skinD": "#d49d86",
}
PAL = {k: tuple(int(v[i:i + 2], 16) for i in (1, 3, 5)) for k, v in HEX.items()}

FACADES = {
    "cre": ("creL", "creM", "creD", "creX"), "pea": ("peaL", "peaM", "peaD", "peaX"),
    "min": ("minL", "minM", "minD", "minX"), "sky": ("skyL", "skyM", "skyD", "skyX"),
    "ros": ("rosL", "rosM", "rosD", "rosX"), "but": ("butL", "butM", "butD", "butX"),
}

SUN_H = np.array([-0.6, -0.8])          # horizontal direction TO the sun (south-west)
SUN_ELEV = math.radians(37)


def h01(*parts):
    return int(hashlib.md5("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2 ** 32


def hv(*parts):  # vectorised-friendly integer hash for numpy arrays
    pass


def ihash(a, b, seed=0):
    """cheap integer hash on numpy int arrays -> [0,1)"""
    a = np.asarray(a, dtype=np.int64); b = np.asarray(b, dtype=np.int64)
    h = (a * 374761393 + b * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return (h & 0xFFFF) / 65536.0


def col(name):
    return PAL[name]


class Ctx:
    pass


class Scene:
    def __init__(self, W, H, S, SZ, wc, sc):
        self.W, self.H, self.S, self.SZ = W, H, S, SZ
        self.wcx, self.wcy = wc
        self.scx, self.scy = sc
        self.lit = np.zeros((H, W, 3), np.uint8)
        self.shd = np.zeros((H, W, 3), np.uint8)
        self.depth = np.full((H, W), -1e9)
        self.wx = np.zeros((H, W)); self.wy = np.zeros((H, W)); self.wz = np.zeros((H, W))
        self.recv = np.zeros((H, W), bool)        # receives cast shadows
        self.kind = np.zeros((H, W), np.int8)     # 0 bg, 1 ground, 2 object, 3 sprite
        self.oid = np.zeros((H, W), np.int32)
        self.blockers = []                        # (poly2d, zmin, zmax) for shadow heightmap
        self.disks = []                           # (cx, cy, r, zmin, zmax)
        self.D = np.array([1.0, -1.0, S / SZ])

    # ---- projection ---------------------------------------------------------------
    def proj(self, x, y, z=0.0):
        X = (x + y - (self.wcx + self.wcy)) * self.S + self.scx
        Y = (x - y - (self.wcx - self.wcy)) * self.S / 2 - z * self.SZ + self.scy
        return X, Y

    def unproj(self, X, Y):
        a = (X - self.scx) / self.S + (self.wcx + self.wcy)
        b = 2 * (Y - self.scy) / self.S + (self.wcx - self.wcy)
        return (a + b) / 2, (a - b) / 2

    def ipt(self, x, y, z=0.0):
        X, Y = self.proj(x, y, z)
        return int(math.floor(X + 0.5)), int(math.floor(Y + 0.5))

    # ---- writing ------------------------------------------------------------------
    def write(self, X, Y, depth, lit, shd, wx, wy, wz, recv, kind=2, oid=0):
        ok = (X >= 0) & (X < self.W) & (Y >= 0) & (Y < self.H)
        X, Y, depth = X[ok], Y[ok], depth[ok]
        lit, shd, wx, wy, wz = lit[ok], shd[ok], wx[ok], wy[ok], wz[ok]
        recv = recv[ok] if isinstance(recv, np.ndarray) else np.full(len(X), recv)
        # keep only the closest sample per pixel inside this batch
        o = np.argsort(depth, kind="stable")
        X, Y, depth = X[o], Y[o], depth[o]
        lit, shd, wx, wy, wz, recv = lit[o], shd[o], wx[o], wy[o], wz[o], recv[o]
        flat = Y * self.W + X
        _, idx = np.unique(flat[::-1], return_index=True)
        idx = len(flat) - 1 - idx
        X, Y, depth = X[idx], Y[idx], depth[idx]
        lit, shd, wx, wy, wz, recv = lit[idx], shd[idx], wx[idx], wy[idx], wz[idx], recv[idx]
        m = depth > self.depth[Y, X]
        X, Y = X[m], Y[m]
        self.depth[Y, X] = depth[m]
        self.lit[Y, X] = lit[m]; self.shd[Y, X] = shd[m]
        self.wx[Y, X] = wx[m]; self.wy[Y, X] = wy[m]; self.wz[Y, X] = wz[m]
        self.recv[Y, X] = recv[m]; self.kind[Y, X] = kind; self.oid[Y, X] = oid

    # ---- planar 3D polygon --------------------------------------------------------
    def face(self, verts, shader, bias=0.0, oid=0, **info):
        V = np.array(verts, float)
        n = np.zeros(3)
        for i in range(len(V)):
            a, b = V[i], V[(i + 1) % len(V)]
            n += np.array([(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])])
        ln = np.linalg.norm(n)
        if ln < 1e-9: return
        n /= ln
        # orient normal toward viewer
        if n @ self.D < 0: n = -n
        nd = n @ self.D
        if nd < 1e-6: return
        P = [self.proj(*v) for v in V]
        xs = [p[0] for p in P]; ys = [p[1] for p in P]
        x0, x1 = int(math.floor(min(xs))) - 1, int(math.ceil(max(xs))) + 1
        y0, y1 = int(math.floor(min(ys))) - 1, int(math.ceil(max(ys))) + 1
        if x1 < 0 or y1 < 0 or x0 >= self.W or y0 >= self.H: return
        w, h = x1 - x0 + 1, y1 - y0 + 1
        m = Image.new("L", (w, h), 0)
        ImageDraw.Draw(m).polygon([(px - x0 + 0.0, py - y0 + 0.0) for px, py in P], fill=1)
        M = np.array(m, bool)
        if not M.any(): return
        ly, lx = np.nonzero(M)
        X = lx + x0; Y = ly + y0
        gx, gy = self.unproj(X.astype(float), Y.astype(float))
        t = (n @ V[0] - (n[0] * gx + n[1] * gy)) / nd
        wx = gx + t; wy = gy - t; wz = t * self.S / self.SZ
        pad = np.pad(M, 2)
        c = Ctx()
        c.X, c.Y, c.x, c.y, c.z, c.n, c.V, c.P = X, Y, wx, wy, wz, n, V, P
        c.e_up = ~pad[ly + 1, lx + 2]; c.e_dn = ~pad[ly + 3, lx + 2]
        c.e_l = ~pad[ly + 2, lx + 1]; c.e_r = ~pad[ly + 2, lx + 3]
        c.e_up2 = ~pad[ly, lx + 2]; c.e_l2 = ~pad[ly + 2, lx]
        c.edge = c.e_up | c.e_dn | c.e_l | c.e_r
        c.info = info; c.scene = self
        # sun facing
        hn = n[:2]; hl = np.linalg.norm(hn)
        c.sun = float(hn @ SUN_H / hl) if hl > 1e-6 else 1.0
        c.vertical = abs(n[2]) < 0.05
        res = shader(c)
        if res is None: return
        lit, shd = res[0], res[1]
        recv = res[2] if len(res) > 2 else (c.sun > -0.2)
        keep = res[3] if len(res) > 3 else None
        if keep is not None:
            X, Y, wx, wy, wz, lit, shd = X[keep], Y[keep], wx[keep], wy[keep], wz[keep], lit[keep], shd[keep]
            if isinstance(recv, np.ndarray): recv = recv[keep]
        self.write(X, Y, wx - wy + bias, lit, shd, wx, wy, wz, recv, 2, oid)

    # ---- prism ----------------------------------------------------------------------
    def prism(self, poly, z0, z1, wall_shader, top_shader=None, oid=0, shadow=True, top_bias=0.02, **info):
        poly = [tuple(p) for p in poly]
        # make ccw in x,y
        a = sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]))
        if a < 0: poly = poly[::-1]
        for i, (A, B) in enumerate(zip(poly, poly[1:] + poly[:1])):
            dx, dy = B[0] - A[0], B[1] - A[1]
            nx, ny = dy, -dx                       # outward normal for ccw
            if nx - ny <= 1e-6: continue            # faces away from viewer
            if wall_shader is None: continue
            self.face([(A[0], A[1], z0), (B[0], B[1], z0), (B[0], B[1], z1), (A[0], A[1], z1)],
                      wall_shader, oid=oid, A=A, B=B, z0=z0, z1=z1, edge_i=i, **info)
        if top_shader is not None:
            self.face([(x, y, z1) for x, y in poly], top_shader, bias=top_bias, oid=oid, z0=z0, z1=z1, **info)
        if shadow:
            self.blockers.append((poly, z0, z1))

    def box(self, x0, y0, x1, y1, z0, z1, wall, top, **kw):
        self.prism([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], z0, z1, wall, top, **kw)

    # ---- sprites --------------------------------------------------------------------
    def sprite(self, rows, cmap, wx, wy, wz, ax, ay, bias=0.5, recv=True, oid=0, kind=3):
        """rows: list of strings. cmap: char -> (litname, shdname) or name. (ax,ay) sprite px = anchor."""
        AX, AY = self.ipt(wx, wy, wz)
        Xs, Ys, L, Sh = [], [], [], []
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch in ". ": continue
                v = cmap[ch]
                if isinstance(v, str): v = (v, v)
                Xs.append(AX + i - ax); Ys.append(AY + j - ay)
                L.append(PAL[v[0]]); Sh.append(PAL[v[1]])
        if not Xs: return
        X = np.array(Xs); Y = np.array(Ys)
        n = len(X)
        dep = np.full(n, wx - wy + bias)
        zz = wz + (AY - Y) / self.SZ
        self.write(X, Y, dep, np.array(L, np.uint8), np.array(Sh, np.uint8),
                   np.full(n, float(wx)), np.full(n, float(wy)), zz, recv, kind, oid)

    def pixels(self, pts, wx, wy, wz, bias=0.5, recv=True):
        """pts: list of (dx, dy, litname, shdname) relative to projected anchor"""
        AX, AY = self.ipt(wx, wy, wz)
        if not pts: return
        X = np.array([AX + p[0] for p in pts]); Y = np.array([AY + p[1] for p in pts])
        L = np.array([PAL[p[2]] for p in pts], np.uint8); Sh = np.array([PAL[p[3]] for p in pts], np.uint8)
        n = len(X)
        self.write(X, Y, np.full(n, wx - wy + bias), L, Sh, np.full(n, float(wx)), np.full(n, float(wy)),
                   wz + (AY - Y) / self.SZ, recv, 3)

    # ---- shadows --------------------------------------------------------------------
    def shadows(self, bounds, res=0.5, elevs=(37, 33), azim_off=(0, 4)):
        x0, y0, x1, y1 = bounds
        gw, gh = int((x1 - x0) / res) + 1, int((y1 - y0) / res) + 1
        hmin = np.full((gh, gw), 1e9); hmax = np.full((gh, gw), -1e9)
        for poly, za, zb in self.blockers:
            m = Image.new("L", (gw, gh), 0)
            ImageDraw.Draw(m).polygon([((x - x0) / res, (y - y0) / res) for x, y in poly], fill=1)
            M = np.array(m, bool)
            hmin[M] = np.minimum(hmin[M], za); hmax[M] = np.maximum(hmax[M], zb)
        for cx, cy, r, za, zb in self.disks:
            m = Image.new("L", (gw, gh), 0)
            ImageDraw.Draw(m).ellipse([(cx - r - x0) / res, (cy - r - y0) / res, (cx + r - x0) / res, (cy + r - y0) / res], fill=1)
            M = np.array(m, bool)
            hmin[M] = np.minimum(hmin[M], za); hmax[M] = np.maximum(hmax[M], zb)
        R = self.recv & (self.kind > 0)
        ys, xs = np.nonzero(R)
        px, py, pz = self.wx[ys, xs], self.wy[ys, xs], self.wz[ys, xs]
        counts = np.zeros(len(xs), np.int8)
        for el, az in zip(elevs, azim_off):
            e = math.radians(el)
            a = math.atan2(SUN_H[1], SUN_H[0]) + math.radians(az)
            L = np.array([math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)])
            step = 0.45
            hit = np.zeros(len(xs), bool)
            k = 1
            maxz = max([b[2] for b in self.blockers] + [d[4] for d in self.disks] + [1])
            while True:
                d = step * k
                qx = px + L[0] * d; qy = py + L[1] * d; qz = pz + L[2] * d + 0.05
                act = ~hit & (qz <= maxz)
                if not act.any(): break
                gi = ((qx - x0) / res).astype(int); gj = ((qy - y0) / res).astype(int)
                inb = act & (gi >= 0) & (gi < gw) & (gj >= 0) & (gj < gh)
                gi2 = np.clip(gi, 0, gw - 1); gj2 = np.clip(gj, 0, gh - 1)
                hit |= inb & (hmin[gj2, gi2] <= qz) & (hmax[gj2, gi2] >= qz)
                k += 1
            counts += hit
        self.shadow_count = np.zeros((self.H, self.W), np.int8)
        self.shadow_count[ys, xs] = counts

    def compose(self, dither=True):
        out = self.lit.copy()
        sc = getattr(self, "shadow_count", np.zeros((self.H, self.W), np.int8))
        yy, xx = np.mgrid[0:self.H, 0:self.W]
        full = sc >= 2
        half = (sc == 1) & (((xx + yy) % 2) == 0) if dither else (sc == 1)
        m = full | half
        out[m] = self.shd[m]
        return out


# ------------------------------------------------------------------ pixel fonts -----
F35 = {
    "A": [".#.", "#.#", "###", "#.#", "#.#"], "B": ["##.", "#.#", "##.", "#.#", "##."],
    "C": [".##", "#..", "#..", "#..", ".##"], "D": ["##.", "#.#", "#.#", "#.#", "##."],
    "E": ["###", "#..", "##.", "#..", "###"], "F": ["###", "#..", "##.", "#..", "#.."],
    "G": [".##", "#..", "#.#", "#.#", ".##"], "H": ["#.#", "#.#", "###", "#.#", "#.#"],
    "I": ["###", ".#.", ".#.", ".#.", "###"], "J": ["..#", "..#", "..#", "#.#", ".#."],
    "K": ["#.#", "#.#", "##.", "#.#", "#.#"], "L": ["#..", "#..", "#..", "#..", "###"],
    "M": ["#.#", "###", "###", "#.#", "#.#"], "N": ["##.", "#.#", "#.#", "#.#", "#.#"],
    "O": [".#.", "#.#", "#.#", "#.#", ".#."], "P": ["##.", "#.#", "##.", "#..", "#.."],
    "Q": [".#.", "#.#", "#.#", "##.", ".##"], "R": ["##.", "#.#", "##.", "#.#", "#.#"],
    "S": [".##", "#..", ".#.", "..#", "##."], "T": ["###", ".#.", ".#.", ".#.", ".#."],
    "U": ["#.#", "#.#", "#.#", "#.#", "###"], "V": ["#.#", "#.#", "#.#", "#.#", ".#."],
    "W": ["#.#", "#.#", "###", "###", "#.#"], "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["###", "..#", ".#.", "#..", "###"],
    "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
    "2": ["##.", "..#", ".#.", "#..", "###"], "3": ["##.", "..#", ".#.", "..#", "##."],
    "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "##.", "..#", "##."],
    "6": [".##", "#..", "###", "#.#", "###"], "7": ["###", "..#", ".#.", ".#.", ".#."],
    "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "##."],
    ".": [".", ".", ".", ".", "#"], ",": ["..", "..", "..", ".#", "#."],
    "+": ["...", ".#.", "###", ".#.", "..."], "-": ["...", "...", "###", "...", "..."],
    "/": ["..#", "..#", ".#.", "#..", "#.."], "%": ["#.#", "..#", ".#.", "#..", "#.#"],
    ":": [".", "#", ".", "#", "."], " ": ["..", "..", "..", "..", ".."],
    "€": [".##", "#..", "###", "#..", ".##"], "'": ["#", "#", ".", ".", "."],
    "©": [".####.", "#.##.#", "#.#..#", "#.##.#", ".####."],
    "x": ["...", "#.#", ".#.", "#.#", "..."],
}
F57 = {
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    ".": ["..", "..", "..", "..", "..", "##", "##"],
    "€": ["..###", ".#...", "####.", ".#...", "####.", ".#...", "..###"],
    " ": ["...", "...", "...", "...", "...", "...", "..."],
}


def text_width(s, font=F35, gap=1):
    return sum(len(font.get(ch, font[" "])[0]) + gap for ch in s) - gap


def draw_text(img_arr, s, x, y, color, font=F35, gap=1, shadow=None):
    """draw into an HxWx3 numpy array"""
    H, W = img_arr.shape[:2]
    cx = x
    for ch in s:
        g = font.get(ch, font.get(ch.upper(), font[" "]))
        for j, row in enumerate(g):
            for i, c in enumerate(row):
                if c == "#":
                    if shadow is not None and 0 <= y + j + 1 < H and 0 <= cx + i < W:
                        img_arr[y + j + 1, cx + i] = shadow
        for j, row in enumerate(g):
            for i, c in enumerate(row):
                if c == "#" and 0 <= y + j < H and 0 <= cx + i < W:
                    img_arr[y + j, cx + i] = color
        cx += len(g[0]) + gap
    return cx
