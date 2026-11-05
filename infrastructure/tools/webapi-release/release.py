"""Import clean web/API images; apply Ubuntu env without changing database roles."""
import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tarfile

K = ['sudo', 'k3s', 'kubectl', '-n', 'telecom']
TARGETS = {'telecom-api': ('api', 'backend'), 'telecom-web': ('web', 'frontend')}


def command(argv, data=None):
    result = subprocess.run(argv, input=None if data is None else json.dumps(data),
                            capture_output=True, text=True, encoding='utf-8')
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(argv[:5]) + ' (private output withheld)')
    return result.stdout


def k(args, data=None):
    return command(K + args, data)


def private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(data, stream)


def archive_config_ids(archive, image_id, revision):
    """Resolve an OCI index/manifest or legacy Docker config to config digests."""
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
        raise RuntimeError('Invalid source image digest')
    with tarfile.open(archive, 'r:*') as stream:
        members = {m.name.removeprefix('./'): m for m in stream.getmembers() if m.isfile()}
        visited = set()
        configs = set()

        def visit(digest):
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
                raise RuntimeError('Invalid archive descriptor digest')
            if digest in visited:
                return
            visited.add(digest)
            hex_digest = digest.split(':', 1)[1]
            member = next((members[n] for n in ('blobs/sha256/' + hex_digest, hex_digest + '.json')
                           if n in members), None)
            if member is None or member.size > 16 * 1024 * 1024:
                raise RuntimeError('Image descriptor/config missing or too large')
            raw = stream.extractfile(member).read()
            if hashlib.sha256(raw).hexdigest() != hex_digest:
                raise RuntimeError('Image descriptor/config SHA256 mismatch')
            node = json.loads(raw)
            if 'manifests' in node:
                for descriptor in node['manifests']:
                    platform = descriptor.get('platform', {})
                    if platform and (platform.get('os'), platform.get('architecture')) != ('linux', 'amd64'):
                        continue
                    visit(descriptor['digest'])
            elif isinstance(node.get('config'), dict) and 'digest' in node['config']:
                visit(node['config']['digest'])
            elif 'rootfs' in node:
                if (node.get('os'), node.get('architecture')) != ('linux', 'amd64'):
                    return
                labels = node.get('config', {}).get('Labels') or {}
                if labels.get('org.opencontainers.image.revision') != revision:
                    raise RuntimeError('Archive image source revision mismatch')
                configs.add(digest)
            else:
                raise RuntimeError('Unsupported image descriptor')

        visit(image_id)
        if not configs:
            raise RuntimeError('No matching linux/amd64 image config in archive')
        return configs


def validate_runtime_image(found, expected_image, config_ids, revision):
    def normalize(name):
        return name.removeprefix('docker.io/').removeprefix('library/')

    status = found.get('status', {})
    if status.get('id') not in config_ids:
        raise RuntimeError('Imported image config digest mismatch')
    if normalize(expected_image) not in {normalize(tag) for tag in status.get('repoTags', [])}:
        raise RuntimeError('Imported image tag mismatch')

    def revisions(value):
        result = set()
        if isinstance(value, dict):
            item = value.get('org.opencontainers.image.revision')
            if isinstance(item, str):
                result.add(item)
            for item in value.values():
                result.update(revisions(item))
        elif isinstance(value, list):
            for item in value:
                result.update(revisions(item))
        return result

    if revisions(found) != {revision}:
        raise RuntimeError('Imported image source revision mismatch')


def pods(app):
    items = json.loads(k(['get', 'pods', '-l', 'app=' + app, '-o', 'json']))['items']
    items = [p for p in items if not p['metadata'].get('deletionTimestamp')]
    if len(items) != 2 or {p['spec']['nodeName'] for p in items} != {'pc1-k3s', 'pc2-k3s'}:
        raise RuntimeError(app + ': need exactly one Pod per node')
    if any(not any(c['type'] == 'Ready' and c['status'] == 'True'
                   for c in p.get('status', {}).get('conditions', [])) for p in items):
        raise RuntimeError(app + ': some Pods are not Ready')
    return items


