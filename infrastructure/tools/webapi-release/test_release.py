import copy
import importlib.util
import io
import hashlib
import json
import shutil
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from dotenv import dotenv_values

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

CONFIG = '''events { worker_connections 512; }
http {
  server {
    listen 8443 ssl;
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


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.test_root = Path(__file__).resolve().parents[3] / 'tmp/webapi-release-tests'
        self.test_root.mkdir(parents=True, exist_ok=True)

    def test_apply_images_does_not_create_secret_or_read_env_files(self):
        deployments = {name: {'metadata': {'resourceVersion': '1'}, 'status': {'readyReplicas': 2},
            'spec': {'replicas': 2, 'template': {'spec': {'containers': [{'name': container, 'image': 'old',
                'envFrom': [{'secretRef': {'name': 'keep-existing'}}]}]}}}}
            for name, (container, _) in release.TARGETS.items()}
        metadata = {'backend': 'new-api', 'frontend': 'new-web', 'source_commit': 'a' * 40}
        protected = {'DB_HOST': '192.168.3.19', 'DB_USER': 'webuser', 'DB_NAME': 'my_new_board_db',
                     'DB_PASSWORD': 'fixture-only'}
        calls = []
        def fake_k(args, data=None):
            calls.append(args)
            self.assertNotIn('create', args)
            self.assertNotIn('secret', args)
            if args[0] == 'get':
                return json.dumps(deployments[args[2]])
            if args[0] == 'patch':
                name = args[2]
                changed = copy.deepcopy(deployments[name])
                changed['spec']['template'] = data[1]['value']
                if '--dry-run=server' not in args:
                    deployments[name] = changed
                return json.dumps(changed)
            raise AssertionError(args)
        with tempfile.TemporaryDirectory(dir=self.test_root) as directory, patch.object(release, 'k', side_effect=fake_k), \
             patch.object(release, 'pods', return_value=[{'metadata': {'name': 'api-one'}}, {'metadata': {'name': 'api-two'}}]), \
             patch.object(release, 'probe', return_value={'protected': protected}), \
             patch.object(release, 'verify_admin_edge_policy') as policy, \
             patch.object(release, 'rollout') as rollout, patch.object(release, 'verify') as verify, \
             patch.object(release.Path, 'read_text', side_effect=AssertionError('Must not read env files')):
            target = Path(directory)
            (target / 'import-ok.json').touch()
            release.apply_images(target, metadata)
            policy.assert_called_once()
            self.assertEqual(rollout.call_args_list, [unittest.mock.call('telecom-api'), unittest.mock.call('telecom-web')])
            verify.assert_called_once_with(target, metadata)
        self.assertEqual(len([args for args in calls if args[0] == 'patch' and '--dry-run=server' not in args]), 2)

    def test_admin_regression_stops_image_apply_before_mutation(self):
        with tempfile.TemporaryDirectory(dir=self.test_root) as directory, patch.object(release, 'k') as cluster, \
             patch.object(release, 'verify_admin_edge_policy', side_effect=RuntimeError('admin denial missing')):
            target = Path(directory)
            (target / 'import-ok.json').touch()
            with self.assertRaisesRegex(RuntimeError, 'admin denial missing'):
                release.apply_images(target, {})
            cluster.assert_not_called()
            self.assertFalse((target / 'deployment-state.json').exists())

    def test_image_only_template_preserves_api_environment(self):
        before = {'spec': {'template': {'spec': {
            'containers': [{'name': 'api', 'image': 'old',
                            'env': [{'name': 'DB_PASSWORD', 'valueFrom': {'secretKeyRef': {'name': 'existing', 'key': 'DB_PASSWORD'}}}],
                            'envFrom': [{'configMapRef': {'name': 'telecom-runtime'}}],
                            'volumeMounts': [{'name': 'env', 'mountPath': '/app/.env', 'subPath': '.env'}]}],
            'volumes': [{'name': 'env', 'secret': {'secretName': 'existing-env'}}]}}}}
        metadata = {'backend': 'new-api', 'source_commit': 'a' * 40}
        changed = release.make_template(before, 'telecom-api', metadata)
        self.assertEqual(release.environment_spec(before['spec']['template']['spec']), release.environment_spec(changed['spec']))
        self.assertEqual(changed['spec']['containers'][0]['image'], 'new-api')

    def test_admin_edge_regression_guard(self):
        policy = release.edge_policy_tool()
        policy.assert_public_admin_blocked(CONFIG)
        for line in ('location = /admin { return 404; }', 'location ^~ /admin/ { return 404; }',
                     'location = /api/admin { return 404; }', 'location ^~ /api/admin/ { return 404; }',
                     'location = /api/internal { return 404; }'):
            with self.subTest(line=line), self.assertRaises(RuntimeError):
                policy.assert_public_admin_blocked(CONFIG.replace(line, ''))
        commented = CONFIG.replace('location = /admin { return 404; }', '# location = /admin { return 404; }')
        with self.assertRaises(RuntimeError):
            policy.assert_public_admin_blocked(commented)

    def check_policy(self, *, live_config=CONFIG, ready=1, audit_status=401):
        calls = []
        def fake_k(args, data=None):
            calls.append(args)
            self.assertIn(args[0], ('get', 'exec'))
            if args[:3] == ['get', 'configmap', 'telecom-edge-config']:
                return json.dumps({'data': {'nginx.conf': CONFIG}})
            if args[:3] == ['get', 'deployment', 'telecom-admin-edge']:
                return json.dumps({'status': {'readyReplicas': ready}})
            if args[:3] == ['get', 'deployment', 'telecom-edge-proxytest']:
                return ''
            if args[0] == 'exec' and 'nginx' in args:
                return live_config
            if args[0] == 'exec' and 'python' in args:
                return 'ADMIN_AUDIT=' + json.dumps({'routes': 46, 'anonymous': audit_status})
            raise AssertionError(args)
        def pods(app):
            return [{'metadata': {'name': app + '-' + str(i)}} for i in (1, 2)]
        with patch.object(release, 'k', side_effect=fake_k), patch.object(release, 'pods', side_effect=pods):
            release.verify_admin_edge_policy()
        return calls

    def test_policy_checks_both_effective_edges_and_api_authorization(self):
        calls = self.check_policy()
        self.assertEqual(len([c for c in calls if 'nginx' in c]), 2)
        self.assertEqual(len([c for c in calls if 'python' in c]), 2)

    def check_proxy_policy(self, *, bad_service=False, stale_pod=False, missing_helper=False):
        source = Path(release.__file__).parent.parent / 'loop-client-ip-test.py'
        spec = importlib.util.spec_from_file_location('test_proxy_tool', source)
        trial = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(trial)
        base = CONFIG.replace('listen 8443 ssl;',
                              'listen 8443 ssl;\n    proxy_set_header X-Forwarded-For $remote_addr;')
        config = trial.make_config(base, '192.0.2.10')
        items, _, _ = trial.build_resources(
            {'spec': {'template': {'spec': {
                'containers': [{'name': 'edge', 'command': ['nginx'], 'image': 'cached',
                    'imagePullPolicy': 'Never', 'ports': [{'name': 'https', 'containerPort': 8443}],
                    'readinessProbe': {'httpGet': {'port': 'https', 'path': '/edge-health'}},
                    'livenessProbe': {'httpGet': {'port': 'https', 'path': '/edge-health'}}}],
                'volumes': [{'configMap': {'name': 'telecom-edge-config'}},
                            {'name': 'tls', 'secret': {'secretName': 'existing'}}]}}}},
            base, '192.0.2.10', 'test', ['pc1-k3s', 'pc2-k3s'])
        service = items[2]
        if bad_service:
            service['spec']['externalTrafficPolicy'] = 'Cluster'
        calls = []
        def fake_k(args, data=None):
            calls.append(args)
            self.assertIn(args[0], ('get', 'exec'))
            if args[:3] == ['get', 'deployment', trial.TRIAL]:
                return json.dumps({'metadata': {'name': trial.TRIAL}})
            if args[:3] == ['get', 'service', trial.TRIAL]:
                return json.dumps(service)
            if args[:3] == ['get', 'configmap', trial.CM]:
                return json.dumps({'data': {'nginx.conf': config}})
            if args[0] == 'exec':
                return base if stale_pod and args[1].endswith('-2') else config
            raise AssertionError(args)
        with patch.object(release, 'k', side_effect=fake_k), \
             patch.object(release, 'pods', return_value=[{'metadata': {'name': 'proxy-' + str(i)}} for i in (1, 2)]):
            if missing_helper:
                with patch.object(release.Path, 'is_file', return_value=False):
                    release.verify_proxy_edge_policy(release.edge_policy_tool())
            else:
                release.verify_proxy_edge_policy(release.edge_policy_tool())
        return calls

    def test_proxy_guard_checks_service_configmap_and_both_effective_pods(self):
        calls = self.check_proxy_policy()
        self.assertEqual(len([c for c in calls if c[0] == 'exec']), 2)

    def test_proxy_guard_rejects_cluster_routing_and_one_stale_pod(self):
        for kwargs in ({'bad_service': True}, {'stale_pod': True}):
            with self.subTest(kwargs=kwargs), self.assertRaises(RuntimeError):
                self.check_proxy_policy(**kwargs)

    def test_standalone_proxy_guard_and_missing_helper(self):
        with tempfile.TemporaryDirectory(dir=self.test_root) as directory:
            target = Path(directory)
            tools = Path(release.__file__).parent.parent
            for source in (Path(release.__file__), tools / 'k3s-admin-access.py', tools / 'loop-client-ip-test.py'):
                shutil.copyfile(source, target / source.name)
            spec = importlib.util.spec_from_file_location('standalone_proxy_release', target / 'release.py')
            standalone = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(standalone)
            # Absent trial is compatible with an unmodified cluster; no writes occur.
            with patch.object(standalone, 'k', return_value=''):
                standalone.verify_proxy_edge_policy(standalone.edge_policy_tool())
            (target / 'loop-client-ip-test.py').unlink()
            with patch.object(standalone, 'k', return_value='{}'):
                with self.assertRaisesRegex(RuntimeError, 'Missing loop-client-ip-test.py'):
                    standalone.verify_proxy_edge_policy(standalone.edge_policy_tool())

    def test_stale_edge_private_outage_or_bad_auth_fail_release(self):
        for kwargs in ({'live_config': CONFIG.replace('location = /admin { return 404; }', '')},
                       {'ready': 0}, {'audit_status': 200}):
            with self.subTest(kwargs=kwargs), self.assertRaises(RuntimeError):
                self.check_policy(**kwargs)

    def test_standalone_release_loads_bundled_policy_and_requires_it(self):
        with tempfile.TemporaryDirectory(dir=self.test_root) as directory:
            target = Path(directory)
            shutil.copyfile(Path(release.__file__), target / 'release.py')
            policy_source = Path(release.__file__).parent.parent / 'k3s-admin-access.py'
            shutil.copyfile(policy_source, target / 'k3s-admin-access.py')
            spec = importlib.util.spec_from_file_location('standalone_release', target / 'release.py')
            standalone = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(standalone)
            standalone.edge_policy_tool().assert_public_admin_blocked(CONFIG)
        with patch.object(release.Path, 'is_file', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'Missing k3s-admin-access.py'):
                release.edge_policy_tool()

    def test_oci_index_id_resolves_to_runtime_config(self):
        revision = 'a' * 40
        blobs = {}

        def blob(value):
            raw = json.dumps(value).encode()
            digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
            blobs['blobs/sha256/' + digest.split(':')[1]] = raw
            return digest

        config = blob({'os': 'linux', 'architecture': 'amd64', 'rootfs': {'type': 'layers', 'diff_ids': []},
                       'config': {'Labels': {'org.opencontainers.image.revision': revision}}})
        manifest = blob({'schemaVersion': 2, 'config': {'digest': config}, 'layers': []})
        index = blob({'schemaVersion': 2, 'manifests': [
            {'digest': manifest, 'platform': {'os': 'linux', 'architecture': 'amd64'}},
            {'digest': 'sha256:' + 'b' * 64, 'platform': {'os': 'unknown', 'architecture': 'unknown'}}]})
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            archive = Path(directory) / 'images.tar'
            with tarfile.open(archive, 'w') as stream:
                for name, raw in blobs.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(raw)
                    stream.addfile(info, io.BytesIO(raw))
            self.assertNotEqual(index, config)
            self.assertEqual(release.archive_config_ids(archive, index, revision), {config})
            self.assertEqual(release.archive_config_ids(archive, manifest, revision), {config})
            self.assertEqual(release.archive_config_ids(archive, config, revision), {config})
            with self.assertRaises(RuntimeError):
                release.archive_config_ids(archive, index, 'c' * 40)
            blobs['blobs/sha256/' + config.split(':')[1]] += b' '
            with tarfile.open(archive, 'w') as stream:
                for name, raw in blobs.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(raw)
                    stream.addfile(info, io.BytesIO(raw))
            with self.assertRaises(RuntimeError):
                release.archive_config_ids(archive, index, revision)

    def test_revision_label_alone_cannot_bypass_digest_check(self):
        revision = 'a' * 40
        image = {'status': {'id': 'sha256:' + 'b' * 64, 'repoTags': ['docker.io/library/telecom-backend:test']},
                 'info': {'imageSpec': {'config': {'Labels': {'org.opencontainers.image.revision': revision}}}}}
        release.validate_runtime_image(image, 'docker.io/library/telecom-backend:test', {'sha256:' + 'b' * 64}, revision)
        with self.assertRaises(RuntimeError):
            release.validate_runtime_image(image, 'docker.io/library/telecom-backend:test', {'sha256:' + 'c' * 64}, revision)
        with self.assertRaises(RuntimeError):
            release.validate_runtime_image(image, 'docker.io/library/telecom-backend:wrong', {'sha256:' + 'b' * 64}, revision)

    def test_stale_env_cannot_revert_primary_or_tokens(self):
        protected = {'DB_HOST': '192.168.3.19', 'DB_USER': 'webuser',
                     'DB_PASSWORD': 'fixture-only', 'APP_ENV': 'lab',
                     'INCIDENT_API_TOKEN': 'fixture-token', 'AUTOMATION_API_TOKEN': 'fixture-auto'}
        source = {'DB_HOST': '192.168.3.18', 'DB_USER': 'root', 'APP_ENV': 'local',
                  'INCIDENT_API_TOKEN': 'stale', 'DATABASE_URL': 'stale',
                  'MYSQL_HOST': 'stale', 'GRAFANA_URL': 'https://changed.example',
                  'PUBLIC_BASE_URL': 'http://stale', 'TRUSTED_PROXY_HOPS': '0'}
        result = release.merged_values(source, protected)
        self.assertEqual({key: result[key] for key in protected}, protected)
        self.assertEqual(result['GRAFANA_URL'], 'https://changed.example')
        self.assertNotIn('DATABASE_URL', result)
        self.assertNotIn('MYSQL_HOST', result)
        self.assertEqual(result['PUBLIC_BASE_URL'], 'https://192.168.3.30')
        self.assertEqual(result['TRUSTED_PROXY_HOPS'], '1')

    def test_ambiguous_env_is_rejected(self):
        for invalid in ({'BAD-KEY': 'x'}, {'EMPTY_ENTRY': None}, {'KEY': '${OTHER}'}, {'KEY': 'a\x00b'}):
            with self.assertRaises(RuntimeError):
                release.merged_values(invalid, {})

    def test_env_roundtrip_preserves_values(self):
        values = {'EMPTY': '', 'QUOTE': "a'b\"c", 'PATH': r'C:\test\new',
                  'MULTI': 'first\nsecond', 'TEXT': '�ѱ� # test $value', 'SPACES': '  x  '}
        parsed = dict(dotenv_values(stream=io.StringIO(release.encode_env(values)), interpolate=False))
        self.assertEqual(values, parsed)

    def test_api_patch_replaces_old_env_mount_and_literal(self):
        before = {'metadata': {'resourceVersion': '4'}, 'spec': {'template': {'spec': {
            'containers': [{'name': 'api', 'image': 'old',
                            'envFrom': [{'configMapRef': {'name': 'telecom-runtime'}}],
                            'env': [{'name': 'DB_HOST', 'value': 'wrong'}, {'name': 'KEEP', 'value': 'unchanged'}],
                            'volumeMounts': [
                                {'name': 'old-env', 'mountPath': '/app/.env'},
                                {'name': 'tls', 'mountPath': '/tls'}]}],
            'volumes': [{'name': 'old-env', 'secret': {'secretName': 'old'}},
                        {'name': 'tls', 'secret': {'secretName': 'tls'}}],
            'affinity': {'keep': True}}}}}
        original = copy.deepcopy(before)
        metadata = {'backend': 'new-api', 'frontend': 'new-web', 'source_commit': 'a' * 40}
        template = release.make_template(before, 'telecom-api', metadata, 'new-secret', {'DB_HOST': '192.168.3.19'})
        api = template['spec']['containers'][0]
        self.assertEqual(before, original)
        self.assertEqual(api['image'], 'new-api')
        self.assertEqual(api['imagePullPolicy'], 'Never')
        self.assertEqual([e for e in api['env'] if e['name'] == 'DB_HOST'], [
            {'name': 'DB_HOST', 'valueFrom': {'secretKeyRef': {'name': 'new-secret', 'key': 'DB_HOST'}}}])
        self.assertEqual([m['name'] for m in api['volumeMounts'] if m['mountPath'] == '/app/.env'], ['clean-release-env'])
        self.assertEqual(api['envFrom'], original['spec']['template']['spec']['containers'][0]['envFrom'])
        self.assertEqual(template['spec']['affinity'], {'keep': True})
        self.assertIn({'name': 'KEEP', 'value': 'unchanged'}, api['env'])
        ops = release.operations(before, template)
        self.assertEqual(ops[0], {'op': 'test', 'path': '/metadata/resourceVersion', 'value': '4'})

    def test_frontend_patch_keeps_configuration(self):
        before = {'spec': {'template': {'spec': {'containers': [
            {'name': 'web', 'image': 'old', 'volumeMounts': [{'name': 'nginx', 'mountPath': '/etc/nginx/conf.d'}]}
        ]}}}}
        metadata = {'backend': 'new-api', 'frontend': 'new-web', 'source_commit': 'a' * 40}
        template = release.make_template(before, 'telecom-web', metadata)
        self.assertEqual(template['spec']['containers'][0]['volumeMounts'],
                         before['spec']['template']['spec']['containers'][0]['volumeMounts'])
        self.assertNotIn('volumes', template['spec'])


if __name__ == '__main__':
    unittest.main()
