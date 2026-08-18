#!/usr/bin/env bash
# Probe Glooko using the exact login the working driver uses.
#
# Key detail lifted from node_modules/nightscout-connect/lib/sources/glooko:
# deviceInformation only needs {"deviceModel":"iPhone"}. Sending a richer
# block gets a 422.
#
# The driver defines LatestFoods (/api/v2/foods) and LatestInsulins
# (/api/v2/insulins) but only reads treatments from pumps/normal_boluses.
# On pens that endpoint is mostly empty, which is what we're testing.
#
# Usage:  ./glooko-probe.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; source .env; set +a

API=https://eu.api.glooko.com
ORIGIN=https://eu.my.glooko.com
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15'
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT

echo "== signing in =="
LOGIN=$(curl -s -c "$JAR" -A "$UA" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/plain, */*' \
  -H "Origin: $ORIGIN" -H "Referer: $ORIGIN/" \
  -X POST "$API/api/v2/users/sign_in" \
  -w '\n__HTTP_%{http_code}__' \
  -d "{\"userLogin\":{\"email\":\"${CONNECT_GLOOKO_EMAIL}\",\"password\":\"${CONNECT_GLOOKO_PASSWORD}\"},\"deviceInformation\":{\"deviceModel\":\"iPhone\"}}")

CODE=$(echo "$LOGIN" | tail -1)
echo "$CODE"
if [[ "$CODE" != "__HTTP_200__" ]]; then
  echo "$LOGIN" | head -c 400; echo; exit 1
fi

PATIENT=$(echo "$LOGIN" | sed '$d' | python3 -c "
import sys,json
def find(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k.lower() in ('guid','patientguid') and isinstance(v,str): return v
            r=find(v)
            if r: return r
    elif isinstance(o,list):
        for i in o:
            r=find(i)
            if r: return r
try: print(find(json.load(sys.stdin)) or '')
except Exception: print('')
")
PATIENT="${PATIENT_OVERRIDE:-$PATIENT}"
echo "patient: $PATIENT"

START=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S.000Z)
END=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
echo "window: $START -> $END"; echo

get () { curl -s -b "$JAR" -A "$UA" -H 'Accept: application/json' \
           -H "Origin: $ORIGIN" -H "Referer: $ORIGIN/" "$1"; }

probe () {
  local EP="$1"
  get "$API/api/v2/${EP}?patient=${PATIENT}&startDate=${START}&endDate=${END}" \
  | python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception:
    print('  %-26s non-json: %s' % ('$EP', raw[:50].replace(chr(10),' '))); sys.exit()
def s(o):
    if isinstance(o,list): return '%d items' % len(o)
    if isinstance(o,dict):
        b=[k+'='+str(len(v)) for k,v in o.items() if isinstance(v,list)]
        return ', '.join(b) if b else 'keys: '+','.join(list(o.keys())[:5])
    return '?'
print('  %-26s %s' % ('$EP', s(d)))
def sample(o):
    if isinstance(o,list) and o: return o[0]
    if isinstance(o,dict):
        for k,v in o.items():
            if isinstance(v,list) and v: return {k:v[0]}
    return None
sm=sample(d)
if sm: print('      %s' % json.dumps(sm)[:300])
"
}

echo "== endpoints the driver reads for treatments =="
probe "pumps/normal_boluses"

echo
echo "== endpoints it defines but never reads =="
probe "foods"
probe "insulins"

echo
echo "== v3 graph: the pen series (injectionBolus / gkCarb / gkInsulin) =="
V3="$API/api/v3/graph/data?patient=${PATIENT}&startDate=${START}&endDate=${END}"
V3="${V3}&series[]=injectionBolus&series[]=gkCarb&series[]=gkInsulin&series[]=carbNonManual&series[]=deliveredBolus&locale=en-GB"
get "$V3" | python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception:
    print('  non-json:', raw[:200]); sys.exit()
def walk(o,path=''):
    if isinstance(o,dict):
        for k,v in o.items(): walk(v, path+'/'+k)
    elif isinstance(o,list):
        if o: print('  %-40s %d items' % (path, len(o)))
        if o and not isinstance(o[0],(list,dict)): return
        if o: print('      %s' % json.dumps(o[0])[:280])
walk(d)
"