PROBE = r'''
import json, os, sys
from pathlib import Path
from sqlalchemy.engine import make_url
from wsgi import app
from dotenv import dotenv_values
url = make_url(app.config['SQLALCHEMY_DATABASE_URI'])
keys = json.load(sys.stdin)
protected = {
 'DB_HOST': url.host, 'DB_PORT': str(url.port or 3306),
 'DB_NAME': url.database, 'DB_USER': url.username, 'DB_PASSWORD': url.password,
 'APP_ENV': app.config.get('APP_ENV', 'lab'),
 'INCIDENT_API_TOKEN': app.config.get('INCIDENT_API_TOKEN', ''),
 'AUTOMATION_API_TOKEN': app.config.get('AUTOMATION_API_TOKEN', '')}
file_values = dict(dotenv_values('/app/.env', interpolate=False)) if Path('/app/.env').is_file() else {}
print('PRIVATE_RELEASE:' + json.dumps({'protected': protected,
 'env': {key: os.getenv(key) for key in keys},
 'file': {key: file_values.get(key) for key in keys}}))
'''


def probe(pod, keys=()):
    output = k(['exec', '-i', pod, '-c', 'api', '--', 'python', '-c', PROBE], list(keys))
    records = [s.split(':', 1)[1] for s in output.splitlines() if s.startswith('PRIVATE_RELEASE:')]
    if len(records) != 1:
        raise RuntimeError('Cannot inspect Flask configuration')
    return json.loads(records[0])


def encode_env(values):
    # Single quotes avoid interpreting JSON-only escapes or expanding dollar references.
    return ''.join(key + "='" + value.replace('\\', '\\\\').replace("'", "\\'") + "'\n"
                   for key, value in sorted(values.items()))


def merged_values(values, protected):
    if any(not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or not isinstance(value, str)
           or '\x00' in value or '${' in value for key, value in values.items()):
        raise RuntimeError('Invalid env entry, NUL or ${...} reference. Review files locally.')
    result = {key: value for key, value in values.items() if not key.startswith(('DB_', 'MYSQL_'))
              and key not in ('DATABASE_URL', 'SQLALCHEMY_DATABASE_URI')}
    result.update(protected)
    result['TRUSTED_PROXY_HOPS'] = '1'
    result['PUBLIC_BASE_URL'] = 'https://192.168.3.30'
    return result


def make_template(before, name, metadata, secret_name=None, values=None):
    template = copy.deepcopy(before['spec']['template'])
    spec = template['spec']
    container_name, image_key = TARGETS[name]
    matching = [c for c in spec['containers'] if c['name'] == container_name]
    if len(matching) != 1:
        raise RuntimeError('Unexpected container identity: ' + name)
    container = matching[0]
    container['image'] = metadata[image_key]
    container['imagePullPolicy'] = 'Never'
    template.setdefault('metadata', {}).setdefault('annotations', {})['telecom.loop/source-commit'] = metadata['source_commit']
    if values is not None:
        # Avoid old explicit env entries taking priority over new values.
        container['env'] = [e for e in container.get('env', []) if e['name'] not in values]
        container['env'] += [{'name': key, 'valueFrom': {'secretKeyRef': {'name': secret_name, 'key': key}}}
                             for key in sorted(values)]
        # Replace whichever previous release mounted /app/.env; keep other mounts.
        mounts = [m for m in container.get('volumeMounts', []) if m['mountPath'] != '/app/.env']
        mounts.append({'name': 'clean-release-env', 'mountPath': '/app/.env', 'subPath': '.env', 'readOnly': True})
        container['volumeMounts'] = mounts
        spec['volumes'] = [v for v in spec.get('volumes', []) if v['name'] != 'clean-release-env']
        spec['volumes'].append({'name': 'clean-release-env', 'secret': {
            'secretName': secret_name, 'defaultMode': 0o444,
            'items': [{'key': '.env', 'path': '.env'}]}})
    return template


