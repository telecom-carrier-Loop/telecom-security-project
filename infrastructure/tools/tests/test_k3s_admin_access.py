import contextlib
import functools
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'k3s-admin-access.py'
SPEC = importlib.util.spec_from_file_location('admin_access', MODULE)
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)

CONFIG = '''worker_processes auto;
pid /tmp/nginx.pid;
events { worker_connections 512; }
http {
  log_format edge '$remote_addr "$request_method $uri" $status';
  server {
    listen 8443 ssl;
    ssl_certificate /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;
    proxy_set_header X-Forwarded-Proto $scheme;
    location = /admin { return 404; }
    location ^~ /admin/ { return 404; }
    location = /api/admin { return 404; }
    location ^~ /api/admin/ { return 404; }
    location ~ ^/api/admin/ { return 404; }
    location = /api/internal { return 404; }
    location ^~ /api/internal/ { return 404; }
    location /api/ { proxy_pass http://telecom-api:5000; }
    location / { proxy_pass http://telecom-web:80; }
  }
}
'''


def pod(name, container):
    return {'metadata': {'name': name}, 'status': {'phase': 'Running',
            'containerStatuses': [{'name': container, 'ready': True}]}}


class Cluster:
    def __init__(self):
        self.config = {'metadata': {'uid': 'cm-uid', 'resourceVersion': '10'},
                       'data': {'nginx.conf': CONFIG, 'unrelated': 'preserve'}}
        self.deployment = {'metadata': {'uid': 'edge-uid', 'name': tool.DEPLOYMENT},
                           'spec': {'replicas': 2, 'template': {'spec': {'volumes': [
                               {'configMap': {'name': tool.CONFIGMAP}}]}}}}
        self.edge = [pod('edge-old-1', 'edge'), pod('edge-old-2', 'edge')]
        self.api = [pod('api-1', 'api'), pod('api-2', 'api')]
        self.audit_ok = True
        self.nginx_ok = True
        self.fail_delete_once = False
        self.calls = []
        self.patches = []
        self.deleted = []

    def __call__(self, *args, input_text=None):
        self.calls.append(args)
        if args[0] == 'get':
            if args[1] == 'configmap':
                return json.dumps(self.config)
            if args[1] == 'deployment':
                return json.dumps(self.deployment)
            if args[1] == 'deployments':
                return json.dumps({'items': [self.deployment]})
            if args[1] == 'pods':
                return json.dumps({'items': self.api if 'app=telecom-api' in args else self.edge})
        if args[0] == 'exec':
            if 'python' in args:
                return 'ADMIN_AUDIT=' + json.dumps({'routes': 42, 'anonymous': 401 if self.audit_ok else 200})
            if 'nginx' in args and not self.nginx_ok:
                raise RuntimeError('fixture nginx validation failed')
            return ''
        if args[0] == 'patch':
            if args[1:3] != ('configmap', tool.CONFIGMAP):
                raise AssertionError('Only the public configmap may change')
            payload = json.loads(Path(args[-1]).read_text())
            assert payload['metadata']['resourceVersion'] == self.config['metadata']['resourceVersion']
            assert list(payload['data']) == [tool.KEY]
            self.patches.append(payload)
            self.config['data'].update(payload['data'])
            self.config['metadata']['resourceVersion'] = str(int(self.config['metadata']['resourceVersion']) + 1)
            return 'patched'
        if args[0] == 'delete':
            assert args[1] == 'pod'
            if self.fail_delete_once:
                self.fail_delete_once = False
                raise RuntimeError('fixture pod refresh failure')
            assert sum(tool.ready(item, 'edge') for item in self.edge) == 2
            assert args[2] in [item['metadata']['name'] for item in self.edge]
            self.deleted.append(args[2])
            self.edge = [item for item in self.edge if item['metadata']['name'] != args[2]]
            self.edge.append(pod('edge-new-' + str(len(self.deleted)), 'edge'))
            return 'deleted'
        raise AssertionError('Unexpected cluster mutation: ' + str(args))


