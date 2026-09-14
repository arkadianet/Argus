#!/usr/bin/env python3
"""Read-only rank-2 probe; requires requests. No wallet/configuration changes.

Run from the repo root: python3 scripts/tx_latency_endpoints.py
Redirect output to rust/target to retain the JSONL measurements in the worktree.
Each host has one persistent session; hosts overlap, requests per host are serial.
"""
import concurrent.futures
import json
import time

import requests

TREE = "0008cd03986ae12afbc27b9436ce23cb90faf7864376c5250b6a019d45a7aabfc7c910c9"
ADDRESS = "9hcvzUtMhsNnbfewYErk65mUxjWGn9DxQdiRVkMesg5fpZHwqF7"
OTHER_TREE = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
CASES = [
    ("info", "GET", "/info", None),
    ("unspent", "POST", "/blockchain/box/unspent/byAddress?offset=0&limit=500", ADDRESS),
    ("tree100", "POST", "/transactions/unconfirmed/byErgoTree?offset=0&limit=100", TREE),
    ("tree1", "POST", "/transactions/unconfirmed/byErgoTree?offset=0&limit=1", TREE),
    ("pool", "GET", "/transactions/unconfirmed?offset=0&limit=100", None),
    ("other_tree", "POST", "/transactions/unconfirmed/byErgoTree?offset=0&limit=100", OTHER_TREE),
    ("ids", "GET", "/transactions/unconfirmed/transactionIds", None),
    ("outputs_tree", "POST", "/transactions/unconfirmed/outputs/byErgoTree?offset=0&limit=100", TREE),
    ("pool1", "GET", "/transactions/unconfirmed?offset=0&limit=1", None),
]


def probe_host(url):
    with requests.Session() as session:
        for trial in range(3):
            for name, method, path, body in CASES if trial % 2 == 0 else reversed(CASES):
                row = dict(host=url, trial=trial, case=name)
                start = time.perf_counter()
                try:
                    response = session.request(method, url + path, json=body, timeout=35)
                    row.update(
                        status=response.status_code,
                        ms=(time.perf_counter() - start) * 1000,
                        headers_ms=response.elapsed.total_seconds() * 1000,
                        bytes=len(response.content),
                    )
                    decode_start = time.perf_counter()
                    try:
                        value = response.json()
                        if name == "info" and isinstance(value, dict):
                            row.update(version=value.get("appVersion"), unconfirmedCount=value.get("unconfirmedCount"))
                    except ValueError:
                        row["json_error"] = True
                    row["decode_ms"] = (time.perf_counter() - decode_start) * 1000
                except requests.RequestException as error:
                    row["error"] = str(error)
                print(json.dumps(row), flush=True)


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(probe_host, ["https://node.kadia.io", "https://ergo-node.eutxo.de"]))
