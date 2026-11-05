#!/usr/bin/env python3
"""Plan/create an isolated PROXY-protocol trial. No edits to existing resources."""
import argparse
import copy
import datetime as dt
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

NS='telecom'
ORIGINAL='telecom-edge'
TRIAL='telecom-edge-proxytest'
CM='telecom-edge-proxytest-config'
OWNER='loop-client-ip-trial'
NODEPORT=31443
LISTENER=8445

def stop(message):
    raise RuntimeError(message)

def kube(args, stdin=None):
    p=subprocess.run(['sudo','-n','k3s','kubectl']+args,input=stdin,
                     text=True,encoding='utf-8',capture_output=True,timeout=60)
    if p.returncode:
        stop('kubectl failed: '+p.stderr.strip()[:1500])
    return p.stdout

def get(kind,name=None,namespace=NS):
    args=['get',kind]
    if name:args += [name,'--ignore-not-found']
    if namespace:args += ['-n',namespace]
    args += ['-o','json']
    text=kube(args)
    return json.loads(text) if text.strip() else None

def mask_config(s):
    # Hide quoted strings/comments when locating nginx block boundaries.
    result=list(s);quote=None;comment=False;escaped=False
    for i,c in enumerate(s):
        if comment:
            if c=='\n':comment=False
            else:result[i]=' '
        elif quote:
            result[i]=' '
            if escaped:escaped=False
            elif c=='\\':escaped=True
            elif c==quote:quote=None
        elif c=='#':comment=True;result[i]=' '
        elif c in ['"',"'"]:quote=c;result[i]=' '
    if quote:stop('Unclosed nginx string')
    return ''.join(result)

def make_config(source,proxy_ip):
    proxy_ip=str(ipaddress.IPv4Address(proxy_ip))
    masked=mask_config(source)
    matches=list(re.finditer(r'(?m)^[ \t]*server\s*\{',masked))
    if len(matches)!=1:stop('Expected exactly one existing public server block')
    match=matches[0];opening=masked.index('{',match.start());depth=1;end=None
    for i in range(opening+1,len(masked)):
        if masked[i]=='{':depth+=1
        elif masked[i]=='}':
            depth-=1
            if depth==0:end=i+1;break
    if end is None:stop('Unbalanced nginx server block')
    server=source[match.start():end]
    listens=re.findall(r'(?m)^[ \t]*listen[^;]*;',mask_config(server))
    if len(listens)!=1 or not re.fullmatch(r'\s*listen\s+8443\s+ssl\s*;',listens[0]):
        stop('Unexpected existing public listener; inspect before proceeding')
    if not re.search(r'proxy_set_header\s+X-Forwarded-For\s+\$remote_addr\s*;',server):
        stop('Expected trusted single-hop X-Forwarded-For overwrite')
    for path in ['/admin','/admin/','/api/admin','/api/admin/','/api/internal','/api/internal/']:
        pattern=r'location\s+(?:=|\^~)\s+'+re.escape(path)+r'\s*\{\s*return\s+404\s*;\s*\}'
        if not re.search(pattern,server):stop('Missing existing public denial: '+path)
    targets=re.findall(r'proxy_pass\s+([^;\s]+)\s*;',server)
    if sorted(targets)!=['http://telecom-api-local:5000','http://telecom-web-local:80']:
        stop('Unexpected public upstreams; do not overwrite them')
    if re.search(r'(?m)^\s*(?:set_real_ip_from|real_ip_header)\b',masked):
        stop('Existing real-IP directives need manual reconciliation')
    replacement=(f'        listen {LISTENER} ssl proxy_protocol;\n'
                 f'        set_real_ip_from {proxy_ip}/32;\n'
                 '        real_ip_header proxy_protocol;\n'
                 f'        if ($realip_remote_addr != {proxy_ip}) {{ return 403; }}')
    trial,count=re.subn(r'(?m)^[ \t]*listen\s+8443\s+ssl\s*;',replacement,server)
    if count!=1:stop('Could not isolate the trial listener')
    result=source[:end]+'\n\n'+trial+source[end:]
    if result.count(source[match.start():end])!=1:stop('Existing block changed')
    return result

