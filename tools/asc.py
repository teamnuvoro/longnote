#!/usr/bin/env python3
"""Tiny App Store Connect API helper. Reads ASC_KEY_ID / ASC_ISSUER_ID from story-app/.env.local and the .p8 key;
never prints secrets. usage: asc.py GET /v1/apps | asc.py POST /v1/bundleIds '<json>'"""
import sys, time, json, urllib.request, urllib.error, re, jwt
env={}
for l in open("/root/projects/story-app/.env.local"):
    m=re.match(r'^([A-Z_]+)=(.*)$', l.strip())
    if m: env[m.group(1)]=m.group(2).strip().strip('"').strip("'")
key=open("/root/projects/story-app/.secrets/App Store Connect Auth Key.p8").read()
tok=jwt.encode({"iss":env["ASC_ISSUER_ID"],"iat":int(time.time()),"exp":int(time.time())+900,"aud":"appstoreconnect-v1"},key,algorithm="ES256",headers={"kid":env["ASC_KEY_ID"]})
meth,path=sys.argv[1],sys.argv[2]; body=sys.argv[3].encode() if len(sys.argv)>3 else None
r=urllib.request.Request("https://api.appstoreconnect.apple.com"+path,data=body,method=meth,headers={"Authorization":"Bearer "+tok,"Content-Type":"application/json"})
try: print(urllib.request.urlopen(r).read().decode())
except urllib.error.HTTPError as e: print("HTTP",e.code,e.read().decode()[:800])
