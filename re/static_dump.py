#!/usr/bin/env python3
# static_dump.py — 离线抽取脱壳 Mach-O 里的 Obj-C 类名 + selector（Android dex 扫字符串的等价）
#
# 用法:
#   1) 从脱壳 IPA 取二进制:  unzip -o App.ipa "Payload/*.app/*" -d /tmp/app
#      二进制通常是 /tmp/app/Payload/xxx.app/xxx （用 file 确认是 Mach-O executable）
#   2) python3 re/static_dump.py /tmp/app/Payload/xxx.app/xxx
#
# 输出: 每个命中的广告类 + 它"自身"的广告方法 selector（等价 frida dump_classes.js），
#       另附全部广告类名候选 + 全部广告 selector 候选（便于手配 Class+selector）。
#
# 纯标准库，无外部依赖。覆盖: FAT(arm64/arm64e) 切片选择、__objc_classlist /
# __objc_methname / __objc_classname 解析、class_ro_t 取类名、method_list_t
# （含 relative method list 标志）取 selector。任意单类解析失败不影响整体。

import sys, struct

TOKENS = [
    "Splash", "Banner", "Ad", "AD", "GDT", "CSJ", "Pangle", "KSAd", "BUAd", "BUN",
    "Meridian", "GroMore", "AnyThink", "ATAd", "Sigmob", "Beizi", "Octopus",
    "Qumeng", "Meishu", "UnityAds", "AdColony", "Chartboost", "Vungle", "InMobi",
    "TencentAd", "WXAd", "BaiduAd", "Reward", "Interstitial", "Feed", "Native",
]

def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]

def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]

def cstr(b, o):
    if o < 0 or o >= len(b):
        return None
    end = b.find(b'\x00', o)
    if end < 0:
        return None
    try:
        return b[o:end].decode('utf-8', 'replace')
    except Exception:
        return None

class Slice:
    def __init__(self, data, base):
        self.data = data
        self.base = base          # file offset of this Mach-O slice
        self.seg_vm = []          # (vmaddr, vmsize, fileoff)
        self.sections = {}        # sectname -> (addr_vm, offset, size)
        self._parse()

    def _parse(self):
        d = self.data
        o = self.base
        magic = u32(d, o)
        if magic == 0xFEEDFACF:    # MH_MAGIC_64
            pass
        elif magic == 0xCFFAEDFE:  # byte-swapped (罕见)
            raise ValueError("byte-swapped Mach-O not supported")
        else:
            raise ValueError("not a 64-bit Mach-O at base %d (magic=%#x)" % (o, magic))
        ncmds = u32(d, o + 16)
        off = o + 32
        for _ in range(ncmds):
            cmd = u32(d, off)
            cmdsize = u32(d, off + 4)
            if cmd == 0x19:  # LC_SEGMENT_64
                vmaddr = u64(d, off + 0x18)
                vmsize = u64(d, off + 0x20)
                fileoff = u64(d, off + 0x28)
                filesize = u64(d, off + 0x30)
                self.seg_vm.append((vmaddr, vmsize, fileoff))
                nsects = u32(d, off + 0x40)
                sec = off + 72
                for i in range(nsects):
                    sname = d[sec:sec + 16].split(b'\x00')[0].decode('utf-8', 'replace')
                    # section_64: sectname@0(16) segname@16(16) addr@32(8) size@40(8) offset@48(8)
                    saddr = u64(d, sec + 32)
                    ssize = u64(d, sec + 40)
                    soff = u64(d, sec + 48)
                    self.sections[sname] = (saddr, soff, ssize)
                    sec += 80
            off += cmdsize

    def v2o(self, va):
        for vmaddr, vmsize, fileoff in self.seg_vm:
            if vmaddr <= va < vmaddr + vmsize:
                return fileoff + (va - vmaddr)
        return None

    def o2v(self, fo):
        for vmaddr, vmsize, fileoff in self.seg_vm:
            if fileoff <= fo < fileoff + vmsize:
                return vmaddr + (fo - fileoff)
        return None

    def read(self, va, n):
        fo = self.v2o(va)
        if fo is None or fo + n > len(self.data):
            return None
        return self.data[fo:fo + n]

    def cstr_vm(self, va):
        fo = self.v2o(va)
        if fo is None:
            return None
        return cstr(self.data, fo)

def pick_arm64_slice(data):
    # 处理 FAT。返回 (base_offset)，若是 thin 直接返回 0。
    if len(data) < 4:
        raise ValueError("file too small")
    magic = u32(data, 0)
    if magic == 0xFEEDFACF:
        return 0
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        # FAT (32 or 64). 选 arm64/arm64e 切片。
        is64 = (magic == 0xCAFEBABF)
        nfat = u32(data, 4)
        p = 8
        best = None
        for _ in range(nfat):
            if is64:
                cputype = u32(data, p)
                cpusub = u32(data, p + 4)
                off = u64(data, p + 8)
                size = u64(data, p + 16)
                p += 32
            else:
                cputype = u32(data, p)
                cpusub = u32(data, p + 4)
                off = u32(data, p + 8)
                size = u32(data, p + 12)
                p += 20
            # CPU_TYPE_ARM64 = 0x0100000C ; CPU_SUBTYPE_ARM64E = 0x02
            if cputype == 0x0100000C:
                score = 2 if (cpusub & 0x00FFFFFF) == 0x02 else 1
                if best is None or score > best[0]:
                    best = (score, off)
        if best is None:
            raise ValueError("no arm64 slice in FAT")
        return best[1]
    raise ValueError("unknown magic %#x" % magic)