def assert_proxy_config(source,policy,expected_peer=None):
    """Read-only release guard for the exact two-listener configuration we create."""
    blocks=policy.config_blocks(source)
    servers=[b for b in blocks if b['header']==('server',) and b['parent'] is not None
             and b['parent']['header']==('http',)]
    if len(servers)!=2:stop('Expected the original and PROXY public servers')
    trials=[b for b in servers if ('listen',str(LISTENER),'ssl','proxy_protocol') in b['directives']]
    if len(trials)!=1:stop('Missing unique PROXY listener')
    trial=trials[0]
    trusts=[d for d in trial['directives'] if d and d[0]=='set_real_ip_from']
    if len(trusts)!=1 or len(trusts[0])!=2 or not trusts[0][1].endswith('/32'):
        stop('Expected one exact trusted proxy IPv4 peer')
    peer=str(ipaddress.IPv4Address(trusts[0][1][:-3]))
    if expected_peer is not None and peer!=expected_peer:stop('Running proxy peer differs from ConfigMap')
    original=source[:trial['start']]+source[trial['end']:]
    policy.assert_public_admin_blocked(original)
    expected=make_config(original,peer)
    def tokens(text):
        return [m.group() for m in policy.TOKEN.finditer(text)
                if not m.group().isspace() and not m.group().startswith('#')]
    if tokens(source)!=tokens(expected):stop('PROXY server differs from the validated public clone')
    return peer

def build_resources(deployment,config,proxy_ip,run_id,hostnames):
    labels={'app':TRIAL,OWNER:run_id}
    cm={'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':CM,'namespace':NS,'labels':labels},
        'data':{'nginx.conf':make_config(config,proxy_ip)}}
    spec=copy.deepcopy(deployment['spec'])
    spec['replicas']=2
    spec['selector']={'matchLabels':{'app':TRIAL}}
    template=spec['template']
    template['metadata']={'labels':labels}
    pod=template['spec']
    if 'nodeName' in pod:stop('Unexpected fixed nodeName')
    containers=pod.get('containers',[])
    if len(containers)!=1 or containers[0].get('name')!='edge':stop('Unexpected edge containers')
    edge=containers[0]
    if edge.get('imagePullPolicy')!='Never':stop('Expected existing cached image with Never pull policy')
    if edge.get('command')!=['nginx']:stop('Unexpected nginx startup')
    if not any(p.get('name')=='https' and p.get('containerPort')==8443 for p in edge.get('ports',[])):
        stop('Existing health listener port not found')
    for kind in ['readinessProbe','livenessProbe']:
        probe=edge.get(kind,{}).get('httpGet',{})
        if probe.get('port')!='https' or probe.get('path')!='/edge-health':
            stop('Unexpected probe configuration')
    edge['ports'].append({'name':'https-proxy','containerPort':LISTENER,'protocol':'TCP'})
    volumes=pod.get('volumes',[])
    replacements=0
    for v in volumes:
        if v.get('configMap',{}).get('name')=='telecom-edge-config':
            v['configMap']['name']=CM;replacements+=1
    if replacements!=1:stop('Expected one public nginx ConfigMap volume')
    tls=[v['secret']['secretName'] for v in volumes if v.get('name')=='tls' and 'secret' in v]
    if len(tls)!=1:stop('Existing TLS reference not found')
    affinity=pod.setdefault('affinity',{})
    if affinity.get('nodeAffinity'):stop('Existing node affinity needs manual reconciliation')
    affinity['nodeAffinity']={'requiredDuringSchedulingIgnoredDuringExecution':{'nodeSelectorTerms':[
        {'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':hostnames}]}]}}
    affinity['podAntiAffinity']={'requiredDuringSchedulingIgnoredDuringExecution':[
        {'labelSelector':{'matchLabels':{'app':TRIAL}},'topologyKey':'kubernetes.io/hostname'}]}
    new_deployment={'apiVersion':'apps/v1','kind':'Deployment',
                    'metadata':{'name':TRIAL,'namespace':NS,'labels':labels},'spec':spec}
    service={'apiVersion':'v1','kind':'Service','metadata':{'name':TRIAL,'namespace':NS,'labels':labels},
             'spec':{'type':'NodePort','externalTrafficPolicy':'Local','selector':{'app':TRIAL},
                     'ports':[{'name':'https-proxy','port':443,'targetPort':LISTENER,
                               'nodePort':NODEPORT,'protocol':'TCP'}]}}
    return [cm,new_deployment,service],edge['image'],tls[0]