def operations(current, template):
    return [
        {'op': 'test', 'path': '/metadata/resourceVersion', 'value': current['metadata']['resourceVersion']},
        {'op': 'replace', 'path': '/spec/template', 'value': template},
        {'op': 'replace', 'path': '/spec/strategy', 'value': {
            'type': 'RollingUpdate', 'rollingUpdate': {'maxSurge': 0, 'maxUnavailable': 1}}},
    ]


def rollout(name):
    result = subprocess.run(K + ['rollout', 'status', 'deployment/' + name, '--timeout=300s'])
    if result.returncode:
        raise RuntimeError('Rollout incomplete: ' + name)


def edge_policy_tool():
    """Use the same fail-closed parser in the checkout and standalone release."""
    directory = Path(__file__).resolve().parent
    source = directory / 'k3s-admin-access.py'
    if not source.is_file() and directory.name == 'webapi-release':
        source = directory.parent / 'k3s-admin-access.py'
    if not source.is_file():
        raise RuntimeError('Missing k3s-admin-access.py in release package. Rebuild the package.')
    spec = importlib.util.spec_from_file_location('public_admin_guard', source)
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    return policy


def verify_admin_edge_policy():
    policy = edge_policy_tool()
    current = json.loads(k(['get', 'configmap', 'telecom-edge-config', '-o', 'json']))
    policy.assert_public_admin_blocked(current['data']['nginx.conf'])
    for pod in pods('telecom-edge'):
        config = k(['exec', pod['metadata']['name'], '-c', 'edge', '--', 'nginx', '-T'])
        policy.assert_public_admin_blocked(config)
    verify_proxy_edge_policy(policy)
    private_edge = json.loads(k(['get', 'deployment', 'telecom-admin-edge', '-o', 'json']))
    if private_edge.get('status', {}).get('readyReplicas', 0) < 1:
        raise RuntimeError('Private admin edge must have a Ready replica before release.')
    for pod in pods('telecom-api'):
        output = k(['exec', pod['metadata']['name'], '-c', 'api', '--', 'python', '-c', policy.AUDIT])
        reports = [json.loads(line[len('ADMIN_AUDIT='):]) for line in output.splitlines()
                   if line.startswith('ADMIN_AUDIT=')]
        if len(reports) != 1 or reports[0].get('anonymous') != 401 or reports[0].get('routes', 0) < 1:
            raise RuntimeError('API ADMIN authorization audit failed.')
    print('PASS: public admin/internal 404 policy and customer upstreams verified in ConfigMap and both Pods.')
    print('PASS: private admin edge Ready; API ADMIN protection verified. HTTP/login/PC/VPN tests still required.')


def verify_proxy_edge_policy(policy):
    """Also inspect the independently deployed public PROXY edge, when present."""
    found = k(['get', 'deployment', 'telecom-edge-proxytest', '--ignore-not-found', '-o', 'json'])
    if not found.strip():
        return
    directory = Path(__file__).resolve().parent
    source = directory / 'loop-client-ip-test.py'
    if not source.is_file() and directory.name == 'webapi-release':
        source = directory.parent / 'loop-client-ip-test.py'
    if not source.is_file():
        raise RuntimeError('Missing loop-client-ip-test.py in release package. Rebuild the package.')
    spec = importlib.util.spec_from_file_location('client_ip_policy', source)
    trial = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(trial)
    service = json.loads(k(['get', 'service', trial.TRIAL, '-o', 'json']))['spec']
    ports = service.get('ports', [])
    if (service.get('type') != 'NodePort' or service.get('externalTrafficPolicy') != 'Local'
            or service.get('selector') != {'app': trial.TRIAL} or len(ports) != 1
            or ports[0].get('port') != 443 or ports[0].get('protocol') != 'TCP'
            or ports[0].get('nodePort') != trial.NODEPORT or ports[0].get('targetPort') != trial.LISTENER):
        raise RuntimeError('Unexpected PROXY public Service routing')
    current = json.loads(k(['get', 'configmap', trial.CM, '-o', 'json']))
    peer = trial.assert_proxy_config(current['data']['nginx.conf'], policy)
    for pod in pods(trial.TRIAL):
        effective = k(['exec', pod['metadata']['name'], '-c', 'edge', '--', 'nginx', '-T'])
        trial.assert_proxy_config(effective, policy, expected_peer=peer)
    print('PASS: PROXY public edge Local routing, exact peer, denials and both effective Pods verified.')


