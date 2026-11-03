#!/usr/bin/env python3
"""Install the user-owned local bridge. No cloud credentials are read or copied."""
from pathlib import Path
import os,plistlib,shutil,signal,subprocess,time
source=Path(__file__).resolve().parent
home=Path.home()
destination=home/'Library/Application Support/Grok Notch Bridge'
label='local.grok-notch.bridge'
plist=home/f'Library/LaunchAgents/{label}.plist'
node=next((p for p in [Path('/usr/local/bin/node'),Path('/opt/homebrew/bin/node'),Path(shutil.which('node') or '/nonexistent')] if p.is_file()),None)
if node is None:raise SystemExit('Node.js 22 ou supérieur requis.')
major=int(subprocess.check_output([str(node),'--version'],text=True).strip().lstrip('v').split('.')[0])
if major<22:raise SystemExit('Node.js 22 ou supérieur requis.')
destination.mkdir(parents=True,exist_ok=True,mode=0o700)
# Remove the launchd job first so KeepAlive cannot race the update.
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}/{label}'],capture_output=True)
for _ in range(30):
 if subprocess.run(['launchctl','print',f'gui/{os.getuid()}/{label}'],capture_output=True).returncode != 0:break
 time.sleep(.1)
# Stop an earlier manually started bridge only when its command matches.
pidfile=destination/'bridge.pid'
if pidfile.exists():
 try:
  pid=int(pidfile.read_text());args=subprocess.check_output(['ps','-p',str(pid),'-o','args='],text=True).strip()
  if 'grok-notch/Bridge/server.mjs' in args or 'Grok Notch Bridge/server.mjs' in args:
   os.kill(pid,signal.SIGTERM)
   for _ in range(50):
    try:os.kill(pid,0)
    except ProcessLookupError:break
    time.sleep(.1)
 except (ValueError,ProcessLookupError,subprocess.CalledProcessError):pass
for name in ['server.mjs','runtime.mjs']:
 shutil.copy2(source/name,destination/name)
log=home/'Library/Logs/GrokNotchBridge.log'
log.parent.mkdir(parents=True,exist_ok=True)
plist.parent.mkdir(parents=True,exist_ok=True)
configuration={'Label':label,'ProgramArguments':[str(node),str(destination/'server.mjs')],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'StandardOutPath':str(log),'StandardErrorPath':str(log),'WorkingDirectory':str(destination)}
with plist.open('wb')as handle:plistlib.dump(configuration,handle)
os.chmod(plist,0o600)
for attempt in range(12):
 result=subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],capture_output=True,text=True)
 if result.returncode==0:break
 time.sleep(.25)
if result.returncode:raise SystemExit(result.stderr)
print('Bridge installé et démarré pour cette session utilisateur.')
