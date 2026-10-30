from app.dashboard.zabbix_routes import _node_status


def item(key, value=1, clock=1000, **extra):
    return {'key_': key, 'lastvalue': str(value), 'lastclock': str(clock), **extra}


def test_node_on_when_ping_is_blocked_but_agent_responds():
    rows = [item('icmpping[192.168.7.185]', 0), item('net.tcp.service[tcp,192.168.7.185,22]', 1)]
    assert _node_status(rows, '192.168.7.185', 1010)['status'] == 'ON'


def test_node_off_requires_all_fresh_checks_to_fail():
    rows = [item('icmpping[192.168.7.185]', 0), item('net.tcp.service[tcp,192.168.7.185,22]', 0)]
    assert _node_status(rows, '192.168.7.185', 1010)['status'] == 'OFF'
    assert _node_status(rows[:1], '192.168.7.185', 1010)['status'] == 'UNKNOWN'


def test_stale_disabled_unsupported_or_uncollected_values_are_unknown():
    for extra in ({'lastclock': '0'}, {'lastclock': '500'}, {'lastclock': '1100'},
                  {'status': '1'}, {'state': '1'}, {'lastvalue': 'invalid'}):
        row = item('icmpping[192.168.7.185]')
        row.update(extra)
        assert _node_status([row], '192.168.7.185', 1010)['status'] == 'UNKNOWN'


def test_other_host_does_not_make_target_online():
    assert _node_status([item('icmpping[192.168.7.100]')], '192.168.7.185', 1010)['status'] == 'UNKNOWN'


def test_dashboard_contract_queries_only_remaining_resource_histories(monkeypatch):
    from flask import Flask
    from app.dashboard import zabbix_routes as route
    monkeypatch.setenv('ZABBIX_API_URL', 'http://zabbix.invalid/api_jsonrpc.php')
    monkeypatch.setenv('ZABBIX_API_TOKEN', 'test-only')
    monkeypatch.setattr(route.time, 'time', lambda: 1010)
    histories = []
    def rpc(method, params, *_):
        if method == 'host.get':
            return [{'host': 'telecom-services', 'hostid': '1'}, {'host': 'PC2-Windows', 'hostid': '2'}]
        if method == 'item.get':
            rows = [dict(item('icmpping[192.168.7.185]'), hostid='1')]
            for i, name in enumerate(['CPU utilization', 'Memory utilization', 'FS [(C:)]: Space: Used, in %',
                                      'FS [새 볼륨 (D:)]: Space: Used, in %',
                                      'Realtek PCIe GbE Family Controller(이더넷): Bits received']):
                rows.append({'hostid': '2', 'itemid': str(i), 'name': name, 'lastvalue': '5', 'value_type': '0'})
            return rows
        if method == 'history.get':
            histories.extend(params['itemids'])
            return []
        if method == 'problem.get':
            return []
        raise AssertionError(method)
    monkeypatch.setattr(route, '_rpc', rpc)
    with Flask(__name__).test_request_context():
        result = route.zabbix_dashboard.__wrapped__()[0].get_json()['data']
    assert set(result['metrics']) == {'cpu', 'ram', 'disk_c'}
    assert histories == ['0', '1', '2']
    assert result['nodes'][0]['status'] == 'ON'
    assert result['nodes'][1]['status'] == 'UNKNOWN'
