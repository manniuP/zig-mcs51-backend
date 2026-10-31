
import json, urllib.request, socket
for method, hdrs in [
    ("GET", {"Accept": "text/event-stream"}),
    ("POST", {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}),
]:
    try:
        data = None
        if method == "POST":
            data = json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize",
                               "params":{"protocolVersion":"2025-03-26","capabilities":{},
                                         "clientInfo":{"name":"mcs2","version":"0.1"}}}).encode()
        req = urllib.request.Request("http://127.0.0.1:8051/mcp", data=data, headers=hdrs, method=method)
        with urllib.request.urlopen(req, timeout=5) as r:
            print(method, r.status, dict(r.headers).get("Mcp-Session-Id"), r.read(300))
    except Exception as e:
        print(method, "ERR", type(e).__name__, str(e)[:160])
