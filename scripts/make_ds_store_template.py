#!/usr/bin/env python3
"""把「Finder 布局成功」的 .DS_Store 转成可长期复用的仓库模板。

★ 核心约束（血泪教训，别改）：**不许重建容器**。

用 ds_store 库读出记录再写回，产出的文件体积会从 10,244 涨到 16,388、头部
`0000 100c` 之后被塞进库写死的常量、块分配被打散 —— Finder 会**整份忽略**，
表现为「双击 DMG 后 iconSize / 窗口 / 坐标 / 背景图 全部不生效，就是默认排版」。
（2026-11-25 实测：这就是模板方案第一次失败的真正原因。）

唯一安全的做法是：**拷贝 Finder 原件，只做等长 bytes.replace()**，
其余一个字节都不动。所以本脚本只干两件事：
  ① 把别名里的卷名换成目标卷名（**必须等长**）；
  ② 校验替换后长度、卷名、别名可解析。

卷名在别名里存了**两份编码**，都要换，否则 Alias Manager 报 -43：
  · volume.name   → UTF-16BE
  · HFS carbon_path → 单字节 ASCII

依赖（仅维护期需要，打包流程不依赖）：
    python3 -m venv /tmp/dsvenv && /tmp/dsvenv/bin/pip install ds_store mac_alias

用法：
    # 源：一份「Finder 摆好过」的 .DS_Store（从成品 DMG 里拷出来即可，不需要挂载）
    cp "/Volumes/OneOfPassword 1.79/.DS_Store" /tmp/orig.ds
    /tmp/dsvenv/bin/python scripts/make_ds_store_template.py \
        --src /tmp/orig.ds --volume-name "OneOfPassword Disk" \
        --out scripts/dmg/DS_Store.template

    # 目标卷名必须与源卷名**等长**，否则会明确报错并给出可选长度
"""
import argparse
import os
import sys

import mac_alias
import ds_store.store as S
from ds_store import DSStore


def _patch_codecs():
    """未知/损坏的 blob 保留原始字节，而不是抛异常中断遍历。"""
    for _code, codec in list(S.codecs.items()):
        orig = codec.decode

        def make(orig=orig):
            def dec(v, **kw):
                try:
                    return orig(v, **kw)
                except Exception:
                    return bytes(v)
            return dec

        # 注意：必须调用 make()，直接赋 make 会让 decode 返回工厂函数而不是值
        codec.decode = make()


def read_records(path):
    """读出 (code, filename) → value，用于只读比对。"""
    _patch_codecs()
    return {(e.code, e.filename): e.value for e in DSStore.open(path)}


def get_alias_from(records):
    for (code, _name), value in records.items():
        if code == b"icvp" and isinstance(value, dict) and "backgroundImageAlias" in value:
            return value["backgroundImageAlias"]
    return None