def parse_methods(slc, ml_vm):
    """返回该类自身方法的 selector 字符串列表。"""
    out = []
    ml_off = slc.v2o(ml_vm)
    if ml_off is None:
        return out
    eaf = u32(slc.data, ml_off)          # entsize (low16) | flags (high16)
    count = u32(slc.data, ml_off + 4)
    entsize = eaf & 0xFFFF
    is_relative = bool(eaf & 0x80000000)
    if entsize not in (12, 24) or count <= 0 or count > 100000:
        return out
    cur = ml_off + 8
    for _ in range(count):
        if is_relative:
            # 每个 method_t = 12 字节: name_rel, types_rel, imp_rel (有符号相对偏移)
            name_rel = struct.unpack_from('<i', slc.data, cur)[0]
            field_vm = slc.o2v(cur)       # 该 name 字段的 VM 地址
            if field_vm is not None:
                sel_vm = field_vm + name_rel
                s = slc.cstr_vm(sel_vm)
                if s:
                    out.append(s)
            cur += 12
        else:
            name_ptr = u64(slc.data, cur)
            s = slc.cstr_vm(name_ptr)
            if s:
                out.append(s)
            cur += 24
    return out

def ad_match(name):
    if not name or len(name) < 3:
        return False
    if name.startswith(("UI", "NS", "CA", "WK", "_")):
        return False
    return any(t in name for t in TOKENS)

def main():
    if len(sys.argv) < 2:
        print("usage: static_dump.py <decrypted-mach-o-binary>")
        sys.exit(2)
    path = sys.argv[1]
    with open(path, 'rb') as f:
        data = f.read()
    base = pick_arm64_slice(data)
    slc = Slice(data, base)

    # 全量候选（来自 __objc_classname / __objc_methname 字符串池）
    cls_names = set()
    sec = slc.sections.get('__objc_classname')
    if sec:
        a, o, sz = sec
        pool = data[o:o + sz]
        for s in pool.split(b'\x00'):
            try:
                nm = s.decode('utf-8', 'replace')
            except Exception:
                continue
            if ad_match(nm):
                cls_names.add(nm)

    sel_names = set()
    sec = slc.sections.get('__objc_methname')
    if sec:
        a, o, sz = sec
        pool = data[o:o + sz]
        for s in pool.split(b'\x00'):
            try:
                nm = s.decode('utf-8', 'replace')
            except Exception:
                continue
            low = nm.lower()
            if any(k in low for k in ('ad', 'splash', 'banner', 'load', 'show', 'present', 'request', 'fetch', 'render', 'display')):
                sel_names.add(nm)

    # 逐类关联自身方法（等价 frida $ownMethods）
    classlist = slc.sections.get('__objc_classlist')
    paired = []
    if classlist:
        a, o, sz = classlist
        n = sz // 8
        for i in range(n):
            ptr = u64(data, o + i * 8)
            try:
                # class_t: isa(8) superclass(8) cache(16) bits(8) -> bits @0x20
                bits = u64(data, slc.v2o(ptr) + 0x20)
                ro = bits & 0x7FFFFFFFF8
                ro_off = slc.v2o(ro)
                if ro_off is None:
                    continue
                name_ptr = u64(data, ro_off + 24)
                cls_name = slc.cstr_vm(name_ptr)
                if not cls_name or not ad_match(cls_name):
                    continue
                base_methods = u64(data, ro_off + 32)
                meths = []
                if base_methods:
                    for m in parse_methods(slc, base_methods):
                        if any(k in m.lower() for k in ('ad', 'splash', 'banner', 'load', 'show', 'present', 'request', 'fetch', 'render', 'display')):
                            meths.append(m)
                if meths:
                    paired.append((cls_name, meths))
            except Exception:
                continue

    print("=== 广告类 + 自身广告方法（填 installTargetedHooks 用：@[类名, selector]）===")
    for cls_name, meths in sorted(paired):
        print("== " + cls_name)
        for m in sorted(set(meths)):
            print("   - " + m)

    print("\n=== 广告类名候选（来自 __objc_classname，按 token 命中）===")
    for nm in sorted(cls_names):
        print("   # " + nm)

    print("\n=== 广告 selector 候选（来自 __objc_methname，按 token 命中）===")
    for nm in sorted(sel_names):
        print("   @ " + nm)

    print("\nSTAT: paired_classes=%d class_candidates=%d selector_candidates=%d" %
          (len(paired), len(cls_names), len(sel_names)))

if __name__ == '__main__':
    main()
