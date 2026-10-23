#!/usr/bin/env python3
"""Setzt/aktualisiert die Content-Security-Policy in index.html.
Der Hash des eingebetteten Skripts muss nach JEDER Änderung am Skript neu berechnet werden –
sonst blockiert der Browser das Spiel. Aufruf: python3 tools/csp.py index.html  (mit --check nur prüfen)"""
import base64, hashlib, re, sys
path = sys.argv[1]; check = '--check' in sys.argv
s = open(path, encoding='utf-8').read()
m = re.search(r'<script>(.*?)</script>', s, re.S)
h = base64.b64encode(hashlib.sha256(m.group(1).encode('utf-8')).digest()).decode()
SUPA = 'eaydvicdtlnkuniqeqte.supabase.co'
pol = ("default-src 'self'; "
       f"script-src 'self' file: 'sha256-{h}'; "
       "style-src 'self' 'unsafe-inline'; font-src 'self' file:; "
       f"img-src 'self' file: data: blob: https://{SUPA}; "
       f"connect-src 'self' https://{SUPA} wss://{SUPA} https://0.peerjs.com wss://0.peerjs.com; "
       "frame-src https://maps.google.com https://www.google.com; "
       "object-src 'none'; base-uri 'none'; form-action 'self'; worker-src 'none'; media-src 'none'")
tag = f'<meta http-equiv="Content-Security-Policy" content="{pol}">'
old = re.search(r'<meta http-equiv="Content-Security-Policy" content="[^"]*">', s)
if check:
    ok = bool(old) and old.group(0) == tag
    print('CSP ok' if ok else 'CSP VERALTET'); sys.exit(0 if ok else 1)
s = s.replace(old.group(0), tag) if old else s.replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + tag, 1)
open(path, 'w', encoding='utf-8').write(s); print('CSP gesetzt, sha256-' + h)