class ConfigTests(unittest.TestCase):
    def test_only_admin_denials_removed(self):
        candidate, count = tool.candidate_config(CONFIG)
        self.assertEqual(count, 5)
        for header, body, _, _ in tool.locations(CONFIG):
            if header in tool.ADMIN_HEADERS:
                continue
            self.assertIn((header, body), [(h, b) for h, b, _, _ in tool.locations(candidate)])
        self.assertIn('ssl_certificate_key /etc/nginx/tls/tls.key;', candidate)
        self.assertIn('proxy_set_header X-Forwarded-Proto $scheme;', candidate)

    def test_comments_and_quoted_braces_do_not_change_parse(self):
        text = '# location = /admin { return 404; }\n' + CONFIG.replace(
            "log_format edge", "# } ignored comment\n  log_format edge")
        text = text.replace('$status\';', '$status {quoted}\';')
        candidate, count = tool.candidate_config(text)
        self.assertEqual(count, 5)
        self.assertTrue(candidate.startswith('# location = /admin { return 404; }'))

    def test_unknown_or_extra_admin_behavior_rejected(self):
        for changed in [CONFIG.replace('location = /admin { return 404; }',
                                       'location = /admin { allow 127.0.0.1; return 404; }'),
                        CONFIG.replace('location ^~ /admin/', 'location ~ /admin.*')]:
            with self.assertRaises(ValueError):
                tool.candidate_config(changed)

    def test_missing_internal_denial_or_wrong_upstream_rejected(self):
        for changed in [CONFIG.replace('location = /api/internal { return 404; }', ''),
                        CONFIG.replace('http://telecom-api:5000', 'http://other-api:5000')]:
            with self.assertRaises(ValueError):
                tool.candidate_config(changed)


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.test_root = (Path(__file__).resolve().parents[3] / 'tmp/admin-access-tests').resolve()
        self.test_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=self.test_root)
        def cleanup():
            target = Path(self.temp.name).resolve()
            if target == self.test_root or self.test_root not in target.parents:
                raise RuntimeError('Refusing cleanup outside the test directory')
            self.temp.cleanup()
        self.addCleanup(cleanup)
        self.directory = Path(self.temp.name) / 'plan'
        self.cluster = Cluster()
        self.addCleanup(patch.stopall)
        patch.object(tool, 'kubectl', self.cluster).start()
        patch.object(tool.Path, 'home', return_value=Path(self.temp.name)).start()
        patch('sys.stdout', new=io.StringIO()).start()

    def test_plan_apply_preserves_internal_and_other_resources(self):
        tool.plan(self.directory)
        self.assertFalse(self.cluster.patches)
        self.assertFalse(self.cluster.deleted)
        tool.apply(self.directory)
        self.assertEqual(len(self.cluster.patches), 1)
        self.assertEqual(self.cluster.deleted, ['edge-old-1', 'edge-old-2'])
        self.assertEqual(tool.load_state(self.directory)['stage'], 'applied-needs-role-tests')
        self.assertEqual(self.cluster.config['data']['unrelated'], 'preserve')
        tool.validate_routes(self.cluster.config['data'][tool.KEY])
        self.assertFalse(any('secret' in call for call in self.cluster.calls))
        tool.rollback(self.directory, tool.load_state(self.directory))
        self.assertEqual(self.cluster.config['data'][tool.KEY], CONFIG)
        self.assertEqual(tool.load_state(self.directory)['stage'], 'rolled-back')

    def test_bad_authorization_or_nginx_never_patches(self):
        self.cluster.audit_ok = False
        with self.assertRaises(RuntimeError):
            tool.plan(self.directory)
        self.assertFalse(self.cluster.patches)
        self.cluster.audit_ok = True
        self.cluster.nginx_ok = False
        with self.assertRaises(RuntimeError):
            tool.plan(Path(self.temp.name) / 'other')
        self.assertFalse(self.cluster.patches)

    def test_stale_plan_and_tampered_candidate_never_patch(self):
        tool.plan(self.directory)
        self.cluster.config['metadata']['resourceVersion'] = '11'
        with self.assertRaises(RuntimeError):
            tool.apply(self.directory)
        self.cluster.config['metadata']['resourceVersion'] = '10'
        (self.directory / 'candidate.conf').write_text('tampered')
        with self.assertRaises(ValueError):
            tool.apply(self.directory)
        self.assertFalse(self.cluster.patches)

    def test_crlf_config_round_trip(self):
        self.cluster.config['data'][tool.KEY] = CONFIG.replace('\n', '\r\n')
        tool.plan(self.directory)
        tool.apply(self.directory)
        self.assertIn('\r\n', self.cluster.config['data'][tool.KEY])
        self.assertEqual(tool.load_state(self.directory)['stage'], 'applied-needs-role-tests')

    def test_refresh_failure_restores_original_configuration(self):
        tool.plan(self.directory)
        self.cluster.fail_delete_once = True
        with self.assertRaises(RuntimeError):
            tool.apply(self.directory)
        self.assertEqual(self.cluster.config['data'][tool.KEY], CONFIG)
        self.assertEqual(tool.load_state(self.directory)['stage'], 'rolled-back')

    def test_concurrent_config_edit_blocks_rollback(self):
        tool.plan(self.directory)
        tool.apply(self.directory)
        self.cluster.config['data'][tool.KEY] += '\n# peer change\n'
        count = len(self.cluster.patches)
        with self.assertRaises(RuntimeError):
            tool.rollback(self.directory, tool.load_state(self.directory))
        self.assertEqual(len(self.cluster.patches), count)


class AuditTests(unittest.TestCase):
    def audit(self, protected=True, status=401):
        namespace = {'wraps': functools.wraps}
        exec(compile('''def roles_required(*roles):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            if roles: return fn(*args, **kwargs)
        return wrapper
    return decorator
''', '/app/core/permissions.py', 'exec'), namespace)
        fn = lambda: None
        if protected:
            fn = namespace['roles_required']('ADMIN')(fn)
        app = types.SimpleNamespace(
            url_map=types.SimpleNamespace(iter_rules=lambda: [types.SimpleNamespace(rule='/api/admin/dashboard', endpoint='dashboard')]),
            view_functions={'dashboard': fn},
            test_client=lambda: contextlib.nullcontext(types.SimpleNamespace(get=lambda *a, **kw: types.SimpleNamespace(status_code=status))))
        with patch.dict(sys.modules, {'wsgi': types.SimpleNamespace(app=app)}), contextlib.redirect_stdout(io.StringIO()) as output:
            exec(tool.AUDIT, {})
        return output.getvalue()

    def test_live_auditor_accepts_role_wrapper_and_anonymous_denial(self):
        self.assertIn('ADMIN_AUDIT=', self.audit())

    def test_live_auditor_rejects_unprotected_route_or_anonymous_access(self):
        with self.assertRaises(SystemExit):
            self.audit(protected=False)
        with self.assertRaises(SystemExit):
            self.audit(status=200)


if __name__ == '__main__':
    unittest.main()