def no_existing_trial():
    for kind,name in [('configmap',CM),('deployment',TRIAL),('service',TRIAL)]:
        if get(kind,name):stop('Trial resource already exists: '+kind+'/'+name)
    if get('networkpolicy').get('items'):stop('Namespace has NetworkPolicies; reconcile trial access first')
    all_services=json.loads(kube(['get','svc','-A','-o','json']))
    for s in all_services['items']:
        if any(p.get('nodePort')==NODEPORT for p in s.get('spec',{}).get('ports',[])):
            stop('Proposed NodePort is already allocated: '+str(NODEPORT))

def stamp(obj):
    m=obj['metadata'];return {'uid':m['uid'],'resourceVersion':m['resourceVersion']}

def plan(args):
    proxy_ip=str(ipaddress.IPv4Address(args.proxy_ip))
    no_existing_trial()
    dep=get('deployment',ORIGINAL);cm=get('configmap','telecom-edge-config');svc=get('service',ORIGINAL)
    if not all([dep,cm,svc]):stop('Original public resources not found')
    if svc['spec'].get('externalTrafficPolicy')!='Local':stop('Expected original public Service Local')
    if svc['spec'].get('selector')!={'app':ORIGINAL}:stop('Unexpected original public selector')
    if dep['spec'].get('replicas')!=2 or dep.get('status',{}).get('readyReplicas')!=2:
        stop('Original public Deployment must have two Ready replicas')
    pods=json.loads(kube(['get','pods','-n',NS,'-l','app='+ORIGINAL,'-o','json']))['items']
    ready=[p for p in pods if not p['metadata'].get('deletionTimestamp') and
           any(c.get('type')=='Ready' and c.get('status')=='True' for c in p.get('status',{}).get('conditions',[]))]
    if len(ready)!=2:stop('Expected exactly two current Ready public pods')
    nodes=sorted(set(p['spec']['nodeName'] for p in ready))
    if len(nodes)!=2:stop('Public pods must occupy two different nodes')
    node_objects=[get('node',n,namespace=None) for n in nodes]
    if not all(any(c.get('type')=='Ready' and c.get('status')=='True' for c in n['status']['conditions']) for n in node_objects):
        stop('Both source nodes must be Ready')
    hostnames=[n['metadata']['labels']['kubernetes.io/hostname'] for n in node_objects]
    run_id=uuid.uuid4().hex[:12]
    resources,image,tls=build_resources(dep,cm['data']['nginx.conf'],proxy_ip,run_id,hostnames)
    # Reuse the existing mounted TLS reference without requesting any Secret object.
    # Check both existing image instances. Only a unique temporary config is written.
    tmp='/tmp/loop-proxy-check-'+run_id+'.conf'
    check='umask 077; tmp='+tmp+'; trap \'rm -f "$tmp"\' EXIT; cat > "$tmp"; nginx -t -c "$tmp"'
    for pod in ready:
        # nginx -t itself proves the real-IP directives are supported.
        if not any(c.get('name')=='edge' and c.get('image')==image for c in pod['spec']['containers']):
            stop('Ready public pod image differs from the Deployment')
        kube(['exec','-i','-n',NS,pod['metadata']['name'],'-c','edge','--','sh','-c',check],
             resources[0]['data']['nginx.conf'])
    payload={'apiVersion':'v1','kind':'List','items':resources}
    kube(['create','--dry-run=server','-f','-','-o','name'],json.dumps(payload))
    home=Path.home();work=home/('loop-client-ip-test-'+dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+run_id)
    work.mkdir(mode=0o700)
    manifest=json.dumps(payload,ensure_ascii=False,indent=2)+'\n'
    (work/'trial-resources.json').write_text(manifest,encoding='utf-8')
    info={'run_id':run_id,'proxy_ip':proxy_ip,'nodes':nodes,'image':image,'tls_secret_reference':tls,
          'originals':{'deployment':stamp(dep),'configmap':stamp(cm),'service':stamp(svc)},
          'manifest_sha256':hashlib.sha256(manifest.encode()).hexdigest(),'stage':'planned-not-created'}
    (work/'plan.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    for f in work.iterdir():f.chmod(0o600)
    (home/'.loop-client-ip-test-workdir').write_text(str(work)+'\n',encoding='utf-8')
    print('PLAN OK: two-node nginx -t and server dry-run passed.')
    print('Existing public/admin/automation resources were not changed.')
    print('WORK_DIR='+str(work))
    print('Next step, after reviewing this result: python3 ~/loop-client-ip-test.py apply')

def apply(args):
    work=Path(args.work_dir).expanduser().resolve() if args.work_dir else Path((Path.home()/'.loop-client-ip-test-workdir').read_text().strip()).resolve()
    info=json.loads((work/'plan.json').read_text());manifest=(work/'trial-resources.json').read_text()
    if hashlib.sha256(manifest.encode()).hexdigest()!=info['manifest_sha256']:stop('Trial manifest changed after validation')
    for kind,name in [('deployment',ORIGINAL),('configmap','telecom-edge-config'),('service',ORIGINAL)]:
        current=get(kind,name)
        if not current or stamp(current)!=info['originals'][kind]:stop('Original resource changed since plan: '+kind)
    no_existing_trial()
    payload=json.loads(manifest)
    if [(o['kind'],o['metadata']['name']) for o in payload['items']] != [('ConfigMap',CM),('Deployment',TRIAL),('Service',TRIAL)]:
        stop('Unexpected planned resources')
    journal=[]
    try:
        for obj in payload['items']:
            created=json.loads(kube(['create','-f','-','-o','json'],json.dumps(obj)))
            journal.append({'kind':created['kind'],'name':created['metadata']['name'],'uid':created['metadata']['uid']})
            (work/'created-resources.json').write_text(json.dumps(journal,indent=2)+'\n')
        kube(['rollout','status','deployment/'+TRIAL,'-n',NS,'--timeout=45s'])
    except Exception:
        print('Stopped. Existing production resources were not edited. Trial resources recorded in '+str(work/'created-resources.json'),file=sys.stderr)
        raise
    status=get('deployment',TRIAL)
    if status.get('status',{}).get('readyReplicas')!=2:stop('Trial does not have two Ready replicas')
    info['stage']='trial-created-needs-haproxy-test'
    (work/'plan.json').write_text(json.dumps(info,indent=2)+'\n')
    print('PC1 TRIAL READY: two test pods, NodePort 31443 -> listener 8445.')
    print('Now configure only the pfSense 11443 test frontend/backend; public 443 is unchanged.')
    print(kube(['get','pods','-n',NS,'-l','app='+TRIAL,'-o','wide']).strip())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    subs=parser.add_subparsers(dest='mode',required=True)
    p=subs.add_parser('plan');p.add_argument('--proxy-ip',required=True,
        help='Exact IPv4 socket peer observed from HAProxy; do not use a subnet or client address')
    p=subs.add_parser('apply');p.add_argument('--work-dir')
    args=parser.parse_args()
    if subprocess.run(['sudo','-v']).returncode:stop('sudo authentication failed')
    if args.mode=='plan':plan(args)
    else:apply(args)

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as exc:
        print('STOP: '+str(exc),file=sys.stderr);sys.exit(1)
