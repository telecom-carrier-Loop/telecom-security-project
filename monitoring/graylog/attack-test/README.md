# Telecom PC1/PC2 Graylog & Wazuh test pack

## Origin and scope
Based on `telecom-carrier-Loop/telecom-security-project`, `monitoring/graylog/attack-test`, and uploaded Graylog Content Pack `ED` (2026-10-26). No live deployments or end-to-end receipt were performed by the generator. All commands are explicit manual PowerShell **simulations**; no real traffic attacks.

## Folder layout
- `PC1_to_PC1/Graylog`: send mock GELF messages from **PC1 Windows** to its Graylog on `127.0.0.1:12201`.
- `PC2_to_PC1/Graylog`: send mock GELF messages from **PC2 Windows** to PC1 `192.168.3.18:12201`.
- `PC1_to_PC1/Wazuh`: PC1's Wazuh Manager **offline rule-engine check** where possible. This is NOT an end-to-end agent test of PC2 Linux conditions, and for FIM scenarios is only a diagnostic guide. Wazuh IDs 100230-100237 cannot be promised from PC1's Windows Agent.
- `PC2_to_PC1/Wazuh`: submit distinct Wazuh **simulated JSON records** over SSH to PC2 Ubuntu Agent file `/var/log/wazuh-lab/ui-tests.jsonl`; PC2 Wazuh Manager's **confirmed rule 100498** then forwards its alert to PC1 Graylog on port 5140. Real 100230-100237 attack detections are NOT tested by this technique.

## Run
Open a `.txt` file in Notepad. Copy ONLY its PowerShell commands into PowerShell on the named PC. For Wazuh PC2 tests, require SSH BatchMode key auth, Agent JSON localfile, rule 100498. A clean environment might lack these prerequisites. For Graylog, require GELF UDP 12201, Graylog rules and matching sources. These tests never modify pfSense or third-party devices.

## Check outcomes
- Graylog Search: `test_source:TELECOM-MIGRATION-20261026` (GELF); events in Alerts > Events.
- PC2 Wazuh: `docker exec wazuh-manager sh -c "grep -F '100498' /var/ossec/logs/alerts/alerts.json | tail -n 3"`
- PC1 Graylog for Wazuh: `wazuh_agent_name:pc2-k3s AND wazuh_rule_id:100498`.
- Then PC2 n8n Executions and Discord. UDP Send output alone is not receipt proof. If wrong destination in Notification, fix to actual PC2 webhook path rather than guessing.

## Crucial limitations based on uploaded Content Pack
- `ED-WZ-02` query looks for **actual** `100230 ... 100237`, is **unscheduled/disabled** in the supplied export; it will NOT trigger from test-only Wazuh rule `100498`.
- `ED-EX-03` and `ED-EX-07` names in GitHub say disabled, but uploaded Content Pack shows scheduled=true. Confirm current live Graylog state before using. Same for other rules.
- Tests may match several existing EDs and may generate repeated Discord notices. Some rules require time aggregation/grouping and their index mapping must be numeric (`unique_dst_ports`, `packet_count`, `tcp_syn_count`).
- `ED-09` checks `rule:web-scan` and log count; HTTP 404 status is only illustrative, **not validated by its query**.
- `ED-04 / ED-08` sample emits 12 matching events to exceed count>=10 for source IP / username.
- `ED-05` sample emits two different rule values from same source IP.
- `ED-07` supplemental direct GELF Wazuh-shaped alert is **not** a Wazuh engine detection.
- `wazuh경보.txt` in original repo is empty; only a diagnostic document is made.
- `Wazuh_실제룰엔진_logtest_보조` is a supplementary engine inspection, not a live attack.
- Never infer successful Discord delivery without inspecting n8n executions and actual Discord messages.

## Event map
| GitHub scenario | route | target/limitation |
|---|---|---|
| `EX-01_단독포트스캔` | graylog | ED-EX-01 |
| `EX-02_SYN_Flood탐지` | graylog | ED-EX-02 |
| `EX-03_LowAndSlow_비활성` | graylog | ED-EX-03 |
| `EX-04_심야로그인` | graylog | ED-EX-04 |
| `EX-05_SQLInjection` | graylog | ED-EX-05 |
| `EX-06_내부비인가접근` | graylog | ED-EX-06 |
| `EX-07_로그변조_비활성` | graylog | ED-EX-07 |
| `EX-08_Nikto스캐너` | graylog | ED-EX-08 |
| `K09-01_다중포트접근` | graylog | ED-K09-01 |
| `K09-02_TCP_SYN급증` | graylog | ED-K09-02 |
| `K09-03_IP별패킷과다` | graylog | ED-K09-03 |
| `WZ-100230_Linux보안로그변경` | wazuh | 100498 PC2/ offline on PC1; original ID 100230 not proven |
| `WZ-100231_SSH및감사설정변경` | wazuh | 100498 PC2/ offline on PC1; original ID 100231 not proven |
| `WZ-100232_sudo특권명령` | wazuh | 100498 PC2/ offline on PC1; original ID 100232 not proven |
| `WZ-100233_Linux사용자그룹변경` | wazuh | 100498 PC2/ offline on PC1; original ID 100233 not proven |
| `WZ-100234_rootSSH로그인성공` | wazuh | 100498 PC2/ offline on PC1; original ID 100234 not proven |
| `WZ-100235_허용되지않은SSH계정` | wazuh | 100498 PC2/ offline on PC1; original ID 100235 not proven |
| `WZ-100236_Flaskk3s설정변경` | wazuh | 100498 PC2/ offline on PC1; original ID 100236 not proven |
| `WZ-100237_Flaskk3s파일삭제` | wazuh | 100498 PC2/ offline on PC1; original ID 100237 not proven |
| `Wazuh_실제룰엔진_logtest_보조` | wazuh | logtest reference |
| `graylog 4번 8번 테스트` | graylog | ED-04 / ED-08 |
| `wazuh경보` | empty | original empty |
| `관리자 권한 RBAC 감사` | graylog | ED-01 |
| `다중공격` | graylog | ED-05 cardinality two rules |
| `웹스캐너 404 폭주` | graylog | ED-09 |
| `인시던트 승격` | graylog | ED-07 |