def verify(directory, metadata):
    state = json.loads((directory / 'deployment-state.json').read_text(encoding='utf-8'))
    expected = state['expected']
    for name, (container, key) in TARGETS.items():
        if state.get('mode') == 'images-only':
            current = json.loads(k(['get', 'deployment', name, '-o', 'json']))
            before = state['before'][name]['spec']['template']['spec']
            after = current['spec']['template']['spec']
            if environment_spec(before) != environment_spec(after):
                raise RuntimeError('Existing environment references or mounts changed: ' + name)
        for pod in pods(name):
            actual_image = next(c['image'] for c in pod['spec']['containers'] if c['name'] == container)
            if actual_image != metadata[key]:
                raise RuntimeError('Unexpected running image: ' + pod['metadata']['name'])
            if name == 'telecom-api':
                found = probe(pod['metadata']['name'], expected)
                differing = sorted(key for key in expected if found['env'].get(key) != expected[key]
                                   or found['file'].get(key) != expected[key])
                if differing:
                    raise RuntimeError('Env mismatch keys only: ' + ', '.join(differing))
                if found['protected'] != state['protected']:
                    raise RuntimeError('Effective DB or protected token configuration changed')
            env_status = '; ENV_SETTINGS_PRESERVED=True; DB=PC2/webuser' if state.get('mode') == 'images-only' else '; ENV_MATCH=True; DB=PC2/webuser'
            print('PASS:', pod['metadata']['name'], 'image verified' + (env_status if name == 'telecom-api' else ''))
    verify_admin_edge_policy()
    print('SOURCE_COMMIT:', metadata['source_commit'])
    print('PASS: web/API images and Ubuntu environment verified. No DB role/schema changes.')


def environment_spec(spec):
    return {'volumes': spec.get('volumes', []), 'containers': {
        c['name']: {key: c.get(key, []) for key in ('env', 'envFrom', 'volumeMounts')}
        for c in spec['containers']}}


