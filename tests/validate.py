"""Offline package validation. Does not start any GPU process."""
from pathlib import Path
import os
import tempfile
import subprocess
import shutil

root = Path(__file__).resolve().parents[1]
server = root / 'Server'
ui = root / 'DGGS_Control_Center.ps1'
setup = root / 'Windows/Setup-DGGS.ps1'
for p in [ui, setup, root/'README.md', root/'Open_DGGS_Control_Center.cmd', root/'Open_DGGS_Control_Center.vbs']:
    assert p.is_file(), p
for p in server.glob('*.sh'):
    subprocess.run(['bash', '-n', str(p)], check=True)

# Lightweight lexical balance checker for our PowerShell sources. It is not a
# replacement for PowerShell's own parser on Windows.
def check_balancing(src):
    stack = []
    matches = {')':'(', ']':'[', '}':'{'}
    row = 1
    state = 'code'
    i = 0
    while i < len(src):
        c = src[i]
        if c == '\n':
            row += 1
            if state == 'comment': state = 'code'
            i += 1
            continue
        if state == 'comment':
            i += 1
            continue
        if state == 'single':
            if c == "'":
                if i + 1 < len(src) and src[i+1] == "'": i += 2; continue
                state = 'code'
            i += 1
            continue
        if state == 'double':
            if c == '`': i += 2; continue
            if c == '"': state = 'code'
            i += 1
            continue
        if c == '#': state = 'comment'; i += 1; continue
        if c == "'": state = 'single'; i += 1; continue
        if c == '"': state = 'double'; i += 1; continue
        if c == '`': i += 2; continue
        if c in '([{': stack.append((c,row))
        elif c in ')]}':
            assert stack and stack[-1][0] == matches[c], (row,c,stack[-1] if stack else '')
            stack.pop()
        i += 1
    assert not stack, stack
    assert state == 'code', state

check_balancing(ui.read_text())
check_balancing(setup.read_text())
# Regression guard: Windows PowerShell 5.1 must not abort on the expected
# unauthorized-key check before attempting interactive password login.
setup_src = setup.read_text()
assert "& ssh.exe -T -i $KeyFile -o IdentitiesOnly=yes -o BatchMode=yes" in setup_src
assert "if (-not $keyAlreadyAuthorized)" in setup_src
assert 'Get-Content -LiteralPath "$KeyFile.pub"' in setup_src
assert setup_src.count("$ErrorActionPreference = 'Continue'") >= 2
assert 'SSH will ask for your university server login password once.' in setup_src
s = ui.read_text()
for token in [
    'Start-GPUService', 'Start-Tunnel', 'Start-WebUI', 'Open-WebUIBrowser',
    'Start-ModelApiJob', 'Stop-Models', 'Get-GPUStatus', 'Do-StartEverything',
    'systemctl --user stop dggs-llama.service', "Start-ModelApiJob 'load'",
    'Stop-Process -Id ([int]$process.ProcessId)',
    '192.0.2.', # exclude example placeholder value below, checked separately
]:
    if token == '192.0.2.':
        assert token not in s
    else:
        assert token in s, token
script_no_comments = '\n'.join(x for x in s.splitlines() if not x.lstrip().startswith('#'))
assert 'pkill' not in script_no_comments and 'killall' not in script_no_comments and 'sudo ' not in script_no_comments
assert 'Stop-Models' in s and "Start-Job -ArgumentList" in s
router_text = (server/'run-router.sh').read_text()
for token in ['--models-preset', '--models-max 1', '--ctx-size 32768', '--sleep-idle-seconds 900', '--host 127.0.0.1', '--port 8080']:
    assert token in router_text

with tempfile.TemporaryDirectory(prefix='dggs-ui-test-') as t:
    home = Path(t)/'home'
    exe = home/'dggs-ai/llama.cpp/build-mi100-rocm641/bin/llama-server'
    exe.parent.mkdir(parents=True)
    exe.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n')
    exe.chmod(0o755)
    model = home/'dggs-ai/models/flashnext/Qwen3.8-Flash-Next-IQ4_XS'
    model.mkdir(parents=True)
    for i in range(1,4):
        (model/f'Qwen3.8-Flash-Next-IQ4_XS-{i:05d}-of-00003.gguf').touch()
    launch = home/'dggs-ai/launcher'
    launch.mkdir(parents=True)
    shutil.copy2(server/'run-router.sh', launch/'run-router.sh')
    (launch/'run-router.sh').chmod(0o755)
    bins = Path(t)/'bin'
    bins.mkdir()
    ctl = bins/'systemctl'
    ctl.write_text('#!/bin/sh\nexit 0\n')
    ctl.chmod(0o755)
    env = dict(os.environ,HOME=str(home),PATH=str(bins)+':'+os.environ['PATH'])
    subprocess.run(['bash',str(server/'install-router.sh')],env=env,check=True,capture_output=True,text=True)
    cfg = (home/'.config/dggs-ai/models.ini').read_text()
    assert '[dggs-main]' in cfg and '[dggs-uncensored]' not in cfg
    unit = (home/'.config/systemd/user/dggs-llama.service').read_text()
    assert 'KillMode=control-group' in unit
    assert 'ExecStart=%h/dggs-ai/launcher/run-router.sh' in unit
    assert 'systemctl --user enable' not in (server/'install-router.sh').read_text()
    output = subprocess.run(['bash',str(launch/'run-router.sh')],env=env,capture_output=True,text=True,check=True).stdout
    assert '--models-max\n1\n' in output and '--ctx-size\n32768\n' in output
    extra = home/'dggs-ai/models/qwen35-uncensored/Qwen3.5-122B-A10B-Uncensored-HauhauCS-Aggressive-Q5_K_M.gguf'
    extra.parent.mkdir(parents=True)
    extra.touch()
    subprocess.run(['bash',str(server/'install-router.sh')],env=env,check=True,capture_output=True,text=True)
    cfg = (home/'.config/dggs-ai/models.ini').read_text()
    assert '[dggs-main]' in cfg and '[dggs-uncensored]' in cfg
print('PASS: package inventory, PowerShell delimiter checks, shell syntax, safety rules, mocked service installation with one/two models, router arguments.')