def describe(alias_bytes):
    a = mac_alias.Alias.from_bytes(alias_bytes)
    name = a.volume.name
    if isinstance(name, bytes):
        name = name.decode("utf-16-be", "replace")
    return {
        "vol_name": name,
        "vol_posix": a.volume.posix_path,
        "has_disk_image": a.volume.disk_image_alias is not None,
        "target_posix": a.target.posix_path,
        "target_name": a.target.filename,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="Finder 原件 .DS_Store 路径")
    ap.add_argument("--volume-name", required=True, help="目标卷名（与源卷名等长）")
    ap.add_argument("--out", required=True, help="输出模板路径，如 scripts/dmg/DS_Store.template")
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        sys.exit(f"✗ 源文件不存在：{args.src}")

    data = open(args.src, "rb").read()
    records = read_records(args.src)
    alias = get_alias_from(records)
    if alias is None:
        sys.exit("✗ 源 .DS_Store 里没有 icvp.backgroundImageAlias，不是图标视图布局")

    info = describe(alias)
    old_name = info["vol_name"]
    new_name = args.volume_name

    print(f"源文件      : {args.src}（{len(data)} 字节，{len(records)} 条记录）")
    print(f"别名卷名    : {old_name!r}")
    print(f"目标卷名    : {new_name!r}")
    print(f"卷内目标路径: {info['target_posix']}")

    if old_name == new_name:
        print("相同时直接拷贝；仍会跑一遍校验。")

    old_b = old_name.encode("utf-16-be")
    new_b = new_name.encode("utf-16-be")
    if len(old_b) != len(new_b):
        # 说明可用的等长卷名，省得用户瞎试
        pad = len(old_b) - len(new_name.encode("utf-16-be"))
        sys.exit(
            f"✗ 卷名长度必须与源相同\n"
            f"  源 {old_name!r} = {len(old_b)//2} 字符；目标 {new_name!r} = {len(new_b)//2} 字符\n"
            f"  还差 {pad//2} 字符。建议补成 {new_name + ' ' * (pad//2)!r} 或换个等长写法。"
        )

    # 等长替换：UTF-16BE 与单字节各一份，顺序无所谓（互不重叠）
    patched = data.replace(old_b, new_b)
    n_utf16 = data.count(old_b)

    old_a = old_name.encode("ascii", "replace")
    new_a = new_name.encode("ascii", "replace")
    if len(old_a) == len(new_a) and old_a != new_a:
        n_ascii = patched.count(old_a)
        patched = patched.replace(old_a, new_a)
    else:
        n_ascii = 0

    if len(patched) != len(data):
        sys.exit(f"✗ 替换后长度变了（{len(data)} → {len(patched)}），容器偏移会错乱，中止")
    print(f"替换次数    : UTF-16BE ×{n_utf16}，单字节 ×{n_ascii}；长度不变 ✓")

    # 校验 ① 头部前 16 字节保持原样
    if patched[:16] != data[:16]:
        sys.exit("✗ 文件头被改动，Finder 会忽略整份文件")
    print(f"文件头      : {patched[:16].hex(' ')} ✓")

    # 校验 ② 记录集合不变，且只有 icvp / pBBk 允许变化
    #    pBBk 内嵌「卷级别名」，卷名替换必然波及它，属预期
    ALLOWED = {b"icvp", b"pBBk"}
    tmp = args.out + ".tmp"
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    open(tmp, "wb").write(patched)
    try:
        after = read_records(tmp)
        if set(records) != set(after):
            sys.exit(f"✗ 记录集合变了：{set(records) ^ set(after)}")
        changed = []
        for k in records:
            if records[k] == after[k] and k[0] not in (b"icvp",):
                continue
            if k[0] == b"icvp":
                b, a = dict(records[k]), dict(after[k])
                b.pop("backgroundImageAlias", None)
                a.pop("backgroundImageAlias", None)
                if b != a:
                    sys.exit(f"✗ icvp 其它字段被改动：{b} vs {a}")
                changed.append("icvp(alias)")
            elif k[0] in ALLOWED:
                changed.append(k[0].decode())
            else:
                sys.exit(f"✗ {k} 被意外改动")
        print(f"记录比对    : {len(after)} 条，仅 {', '.join(changed) or '无'} 变化 ✓")

        # 校验 ③ 新别名里的卷名确实是目标卷名
        new_alias = get_alias_from(after)
        got = describe(new_alias)["vol_name"]
        if got != new_name:
            sys.exit(f"✗ 别名卷名仍是 {got!r}，期望 {new_name!r}（可能有第二处编码没换到）")
        print(f"新别名卷名  : {got!r} ✓")

        # 提示：百分号编码的旧路径（如 OneOfPassword%201.79）替换不到，属已知无害残留
        stale = patched.count(old_name.replace(" ", "%20").encode())
        if stale:
            print(f"提示        : 仍有 {stale} 处百分号编码旧路径（Finder 不依赖，实测无影响）")
    finally:
        if os.path.exists(tmp) and os.path.exists(args.out) is False:
            pass

    os.replace(tmp, args.out)
    print(f"✓ 模板已生成：{args.out}（{os.path.getsize(args.out)} 字节）")
    print(f"  ⚠️  build.sh 里的 VOL_NAME 必须等于 {new_name!r}，否则背景图会丢")


if __name__ == "__main__":
    main()
