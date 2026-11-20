#!/usr/bin/env python3
"""Write a fresh reference vector for the Send-to-Kindle request signature.

Signs exactly like the reference client "stkclient": SHA-256 over
method/path/date/body/token, RSA PKCS#1 v1.5 without DigestInfo. The app's
`--self-test-stk VECTOR` must produce the identical header. The key is
generated on the fly and thrown away.
"""
import base64, hashlib, json, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption()).decode()
adp = "{enc:SELFTEST}{key:x}{iv:y}{name:QURQVG9rZW4=}{serial:Mg==}"
date = "2026-11-19T15:30:00Z"
path = "/import/kindle-doc/get-device-list"
body = '{"clientInfo":{"appName":"ShellExtension","appVersion":"1.1.1.253","os":"MacOSX_10.14.6_x64","osArchitecture":"x64"}}'
digest = hashlib.sha256("\n".join(["POST", path, date, body, adp]).encode()).digest()
sig = key.sign(digest, padding.PKCS1v15(), utils.NoDigestInfo())
json.dump({"pem": pem, "adp": adp, "date": date, "path": path, "body": body,
           "header": base64.b64encode(sig).decode() + ":" + date}, open(sys.argv[1], "w"))
