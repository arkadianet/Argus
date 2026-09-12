"""Refresh historical evidence from the public explorer and an indexed mainnet node."""
import concurrent.futures
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).parent
NODE = 'https://ergo-node.eutxo.de'
EXPLORER = 'https://api.ergoplatform.com/api/v1'
TRANSACTIONS = {
    'ergopad': '0e1f269f2fe8e75d1c75d6550b4bff13ec43cdde7cb5afc94690e5cc1139e032',
    'paideia-unstake': 'fccb0c4979d43295a27af7be0da3aa93db840776979621bee7c13a1b51c3cf97',
    'paideia-refund': '72e33dd7344b76cd3cd1a3721f126b3e6dc2f24620ed486af9eceabbbe690c7f',
}

def get(url):
    with urlopen(url, timeout=40) as response:
        return json.load(response)

def fetch(item):
    name, tx_id = item
    explorer = get(f'{EXPLORER}/transactions/{tx_id}')
    indexed = get(f'{NODE}/blockchain/transaction/byId/{tx_id}')
    block_id = explorer['blockId']
    block = get(f'{NODE}/blocks/{block_id}/transactions')
    transaction = next(t for t in block['transactions'] if t['id'] == tx_id)
    inclusion = get(f'{NODE}/blocks/{block_id}/header')
    headers = []
    parent = inclusion['parentId']
    for _ in range(10):
        header = get(f'{NODE}/blocks/{parent}/header')
        headers.append(header)
        parent = header['parentId']
    data = [get(f'{NODE}/blockchain/box/byId/{d["boxId"]}') for d in transaction['dataInputs']]
    result = dict(explorer=explorer, transaction=transaction, inputs=indexed['inputs'],
                  dataInputBoxes=data, inclusionHeader=inclusion, headers=headers,
                  sources=dict(explorer=EXPLORER, node=NODE), capturedOn='2026-09-11')
    (ROOT / f'{name}.json').write_text(json.dumps(result, indent=2) + '\n')
    print(name, 'captured', flush=True)

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, TRANSACTIONS.items()))
