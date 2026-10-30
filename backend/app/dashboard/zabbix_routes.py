"""Read-only, admin-only Zabbix monitoring proxy. Never sends credentials to browsers."""
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit

import requests
from flask import Blueprint

from ..core.permissions import ROLE_ADMIN, roles_required
from ..core.responses import ok

bp = Blueprint('admin_zabbix', __name__, url_prefix='/api/admin')

# Host names are the Zabbix technical host names (not visible labels).
TARGETS = {
    'services': 'telecom-services',
    'windows': 'PC2-Windows',
}
SERVICE_PORTS = {
    '192.168.3.19:5000': 'Flask API',
    '192.168.3.19:443': 'Wazuh Dashboard',
    '192.168.3.19:3306': 'MySQL',
    '192.168.3.19:5678': 'n8n',
    '192.168.3.18:9000': 'Graylog',
}


def _node_status(items, ip, now):
    keys = (f'icmpping[{ip}]', f'net.tcp.service[tcp,{ip},22]',
            *(f"net.tcp.service[tcp,{address.replace(':', ',')}]" for address in SERVICE_PORTS if address.startswith(ip + ':')))
    checks = []
    for key in keys:
        item = next((x for x in items if x.get('key_') == key), None)
        if not item or str(item.get('status', '0')) != '0' or str(item.get('state', '0')) != '0':
            continue
        try:
            clock = int(item.get('lastclock', 0))
            value = float(item['lastvalue'])
        except (TypeError, ValueError, KeyError):
            continue
        if clock <= 0 or not 0 <= now - clock <= 180 or value not in (0, 1):
            continue
        checks.append((value, clock))
    status = 'ON' if any(v == 1 for v, _ in checks) else 'OFF' if len(checks) == len(keys) else 'UNKNOWN'
    return {'status': status, 'checked_at': max((t for _, t in checks), default=None),
            'method': 'ICMP·SSH·등록 서비스 TCP 응답',
            'message': None if status != 'UNKNOWN' else '감시 항목 미설정·수집 지연 또는 데이터 확인 불가'}


def _rpc(method, params, base_url, token):
    response = requests.post(
        base_url,
        json={'jsonrpc': '2.0', 'method': method, 'params': params, 'id': 1},
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        timeout=(3, 8),
        allow_redirects=False,
    )
    response.raise_for_status()
    data = response.json()
    if 'error' in data:
        raise RuntimeError('Zabbix API rejected request')
    return data['result']


def _metric_match(item, text):
    return text.lower() in item.get('name', '').lower()


def _metric_item(items, patterns):
    for text in patterns:
        for item in items:
            if _metric_match(item, text):
                return item
    return None


def _numeric(item):
    try:
        return round(float(item['lastvalue']), 3)
    except (TypeError, ValueError, KeyError):
        return None


@bp.get('/monitoring/zabbix')
@roles_required(ROLE_ADMIN)
def zabbix_dashboard():
    base = os.getenv('ZABBIX_API_URL', '').strip()
    token = os.getenv('ZABBIX_API_TOKEN', '').strip()
    result = {'configured': bool(base and token), 'connected': False, 'updated_at': None,
              'nodes': [], 'services': [], 'metrics': {}, 'history': {}, 'problems': [], 'message': None}
    if not result['configured']:
        result['message'] = 'ZABBIX_API_URL 및 ZABBIX_API_TOKEN 서버 환경변수를 설정하세요.'
        return ok(result)
    parsed = urlsplit(base)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username or parsed.password:
        result['message'] = 'Zabbix API 주소 설정이 올바르지 않습니다.'
        return ok(result)
    # Do not accept any user-supplied URL or Zabbix token, even through query parameters.
    try:
        hosts = _rpc('host.get', {'output': ['hostid', 'host'],
                                  'filter': {'host': list(TARGETS.values())}}, base, token)
        ids = {h['host']: h['hostid'] for h in hosts}
        if not ids:
            result['message'] = 'Zabbix에서 대상 호스트를 찾지 못했습니다. 계정 읽기 권한과 호스트 이름을 확인하세요.'
            return ok(result)
        items = _rpc('item.get', {
            'output': ['itemid', 'hostid', 'name', 'key_', 'lastvalue', 'lastclock', 'units', 'value_type', 'status', 'state'],
            'hostids': list(ids.values()), 'filter': {'status': 0}, 'limit': 2000,
        }, base, token)
        now = int(time.time())
        for name, ip in [('PC1', os.getenv('ZABBIX_PC1_IP', '192.168.7.185')),
                         ('PC2', os.getenv('ZABBIX_PC2_IP', '192.168.7.100'))]:
            node_items = [x for x in items if x['hostid'] == ids.get(TARGETS['services'])]
            result['nodes'].append({'name': name, 'ip': ip, **_node_status(node_items, ip, now)})
        service_items = [x for x in items if x['hostid'] == ids.get(TARGETS['services'])
                         and x.get('key_', '').startswith('net.tcp.service[')]
        for label_key, label in SERVICE_PORTS.items():
            ip, port = label_key.split(':')
            key = f'net.tcp.service[tcp,{ip},{port}]'
            item = next((v for v in service_items if v.get('key_') == key), None)
            value = _numeric(item) if item else None
            result['services'].append({'name': label, 'status': ('UP' if value == 1 else 'DOWN' if value == 0 else 'UNKNOWN'),
                                       'checked_at': int(item['lastclock']) if item and item.get('lastclock') else None})
        windows_items = [x for x in items if x['hostid'] == ids.get(TARGETS['windows'])]
        selectors = {
            'cpu': ['CPU utilization'], 'ram': ['Memory utilization'],
            'disk_c': ['FS [(C:)]: Space: Used, in %'],
        }
        # Template names can vary; not finding an item returns null rather than invented values.
        for key, patterns in selectors.items():
            item = _metric_item(windows_items, patterns)
            result['metrics'][key] = _numeric(item) if item else None
            result['history'][key] = []
            if item and item.get('value_type') in ('0', '3'):
                samples = _rpc('history.get', {
                    'output': 'extend', 'history': int(item['value_type']),
                    'itemids': [item['itemid']], 'time_from': int(time.time()) - 3600,
                    'sortfield': 'clock', 'sortorder': 'ASC', 'limit': 180,
                }, base, token)
                result['history'][key] = [{'t': int(p['clock']), 'v': float(p['value'])} for p in samples]
        problems = _rpc('problem.get', {
            'output': ['eventid', 'name', 'severity', 'clock'], 'recent': False,
            'sortfield': ['eventid'], 'sortorder': 'DESC', 'limit': 20,
        }, base, token)
        result['problems'] = [{'name': x['name'], 'severity': int(x['severity']), 'clock': int(x['clock'])}
                              for x in problems]
        result['connected'] = True
        result['updated_at'] = datetime.now(timezone.utc).isoformat()
    except (requests.RequestException, ValueError, KeyError, TypeError, RuntimeError):
        result['message'] = 'Zabbix 데이터를 조회할 수 없습니다. 서버 접근, 토큰, 호스트 읽기 권한을 확인하세요.'
    return ok(result)
