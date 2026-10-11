#!/usr/bin/env python3
"""Record the actual checkout, rather than assuming a PR head was tested."""
import json
import os
from pathlib import Path
import subprocess

def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()

if __name__ == '__main__':
    Path('gate-receipt.json').write_text(json.dumps({
        'schemaVersion': 1, 'repository': os.environ['GITHUB_REPOSITORY'],
        'runId': int(os.environ['GITHUB_RUN_ID']), 'runAttempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
        'job': os.environ['GITHUB_JOB'], 'event': os.environ['GITHUB_EVENT_NAME'],
        'workflowRef': os.environ['GITHUB_WORKFLOW_REF'],
        'checkoutCommit': git('rev-parse', 'HEAD'), 'sourceTree': git('rev-parse', 'HEAD^{tree}'),
        'runnerEnvironment': os.environ['RUNNER_ENVIRONMENT'],
    }, indent=2) + '\n')
