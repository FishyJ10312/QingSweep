#!/usr/bin/env python3
"""Drive actual mouse events inside the private native fixture app, never other apps."""
import fcntl
import json
import os
import pathlib
import sqlite3
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
FOLDER = ROOT / '.build/native16'
FOLDER.mkdir(parents=True, exist_ok=True)
LOCK = (FOLDER / 'run.lock').open('w')
fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
(FOLDER / 'status.json').unlink(missing_ok=True)
LOG = []
OUTPUT = (ROOT / '.build/native16-final.log').open('w')
PROCESS = subprocess.Popen([str(ROOT / '.build/native-workflow16')], cwd=ROOT, stdout=OUTPUT, stderr=subprocess.STDOUT)


def state():
    try:
        data = json.loads((FOLDER / 'status.json').read_text())
        return data if data.get('pid') == PROCESS.pid else {}
    except (OSError, ValueError):
        return {}


def wait(key, value, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if PROCESS.poll() is not None:
            raise AssertionError('Native fixture exited unexpectedly')
        if state().get(key) == value:
            return state()
        time.sleep(.1)
    raise AssertionError(f'{key} did not become {value}: {state()}')


def send(action, **values):
    with (FOLDER / 'commands.jsonl').open('a') as output:
        output.write(json.dumps({'action': action, **values}) + '\n')
    expected = len((FOLDER / 'commands.jsonl').read_text().splitlines())
    until = time.monotonic() + 15
    while time.monotonic() < until:
        if state().get('processed', -1) >= expected:
            return state()
        time.sleep(.1)
    raise AssertionError('Native command timed out: ' + action)


def click(x, y, panel=False):
    return send('click', x=x, y=y, panel=panel)


def check(condition, label):
    assert condition, label
    LOG.append(label)
    (FOLDER / 'walkthrough-checks.json').write_text(json.dumps(LOG, ensure_ascii=False, indent=2))
    print('PASS:', label, flush=True)


def close_result():
    panels = [w for w in state()['windows'] if not w['title']]
    assert panels, 'No result panel'
    panel = panels[0]
    click(panel['width'] / 2, panel['height'] - 29, panel=True)
    wait('message', '')


try:
    wait('pid', PROCESS.pid, timeout=30)
    click(76, 188)
    check(state()['section'] == '清理', 'native sidebar opens cleanup')
    click(884, 475)
    wait('scanning', False)
    check(state()['items'] == 3, 'native scan lists every fixture file')
    check(state()['selected'] == [], 'media and projects start deselected')
    send('snapshot', name='final01-scanned')
    click(1260, 247)
    check(len(state()['selected']) == 1, 'recommendations select only the old installer')
    click(300, 355)
    check(len(state()['selected']) == 1, 'switching categories preserves selection without selecting media')
    send('snapshot', name='final02-manual')
    click(1308, 395)
    click(1266, 315)
    wait('preview', '素材.png')
    check(len(state()['selected']) == 1, 'native Quick Look does not select media')
    send('snapshot', name='final03-preview')
    # Quick Look becomes visible after the binding changes; wait for its native panel.
    until = time.monotonic() + 10
    while time.monotonic() < until and len(state()['windows']) < 2:
        time.sleep(.1)
    for attempt in range(4):
        if not state()['preview']:
            break
        click(18, 19, panel=True)
        time.sleep(.35)
    wait('preview', '')
    click(457, 147)
    check(state()['scope'] == '需自行确认', 'Back returns from file group')
    click(1260, 247)
    check(len(state()['selected']) == 3, 'manual select-all requires an explicit click')
    click(457, 319)
    check(len(state()['selected']) == 2 and not any(x.endswith('edit.drp') for x in state()['selected']), 'cancelling the project preserves other choices')
    click(490, 727)
    wait('showingReview', True)
    check(state()['review'] == 2, 'review includes all remaining selected scopes')
    send('snapshot', name='final04-review')
    click(606, 501, panel=True)
    wait('manualConfirmation', True)
    check(state()['history'] == 0, 'first confirmation does not move creative files')
    send('snapshot', name='final05-second-confirmation')
    click(36, 416, panel=True)
    check(state()['acknowledged'], 'second confirmation requires acknowledgement')
    click(586, 463, panel=True)
    wait('mutating', False)
    wait('history', 2)
    check(state()['receipts'] == 1, 'actual Trash move creates one batch for two fixture files')
    close_result()
    click(76, 318)
    wait('recoverable', 2)
    check(state()['section'] == '清理记录', 'history exposes the recoverable batch')
    send('snapshot', name='final07-batch-history')
    click(1251, 207)
    wait('mutating', False)
    wait('history', 0)
    home = pathlib.Path(state()['fixture'])
    check((home / 'Downloads/IINA.v1.0.0.dmg').exists() and (home / 'Downloads/素材.png').exists(), 'restore-this-batch returns both actual fixture files')
    check((home / 'Downloads/Projects/edit.drp').exists(), 'deselected project remains untouched')
    check(state()['receipts'] == 1 and not state()['selected'], 'receipt remains after recovery and no file is selected')
    close_result()
    send('snapshot', name='final08-batch-restored')
    send('change')
    click(76, 230)
    click(1220, 84)
    wait('analyzing', False)
    check(state()['storagePending'] == 0 and state()['storageStatus'] == '更新完成', 'incremental update finishes with the correct status')
    index = sqlite3.connect(f'file:{home / "storage.sqlite"}?mode=ro', uri=True)
    check(index.execute('select own_bytes from nodes where path=?', (str(home / 'Movies/group/added.mov'),)).fetchone()[0] == 16384, 'native update indexes the added file')
    visited_before = json.loads(index.execute("select value from metadata where key='scan'").fetchone()[0])['visited']
    send('snapshot', name='final10-incremental-update')
    click(1220, 84)
    wait('analyzing', False)
    visited_after = json.loads(index.execute("select value from metadata where key='scan'").fetchone()[0])['visited']
    check(visited_after == visited_before and state()['storageStatus'] == '没有需要更新的文件夹', 'unchanged update reuses the index without recursive scanning')
    index.close()
    send('snapshot', name='final11-unchanged-update')
    print(f'{len(LOG)} native UI assertions passed; every moved fixture was restored.', flush=True)
finally:
    if PROCESS.poll() is None:
        with (FOLDER / 'commands.jsonl').open('a') as output:
            output.write(json.dumps({'action': 'stop'}) + '\n')
        try:
            PROCESS.wait(timeout=8)
        except subprocess.TimeoutExpired:
            PROCESS.terminate()
            PROCESS.wait(timeout=5)
    OUTPUT.close()
