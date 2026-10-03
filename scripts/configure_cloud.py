"""Inject public backend configuration before XcodeGen; never print keys."""
import base64
import json
import os
from pathlib import Path
from urllib.parse import urlparse
import yaml


def configure():
    path = Path('ios-app/project.yml')
    project = yaml.safe_load(path.read_text(encoding='utf-8'))
    settings = project['settings']['base']
    url = os.environ.get('SUPABASE_URL', '').strip()
    key = os.environ.get('SUPABASE_PUBLISHABLE_KEY', '').strip()
    if bool(url) != bool(key):
        raise ValueError('Set both Supabase public configuration variables, or neither.')
    if url:
        if urlparse(url).scheme != 'https' or not urlparse(url).hostname:
            raise ValueError('SUPABASE_URL must be an HTTPS URL.')
        if not key.startswith('sb_publishable_'):
            try:
                encoded = key.split('.')[1]
                payload = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
            except (IndexError, ValueError) as exc:
                raise ValueError('Use a publishable or legacy anon key only.') from exc
            if payload.get('role') != 'anon':
                raise ValueError('Privileged Supabase keys must never be included in an app.')
        settings['SUPABASE_URL'] = url
        settings['SUPABASE_PUBLISHABLE_KEY'] = key
    google = os.environ.get('GOOGLE_IOS_CLIENT_ID', '').strip()
    if google:
        if not google.endswith('.apps.googleusercontent.com'):
            raise ValueError('Invalid legacy Google iOS client ID.')
        settings['GOOGLE_CLIENT_ID'] = google
        settings['GOOGLE_REVERSED_CLIENT_ID'] = 'com.googleusercontent.apps.' + google.removesuffix('.apps.googleusercontent.com')
    path.write_text(yaml.safe_dump(project, allow_unicode=True, sort_keys=False), encoding='utf-8')
    print('Public cloud configuration applied.' if url else 'Offline build: Supabase is not configured.')


if __name__ == '__main__':
    configure()
