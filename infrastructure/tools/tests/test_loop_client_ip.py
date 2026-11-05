import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


TOOLS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load('client_ip_trial', TOOLS / 'loop-client-ip-test.py')
policy = load('client_ip_admin_policy', TOOLS / 'k3s-admin-access.py')
PEER = '192.0.2.10'
CONFIG = '''events { worker_connections 512; }
http {
    server {
        listen 8443 ssl;
        ssl_certificate /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        proxy_set_header X-Forwarded-For $remote_addr;
        location = /edge-health { return 200; }
        location = /admin { return 404; }
        location ^~ /admin/ { return 404; }
        location = /api/admin { return 404; }
        location ^~ /api/admin/ { return 404; }
        location = /api/internal { return 404; }
        location ^~ /api/internal/ { return 404; }
        location /api/ { proxy_pass http://telecom-api-local:5000; }
        location / { proxy_pass http://telecom-web-local:80; }
    }
}
'''


def deployment():
    return {'spec': {'replicas': 2, 'selector': {'matchLabels': {'app': 'telecom-edge'}},
        'template': {'metadata': {'labels': {'app': 'telecom-edge'}}, 'spec': {
            'containers': [{'name': 'edge', 'image': 'example/edge:fixed',
                'imagePullPolicy': 'Never', 'command': ['nginx'],
                'ports': [{'name': 'https', 'containerPort': 8443}],
                'readinessProbe': {'httpGet': {'port': 'https', 'path': '/edge-health'}},
                'livenessProbe': {'httpGet': {'port': 'https', 'path': '/edge-health'}},
                'securityContext': {'readOnlyRootFilesystem': True}}],
            'securityContext': {'runAsNonRoot': True, 'runAsUser': 101},
            'volumes': [{'name': 'config', 'configMap': {'name': 'telecom-edge-config'}},
                {'name': 'tls', 'secret': {'secretName': 'existing-public-tls'}}]}}}}


class ClientIPTests(unittest.TestCase):
    def test_clone_retains_original_and_validates_both_listeners(self):
        result = tool.make_config(CONFIG, PEER)
        self.assertIn(CONFIG.split('    server {')[1].rsplit('\n}', 1)[0], result)
        self.assertEqual(tool.assert_proxy_config(result, policy), PEER)
        self.assertEqual(result.count('location = /api/admin { return 404; }'), 2)

    def test_policy_ignores_comments_but_not_commented_controls(self):
        config = tool.make_config(CONFIG, PEER)
        self.assertEqual(tool.assert_proxy_config('# diagnostic header\n' + config, policy), PEER)
        with self.assertRaises(RuntimeError):
            tool.assert_proxy_config(config.replace('real_ip_header proxy_protocol;',
                                                    '# real_ip_header proxy_protocol;'), policy)

    def test_widened_trust_missing_acl_or_changed_forwarding_is_rejected(self):
        config = tool.make_config(CONFIG, PEER)
        for changed in (
            config.replace(PEER + '/32', '0.0.0.0/0'),
            config.replace(f'if ($realip_remote_addr != {PEER}) {{ return 403; }}', ''),
            config.replace('proxy_set_header X-Forwarded-For $remote_addr;',
                           'proxy_set_header X-Forwarded-For $http_x_forwarded_for;', 1),
            config.replace('listen 8445 ssl proxy_protocol;', 'listen 8445 ssl;'),
            config.replace('location = /api/admin { return 404; }',
                           'location = /api/admin { return 200; }', 1),
        ):
            with self.subTest(config=changed), self.assertRaises((RuntimeError, ValueError)):
                tool.assert_proxy_config(changed, policy)

    def test_one_running_pod_with_another_peer_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'differs from ConfigMap'):
            tool.assert_proxy_config(tool.make_config(CONFIG, PEER), policy, '192.0.2.11')

    def test_unknown_original_config_is_not_automatically_changed(self):
        for changed in (
            CONFIG.replace('listen 8443 ssl;', 'listen 9443 ssl;'),
            CONFIG.replace('http://telecom-api-local:5000', 'http://unexpected:5000'),
            CONFIG.replace('location = /admin { return 404; }', ''),
            CONFIG.replace('listen 8443 ssl;', 'listen 8443 ssl;\n real_ip_header X-Forwarded-For;'),
        ):
            with self.subTest(config=changed), self.assertRaises(RuntimeError):
                tool.make_config(changed, PEER)

    def test_proxy_address_cannot_inject_nginx_directives(self):
        with self.assertRaises(ValueError):
            tool.make_config(CONFIG, '192.0.2.10; return 200')

    def test_build_preserves_actual_tls_image_probes_and_security(self):
        before = deployment()
        snapshot = copy.deepcopy(before)
        resources, image, tls = tool.build_resources(before, CONFIG, PEER, 'owner123', ['one', 'two'])
        self.assertEqual(before, snapshot)
        self.assertEqual([r['kind'] for r in resources], ['ConfigMap', 'Deployment', 'Service'])
        self.assertEqual(image, 'example/edge:fixed')
        self.assertEqual(tls, 'existing-public-tls')
        pod = resources[1]['spec']['template']['spec']
        for key in ('readinessProbe', 'livenessProbe', 'securityContext'):
            self.assertEqual(pod['containers'][0][key], before['spec']['template']['spec']['containers'][0][key])
        self.assertEqual(pod['securityContext'], before['spec']['template']['spec']['securityContext'])
        self.assertEqual(resources[2]['spec']['externalTrafficPolicy'], 'Local')
        self.assertEqual(resources[2]['spec']['ports'][0]['targetPort'], 8445)
        self.assertEqual(resources[2]['spec']['ports'][0]['nodePort'], 31443)
        tool.assert_proxy_config(resources[0]['data']['nginx.conf'], policy)

    def test_unknown_runtime_layout_stops_generation(self):
        for kind in ('sidecar', 'image-pull', 'probe', 'node-affinity'):
            dep = deployment()
            pod = dep['spec']['template']['spec']
            if kind == 'sidecar':
                pod['containers'].append({'name': 'another'})
            elif kind == 'image-pull':
                pod['containers'][0]['imagePullPolicy'] = 'Always'
            elif kind == 'probe':
                pod['containers'][0]['readinessProbe']['httpGet']['port'] = 443
            else:
                pod['affinity'] = {'nodeAffinity': {'existing': True}}
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                tool.build_resources(dep, CONFIG, PEER, 'owner123', ['one', 'two'])

    def test_existing_trial_stops_before_any_mutation(self):
        with patch.object(tool, 'get', return_value={'metadata': {'name': tool.TRIAL}}), \
             patch.object(tool, 'kube') as kubectl:
            with self.assertRaisesRegex(RuntimeError, 'already exists'):
                tool.no_existing_trial()
            kubectl.assert_not_called()

    def test_allocated_nodeport_stops_preflight(self):
        services = {'items': [{'spec': {'ports': [{'nodePort': 31443}]}}]}
        def get(kind, name=None):
            return {'items': []} if kind == 'networkpolicy' else None
        with patch.object(tool, 'get', side_effect=get), \
             patch.object(tool, 'kube', return_value=__import__('json').dumps(services)) as kubectl:
            with self.assertRaisesRegex(RuntimeError, 'already allocated'):
                tool.no_existing_trial()
            self.assertEqual(kubectl.call_args.args[0][:3], ['get', 'svc', '-A'])


if __name__ == '__main__':
    unittest.main()
