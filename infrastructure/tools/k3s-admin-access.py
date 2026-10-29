#!/usr/bin/env python3
"""Enable session/ADMIN authorization on the academy public edge; no DB changes."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

NAMESPACE = 'telecom'
CONFIGMAP = 'telecom-edge-config'
DEPLOYMENT = 'telecom-edge'
KEY = 'nginx.conf'
TOKEN = re.compile(r'''\s+|\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[{};]|[^\s{};\#"']+''')
ADMIN_HEADERS = {
    ('=', '/admin'), ('^~', '/admin/'), ('=', '/api/admin'),
    ('^~', '/api/admin/'), ('~', '^/api/admin/'), ('~*', '^/api/admin/'),
}
AUDIT = r'''
import inspect, json
from wsgi import app
bad = []
count = 0
for rule in app.url_map.iter_rules():
    if not (rule.rule == '/api/admin' or rule.rule.startswith('/api/admin/')):
        continue
    count += 1
    fn = app.view_functions[rule.endpoint]
    protected = False
    while fn is not None:
        code = getattr(fn, '__code__', None)
        if code and code.co_name == 'wrapper' and code.co_filename.endswith('/core/permissions.py'):
            if inspect.getclosurevars(fn).nonlocals.get('roles') == ('ADMIN',):
                protected = True
        fn = getattr(fn, '__wrapped__', None)
    if not protected:
        bad.append(rule.rule)
if not count or bad:
    raise SystemExit('Missing ADMIN route protection: ' + str(bad))
with app.test_client() as client:
    status = client.get('/api/admin/dashboard', base_url='https://192.168.3.30').status_code
if status != 401:
    raise SystemExit('Expected anonymous 401, got ' + str(status))
print('ADMIN_AUDIT=' + json.dumps({'routes': count, 'anonymous': status}))
'''


def kubectl(*args, input_text=None):
    result = subprocess.run(['sudo', '-n', 'k3s', 'kubectl', '-n', NAMESPACE, *args],
                            input=input_text, text=True, capture_output=True)
    if result.returncode:
        # Do not print imported application errors or credentials to shared output.
        raise RuntimeError('kubectl failed: ' + ' '.join(args[:3]) + '; exit=' + str(result.returncode))
    return result.stdout


def get(kind, name=None):
    return json.loads(kubectl('get', kind, *([name] if name else []), '-o', 'json'))


def locations(text):
    tokens = []
    offset = 0
    for match in TOKEN.finditer(text):
        if match.start() != offset:
            raise ValueError('Unsupported Nginx syntax; no automatic edit.')
        offset = match.end()
        value = match.group()
        if value.isspace() or value.startswith('#'):
            continue
        tokens.append((value, match.start(), match.end()))
    if offset != len(text):
        raise ValueError('Incomplete Nginx token; no automatic edit.')
    stack, closing = [], {}
    for i, token in enumerate(tokens):
        if token[0] == '{':
            stack.append(i)
        elif token[0] == '}':
            if not stack:
                raise ValueError('Unbalanced Nginx braces.')
            closing[stack.pop()] = i
    if stack:
        raise ValueError('Unbalanced Nginx braces.')
    result = []
    for i, token in enumerate(tokens):
        if token[0] != 'location' or (i and tokens[i - 1][0] not in ('{', '}', ';')):
            continue
        start = i + 1
        while start < len(tokens) and tokens[start][0] not in ('{', ';', '}'):
            start += 1
        if start not in closing:
            raise ValueError('Unsupported location directive.')
        end = closing[start]
        result.append((tuple(t[0] for t in tokens[i + 1:start]),
                       tuple(t[0] for t in tokens[start + 1:end]), token[1], tokens[end][2]))
    return result


def validate_routes(text):
    blocks = locations(text)
    for header in (('=', '/api/internal'), ('^~', '/api/internal/')):
        if not any(h == header and body == ('return', '404', ';') for h, body, _, _ in blocks):
            raise ValueError('Required /api/internal 404 block is missing or different.')
    for header, upstream in ((('/api/',), 'http://telecom-api:5000'), (('/',), 'http://telecom-web:80')):
        bodies = [body for h, body, _, _ in blocks if h == header]
        if len(bodies) != 1 or not any(bodies[0][i:i + 3] == ('proxy_pass', upstream, ';')
                                        for i in range(len(bodies[0]))):
            raise ValueError('Unexpected public API/web upstream; inspect manually.')


def candidate_config(text):
    validate_routes(text)
    spans = []
    for header, body, start, end in locations(text):
        if any('admin' in value.lower() for value in header):
            if header not in ADMIN_HEADERS or body != ('return', '404', ';'):
                raise ValueError('Unknown admin location; refusing to change it: ' + str(header))
            spans.append((start, end))
    if not spans:
        raise ValueError('No known admin 404 blocks found; inspect the current policy first.')
    updated = text
    for start, end in reversed(spans):
        updated = updated[:start] + updated[end:]
    validate_routes(updated)
    return updated, len(spans)


def template_hash(deployment):
    return hashlib.sha256(json.dumps(deployment['spec']['template'], sort_keys=True).encode()).hexdigest()


def ready(pod, container):
    return (not pod['metadata'].get('deletionTimestamp') and pod.get('status', {}).get('phase') == 'Running'
            and any(c.get('name') == container and c.get('ready') is True
                    for c in pod.get('status', {}).get('containerStatuses', [])))


def pods(app):
    return json.loads(kubectl('get', 'pods', '-l', 'app=' + app, '-o', 'json'))['items']


def prepared_pods(app, container):
    items = pods(app)
    if len(items) != 2 or not all(ready(pod, container) for pod in items):
        raise RuntimeError('Need two stable Ready pods: ' + app)
    return items


def audit_api():
    for pod in prepared_pods('telecom-api', 'api'):
        output = kubectl('exec', '-i', pod['metadata']['name'], '-c', 'api', '--', 'python', '-', input_text=AUDIT)
        reports = [json.loads(line[len('ADMIN_AUDIT='):]) for line in output.splitlines() if line.startswith('ADMIN_AUDIT=')]
        if len(reports) != 1 or reports[0].get('anonymous') != 401 or reports[0].get('routes', 0) < 1:
            raise RuntimeError('API authorization audit did not pass.')
        print(pod['metadata']['name'], 'ADMIN audit:', reports[0])


def edge_snapshot():
    deployment = get('deployment', DEPLOYMENT)
    if deployment['spec'].get('replicas') != 2:
        raise RuntimeError('Expected two public edge replicas.')
    users = []
    for item in get('deployments')['items']:
        if any(v.get('configMap', {}).get('name') == CONFIGMAP
               for v in item['spec']['template']['spec'].get('volumes', [])):
            users.append(item['metadata']['name'])
    if users != [DEPLOYMENT]:
        raise RuntimeError('ConfigMap is missing or shared by other deployments: ' + str(users))
    prepared_pods(DEPLOYMENT, 'edge')
    return deployment


def validate_nginx(text):
    for pod in prepared_pods(DEPLOYMENT, 'edge'):
        name = pod['metadata']['name']
        path = '/tmp/telecom-admin-' + uuid.uuid4().hex + '.conf'
        try:
            kubectl('exec', '-i', name, '-c', 'edge', '--', 'sh', '-c',
                    'umask 077; cat > ' + path, input_text=text)
            kubectl('exec', name, '-c', 'edge', '--', 'nginx', '-t', '-c', path)
        finally:
            kubectl('exec', name, '-c', 'edge', '--', 'rm', '-f', path)


def write_json(path, value):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(path)


def read_config(path):
    with path.open(encoding='utf-8', newline='') as stream:
        return stream.read()


def write_config(path, text):
    with path.open('w', encoding='utf-8', newline='') as stream:
        stream.write(text)


def refresh_edge(snapshot):
    originals = [pod['metadata']['name'] for pod in prepared_pods(DEPLOYMENT, 'edge')]
    # Recreate one pod at a time; required anti-affinity needs a free node slot.
    for name in originals:
        current = get('deployment', DEPLOYMENT)
        if template_hash(current) != snapshot['template_hash'] or current['metadata']['uid'] != snapshot['deployment_uid']:
            raise RuntimeError('Deployment changed concurrently; stop pod refresh.')
        prepared_pods(DEPLOYMENT, 'edge')
        kubectl('delete', 'pod', name, '--wait=true', '--timeout=60s')
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            items = pods(DEPLOYMENT)
            if len(items) == 2 and all(ready(pod, 'edge') for pod in items):
                break
            time.sleep(2)
        else:
            raise RuntimeError('Public edge replacement did not become Ready; inspect pods.')


def patch_config(current, text, directory):
    patch = {'metadata': {'resourceVersion': current['metadata']['resourceVersion']}, 'data': {KEY: text}}
    write_json(directory / 'patch.json', patch)
    kubectl('patch', 'configmap', CONFIGMAP, '--type=merge', '--patch-file', str(directory / 'patch.json'))


def load_state(directory):
    state = json.loads((directory / 'state.json').read_text())
    if state.get('format') != 'telecom-admin-access-v1':
        raise ValueError('Unknown state format.')
    return state


def rollback(directory, state):
    current = get('configmap', CONFIGMAP)
    before = json.loads((directory / 'before.json').read_text())
    candidate = read_config(directory / 'candidate.conf')
    if current['metadata']['uid'] != before['metadata']['uid'] or current['data'][KEY] not in (before['data'][KEY], candidate):
        raise RuntimeError('ConfigMap changed concurrently; refusing rollback overwrite.')
    patch_config(current, before['data'][KEY], directory)
    state['stage'] = 'config-restored-refresh-pending'
    write_json(directory / 'state.json', state)
    refresh_edge(state)
    state['stage'] = 'rolled-back'
    write_json(directory / 'state.json', state)


def plan(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    audit_api()
    deployment = edge_snapshot()
    before = get('configmap', CONFIGMAP)
    candidate, count = candidate_config(before['data'][KEY])
    validate_nginx(candidate)
    write_json(directory / 'before.json', before)
    write_config(directory / 'candidate.conf', candidate)
    state = {'format': 'telecom-admin-access-v1', 'stage': 'planned',
             'deployment_uid': deployment['metadata']['uid'], 'template_hash': template_hash(deployment)}
    write_json(directory / 'state.json', state)
    (Path.home() / '.telecom-admin-access-workdir').write_text(str(directory))
    print(''.join(difflib.unified_diff(before['data'][KEY].splitlines(True), candidate.splitlines(True),
                                       fromfile='before', tofile='candidate')))
    print('PLAN OK; admin 404 blocks removed:', count)
    print('WORK_DIR=' + str(directory))
    print('Service configuration unchanged. Candidate passed nginx -t on both edge pods.')


def apply(directory):
    state = load_state(directory)
    if state['stage'] != 'planned':
        raise RuntimeError('Do not repeat apply; inspect status or rollback.')
    before = json.loads((directory / 'before.json').read_text())
    candidate, _ = candidate_config(before['data'][KEY])
    if candidate != read_config(directory / 'candidate.conf'):
        raise ValueError('Candidate was modified after planning.')
    audit_api()
    deployment = edge_snapshot()
    current = get('configmap', CONFIGMAP)
    if (deployment['metadata']['uid'] != state['deployment_uid'] or template_hash(deployment) != state['template_hash']
            or current['metadata']['uid'] != before['metadata']['uid']
            or current['metadata']['resourceVersion'] != before['metadata']['resourceVersion']
            or current['data'][KEY] != before['data'][KEY]):
        raise RuntimeError('Configuration changed after planning; create a fresh plan.')
    validate_nginx(candidate)
    patch_config(current, candidate, directory)
    state['stage'] = 'config-updated-refresh-pending'
    write_json(directory / 'state.json', state)
    try:
        refresh_edge(state)
    except Exception:
        try:
            rollback(directory, state)
            print('Refresh failed; original policy restored.', file=sys.stderr)
        except Exception:
            print('Recovery incomplete; keep this work directory and inspect pods before retrying.', file=sys.stderr)
        raise
    state['stage'] = 'applied-needs-role-tests'
    write_json(directory / 'state.json', state)
    print('APPLIED: same public URL now forwards admin requests to server authorization.')
    print('Verify anonymous 401, CUSTOMER 403, ADMIN 200 and internal API 404 from another academy PC.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'apply', 'status', 'rollback'))
    parser.add_argument('--work-dir', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Run this tool in the PC1 Ubuntu VM, not Windows.')
    os.umask(0o077)
    if args.action == 'plan':
        directory = args.work_dir or Path.home() / '.local/state/telecom-admin-access' / (time.strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
        plan(directory)
        return
    if not args.work_dir:
        parser.error('--work-dir is required for apply/status/rollback')
    directory = args.work_dir.resolve()
    state = load_state(directory)
    if args.action == 'apply':
        apply(directory)
    elif args.action == 'rollback':
        rollback(directory, state)
        print('ROLLED BACK: original public admin blocking restored.')
    else:
        current = get('configmap', CONFIGMAP)
        print('Stage:', state['stage'])
        print('Config matches candidate:', current['data'][KEY] == read_config(directory / 'candidate.conf'))
        print('Ready public edge pods:', sum(ready(pod, 'edge') for pod in pods(DEPLOYMENT)))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        raise SystemExit(1)
