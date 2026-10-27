import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('automation_ingress', Path(__file__).resolve().parents[1] / 'k3s-automation-ingress.py')
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


def edge():
    return {'spec': {'template': {'spec': {
        'containers': [{'name': 'edge', 'image': 'nginx:cached',
                        'securityContext': {'readOnlyRootFilesystem': True},
                        'volumeMounts': [{'name': 'public-tls', 'mountPath': '/etc/nginx/tls'}]}],
        'volumes': [{'name': 'public-tls', 'secret': {'secretName': 'existing-public-cert'}}],
        'securityContext': {'runAsUser': 101, 'fsGroup': 101},
        'affinity': {'podAntiAffinity': {'old-public-selector': True}}}}}}


class ManifestTests(unittest.TestCase):
    def test_exact_routes_methods_and_headers_preserve_internal_path(self):
        config = tool.nginx_config()
        self.assertEqual(config.count('proxy_pass http://telecom-api:5000;'), 5)
        self.assertEqual(config.count('location = /api/internal/'), 5)
        self.assertNotIn('location /api/internal/', config)
        self.assertIn('if ($request_method != GET) { return 405; }', config)
        self.assertEqual(config.count('if ($request_method != POST)'), 4)
        for text in ['allow 192.168.3.30/32;', 'deny all;', 'location / { return 404; }',
                     'proxy_set_header Authorization $http_authorization;',
                     'proxy_set_header X-API-Key $http_x_api_key;', 'proxy_set_header Cookie "";',
                     'proxy_next_upstream off;']:
            self.assertIn(text, config)
        self.assertNotIn('$request_uri', config)  # no query strings in access log

    def test_isolated_resources_clone_only_image_tls_and_security(self):
        original = edge()
        before = copy.deepcopy(original)
        cm, deployment, service = tool.resources(original, 'owner-id')
        self.assertEqual(original, before)
        self.assertEqual(service['spec']['externalTrafficPolicy'], 'Local')
        self.assertEqual(service['spec']['ports'][0]['nodePort'], 30445)
        pod = deployment['spec']['template']['spec']
        self.assertFalse(pod['automountServiceAccountToken'])
        self.assertEqual(pod['volumes'][1]['secret']['secretName'], 'existing-public-cert')
        selector = pod['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution'][0]['labelSelector']
        self.assertEqual(selector['matchLabels']['app'], tool.APP)
        self.assertEqual(pod['containers'][0]['imagePullPolicy'], 'Never')
        self.assertNotIn('telecom-edge-config', json.dumps([cm, deployment, service]))

    def test_unexpected_tls_layout_is_rejected(self):
        source = edge()
        source['spec']['template']['spec']['volumes'][0] = {'name': 'public-tls', 'emptyDir': {}}
        with self.assertRaises(ValueError):
            tool.resources(source, 'owner-id')


