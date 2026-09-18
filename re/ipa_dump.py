#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipa_dump.py — 从砸壳 IPA 离线提取 Objective-C 类名 / 方法名
=========================================================================
把 Android Xposed 模块（如 MapAdKiller）复刻到 iOS 时，离线路拿到
"广告类 + selector"，直接填进 Tweak.xm 的 installTargetedHooks()。

  * 只读 Mach-O 里真正需要的几段进内存，不解压整个 App
  * 纯标准库，Windows / macOS / Linux 直接跑，不需要 class-dump / Hopper / Frida
  * 自动检查 cryptid，没砸壳会直接告诉你
  * 可选扫 Frameworks/ 里的动态库（广告 SDK 常藏在这）
  * --objc 输出可直接粘贴的 NSArray 字面量

用法：
    python ipa_dump.py 高德地图_15.03.0.ipa
    python ipa_dump.py xxx.ipa --frameworks
    python ipa_dump.py xxx.ipa --out result.txt
    python ipa_dump.py xxx.ipa --objc
"""

import argparse
import io
import os
import plistlib
import re
import struct
import sys
import zipfile

# ==========================================================================
# 广告识别规则
# ==========================================================================

# ---------------------------------------------------------------------------
# 关键教训：绝不能用裸子串匹配 "Ad"
#   AMapAdapter...  ->  Ada|pter       命中的其实是 "ad"，但它是 Adapter
#   DownloadManager ->  Downlo|adManager 命中的其实是 "adManager"
#   NXIRDownloadManager / ACMUploadManager 同理全部误伤
# 所以：按驼峰拆成独立词段后做"整段匹配"。
# ---------------------------------------------------------------------------
RX_CAMEL = re.compile(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+")


def camel_segs(name):
    """AMapAdapterNaviOverlay -> ['A','Map','Adapter','Navi','Overlay']"""
    return RX_CAMEL.findall(name)


# 单驼峰段里含这些词根 ⇒ 广告（用于 DownloadManager 里那种粘连段不好用，
# 这里是"某一段本身就是厂商名/词根"的场景）
VENDOR_STEMS = [
    "gdt", "csj", "pangle", "buad", "ksad", "meridian", "gromore", "anythink",
    "sigmob", "beizi", "mintegral", "inmobi", "vungle", "unityads", "applovin",
    "ironsource", "admob", "mopub", "tanx", "omsdk", "pubnative", "suyi",
    "taku", "adscope", "klevin", "advertis", "interstitial", "rewardvideo",
]

# 独立驼峰段完全等于这些 ⇒ 广告
CAMEL_TOKENS = {
    "ad", "ads", "advert", "splash", "banner", "interstitial", "reward",
    "promo", "popup", "popupad", "nativead", "adview", "adslot", "adkit",
    "admanager", "adloader", "addata", "admodel", "adconfig", "adservice",
    "adrequest", "adresponse", "adsdk", "adx", "adunion", "adprovider",
    "adbanner", "adsplash", "adz", "adresource", "admaterial", "adtrack",
}

# 全大写段结尾：WINAD -> AD
UPPER_SUFFIXES = ("AD", "ADS", "SPLASH", "BANNER", "POP", "PROMO")

# 弱命中（只提示，需人工确认）
WEAK_CAMEL_TOKENS = {
    "feed", "slot", "material", "exposure", "float", "notice", "guide",
    "launch", "promote", "recommend", "operate",
}

SYS_PREFIX_RE = re.compile(
    r"^(UI|NS|CA|CG|WK|MK|CL|AV|CT|CF|SFS|SK|PH|LA|QL|SL|RP|CM|AS|RS|AF|AU|"
    r"MTL|IO|OS|SE|NM|GLK|SCN|AR|MA|AK|MP|MS|UP|NFI|AB|AE|AL|CB|CN|EA|EK|"
    r"FI|FM|GC|GK|HK|HM|IC|ID|LC|ML|NE|PK|PL|SC|SF|SH|SS|SV|TL|TV|UT|WC|AV)"
)


def is_ad_class(name):
    """类名是否命中广告特征。命中返回命中的 token，否则 None。"""
    if not name or len(name) < 4:
        return None
    name = name.lstrip("_")
    if SYS_PREFIX_RE.match(name):
        return None
    segs = camel_segs(name)
    if not segs:
        return None

    # 1) 独立驼峰段 == 广告词
    for s in segs:
        low = s.lower()
        if low in CAMEL_TOKENS:
            return low
    # 2) 某段本身就是厂商名 / 词根
    for s in segs:
        low = s.lower()
        for v in VENDOR_STEMS:
            if low == v or (low.startswith(v) and len(low) - len(v) <= 6):
                return v
    # 3) 全大写粘连段收尾：WINAD -> AD
    for s in segs:
        if s.isupper() and len(s) > 2:
            for suf in UPPER_SUFFIXES:
                if s.endswith(suf) and len(s) > len(suf):
                    return "UP:" + suf
    return None


def is_ad_selector(sel):
    """selector 是否像广告入口（同样按驼峰段匹配，避免 load/read 里的 ad）。"""
    if not sel or sel.startswith("."):
        return False
    base = sel.split(":")[0]
    segs = camel_segs(base)
    if not segs:
        return False
    for s in segs:
        low = s.lower()
        if low in CAMEL_TOKENS:
            return True
        for v in VENDOR_STEMS:
            if low == v or (low.startswith(v) and len(low) - len(v) <= 6):
                return True
    return False


def weak_tokens_of(name):
    segs = camel_segs(name.lstrip("_"))
    return [s for s in segs if s.lower() in WEAK_CAMEL_TOKENS]


# ==========================================================================
# Mach-O
# ==========================================================================

MH64 = 0xFEEDFACF
FAT_BE = 0xCAFEBABE
FAT64_BE = 0xCAFEBABF
CPU_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_ENCRYPTION_INFO_64 = 0x2C
FAST_DATA_MASK = 0x00007FFFFFFFFFF8

MAX_BLOCK = 96 * 1024 * 1024
MERGE_GAP = 2 * 1024 * 1024


class MemMap(object):
    """若干不相交的内存块，按 Mach-O 文件偏移随机读。"""

    def __init__(self):
        self.blocks = []

    def add(self, start, data):
        self.blocks.append((start, data))

    def read(self, off, n):
        if off is None or off < 0:
            return None
        for start, data in self.blocks:
            rel = off - start
            if 0 <= rel and rel + n <= len(data):
                return data[rel:rel + n]
        return None

    def total(self):
        return sum(len(d) for _, d in self.blocks)


class MachO(object):
    def __init__(self, mm, label=""):
        self.mm = mm
        self.label = label
        self.segs = []
        self.secs = {}
        self.cryptid = None
        self.cryptoff = 0
        self.cryptsize = 0
        self.cputype = 0
        self.cpusub = 0
        self._parse_header()

    def _u32(self, off):
        b = self.mm.read(off, 4)
        return struct.unpack("<I", b)[0] if b else 0

    def _u64(self, off):
        b = self.mm.read(off, 8)
        return struct.unpack("<Q", b)[0] if b else 0

    def _parse_header(self):
        raw = self.mm.read(0, 32)
        if not raw or len(raw) < 32:
            raise ValueError("读不到 Mach-O header")
        if struct.unpack(">I", raw[:4])[0] in (FAT_BE, FAT64_BE):
            raise ValueError("FAT binary，请先 thin 到单个 arch")
        if struct.unpack("<I", raw[:4])[0] != MH64:
            raise ValueError("非 Mach-O 64 位格式")
        self.cputype = self._u32(4)
        self.cpusub = self._u32(8)
        self.filetype = self._u32(12)
        ncmds = self._u32(16)
        sizeocmds = self._u32(20)

        off = 32
        end = 32 + sizeocmds
        while off + 8 <= end:
            cmd = self._u32(off)
            cs = self._u32(off + 4)
            if cs == 0 or cs > sizeocmds:
                break
            if cmd == LC_ENCRYPTION_INFO_64:
                b = self.mm.read(off + 8, 12)
                if b and len(b) == 12:
                    self.cryptoff, self.cryptsize, self.cryptid = struct.unpack("<3I", b)
            elif cmd == LC_SEGMENT_64:
                raw = self.mm.read(off, min(cs, 8192))
                if raw is None:
                    break
                segname = raw[8:24].rstrip(b"\0").decode("utf8", "replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<4Q", raw[24:56])
                nsects = struct.unpack("<I", raw[64:68])[0]
                self.segs.append((segname, vmaddr, vmsize, fileoff, filesize))
                so = off + 72
                for _ in range(nsects):
                    sraw = self.mm.read(so, 68)
                    if sraw is None or len(sraw) < 68:
                        break
                    sn = sraw[:16].rstrip(b"\0").decode("utf8", "replace")
                    sgn = sraw[16:32].rstrip(b"\0").decode("utf8", "replace")
                    addr, size = struct.unpack("<2Q", sraw[32:48])
                    soff = struct.unpack("<I", sraw[48:52])[0]
                    self.secs.setdefault(sn, []).append((sgn, addr, size, soff))
                    so += 80
            off += cs

    # -- 地址转换 --
    def v2o(self, vm):
        if not vm:
            return None
        for (nm, vmaddr, vmsize, fileoff, filesize) in self.segs:
            if nm == "__PAGEZERO":
                continue
            if vmaddr <= vm < vmaddr + max(vmsize, 1):
                return vm - vmaddr + fileoff
        return None

    def cstr(self, off, limit=200):
        if off is None:
            return ""
        b = self.mm.read(off, limit)
        if not b:
            return ""
        i = b.find(b"\0")
        if i >= 0:
            b = b[:i]
        try:
            return b.decode("utf-8", "replace")
        except Exception:
            return ""

    def cstr_vm(self, vm, limit=200):
        o = self.v2o(vm) if vm else None
        return self.cstr(o, limit)

    def u64vm(self, vm):
        o = self.v2o(vm) if vm else None
        b = self.mm.read(o, 8) if o is not None else None
        return struct.unpack("<Q", b)[0] if b and len(b) == 8 else 0

    def sec(self, name):
        v = self.secs.get(name)
        return v[0] if v else None

    # -- ObjC --
    def scan_classes(self):
        s = self.sec("__objc_classlist")
        if not s:
            return []
        _, addr, size, _ = s
        mn = self.sec("__objc_methname")
        lo, hi = (mn[1], mn[1] + mn[2]) if mn else (0, 0)

        out = []
        for i in range(size // 8):
            cvm = self.u64vm(addr + i * 8)
            if not cvm:
                continue
            cfo = self.v2o(cvm)
            if cfo is None:
                continue
            bits = self._u64(cfo + 32)
            rofo = self.v2o(bits & FAST_DATA_MASK) if bits else None
            if not rofo:
                continue
            ro = self.mm.read(rofo, 48)
            if not ro or len(ro) < 48:
                continue
            namep = struct.unpack_from("<Q", ro, 24)[0]
            methp = struct.unpack_from("<Q", ro, 32)[0]
            cname = self.cstr_vm(namep)
            if not cname:
                continue
            out.append((cname, self._methods(methp, lo, hi)))
        return out

    def _methods(self, methp, meth_lo, meth_hi):
        res = []
        if not methp:
            return res
        mfo = self.v2o(methp)
        if mfo is None:
            return res
        head = self.mm.read(mfo, 8)
        if not head or len(head) < 8:
            return res
        eaf, cnt = struct.unpack("<2I", head)
        entsize = eaf & 0x0000FFFC
        relative = bool(eaf & 0x80000000)
        if cnt == 0 or cnt > 65535 or entsize not in (12, 24):
            return res
        for i in range(cnt):
            eo = mfo + 8 + i * entsize
            ent = self.mm.read(eo, entsize)
            if not ent or len(ent) < entsize:
                break
            if relative or entsize == 12:
                rel = struct.unpack_from("<i", ent, 0)[0]
                s = self.cstr_vm(methp + 8 + i * entsize + rel)
            else:
                nameptr = struct.unpack_from("<Q", ent, 0)[0]
                if not (meth_lo <= nameptr < meth_hi):
                    continue
                s = self.cstr_vm(nameptr)
            if s and not s.startswith("_"):
                res.append(s)
        return res


# ==========================================================================
# IPA 装载
# ==========================================================================

TEXT_SECS = ["__objc_classname", "__objc_methname", "__objc_methtype"]
DATA_SECS = ["__objc_classlist", "__objc_const", "__objc_data",
             "__objc_superrefs", "__objc_catlist", "__objc_protolist"]
HDR_LEN = 0x80000


def _merge(intervals, gap=MERGE_GAP):
    if not intervals:
        return []
    intervals = sorted(intervals)
    out = [list(intervals[0])]
    for s, e in intervals[1:]:
        if s <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def thin_slice(f):
    """FAT → 挑 arm64e > arm64。返回 (切片绝对偏移, size)。"""
    f.seek(0)
    head = f.read(4096)
    if len(head) < 8:
        return 0, None
    if struct.unpack(">I", head[:4])[0] not in (FAT_BE, FAT64_BE):
        f.seek(0)
        return 0, None
    nfat = struct.unpack(">I", head[4:8])[0]
    base, best = 8, None
    for _ in range(nfat):
        if base + 20 > len(head):
            break
        ct, cs, off, size, align = struct.unpack(">5I", head[base:base + 20])
        base += 20
        if ct != CPU_ARM64:
            continue
        sub = cs & 0xFF
        score = 2 if sub == 2 else (1 if sub == 0 else 0)
        if best is None or score > best[0]:
            best = (score, off, size)
    if not best:
        return 0, None
    f.seek(best[1])
    return best[1], best[2]


def load_binary(z, entry):
    """返回 (MachO|None, info|reason)。"""
    try:
        raw = z.open(entry)
    except KeyError:
        return None, "zip 条目不存在"

    slice_off, slice_size = thin_slice(raw)

    hdr = raw.read(min(HDR_LEN, slice_size or (1 << 30)))
    if len(hdr) < 64:
        return None, "header 过短"
    mm0 = MemMap()
    mm0.add(0, hdr)
    try:
        probe = MachO(mm0)
    except ValueError as e:
        return None, str(e)
    if "__objc_classlist" not in probe.secs:
        return None, "无 __objc_classlist（非 ObjC 二进制）"

    # 需要加载的区间
    need = []
    for name in TEXT_SECS + DATA_SECS:
        s = probe.secs.get(name)
        if s:
            _, _addr, size, soff = s[0]
            need.append((soff, soff + size))
    # __DATA 段的实际文件内容（method list / class ro 都在这）
    for (nm, vmaddr, vmsize, fileoff, filesize) in probe.segs:
        if nm in ("__DATA", "__DATA_CONST") and filesize:
            need.append((fileoff, fileoff + filesize))
    blocks = _merge(need)

    mm = MemMap()
    mm.add(0, hdr)
    loaded = 0
    for s, e in blocks:
        # 已被 hdr 覆盖的部分不用重复读
        st = max(s, HDR_LEN)
        if e <= HDR_LEN or st >= e:
            continue
        length = min(e - st, MAX_BLOCK)
        try:
            raw.seek(slice_off + st)
            data = raw.read(length)
        except Exception:
            continue
        if data:
            mm.add(st, data)
            loaded += len(data)

    mo = MachO(mm)
    mo.loaded = loaded
    return mo, dict(bits=mm, probe=probe)


def read_info(z, appdir):
    try:
        raw = z.read(appdir + "Info.plist")
    except Exception:
        return {}
    try:
        return plistlib.loads(raw)
    except Exception:
        return {}


def pick_targets(z, want_frameworks):
    names = z.namelist()
    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and n.count("/") >= 1})
    out = []
    for app in apps:
        appdir = "Payload/%s/" % app
        info = read_info(z, appdir)
        exe = info.get("CFBundleExecutable")
        out.append((appdir + exe if exe else None, appdir, info, "main"))
        if want_frameworks:
            fw = set()
            for n in names:
                if not n.startswith(appdir + "Frameworks/"):
                    continue
                rest = n[len(appdir + "Frameworks/"):]
                if ".framework/" in rest:
                    fw.add(appdir + "Frameworks/" + rest.split("/")[0] + "/" + rest.split("/")[0])
                elif rest.endswith(".dylib"):
                    fw.add(appdir + "Frameworks/" + rest)
            for f in sorted(fw):
                out.append((f, None, {}, "framework"))
    return out


def bundle_of(info):
    return info.get("CFBundleIdentifier", "?")


def main():
    ap = argparse.ArgumentParser(description="从砸壳 IPA 离线 dump Objective-C 广告类/方法")
    ap.add_argument("ipa")
    ap.add_argument("--frameworks", action="store_true", help="连 Frameworks 里的动态库一起扫")
    ap.add_argument("--all-classes", action="store_true", help="列出全部类名")
    ap.add_argument("--out", help="结果写文件")
    ap.add_argument("--objc", action="store_true", help="输出可直接粘贴的 NSArray 字面量")
    ap.add_argument("--limit", type=int, default=60, help="每个二进制最多展示多少命中类")
    args = ap.parse_args()

    if not os.path.exists(args.ipa):
        print("文件不存在:", args.ipa)
        return 1

    z = zipfile.ZipFile(args.ipa)
    buf = io.StringIO()

    def w(*a):
        s = " ".join(str(x) for x in a)
        print(s)
        buf.write(s + "\n")

    all_pairs = []          # [(bundle, [(class, [sel])])]
    targets = pick_targets(z, args.frameworks)

    for entry, appdir, info, kind in targets:
        if not entry:
            continue
        mo, extra = load_binary(z, entry)
        if mo is None:
            w("[SKIP] %-55s  %s" % (os.path.basename(entry), extra))
            continue

        bundle = bundle_of(info)
        if kind == "framework":
            bundle = bundle or os.path.basename(entry)

        w("")
        w("=" * 78)
        w("[%s] %s" % (kind, entry))
        w("=" * 78)
        arch = "arm64e" if (mo.cpusub & 0xFF) == 2 else "arm64"
        crypt = mo.cryptid
        cryptstr = {0: "cryptid=0 已砸壳 OK", None: "无加密命令（未加密）"}.get(
            crypt, "cryptid=%s 仍加密，静态解析不可靠" % crypt)
        w("  架构=%s  filetype=%d  加载数据=%.1fMB  %s" % (
            arch, mo.filetype, getattr(mo, "loaded", 0) / 1048576.0, cryptstr))
        if bundle and bundle != "?":
            w("  BundleID=%s  Version=%s" % (
                bundle, info.get("CFBundleShortVersionString", "?")))

        try:
            classes = mo.scan_classes()
        except Exception as e:
            w("  解析失败: %r" % (e,))
            continue

        w("  ObjC 类总数: %d" % len(classes))

        if args.all_classes:
            for nm, _ in classes:
                w("    ", nm)
            continue

        primary, secondary = [], []
        for nm, meths in classes:
            tok = is_ad_class(nm)
            if not tok:
                continue
            sels = sorted(set(m for m in meths if is_ad_selector(m)))
            (primary if sels else secondary).append((nm, sels, tok))

        primary.sort()
        secondary.sort()

        w("  命中(类+广告方法): %d      命中类但无广告方法: %d"
          % (len(primary), len(secondary)))

        w("  --- 可直接用于 installTargetedHooks 的类+方法 ---")
        for nm, sels, tok in primary[:args.limit]:
            w("    %-50s # token=%s" % (nm, tok))
            for s in sels[:16]:
                w("         %s" % s)
        if len(primary) > args.limit:
            w("    ... 另有 %d 个类未展示（--limit 调整）" % (len(primary) - args.limit))

        if secondary:
            w("  --- 只有类命中、未见广告方法（建议挂 viewDidAppear: 兜底）---")
            for nm, _, tok in secondary[:25]:
                w("    %-50s # token=%s" % (nm, tok))

        weak = sorted({nm for nm, _ in classes
                       if not is_ad_class(nm) and weak_tokens_of(nm)})
        if weak:
            w("  --- 弱命中类名（人工确认后补进 CLASS_TOKENS）---")
            for nm in weak[:30]:
                w("    ", nm)

        all_pairs.append((bundle, primary, secondary))

    if args.objc and all_pairs:
        w("")
        w("=" * 78)
        w("可直接粘贴进 Tweak.xm 的 installTargetedHooks()")
        w("=" * 78)
        for bundle, primary, secondary in all_pairs:
            if not primary and not secondary:
                continue
            w("")
            w("// bundleID = %s" % bundle)
            w("hooks = @[")
            for nm, sels, _tok in primary:
                for s in sels[:6]:
                    w('    @[@"%s", @"%s"],' % (nm, s))
            for nm, _s, _tok in secondary[:20]:
                w('    @[@"%s", @"viewDidAppear:"],' % nm)
            w("];")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fp:
            fp.write(buf.getvalue())
        print("\n结果已写入: %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
