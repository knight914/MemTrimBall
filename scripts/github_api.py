#!/usr/bin/env python3
import os,json,urllib.request,sys
BASE='https://api.github.com'
def api(path,data=None,method=None):
 req=urllib.request.Request(BASE+path,data=json.dumps(data).encode() if data is not None else None,headers={'Authorization':'Bearer '+os.environ['GITHUB_TOKEN'],'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28'},method=method)
 with urllib.request.urlopen(req) as r:
  b=r.read();return json.loads(b) if b else None
if __name__=='__main__':
 result=api(sys.argv[1],json.loads(sys.argv[2]) if len(sys.argv)>2 else None,sys.argv[3] if len(sys.argv)>3 else None)
 print(json.dumps(result,indent=2))
