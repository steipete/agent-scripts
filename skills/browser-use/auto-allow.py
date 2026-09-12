#!/usr/bin/env python3
"""Watch Chrome for the 'Allow remote debugging?' sheet and press its Allow button (rightmost enabled button inside the sheet)."""
import json, subprocess, sys, time
QUERY = json.dumps({"command_id":"sheet","command":"collectAll","application":"Google Chrome","max_depth":10,
  "attributes_to_return":["AXRole","AXTitle","AXPosition","AXSize","AXEnabled"]})
def val(a,k):
    y=a.get(k); return y.get("any_value") if isinstance(y,dict) else y
def parse_pt(s):
    if not s: return None
    try:
        x,y = s.strip("()").split(","); return float(x), float(y)
    except Exception: return None
def scan():
    out = subprocess.run(["axorc","raw","--stdin","--scan-all","--no-stop-first","--timeout","40"],input=QUERY,capture_output=True,text=True).stdout
    try: d=json.loads(out)
    except Exception: return None, []
    items=d
    for k in ("data","elements","results","matches"):
        if isinstance(items,dict) and k in items: items=items[k]
    if isinstance(items,dict):
        for k in ("elements","results","matches","data"):
            if k in items: items=items[k]; break
    if not isinstance(items,list): return None, []
    sheet=None; buttons=[]
    for it in items:
        a=it.get("attributes") or it
        role=val(a,"AXRole"); title=val(a,"AXTitle") or ""
        pos=parse_pt(val(a,"AXPosition")); size=parse_pt(val(a,"AXSize"))
        if role=="AXSheet" and "Allow remote debugging" in title and pos and size: sheet=(pos,size)
        if role=="AXButton" and pos and size and val(a,"AXEnabled") is not False: buttons.append((pos,size))
    return sheet, buttons
once = "--once" in sys.argv
dry = "--dry" in sys.argv
while True:
    sheet, buttons = scan()
    if sheet:
        (sx,sy),(sw,sh)=sheet
        inside=[(p,s) for p,s in buttons if sx<=p[0]<=sx+sw and sy<=p[1]<=sy+sh and 20<=s[0]<=400 and 16<=s[1]<=80]
        inside.sort(key=lambda b: b[0][0])
        print(time.strftime("%H:%M:%S"), "sheet at", sheet, "buttons inside:", inside, flush=True)
        if inside:
            (bx,by),(bw,bh)=inside[-1]
            cx,cy=int(bx+bw/2), int(by+bh/2)
            if dry: print("DRY: would click", cx, cy, flush=True)
            else:
                subprocess.run(["cliclick", f"c:{cx},{cy}"]); print("CLICKED Allow at", cx, cy, flush=True)
                time.sleep(2)
        if once: break
    elif once:
        print("no sheet", flush=True); break
    time.sleep(2)
