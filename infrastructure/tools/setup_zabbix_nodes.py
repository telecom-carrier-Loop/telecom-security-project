"""Add only missing PC reachability items; never update/delete existing items.

Run with the backend virtualenv Python. Reads existing ZABBIX_API_URL/TOKEN.
Default is a preview. --apply needs a Zabbix token permitted to create items.
"""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend'))
from app import create_app
from app.dashboard.zabbix_routes import _rpc, TARGETS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    create_app()
    url, token = os.getenv('ZABBIX_API_URL', ''), os.getenv('ZABBIX_API_TOKEN', '')
    if not url or not token:
        raise SystemExit('Set ZABBIX_API_URL and ZABBIX_API_TOKEN in the server environment.')
    hosts = _rpc('host.get', {'output': ['hostid'], 'filter': {'host': [TARGETS['services']]}}, url, token)
    if len(hosts) != 1:
        raise SystemExit('Expected exactly one telecom-services host. No changes made.')
    hostid = hosts[0]['hostid']
    existing = _rpc('item.get', {'hostids': [hostid], 'output': ['key_']}, url, token)
    keys = {x['key_'] for x in existing}
    missing = []
    for name, ip in [('PC1', os.getenv('ZABBIX_PC1_IP', '192.168.7.185')),
                     ('PC2', os.getenv('ZABBIX_PC2_IP', '192.168.7.100'))]:
        ip = str(ipaddress.IPv4Address(ip))
        for suffix, key in [('ICMP', f'icmpping[{ip}]'),
                            ('SSH TCP 22', f'net.tcp.service[tcp,{ip},22]')]:
            if key not in keys:
                missing.append({'hostid': hostid, 'name': f'{name} reachability: {suffix}',
                                'key_': key, 'type': 3, 'value_type': 3, 'delay': '30s',
                                'history': '7d', 'trends': '30d',
                                'description': 'Dashboard network reachability; not a direct power sensor.'})
    print(json.dumps({'mode': 'apply' if args.apply else 'preview', 'new_items': missing}, indent=2))
    if args.apply and missing:
        try:
            result = _rpc('item.create', missing, url, token)
        except Exception:
            raise SystemExit('Zabbix did not confirm item creation. Check create permissions and API/server logs; no existing items were modified. Rerun preview before retrying.')
        target = ROOT / 'docs' / 'operations'
        target.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime('%Y%m%dT%H%M%S%f')
        record = target / f'zabbix-nodes-created-{stamp}.json'
        record.write_text(json.dumps({'created': result, 'items': missing}, indent=2), encoding='utf-8')
        print('Created item IDs:', result.get('itemids', []))
        print('Record:', record)


if __name__ == '__main__':
    main()