def apply_images(directory, metadata):
    """Replace images while keeping all current env references and mounts."""
    state_path = directory / 'deployment-state.json'
    if state_path.exists():
        raise RuntimeError('This release was already started. Use verify; do not apply again.')
    if not (directory / 'import-ok.json').is_file():
        raise RuntimeError('Run import on BOTH Ubuntu VMs first')
    verify_admin_edge_policy()
    deployments = {name: json.loads(k(['get', 'deployment', name, '-o', 'json'])) for name in TARGETS}
    for name, item in deployments.items():
        if item['spec'].get('replicas') != 2 or item.get('status', {}).get('readyReplicas') != 2:
            raise RuntimeError(name + ' must have two Ready replicas')
        pods(name)
    live = [probe(p['metadata']['name'])['protected'] for p in pods('telecom-api')]
    if live[0] != live[1]:
        raise RuntimeError('Current API DB/token settings differ between Pods')
    protected = live[0]
    if (protected['DB_HOST'], protected['DB_USER'], protected['DB_NAME']) != ('192.168.3.19', 'webuser', 'my_new_board_db') or not protected['DB_PASSWORD']:
        raise RuntimeError('Expected current PC2/webuser connection not found')
    templates = {name: make_template(before, name, metadata) for name, before in deployments.items()}
    for name in TARGETS:
        if environment_spec(templates[name]['spec']) != environment_spec(deployments[name]['spec']['template']['spec']):
            raise RuntimeError('Image-only operation attempted an environment change')
        k(['patch', 'deployment', name, '--type=json', '--patch-file=/dev/stdin', '--dry-run=server'],
          operations(deployments[name], templates[name]))
    state = {'mode': 'images-only', 'before': deployments, 'applied': {}, 'expected': {}, 'protected': protected}
    private(state_path, state)
    for name in TARGETS:
        current = json.loads(k(['get', 'deployment', name, '-o', 'json']))
        if current['spec']['template'] != deployments[name]['spec']['template'] or current['spec'].get('replicas') != 2:
            raise RuntimeError('Concurrent deployment detected: ' + name)
        applied = json.loads(k(['patch', 'deployment', name, '--type=json', '--patch-file=/dev/stdin', '-o', 'json'],
                               operations(current, templates[name])))
        state['applied'][name] = applied['spec']['template']
        private(state_path, state)
        rollout(name)
    verify(directory, metadata)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['import', 'check-import', 'apply', 'apply-images', 'verify', 'rollback'])
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(__file__).resolve().parent
    metadata = json.loads((directory / 'release.json').read_text(encoding='utf-8'))
    if not re.fullmatch(r'[0-9a-f]{40}', metadata['source_commit']) or not re.fullmatch(r'k3s-[0-9a-f]{12}-[0-9]{14}', metadata['tag']):
        raise RuntimeError('Invalid release metadata')
    for key in ('backend', 'frontend'):
        expected_image = 'docker.io/library/telecom-' + key + ':' + metadata['tag']
        if metadata[key] != expected_image:
            raise RuntimeError('Unexpected image name')
    if args.action in ('import', 'check-import'):
        digest = hashlib.sha256()
        with (directory / 'telecom-app.tar').open('rb') as archive:
            for block in iter(lambda: archive.read(1024 * 1024), b''):
                digest.update(block)
        if digest.hexdigest() != metadata['archive_sha256']:
            raise RuntimeError('Image archive checksum mismatch')
        if args.action == 'import':
            result = subprocess.run(['sudo', 'k3s', 'ctr', 'images', 'import', str(directory / 'telecom-app.tar')])
            if result.returncode:
                raise RuntimeError('Image import failed')
        for key in ('backend', 'frontend'):
            configs = archive_config_ids(directory / 'telecom-app.tar', metadata[key + '_id'], metadata['source_commit'])
            found = json.loads(command(['sudo', 'k3s', 'crictl', 'inspecti', metadata[key]]))
            validate_runtime_image(found, metadata[key], configs, metadata['source_commit'])
            print('PASS:', key, 'archive config digest, runtime tag and source commit match')
        private(directory / 'import-ok.json', {'tag': metadata['tag'], 'node': socket.gethostname()})
        print('PASS: archive SHA256 and both imported images verified')
        return
    if socket.gethostname() != 'pc1-k3s':
        raise RuntimeError('Run apply/verify/rollback on PC1 Ubuntu only')
    if args.action == 'apply-images':
        apply_images(directory, metadata)
        return
    state_path = directory / 'deployment-state.json'
    if args.action == 'verify':
        verify(directory, metadata)
        return
    if args.action == 'rollback':
        state = json.loads(state_path.read_text(encoding='utf-8'))
        pending = []
        for name in state['applied']:
            current = json.loads(k(['get', 'deployment', name, '-o', 'json']))
            if current['spec']['template'] != state['applied'][name]:
                raise RuntimeError('Another deployment occurred; rollback needs inspection: ' + name)
            pending.append((name, current))
        for name, current in reversed(pending):
            k(['patch', 'deployment', name, '--type=json', '--patch-file=/dev/stdin'],
              operations(current, state['before'][name]['spec']['template']))
            rollout(name)
        print('Previous web/API templates restored. Backups and Secrets retained.')
        return
    if state_path.exists():
        raise RuntimeError('This release was already started. Use verify or inspect; do not apply again.')
    if not (directory / 'import-ok.json').is_file():
        raise RuntimeError('Run import on BOTH Ubuntu VMs first')
    verify_admin_edge_policy()
    deployments = {name: json.loads(k(['get', 'deployment', name, '-o', 'json'])) for name in TARGETS}
    for name, item in deployments.items():
        if item['spec'].get('replicas') != 2 or item.get('status', {}).get('readyReplicas') != 2:
            raise RuntimeError(name + ' must have two Ready replicas')
        pods(name)
    api_pods = pods('telecom-api')
    live = [probe(p['metadata']['name'])['protected'] for p in api_pods]
    if live[0] != live[1]:
        raise RuntimeError('Current API DB/token settings differ between Pods')
    protected = live[0]
    if (protected['DB_HOST'], protected['DB_USER'], protected['DB_NAME']) != ('192.168.3.19', 'webuser', 'my_new_board_db') or not protected['DB_PASSWORD']:
        raise RuntimeError('Expected current PC2/webuser connection not found')
    repo = Path('/home/loop/telecom-security-project')
    texts = []
    for source in (repo / '.env', repo / 'backend/.env'):
        source.chmod(0o600)
        texts.append(source.read_text(encoding='utf-8-sig'))
    parse = "import json,sys; from io import StringIO; from dotenv import dotenv_values; values={}; [values.update(dotenv_values(stream=StringIO(s), interpolate=False)) for s in json.load(sys.stdin)]; print(json.dumps(dict(values)))"
    values = json.loads(k(['exec', '-i', api_pods[0]['metadata']['name'], '-c', 'api', '--', 'python', '-c', parse], texts))
    values = merged_values(values, protected)
    secret_name = 'telecom-clean-env-' + metadata['tag'][4:]
    secret = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': secret_name, 'namespace': 'telecom'},
              'type': 'Opaque', 'immutable': True,
              'data': {key: base64.b64encode(value.encode('utf-8')).decode('ascii') for key, value in values.items()}}
    secret['data']['.env'] = base64.b64encode(encode_env(values).encode('utf-8')).decode('ascii')
    templates = {name: make_template(before, name, metadata, secret_name,
                 values if name == 'telecom-api' else None) for name, before in deployments.items()}
    k(['create', '--dry-run=server', '-f', '-'], secret)
    for name in TARGETS:
        k(['patch', 'deployment', name, '--type=json', '--patch-file=/dev/stdin', '--dry-run=server'],
          operations(deployments[name], templates[name]))
    state = {'before': deployments, 'applied': {}, 'expected': values, 'protected': protected}
    private(state_path, state)
    k(['create', '-f', '-'], secret)
    for name in TARGETS:
        current = json.loads(k(['get', 'deployment', name, '-o', 'json']))
        if current['spec']['template'] != deployments[name]['spec']['template'] or current['spec'].get('replicas') != 2:
            raise RuntimeError('Concurrent deployment detected: ' + name)
        applied = json.loads(k(['patch', 'deployment', name, '--type=json', '--patch-file=/dev/stdin', '-o', 'json'],
                               operations(current, templates[name])))
        state['applied'][name] = applied['spec']['template']
        private(state_path, state)
        rollout(name)
        if name == 'telecom-api':
            for pod in pods(name):
                found = probe(pod['metadata']['name'], values)
                different = sorted(key for key in values if found['env'].get(key) != values[key] or found['file'].get(key) != values[key])
                if different or found['protected'] != protected:
                    raise RuntimeError('API env verification failed; mismatch keys only: ' + ', '.join(different))
    verify(directory, metadata)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('STOP:', str(error), file=sys.stderr)
        print('Keep both VMs running. Inspect before further deployment; do not print private state files.', file=sys.stderr)
        sys.exit(1)
