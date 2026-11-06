#!/usr/bin/env python3
"""Source-only assertions, not an Objective-C compiler or device validation."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = Path('/var/minis/shared/github/MemTrimBall')
assert ROOT == EXPECTED, f'Unexpected project root: {ROOT}'
checks = []

def check(name, condition):
    if not condition:
        raise AssertionError(name)
    checks.append(name)

required = ['MTBBall.m', 'MTBPreferences.m', 'MTBEdgeDock.h', 'MTBEdgeDock.m',
            'Makefile', 'MTBBall.plist', 'MTBPreferences.plist', 'control',
            'README.md', '.gitignore', 'VERSION', '.github/workflows/build.yml']
check('All required source/project files exist', all((ROOT / x).is_file() for x in required))
control = dict(line.split(': ', 1) for line in (ROOT/'control').read_text().splitlines())
check('VERSION/control remain 0.0.1', (ROOT/'VERSION').read_text().strip() == control['Version'] == '0.0.1')
check('Independent package identity and original dependency', control['Package'] == 'com.knight914.memtrimball' and 'com.crctdd.memtrim' in control['Depends'])
for name, bundle in [('MTBBall', 'com.apple.springboard'), ('MTBPreferences', 'com.apple.Preferences')]:
    data = plistlib.loads((ROOT/(name+'.plist')).read_bytes())
    check(name+' filter exact bundle only', data == {'Filter': {'Bundles': [bundle]}})
ball = (ROOT/'MTBBall.m').read_text()
prefs = (ROOT/'MTBPreferences.m').read_text()
dock = (ROOT/'MTBEdgeDock.m').read_text()
check('Common domain and preference notification', all(x in ball and x in prefs for x in ['com.knight914.memtrimball', 'com.knight914.memtrimball.preferences-changed']))
check('SpringBoard and Settings runtime guards', 'com.apple.springboard' in ball and 'com.apple.Preferences' in prefs)
check('Strict boolean preferences/default off', 'CFBooleanGetTypeID()' in ball and 'CFBooleanGetTypeID()' in prefs and '@NO' in prefs)
check('Only declared request literals', set(re.findall(r'com\.crctdd\.memtrim\.request\.\w+', ball)) == {'com.crctdd.memtrim.request.normal', 'com.crctdd.memtrim.request.deep'})
check('Single notify_post send funnel', len(re.findall(r'\bnotify_post\s*\(', ball)) == 1)
check('Exactly one call site per request type', ball.count('[self sendRequest:MTBNormalRequest]') == 1 and ball.count('[self sendRequest:MTBDeepRequest]') == 1)
check('No key-window API call', not re.search(r'\[\s*[^\]\n]+\s+(?:makeKeyWindow|makeKeyAndVisible)\s*\]', ball))
check('No repeat timers/display links/polling', not re.search(r'NSTimer|CADisplayLink|dispatch_source_create|scheduledTimer|while\s*\(', ball))
check('One-shot feedback only', ball.count('dispatch_after(') == 1)
check('Event registration and fail-closed states', 'notify_register_dispatch' in ball and 'lock == 0 && display == 1' in ball and 'MTBReadUILocked(&locked)' in ball)
check('Launch and late-injection paths present', 'UIApplicationDidFinishLaunchingNotification' in ball and 'hasSystemWindow' in ball)
check('Gesture failure ordering present', '[self.tap requireGestureRecognizerToFail:self.pan]' in ball and '[self.tap requireGestureRecognizerToFail:self.hold]' in ball)
check('Independent position keys do not write Enabled', 'CFSTR("Enabled")' not in dock)
workflow = (ROOT/'.github/workflows/build.yml').read_text()
check('Workflow dispatch-only source', '  workflow_dispatch:' in workflow and not re.search(r'^  (?:push|pull_request|schedule|workflow_call):', workflow, re.M))
check('Workflow is unconditionally blocked with dependent matrix', 'needs: preflight' in workflow and workflow.count('exit 1') == 2 and 'continue-on-error:' not in workflow and 'always()' not in workflow.replace('# Do not add always(), continue-on-error or an input-based gate override.', ''))
check('Official toolchain matrix URLs only', 'https://github.com/theos/theos' in workflow and 'https://github.com/roothide/theos' in workflow)
check('macOS jobs and read-only permissions', workflow.count('runs-on: macos-14') == 2 and 'contents: read' in workflow)
check('No executable checkout/build/upload in draft', not re.search(r'^\s*(uses:|git clone|make clean|curl |wget )', workflow, re.M))
# BaseLoader avoids YAML 1.1 interpreting GitHub's `on` key as boolean.
try:
    import yaml
except ImportError:
    print('SKIP: optional PyYAML structure parser is unavailable')
else:
    parsed = yaml.load(workflow, Loader=yaml.BaseLoader)
    check('Parsed YAML has only workflow_dispatch', set(parsed['on']) == {'workflow_dispatch'})
    check('Parsed YAML matrix depends on failing preflight', parsed['jobs']['draft-build']['needs'] == 'preflight' and parsed['jobs']['preflight']['steps'][0]['run'].strip().endswith('exit 1'))
    check('Parsed YAML both official environments', [x['environment'] for x in parsed['jobs']['draft-build']['strategy']['matrix']['include']] == ['rootless', 'roothide'])
check('No hardcoded jailbreak root', '/var/jb' not in ball+prefs+dock)
for path in [ROOT/x for x in required] + [Path(__file__)]:
    check('No conflict markers: '+str(path.relative_to(ROOT)), not re.search(r'^(<<<<<<< |=======\s*$|>>>>>>> )', path.read_text(), re.M))
print('\n'.join('PASS: '+x for x in checks))
print(f'PASS: {len(checks)} source-only assertions. No compilation, git, network, device or installation operations.')
print('LIMIT: textual assertions do not validate Objective-C syntax/ABI, Theos builds, UIKit runtime, Darwin event publishers or YAML engine behavior.')
