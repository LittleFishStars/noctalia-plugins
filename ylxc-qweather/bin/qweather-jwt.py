#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成和风天气（QWeather）JWT 访问令牌。

和风天气的 JWT 使用 Ed25519（EdDSA）签名，参数规范见
https://dev.qweather.com/docs/configuration/authentication/

用法：
    qweather-jwt.py <私钥.pem> <凭据ID/kid> <项目ID/sub> --iss <开发者ID> [--ttl 1800]

成功时把 Token 打到 stdout（一行），失败时把原因打到 stderr 并以非 0 退出。
签名优先用 cryptography 库，没装则回退到本机 openssl 命令行。

环境变量：
    QWEATHER_ISS        开发者 ID（Q 开头的 10 位），--iss 未给时用这个
    QWEATHER_OPENSSL    openssl 可执行文件路径，默认从 PATH 里找
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

MAX_TTL = 86400  # 和风允许的最长有效期：24 小时
MIN_TTL = 60
IAT_SKEW = 30  # 签发时间往前挪 30 秒，避免本机时钟快于服务端


def b64url(raw: bytes) -> str:
    """Base64URL 编码（无填充），和风明确要求 URL 变体而非标准 Base64。"""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def sign_with_cryptography(private_key_path: str, message: bytes) -> bytes:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519

    with open(private_key_path, "rb") as fh:
        pem = fh.read()
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, ed25519.Ed25519PrivateKey):
        raise RuntimeError("私钥不是 Ed25519 类型，请用 openssl genpkey -algorithm ED25519 生成")
    return key.sign(message)


def sign_with_openssl(private_key_path: str, message: bytes) -> bytes:
    openssl = os.environ.get("QWEATHER_OPENSSL") or shutil.which("openssl")
    if not openssl:
        raise RuntimeError("找不到 openssl，也无法使用 cryptography 库来签名")

    handle = tempfile.NamedTemporaryFile(delete=False)
    try:
        handle.write(message)
        handle.close()
        proc = subprocess.run(
            [openssl, "pkeyutl", "-sign", "-inkey", private_key_path, "-rawin", "-in", handle.name],
            capture_output=True,
        )
        if proc.returncode != 0:
            detail = proc.stderr.decode("utf-8", "replace").strip()
            raise RuntimeError(detail or "openssl 签名失败")
        if not proc.stdout:
            raise RuntimeError("openssl 返回了空签名")
        return proc.stdout
    finally:
        try:
            os.unlink(handle.name)
        except OSError:
            pass


def sign(private_key_path: str, message: bytes) -> bytes:
    try:
        return sign_with_cryptography(private_key_path, message)
    except ImportError:
        return sign_with_openssl(private_key_path, message)


def build_jwt(private_key_path: str, kid: str, sub: str, iss: str, ttl: int) -> dict:
    now = int(time.time())
    ttl = max(MIN_TTL, min(MAX_TTL, int(ttl)))
    iat = now - IAT_SKEW

    # 和风建议只放必需字段，不要带 typ/aud/nbf 这些保留字段
    header = {"alg": "EdDSA", "kid": kid}
    payload = {"iss": iss, "sub": sub, "iat": iat, "exp": iat + ttl}

    compact = json.dumps(header, separators=(",", ":"), ensure_ascii=False)
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    signing_input = (b64url(compact.encode("utf-8")) + "." + b64url(body.encode("utf-8"))).encode("ascii")
    signature = sign(private_key_path, signing_input)

    return {
        "token": signing_input.decode("ascii") + "." + b64url(signature),
        "iat": iat,
        "exp": iat + ttl,
        "kid": kid,
        "sub": sub,
        "iss": iss,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="生成和风天气 JWT（Ed25519 / EdDSA）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("private_key", help="Ed25519 私钥 PEM 文件路径")
    parser.add_argument("kid", help="凭据 ID（控制台 → 项目管理 → 凭据）")
    parser.add_argument("sub", help="项目 ID（控制台 → 项目管理）")
    parser.add_argument("--iss", default=os.environ.get("QWEATHER_ISS", ""),
                        help="开发者 ID（控制台 → 设置，Q 开头的 10 位）")
    parser.add_argument("--ttl", type=int, default=1800, help="有效期秒数，最长 86400，默认 1800")
    parser.add_argument("--json", action="store_true", help="输出 JSON（含 exp 等信息）而非纯 Token")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.private_key):
        print(f"私钥文件不存在：{args.private_key}", file=sys.stderr)
        return 2
    if not args.iss:
        print("缺少开发者 ID（iss）：请用 --iss 或环境变量 QWEATHER_ISS 提供", file=sys.stderr)
        return 2

    try:
        result = build_jwt(args.private_key, args.kid, args.sub, args.iss, args.ttl)
    except Exception as exc:  # noqa: BLE001 —— 命令行工具，任何失败都以文本报出
        print(f"{exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(result["token"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
