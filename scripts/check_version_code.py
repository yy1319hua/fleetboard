#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发版前 versionCode 预检（fail-closed）。

【由来】2026-11-05 v0.5.3 发版时，误把 app/pubspec.yaml 的 +N 直接当作
Android versionCode，仅凭 build.gradle 静态推断出「0.5.3+19 会产出 19、
低于线上 2018、用户装不上」，据此把 buildNumber 改成 +2019，实际产出
versionCode 4019（跳号）。根因是：没有实测，也没有查已有的历史台账
（台账里 +16→2016、+17→2017、+18→2018 三点早已写明映射关系）。

【固化规则】Flutter --split-per-abi 的 arm64-v8a APK：
    versionCode = 2000 + buildNumber
2000 是 Flutter 工具链给 arm64-v8a 的固定 ABI 偏移。实测四点：
    +16→2016、+17→2017、+18→2018、+2019→4019

【纪律】发版前必须跑本脚本并拿到 PASS 才允许打 tag；基线必须来自
aapt 对「上一版已发布 APK」的实测，不得凭推断填写。

用法：
  python3 scripts/check_version_code.py                  # 自动下载上一版 APK 实测
  python3 scripts/check_version_code.py --baseline 2018  # 基线由人工 aapt 实测后传入
  python3 scripts/check_version_code.py --expected-only  # 只打印预期值
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO = "yy1319hua/fleetboard"
APK_ASSET = "fleetboard-arm64-v8a-release.apk"
ABI_OFFSET = 2000  # Flutter arm64-v8a split-per-abi 固定偏移


def read_build_number(pubspec):
    with open(pubspec, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^version:\s*\S+\+(\d+)\s*$", line)
            if m:
                return int(m.group(1))
    raise SystemExit("FAIL: 在 %s 找不到形如 'version: x.y.z+N' 的行" % pubspec)


def find_aapt():
    p = shutil.which("aapt")
    if p:
        return p
    for root in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                 "/opt/android-sdk"):
        if not root:
            continue
        hits = sorted(glob.glob(os.path.join(root, "build-tools", "*", "aapt")))
        if hits:
            return hits[-1]
    return None


def parse_version_code(apk, aapt):
    out = subprocess.run([aapt, "dump", "badging", apk], capture_output=True, text=True)
    m = re.search(r"versionCode='(\d+)'", out.stdout)
    if not m:
        raise SystemExit("FAIL: aapt 无法解析 %s 的 versionCode（%s）"
                         % (apk, out.stderr[:200]))
    return int(m.group(1))


def fetch_latest_baseline(aapt, token):
    url = "https://api.github.com/repos/%s/releases/latest" % REPO
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "fleetboard-version-check"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    asset = next((a for a in data.get("assets", []) if a["name"] == APK_ASSET), None)
    if not asset:
        raise SystemExit("FAIL: 最新 Release %s 没有资产 %s"
                         % (data.get("tag_name"), APK_ASSET))
    dl = urllib.request.Request(asset["browser_download_url"],
                                headers={"User-Agent": "fleetboard-version-check"})
    if token:
        dl.add_header("Authorization", "Bearer " + token)
    with tempfile.NamedTemporaryFile(suffix=".apk", delete=False) as tmp:
        tmp_path = tmp.name
        with urllib.request.urlopen(dl, timeout=180) as r:
            shutil.copyfileobj(r, tmp)
    try:
        return parse_version_code(tmp_path, aapt), data.get("tag_name")
    finally:
        os.unlink(tmp_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", type=int,
                    help="上一版已发布 APK 的 versionCode（必须来自 aapt 实测）")
    ap.add_argument("--expected-only", action="store_true",
                    help="只打印预期值，不断言")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    n = read_build_number(os.path.join(root, "app", "pubspec.yaml"))
    expected = ABI_OFFSET + n
    print("buildNumber           : +%d  (app/pubspec.yaml)" % n)
    print("规则                  : versionCode = %d + buildNumber（arm64-v8a ABI 偏移）"
          % ABI_OFFSET)
    print("本次预期 versionCode  : %d" % expected)
    if args.expected_only:
        return 0

    if args.baseline is not None:
        baseline = args.baseline
        src = "命令行 --baseline（应来自 aapt 实测上一版 APK）"
    else:
        aapt = find_aapt()
        if not aapt:
            raise SystemExit(
                "FAIL: 未找到 aapt，无法自动实测基线。\n"
                "      请先用 aapt dump badging 解析上一版已发布 APK，"
                "再用 --baseline 传入实测值（禁止凭推断填写）。")
        baseline, tag = fetch_latest_baseline(aapt, os.environ.get("GITHUB_TOKEN"))
        src = "GitHub Release %s 的 APK 实测" % tag
    print("线上基线 versionCode  : %d  (%s)" % (baseline, src))

    if expected <= baseline:
        print("FAIL: 预期 %d <= 基线 %d —— Android 会判为降级、拒绝覆盖安装，禁止发版。"
              % (expected, baseline))
        return 1
    print("PASS: %d > %d，可覆盖升级。" % (expected, baseline))
    print("     下个版本 buildNumber 必须 > %d。" % (baseline - ABI_OFFSET))
    return 0


if __name__ == "__main__":
    sys.exit(main())
