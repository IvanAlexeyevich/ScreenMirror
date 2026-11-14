#!/usr/bin/env python3
import subprocess,sys,os,json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
fixture=subprocess.Popen([sys.executable,str(root/'tools/network_fixture.py')],stdout=subprocess.PIPE,text=True)
try:
    ports=json.loads(fixture.stdout.readline())
    env=dict(os.environ,MIRROR_TEST_HTTP=str(ports['http']),MIRROR_TEST_UDP=str(ports['udp']))
    result=subprocess.run(['swift','test','--package-path',str(root)],env=env)
    sys.exit(result.returncode)
finally:fixture.terminate();fixture.wait(timeout=5)
