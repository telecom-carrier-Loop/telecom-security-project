#!/usr/bin/env python3
"""PC2 n8n 전용 HTTPS 프록시 준비/생성. 공개 edge, DB, pfSense는 변경하지 않는다."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

NS = 'telecom'
APP = 'telecom-automation-edge'
OWNER = 'telecom.test/automation-plan'
NODE_PORT = 30445
ROUTES = {
    '/api/internal/incident-events': ('POST', 'INCIDENT_API_TOKEN'),
    '/api/internal/ip-blocks': ('POST', 'AUTOMATION_API_TOKEN'),
    '/api/internal/account-locks': ('POST', 'AUTOMATION_API_TOKEN'),
    '/api/internal/privilege-violations': ('GET', 'AUTOMATION_API_TOKEN'),
    '/api/internal/role-revocations': ('POST', 'AUTOMATION_API_TOKEN'),
}
# Runs inside each deployed API container. No valid token or mutation is sent.
AUDIT = '''
import ast, inspect, json, textwrap
from wsgi import app
routes = ROUTE_LITERAL
with app.test_client() as client:
    for path, (method, key) in routes.items():
        if not app.config.get(key):
            raise SystemExit('Missing token configuration: ' + key)
        rules = [r for r in app.url_map.iter_rules() if r.rule == path and method in r.methods]
        if len(rules) != 1:
            raise SystemExit('Missing/ambiguous automation route: ' + path)
        fn = app.view_functions[rules[0].endpoint]
        tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
        body = tree.body[0].body
        body = [s for s in body if not isinstance(s, (ast.Import, ast.ImportFrom))
                and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant)
                         and isinstance(s.value.value, str))]
        stmt = body[0] if body else None
        call = stmt.value if isinstance(stmt, (ast.Assign, ast.Expr)) else None
        name = (getattr(call.func, 'attr', None) or getattr(call.func, 'id', None)) if isinstance(call, ast.Call) else None
        args = call.args if isinstance(call, ast.Call) else []
        actual_key = args[0].value if len(args) == 1 and isinstance(args[0], ast.Constant) else 'AUTOMATION_API_TOKEN' if not args else None
        if name != 'check_automation_token' or actual_key != key or call.keywords:
            raise SystemExit('Token-first guard not verified: ' + path)
        response = client.open(path, method=method, json={} if method == 'POST' else None,
                               base_url='https://192.168.3.30:10443')
        if response.status_code != 401:
            raise SystemExit('Expected missing-token 401: ' + path)
print('AUTOMATION_AUDIT=' + json.dumps({'routes': len(routes), 'missing_token': 401}))
'''.replace('ROUTE_LITERAL', repr(ROUTES))


def nginx_config():
    locations = '\n'.join('''        location = %s {
            if ($request_method != %s) { return 405; }
            proxy_pass http://telecom-api:5000;
        }''' % (path, method) for path, (method, _) in ROUTES.items())
    return '''worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
    log_format automation '$remote_addr $request_method $uri $status';
    access_log /dev/stdout automation;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 8443 ssl;
        server_name 192.168.3.30;
        ssl_certificate /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        # pfSense must restrict the original source to PC2 BEFORE this SNAT.
        allow 192.168.3.30/32;
        deny all;
        client_max_body_size 1m;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Request-ID $request_id;
        proxy_set_header Cookie "";
        proxy_set_header Authorization $http_authorization;
        proxy_set_header X-API-Key $http_x_api_key;
        proxy_set_header X-Workflow $http_x_workflow;
        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
        proxy_next_upstream off;
        location = /automation-health { return 200 "automation-edge-ok\\n"; }
''' + locations + '''
        location / { return 404; }
    }
}
'''


def kubectl(*args, input_text=None):
    result = subprocess.run(['sudo', '-n', 'k3s', 'kubectl', '-n', NS, *args],
                            input=input_text, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('kubectl 실패: ' + ' '.join(args[:3]) + '; exit=' + str(result.returncode))
    return result.stdout


def get(kind, name=None):
    return json.loads(kubectl('get', kind, *([name] if name else []), '-o', 'json'))


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def stable_pods(app, container):
    items = json.loads(kubectl('get', 'pods', '-l', 'app=' + app, '-o', 'json'))['items']
    if len(items) != 2 or not all(
        not p['metadata'].get('deletionTimestamp') and any(
            c['name'] == container and c.get('ready') for c in p.get('status', {}).get('containerStatuses', []))
        for p in items
    ):
        raise RuntimeError('정상 Ready Pod 2개 필요: ' + app)
    return items


def audit_api():
    for pod in stable_pods('telecom-api', 'api'):
        output = kubectl('exec', '-i', pod['metadata']['name'], '-c', 'api', '--', 'python', '-', input_text=AUDIT)
        reports = [json.loads(s.split('=', 1)[1]) for s in output.splitlines() if s.startswith('AUTOMATION_AUDIT=')]
        if reports != [{'routes': 5, 'missing_token': 401}]:
            raise RuntimeError('API 토큰 검사 실패')
        print(pod['metadata']['name'], '내부 API 5개: 토큰 설정/선행 검사/미인증 401 확인')


def validate_nginx(config):
    for pod in stable_pods('telecom-edge', 'edge'):
        path = '/tmp/automation-' + uuid.uuid4().hex + '.conf'
        try:
            kubectl('exec', '-i', pod['metadata']['name'], '-c', 'edge', '--', 'sh', '-c',
                    'umask 077; cat > ' + path, input_text=config)
            kubectl('exec', pod['metadata']['name'], '-c', 'edge', '--', 'nginx', '-t', '-c', path)
        finally:
            kubectl('exec', pod['metadata']['name'], '-c', 'edge', '--', 'rm', '-f', path)


def resources(edge, owner):
    source = edge['spec']['template']['spec']
    containers = source['containers']
    if len(containers) != 1 or containers[0]['name'] != 'edge':
        raise ValueError('공개 edge 컨테이너 구조 확인 필요')
    old = containers[0]
    mounts = [m for m in old.get('volumeMounts', []) if m['mountPath'] == '/etc/nginx/tls']
    if len(mounts) != 1 or mounts[0].get('subPath'):
        raise ValueError('공개 edge TLS 마운트 확인 필요')
    volumes = [v for v in source.get('volumes', []) if v['name'] == mounts[0]['name']]
    if len(volumes) != 1 or not volumes[0].get('secret', {}).get('secretName'):
        raise ValueError('TLS Secret 참조 확인 필요')
    tls = copy.deepcopy(volumes[0])
    tls['name'] = 'tls'
    probe = {'httpGet': {'path': '/automation-health', 'port': 8443, 'scheme': 'HTTPS'},
             'periodSeconds': 5, 'timeoutSeconds': 2}
    container = {'name': 'edge', 'image': old['image'], 'imagePullPolicy': 'Never',
                 'command': ['nginx'], 'args': ['-g', 'daemon off;'],
                 'ports': [{'name': 'https', 'containerPort': 8443}],
                 'securityContext': copy.deepcopy(old.get('securityContext', {})),
                 'resources': {'requests': {'cpu': '20m', 'memory': '32Mi'},
                               'limits': {'cpu': '200m', 'memory': '128Mi'}},
                 'volumeMounts': [
                     {'name': 'config', 'mountPath': '/etc/nginx/nginx.conf', 'subPath': 'nginx.conf', 'readOnly': True},
                     {'name': 'tls', 'mountPath': '/etc/nginx/tls', 'readOnly': True},
                     {'name': 'tmp', 'mountPath': '/tmp'}],
                 'readinessProbe': copy.deepcopy(probe), 'livenessProbe': copy.deepcopy(probe)}
    pod = {'automountServiceAccountToken': False, 'containers': [container],
           'securityContext': copy.deepcopy(source.get('securityContext', {})),
           'volumes': [{'name': 'config', 'configMap': {'name': APP + '-config'}}, tls,
                       {'name': 'tmp', 'emptyDir': {}}],
           'affinity': {'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [
               {'matchExpressions': [{'key': 'kubernetes.io/hostname', 'operator': 'In',
                                      'values': ['pc1-k3s', 'pc2-k3s']}]}]}},
               'podAntiAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': [
                   {'labelSelector': {'matchLabels': {'app': APP}}, 'topologyKey': 'kubernetes.io/hostname'}]}}}
    def meta(name):
        return {'name': name, 'namespace': NS, 'annotations': {OWNER: owner}, 'labels': {'app': APP}}
    return [
        {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': meta(APP + '-config'), 'data': {'nginx.conf': nginx_config()}},
        {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': meta(APP),
         'spec': {'replicas': 2, 'strategy': {'type': 'Recreate'}, 'selector': {'matchLabels': {'app': APP}},
                  'template': {'metadata': {'labels': {'app': APP}}, 'spec': pod}}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': meta(APP),
         'spec': {'type': 'NodePort', 'externalTrafficPolicy': 'Local', 'selector': {'app': APP},
                  'ports': [{'name': 'https', 'port': 443, 'targetPort': 'https', 'nodePort': NODE_PORT}]}},
    ]


def preflight():
    # Existing policies may select the new proxy/API; do not blindly add a policy that isolates live API pods.
    if get('networkpolicies')['items']:
        raise RuntimeError('기존 NetworkPolicy가 있습니다. 새 edge → API:5000 및 DNS/TLS 경로를 먼저 검토하세요.')
    for kind, name in [('configmap', APP + '-config'), ('deployment', APP), ('service', APP)]:
        if json.loads(kubectl('get', kind, name, '--ignore-not-found', '-o', 'json') or 'null'):
            raise RuntimeError('전용 리소스가 이미 존재합니다. 반복 생성 대신 기존 작업 폴더 status를 확인하세요.')
    for service in json.loads(kubectl('get', 'services', '--all-namespaces', '-o', 'json'))['items']:
        if any(p.get('nodePort') == NODE_PORT for p in service['spec'].get('ports', [])):
            raise RuntimeError('NodePort 30445 사용 중')
    audit_api()
    edge = get('deployment', 'telecom-edge')
    public = get('configmap', 'telecom-edge-config')
    config = public['data']['nginx.conf']
    for modifier, path in [('=', '/api/internal'), ('^~', '/api/internal/')]:
        if not re.search(r'location\s+' + re.escape(modifier) + r'\s+' + re.escape(path)
                         + r'\s*\{\s*return\s+404\s*;\s*\}', config):
            raise RuntimeError('공개 443의 내부 API 404 정책을 먼저 확인하세요.')
    # The public configuration is fingerprinted, never changed by this tool.
    return edge, public


def save(directory, state):
    target = directory / 'state.json'
    temporary = directory / 'state.new'
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding='utf-8')
    temporary.replace(target)


def load(directory):
    state = json.loads((directory / 'state.json').read_text(encoding='utf-8'))
    if state.get('format') != 'automation-ingress-v1':
        raise ValueError('작업 폴더 형식 불일치')
    return state


def plan(directory):
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    edge, public = preflight()
    owner = uuid.uuid4().hex
    items = resources(edge, owner)
    validate_nginx(items[0]['data']['nginx.conf'])
    bundle = {'apiVersion': 'v1', 'kind': 'List', 'items': items}
    payload = json.dumps(bundle)
    kubectl('create', '--dry-run=server', '-f', '-', input_text=payload)
    (directory / 'resources.json').write_text(payload, encoding='utf-8')
    (directory / 'nginx.conf').write_text(nginx_config(), encoding='utf-8')
    save(directory, {'format': 'automation-ingress-v1', 'owner': owner, 'stage': 'planned',
                     'edge_hash': fingerprint(edge['spec']['template']), 'public_hash': fingerprint(public['data']),
                     'bundle_hash': fingerprint(bundle), 'created': []})
    (Path.home() / '.telecom-automation-workdir').write_text(str(directory), encoding='utf-8')
    print('PLAN OK: 공개 edge 변경 없음. 신규 프록시 2개 + NodePort 30445 준비')
    print('WORK_DIR=' + str(directory))


def rollback(directory, state):
    # Delete only resources created by this plan, with both ownership annotation and UID preconditions.
    pending = state.get('pending')
    if pending and not any(r['name'] == pending['name'] for r in state['created']):
        current = json.loads(kubectl('get', pending['kind'], pending['name'], '--ignore-not-found', '-o', 'json') or 'null')
        if current and current['metadata'].get('annotations', {}).get(OWNER) == state['owner']:
            # Recover the response-lost create using this plan's unique ownership marker.
            state['created'].append({**pending, 'uid': current['metadata']['uid']})
            save(directory, state)
    for record in reversed(state['created']):
        current = json.loads(kubectl('get', record['kind'], record['name'], '--ignore-not-found', '-o', 'json') or 'null')
        if current is None:
            continue
        if current['metadata']['uid'] != record['uid'] or current['metadata'].get('annotations', {}).get(OWNER) != state['owner']:
            raise RuntimeError('리소스 소유권 변경: 자동 삭제 중단')
        # Raw DeleteOptions keeps UID/resourceVersion preconditions atomic at the API server.
        plural = {'ConfigMap': 'configmaps', 'Service': 'services', 'Deployment': 'deployments'}[record['kind']]
        base = '/apis/apps/v1' if record['kind'] == 'Deployment' else '/api/v1'
        options = {'apiVersion': 'v1', 'kind': 'DeleteOptions', 'propagationPolicy': 'Foreground',
                   'preconditions': {'uid': record['uid'], 'resourceVersion': current['metadata']['resourceVersion']}}
        kubectl('delete', '--raw', f'{base}/namespaces/{NS}/{plural}/{record["name"]}', '-f', '-',
                input_text=json.dumps(options))
    state['stage'] = 'rolled-back'
    state['pending'] = None
    save(directory, state)


def apply(directory):
    state = load(directory)
    if state['stage'] != 'planned':
        raise RuntimeError('반복 apply 금지: status 또는 rollback 사용')
    bundle = json.loads((directory / 'resources.json').read_text(encoding='utf-8'))
    if fingerprint(bundle) != state['bundle_hash']:
        raise RuntimeError('계획 파일 변경됨: 새 plan 필요')
    edge, public = preflight()
    if (fingerprint(edge['spec']['template']) != state['edge_hash']
            or fingerprint(public['data']) != state['public_hash']):
        raise RuntimeError('공개 설정이 계획 후 변경됨: 새 plan 필요')
    validate_nginx(bundle['items'][0]['data']['nginx.conf'])
    state['stage'] = 'creating'
    save(directory, state)
    try:
        for item in bundle['items']:
            # Create-only. A conflicting resource is never overwritten or adopted.
            state['pending'] = {'kind': item['kind'], 'name': item['metadata']['name']}
            save(directory, state)
            result = json.loads(kubectl('create', '-f', '-', '-o', 'json', input_text=json.dumps(item)))
            state['created'].append({'kind': item['kind'], 'name': item['metadata']['name'], 'uid': result['metadata']['uid']})
            state['pending'] = None
            save(directory, state)
        kubectl('rollout', 'status', 'deployment/' + APP, '--timeout=180s')
        stable_pods(APP, 'edge')
    except Exception:
        try:
            rollback(directory, state)
            print('생성 실패: 이 계획에서 생성한 리소스만 제거했습니다.', file=sys.stderr)
        except Exception:
            print('자동 복구 미완료: 작업 폴더를 보존하고 status/rollback을 확인하세요.', file=sys.stderr)
        raise
    state['stage'] = 'applied-needs-pfsense-n8n-tests'
    save(directory, state)
    print('생성 완료. 아직 pfSense NAT/SNAT, n8n CA/토큰 및 외부 차단 시험이 필요합니다.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'apply', 'status', 'rollback'])
    parser.add_argument('--work-dir', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('PC1 Ubuntu VM에서 실행하세요.')
    os.umask(0o077)
    if args.action == 'plan':
        directory = args.work_dir or Path.home() / '.local/state/telecom-automation' / uuid.uuid4().hex
        plan(directory)
    else:
        if not args.work_dir:
            parser.error('--work-dir 필요')
        directory = args.work_dir.resolve()
        if args.action == 'apply':
            apply(directory)
        elif args.action == 'rollback':
            rollback(directory, load(directory))
        else:
            state = load(directory)
            print('Stage:', state['stage'])
            print(kubectl('get', 'deployment,service,pods', '-l', 'app=' + APP, '-o', 'wide'))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