class FlowTests(unittest.TestCase):
    def setUp(self):
        # Windows sandbox DACL does not support tempfile mode 0700; tests run with local approval.
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.state = {'format': 'automation-ingress-v1', 'owner': 'test-owner', 'stage': 'planned',
                      'created': [], 'edge_hash': tool.fingerprint(edge()['spec']['template']),
                      'public_hash': tool.fingerprint({'nginx.conf': 'public-original'})}
        self.bundle = {'apiVersion': 'v1', 'kind': 'List', 'items': tool.resources(edge(), 'test-owner')}
        self.state['bundle_hash'] = tool.fingerprint(self.bundle)
        (self.directory / 'resources.json').write_text(json.dumps(self.bundle), encoding='utf-8')
        tool.save(self.directory, self.state)

    def tearDown(self):
        # Explicit absolute target from TemporaryDirectory, no computed recursive shell deletion.
        self.temp.cleanup()

    def test_tampered_plan_never_runs_cluster_commands(self):
        self.bundle['items'][2]['spec']['externalTrafficPolicy'] = 'Cluster'
        (self.directory / 'resources.json').write_text(json.dumps(self.bundle), encoding='utf-8')
        with patch.object(tool, 'kubectl') as command, self.assertRaises(RuntimeError):
            tool.apply(self.directory)
        command.assert_not_called()

    def test_public_config_change_never_creates_resources(self):
        with patch.object(tool, 'preflight', return_value=(edge(), {'data': {'nginx.conf': 'changed'}})), \
             patch.object(tool, 'kubectl') as command, self.assertRaises(RuntimeError):
            tool.apply(self.directory)
        command.assert_not_called()

    def test_partial_create_failure_rolls_back_only_successful_creates(self):
        calls = []
        def command(*args, input_text=None):
            calls.append(args)
            if args[0] == 'create':
                item = json.loads(input_text)
                if item['kind'] == 'Deployment':
                    raise RuntimeError('create denied')
                item['metadata']['uid'] = 'created-uid'
                return json.dumps(item)
            if args[0] == 'get':
                if args[1] == 'Deployment':
                    return ''  # Failed create did not reach the server.
                return json.dumps({'metadata': {'uid': 'created-uid', 'resourceVersion': '9',
                                               'annotations': {tool.OWNER: 'test-owner'}}})
            if args[0] == 'delete':
                self.assertEqual(json.loads(input_text)['preconditions']['uid'], 'created-uid')
                return '{}'
            raise AssertionError(args)
        with patch.object(tool, 'preflight', return_value=(edge(), {'data': {'nginx.conf': 'public-original'}})), \
             patch.object(tool, 'validate_nginx'), patch.object(tool, 'kubectl', side_effect=command), \
             contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            tool.apply(self.directory)
        deletes = [c for c in calls if c[0] == 'delete']
        self.assertEqual(len(deletes), 1)
        self.assertIn('/configmaps/' + tool.APP + '-config', deletes[0][2])
        self.assertEqual(tool.load(self.directory)['stage'], 'rolled-back')

    def test_rollback_refuses_changed_uid(self):
        self.state['created'] = [{'kind': 'Service', 'name': tool.APP, 'uid': 'old'}]
        current = {'metadata': {'uid': 'new', 'annotations': {tool.OWNER: 'test-owner'}}}
        with patch.object(tool, 'kubectl', return_value=json.dumps(current)) as command, self.assertRaises(RuntimeError):
            tool.rollback(self.directory, self.state)
        self.assertEqual(command.call_count, 1)

    def test_response_lost_create_is_recovered_by_unique_owner(self):
        self.state['pending'] = {'kind': 'ConfigMap', 'name': tool.APP + '-config'}
        current = {'metadata': {'uid': 'response-lost', 'resourceVersion': '5',
                                'annotations': {tool.OWNER: 'test-owner'}}}
        with patch.object(tool, 'kubectl', return_value=json.dumps(current)) as command:
            tool.rollback(self.directory, self.state)
        deletes = [c for c in command.call_args_list if c.args[0] == 'delete']
        self.assertEqual(len(deletes), 1)
        self.assertEqual(json.loads(deletes[0].kwargs['input_text'])['preconditions']['uid'], 'response-lost')

    def test_success_creates_new_resources_without_patching_public_edge(self):
        calls = []
        def command(*args, input_text=None):
            calls.append(args)
            if args[0] == 'create':
                item = json.loads(input_text)
                item['metadata']['uid'] = 'uid-' + item['kind']
                return json.dumps(item)
            if args[0] == 'rollout':
                return ''
            raise AssertionError(args)
        with patch.object(tool, 'preflight', return_value=(edge(), {'data': {'nginx.conf': 'public-original'}})), \
             patch.object(tool, 'validate_nginx'), patch.object(tool, 'stable_pods'), \
             patch.object(tool, 'kubectl', side_effect=command), contextlib.redirect_stdout(io.StringIO()):
            tool.apply(self.directory)
        self.assertEqual([c[0] for c in calls], ['create', 'create', 'create', 'rollout'])
        self.assertEqual(tool.load(self.directory)['stage'], 'applied-needs-pfsense-n8n-tests')


class PreflightTests(unittest.TestCase):
    def test_network_policy_is_not_blindly_overridden(self):
        with patch.object(tool, 'get', return_value={'items': [{'metadata': {'name': 'existing-policy'}}]}), \
             patch.object(tool, 'kubectl') as command, self.assertRaisesRegex(RuntimeError, 'NetworkPolicy'):
            tool.preflight()
        command.assert_not_called()

    def test_nodeport_conflict_in_other_namespace_is_rejected(self):
        services = {'items': [{'spec': {'ports': [{'nodePort': 30445}]}}]}
        def command(*args, **kwargs):
            return json.dumps(services) if args[1] == 'services' else ''
        with patch.object(tool, 'get', return_value={'items': []}), \
             patch.object(tool, 'kubectl', side_effect=command), \
             patch.object(tool, 'audit_api') as audit, self.assertRaisesRegex(RuntimeError, '30445'):
            tool.preflight()
        audit.assert_not_called()


class AuditTests(unittest.TestCase):
    def audit(self, guarded=True, status=401, configured=True):
        routes = [types.SimpleNamespace(rule=p, methods={m}, endpoint=p) for p, (m, _) in tool.ROUTES.items()]
        class Client:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def open(self, *args, **kwargs): return types.SimpleNamespace(status_code=status)
        app = types.SimpleNamespace(config={k: 'not-a-real-token' if configured else '' for _, k in tool.ROUTES.values()},
                                    url_map=types.SimpleNamespace(iter_rules=lambda: iter(routes)),
                                    view_functions={r.endpoint: r.endpoint for r in routes}, test_client=Client)
        def source(path):
            key = tool.ROUTES[path][1]
            check = "workflow = check_automation_token(%r)" % key if guarded else 'write_to_db()'
            return 'def route():\n    from module import check_automation_token\n    ' + check + '\n    write_to_db()\n'
        output = io.StringIO()
        with patch.dict('sys.modules', {'wsgi': types.SimpleNamespace(app=app)}), \
             patch('inspect.getsource', side_effect=source), contextlib.redirect_stdout(output):
            exec(tool.AUDIT, {})
        return output.getvalue()

    def test_all_five_must_have_token_first_and_401(self):
        self.assertIn('"routes": 5', self.audit())
        for kwargs in [{'guarded': False}, {'status': 200}, {'configured': False}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(SystemExit):
                self.audit(**kwargs)


if __name__ == '__main__':
    unittest.main()
